// 行级 TOML 编辑：复刻 cc-switch 写入 config.toml 的关键行为
// （experimental_bearer_token 注入 + model_catalog_json 字段管理）。
// 只处理 cc-switch 生成的标准形状（[model_providers.<id>]  section 表头）。

/** Codex 保留供应商 id：token 不能进入这些内置表，只能放顶层。 */
const RESERVED_PROVIDER_IDS = new Set([
  "amazon-bedrock",
  "amazon-bedrock-runtime",
  "openai",
  "ollama",
  "lmstudio",
]);

const CC_SWITCH_CATALOG_FILENAME = "cc-switch-model-catalog.json";

function isCommentOrBlank(line) {
  const t = line.trim();
  return t === "" || t.startsWith("#");
}

/** 匹配顶层键（第一个 section 之前、行首无缩进、非注释）。 */
function topLevelKeyLine(lines, key) {
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (isCommentOrBlank(line)) continue;
    if (/^\s*\[/.test(line)) break; // 进入 section 域
    const m = line.match(/^([A-Za-z0-9_-]+)\s*=/);
    if (m && m[1] === key) return i;
  }
  return -1;
}

/** 读取顶层字符串键值。 */
export function readTopLevelString(text, key) {
  const lines = text.split(/\r?\n/);
  const idx = topLevelKeyLine(lines, key);
  if (idx === -1) return null;
  const m = lines[idx].match(/=\s*"((?:[^"\\]|\\.)*)"/);
  return m ? m[1].replace(/\\"/g, '"') : null;
}

