// cc-switch "通用配置片段"（common_config_codex）的合并/剥离。
// 行级实现：支持顶层键与 [section] / [a.b.c] 表；遇到无法安全处理的结构会抛错，
// 由调用方降级处理（提示改用 cc-switch 界面切换）。

function isBlankOrComment(line) {
  const t = line.trim();
  return t === "" || t.startsWith("#");
}

export function sectionPathOf(line) {
  const m = line.match(/^\s*\[([^\]]+)\]\s*(#.*)?$/);
  if (!m) return null;
  const inner = m[1].trim();
  // 不支持数组表 [[...]]
  if (inner.startsWith("[")) return null;
  const parts = [];
  let buf = "";
  let inQuote = false;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (inQuote) {
      if (ch === "\\" && i + 1 < inner.length) {
        buf += inner[i + 1];
        i++;
      } else if (ch === '"') {
        inQuote = false;
      } else {
        buf += ch;
      }
      continue;
    }
    if (ch === '"') {
      inQuote = true;
    } else if (ch === ".") {
      parts.push(buf.trim());
      buf = "";
    } else {
      buf += ch;
    }
  }
  parts.push(buf.trim());
  return parts.filter(Boolean).length ? parts.filter(Boolean) : null;
}

export function keyOf(line) {
  const m = line.match(/^\s*("(?:[^"\\]|\\.)*"|[A-Za-z0-9_-]+)\s*=/);
  if (!m) return null;
  return m[1].replace(/^"(.*)"$/, "$1");
}

/** 判断单行赋值是否括号/引号闭合；不闭合则说明是多行值。 */
function isBalanced(line) {
  let inBasic = false;
  let inLiteral = false;
  let depth = 0;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inBasic) {
      if (ch === "\\") i++;
      else if (ch === '"') inBasic = false;
      continue;
    }
    if (inLiteral) {
      if (ch === "'") inLiteral = false;
      continue;
    }
    if (ch === "#") break;
    if (ch === '"') inBasic = true;
    else if (ch === "'") inLiteral = true;
    else if (ch === "[" || ch === "{") depth++;
    else if (ch === "]" || ch === "}") depth--;
  }
  return !inBasic && !inLiteral && depth === 0;
}

/**
 * 解析 TOML 文本为块结构。
 * @returns {{top: Array<{key:string,line:string,idx:number}>, sections: Array<{path:string[],header:string,entries:Array<{key:string,line:string,idx:number}>,headerIdx:number}>}}
 */
export function parseBlocks(text) {
  const lines = text.split(/\r?\n/);
  const top = [];
  const sections = [];
  let current = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (isBlankOrComment(line)) continue;

    const path = sectionPathOf(line);
    if (path) {
      current = { path, header: line, entries: [], headerIdx: i };
      sections.push(current);
      continue;
    }

    const key = keyOf(line);
    if (key === null) {
      throw new Error(`无法解析的 TOML 行: ${line.trim().slice(0, 80)}`);
    }
    if (!isBalanced(line)) {
      throw new Error(`不支持多行 TOML 值: ${line.trim().slice(0, 80)}`);
    }
    const entry = { key, line, idx: i };
    if (current) current.entries.push(entry);
    else top.push(entry);
  }
  return { top, sections };
}

function findSection(lines, path) {
  for (let i = 0; i < lines.length; i++) {
    const p = sectionPathOf(lines[i]);
    if (p && p.join(".") === path.join(".")) return i;
  }
  return -1;
}

function sectionEnd(lines, headerIdx) {
  for (let i = headerIdx + 1; i < lines.length; i++) {
    if (isBlankOrComment(lines[i])) continue;
    if (sectionPathOf(lines[i])) return i;
  }
  return lines.length;
}

/** 把 snippet 合并进目标 config 文本（语义同 cc-switch：递归 upsert，标量覆盖）。 */
export function mergeCommonConfig(configText, snippetText) {
  if (!snippetText.trim()) return configText;
  const { top, sections } = parseBlocks(snippetText);
  const lines = configText.split(/\r?\n/);

  // 顶层键：存在则替换，否则插入到第一个 section 之前
  for (const entry of top) {
    const idx = lines.findIndex(
      (l, i) =>
        !isBlankOrComment(l) &&
        keyOf(l) === entry.key &&
        !lines.slice(0, i).some((prev) => sectionPathOf(prev)),
    );
    if (idx !== -1) {
      lines[idx] = entry.line;
    } else {
      let insertAt = lines.length;
      for (let i = 0; i < lines.length; i++) {
        if (!isBlankOrComment(lines[i]) && sectionPathOf(lines[i])) {
          insertAt = i;
          break;
        }
      }
      let j = insertAt;
      while (j > 0 && isBlankOrComment(lines[j - 1])) j--;
      lines.splice(j, 0, entry.line);
    }
  }

  // 表：存在则合并条目；不存在则插到"上一个已处理 section"之后（保持原文件布局）
  let prevPlacedPath = null;
  for (const section of sections) {
    const headerIdx = findSection(lines, section.path);
    if (headerIdx === -1) {
      const anchor = prevPlacedPath ? findSection(lines, prevPlacedPath) : -1;
      const insertAt =
        anchor !== -1 ? sectionEnd(lines, anchor) : firstSectionIndex(lines);
      const block = [...section.entries.map((e) => e.line)];
      const beforeBlank = insertAt > 0 && lines[insertAt - 1].trim() !== "" ? [""] : [];
      const afterBlank = insertAt < lines.length && lines[insertAt].trim() !== "" ? [""] : [];
      lines.splice(insertAt, 0, ...beforeBlank, section.header, ...block, ...afterBlank);
    } else {
      const end = sectionEnd(lines, headerIdx);
      const missing = [];
      for (const entry of section.entries) {
        const existing = lines
          .slice(headerIdx + 1, end)
          .findIndex((l) => !isBlankOrComment(l) && keyOf(l) === entry.key);
        if (existing !== -1) lines[headerIdx + 1 + existing] = entry.line;
        else missing.push(entry.line);
      }
      if (missing.length) {
        // 插到节内最后一个非空行之后（保持原有空行分隔）
        let insertAt = end;
        while (insertAt > headerIdx + 1 && isBlankOrComment(lines[insertAt - 1])) insertAt--;
        lines.splice(insertAt, 0, ...missing);
      }
    }
    prevPlacedPath = section.path;
  }

  return lines.join("\n");
}