/** 当前生效的 model_provider id。 */
export function activeProviderId(text) {
  return readTopLevelString(text, "model_provider");
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** 定位 [model_providers.<id>] section 表头行下标（支持裸键与引号键）。 */
function providerSectionHeader(lines, providerId) {
  const bare = escapeRegExp(providerId);
  const re = new RegExp(
    `^\\s*\\[\\s*model_providers\\s*\\.\\s*(?:"${bare}"|${bare})\\s*\\]\\s*(#.*)?$`,
  );
  for (let i = 0; i < lines.length; i++) {
    if (isCommentOrBlank(lines[i])) continue;
    if (re.test(lines[i])) return i;
  }
  return -1;
}

/** section 主体的结束行（下一个 section 表头，或文件结尾）。 */
function sectionBodyEnd(lines, headerIdx) {
  for (let i = headerIdx + 1; i < lines.length; i++) {
    if (isCommentOrBlank(lines[i])) continue;
    if (/^\s*\[/.test(lines[i])) return i;
  }
  return lines.length;
}

/** section 主体内的键匹配（含子表，如 http_headers.Authorization）。 */
function sectionKeyLines(lines, headerIdx, key) {
  const end = sectionBodyEnd(lines, headerIdx);
  const hits = [];
  const re = new RegExp(`^\\s*("?${escapeRegExp(key)}"?)\\s*=`);
  for (let i = headerIdx + 1; i < end; i++) {
    if (isCommentOrBlank(lines[i])) continue;
    if (re.test(lines[i])) hits.push(i);
  }
  return hits;
}

/** 表内是否声明了自己的鉴权来源（auth/aws/env_key 子表，或 Authorization 头）。 */
function sectionDeclaresAuth(lines, headerIdx) {
  if (sectionKeyLines(lines, headerIdx, "auth").length) return true;
  if (sectionKeyLines(lines, headerIdx, "aws").length) return true;
  if (sectionKeyLines(lines, headerIdx, "env_key").length) return true;

  const end = sectionBodyEnd(lines, headerIdx);
  const requiresOpenaiAuth = (() => {
    const hits = sectionKeyLines(lines, headerIdx, "requires_openai_auth");
    if (!hits.length) return false;
    return /true/.test(lines[hits[0]]);
  })();
  if (requiresOpenaiAuth) return false;

  // http_headers / env_http_headers 子表中的 Authorization（大小写不敏感）
  for (let i = headerIdx + 1; i < end; i++) {
    if (isCommentOrBlank(lines[i])) continue;
    const inHeaderTable =
      /^\s*\[\s*model_providers\s*\./.test(lines[i]) &&
      /(http_headers|env_http_headers)/.test(lines[i]);
    if (inHeaderTable && /^\s*"?authorization"?\s*=/i.test(lines[i])) return true;
    if (/^\s*(http_headers|env_http_headers)\s*=/.test(lines[i]) && /authorization/i.test(lines[i])) {
      return true;
    }
  }
  return false;
}

/**
 * 注入 experimental_bearer_token，规则与 cc-switch 一致：
 * - 供应商表已声明自有鉴权 → 不动
 * - 保留 id 或找不到表 → 放顶层
 * - 否则写入 [model_providers.<id>] 表内
 */
export function injectBearerToken(text, token) {
  if (!text.trim()) {
    throw new Error("第三方供应商的 config 为空，无法写入 bearer token");
  }
  if (!token) return text;

  const lines = text.split(/\r?\n/);
  const providerId = activeProviderId(text);

  const putTopLevel = () => {
    const idx = topLevelKeyLine(lines, "experimental_bearer_token");
    const assignment = `experimental_bearer_token = "${token}"`;
    if (idx !== -1) {
      lines[idx] = assignment;
    } else {
      // 插到最后一个顶层键之后（第一个 section 之前）
      let insertAt = lines.length;
      for (let i = 0; i < lines.length; i++) {
        if (!isCommentOrBlank(lines[i]) && /^\s*\[/.test(lines[i])) {
          insertAt = i;
          break;
        }
      }
      // 保持在顶层键块尾部：从 insertAt 往前跳过空行/注释
      let j = insertAt;
      while (j > 0 && isCommentOrBlank(lines[j - 1])) j--;
      lines.splice(j, 0, assignment);
    }
    return lines.join("\n");
  };

  if (!providerId || RESERVED_PROVIDER_IDS.has(providerId)) {
    return putTopLevel();
  }

  const headerIdx = providerSectionHeader(lines, providerId);
  if (headerIdx === -1) {
    // 找不到供应商表（可能是 inline table 形状）：退回顶层
    return putTopLevel();
  }
  if (sectionDeclaresAuth(lines, headerIdx)) {
    return text; // 表已自有鉴权，保持原样
  }

  const existing = sectionKeyLines(lines, headerIdx, "experimental_bearer_token");
  if (existing.length) {
    lines[existing[0]] = `experimental_bearer_token = "${token}"`;
    return lines.join("\n");
  }

  // cc-switch 用 toml_edit 的 table.insert：键追加在表末尾（保持与原生写入一致）
  const end = sectionBodyEnd(lines, headerIdx);
  let insertAt = end;
  while (insertAt > headerIdx + 1 && isCommentOrBlank(lines[insertAt - 1])) insertAt--;
  lines.splice(insertAt, 0, `experimental_bearer_token = "${token}"`);
  return lines.join("\n");
}

/**
 * 管理顶层 model_catalog_json 字段：
 * - on=true  且字段缺失 → 注入（已存在且非 cc-switch 文件则不动）
 * - on=false 且字段指向 cc-switch 文件 → 移除
 */
export function setCatalogJsonField(text, on) {
  const lines = text.split(/\r?\n/);
  const idx = topLevelKeyLine(lines, "model_catalog_json");
  const currentValue = (() => {
    if (idx === -1) return null;
    const m = lines[idx].match(/=\s*"((?:[^"\\]|\\.)*)"/);
    return m ? m[1] : null;
  })();

  if (on) {
    if (idx !== -1) {
      const owned = currentValue === CC_SWITCH_CATALOG_FILENAME;
      if (owned || currentValue === null) {
        lines[idx] = `model_catalog_json = "${CC_SWITCH_CATALOG_FILENAME}"`;
        return lines.join("\n");
      }
      return text; // 用户自管的外部 catalog 文件，不动
    }
    let insertAt = lines.length;
    for (let i = 0; i < lines.length; i++) {
      if (!isCommentOrBlank(lines[i]) && /^\s*\[/.test(lines[i])) {
        insertAt = i;
        break;
      }
    }
    let j = insertAt;
    while (j > 0 && isCommentOrBlank(lines[j - 1])) j--;
    lines.splice(j, 0, `model_catalog_json = "${CC_SWITCH_CATALOG_FILENAME}"`);
    return lines.join("\n");
  }

  if (idx !== -1 && currentValue === CC_SWITCH_CATALOG_FILENAME) {
    lines.splice(idx, 1);
    return lines.join("\n");
  }
  return text;
}