/** 目标文本中第一个 section 表头的行号（没有则返回文件末尾）。 */
function firstSectionIndex(lines) {
  for (let i = 0; i < lines.length; i++) {
    if (!isBlankOrComment(lines[i]) && sectionPathOf(lines[i])) return i;
  }
  return lines.length;
}

/** 从 config 文本剥离 snippet（语义同 cc-switch：标量相等则删除，空表删除表头）。 */export function removeCommonConfig(configText, snippetText) {
  if (!snippetText.trim()) return configText;
  const { top, sections } = parseBlocks(snippetText);
  const lines = configText.split(/\r?\n/);
  const toRemove = new Set();

  const topRegionEnd = (() => {
    for (let i = 0; i < lines.length; i++) {
      if (!isBlankOrComment(lines[i]) && sectionPathOf(lines[i])) return i;
    }
    return lines.length;
  })();

  for (const entry of top) {
    for (let i = 0; i < topRegionEnd; i++) {
      if (!isBlankOrComment(lines[i]) && keyOf(lines[i]) === entry.key) {
        toRemove.add(i);
        break;
      }
    }
  }

  for (const section of sections) {
    const headerIdx = findSection(lines, section.path);
    if (headerIdx === -1) continue;
    const end = sectionEnd(lines, headerIdx);
    let removedAny = false;
    for (const entry of section.entries) {
      for (let i = headerIdx + 1; i < end; i++) {
        if (toRemove.has(i) || isBlankOrComment(lines[i])) continue;
        if (keyOf(lines[i]) === entry.key) {
          toRemove.add(i);
          removedAny = true;
          break;
        }
      }
    }
    if (removedAny) {
      const remaining = [];
      for (let i = headerIdx + 1; i < end; i++) {
        if (toRemove.has(i) || isBlankOrComment(lines[i])) continue;
        remaining.push(i);
      }
      if (!remaining.length) toRemove.add(headerIdx);
    }
  }

  return lines.filter((_, i) => !toRemove.has(i)).join("\n");
}

/** 取出赋值语句的右侧原文（用于子集比较）。 */
function valueOf(line) {
  const idx = line.indexOf("=");
  return idx === -1 ? "" : line.slice(idx + 1).trim();
}

/**
 * 判断 snippet 是否已完整包含在 config 中（用于 legacy 供应商的"是否使用通用配置"推断，
 * 对应 cc-switch 的 toml_item_is_subset）。
 */
export function isCommonConfigSubset(configText, snippetText) {
  if (!snippetText.trim()) return false;
  let blocks;
  try {
    blocks = parseBlocks(snippetText);
  } catch {
    return false;
  }
  const target = configText.split(/\r?\n/);

  const topEnd = (() => {
    const idx = target.findIndex((l) => !isBlankOrComment(l) && sectionPathOf(l));
    return idx === -1 ? target.length : idx;
  })();

  const findTopValue = (key) => {
    for (let i = 0; i < topEnd; i++) {
      if (!isBlankOrComment(target[i]) && keyOf(target[i]) === key) return valueOf(target[i]);
    }
    return undefined;
  };

  for (const entry of blocks.top) {
    if (findTopValue(entry.key) !== valueOf(entry.line)) return false;
  }

  for (const section of blocks.sections) {
    const headerIdx = findSection(target, section.path);
    if (headerIdx === -1) return false;
    const end = sectionEnd(target, headerIdx);
    for (const entry of section.entries) {
      let found;
      for (let i = headerIdx + 1; i < end; i++) {
        if (!isBlankOrComment(target[i]) && keyOf(target[i]) === entry.key) {
          found = valueOf(target[i]);
          break;
        }
      }
      if (found !== valueOf(entry.line)) return false;
    }
  }
  return true;
}

/**
 * 从配置文本中抽取指定顶层命名空间的 section（含子表），重建为一段 TOML。
 * 用于把「应用自身写入的界面级配置」从 live 配置继承到目标供应商配置。
 */
export function extractSections(text, namespaces) {
  const lines = text.split(/\r?\n/);
  const out = [];
  let current = null;
  for (const line of lines) {
    const path = sectionPathOf(line);
    if (path) {
      current = namespaces.includes(path[0]) ? { header: line, entries: [] } : null;
      if (current) out.push(current.header);
      continue;
    }
    if (!current) continue;
    if (isBlankOrComment(line)) continue;
    if (keyOf(line) !== null) {
      out.push(line);
      current.entries.push(line);
    }
  }
  return out.length ? `${out.join("\n")}\n` : "";
}
