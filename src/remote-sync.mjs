// 把本机 Codex 的供应商配置同步到远程机器。
// 只替换决定请求去向的字段（模型、model_provider、[model_providers.*] 和目录字段），
// 远程自己的项目路径、桌面设置、notify、MCP 保持不动。
// SSH 登录走本机 ~/.ssh/config（User + IdentityFile），不在这里保存密码。
import { execFile } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { keyOf, sectionPathOf } from "./common-config.mjs";
import { ccSwitchCatalogPath, codexConfigPath } from "./paths.mjs";

const execFileAsync = promisify(execFile);

const SYNC_TOP_KEYS = [
  "model_provider",
  "model",
  "model_reasoning_effort",
  "disable_response_storage",
  "model_catalog_json",
];

const CATALOG_FILENAME = "cc-switch-model-catalog.json";

function hereDir() {
  return path.dirname(fileURLToPath(import.meta.url));
}

export function remotesFilePath() {
  return process.env.CODEX_HOTSWITCH_REMOTES?.trim() || path.join(hereDir(), "remotes.json");
}

/** 用户自己添加的机器，以及内置机器的开关。App 与命令行共用这个文件。 */
export function userRemotesPath() {
  return process.env.CODEX_HOTSWITCH_USER_REMOTES?.trim() || path.join(os.homedir(), ".codex-hotswitch", "remotes.json");
}

function readJson(file) {
  if (!file || !existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

export function normalizeHost(item, builtin = false) {
  if (typeof item === "string") {
    const host = item.trim();
    return host ? { host, label: host, user: null, port: null, identityFile: null, builtin } : null;
  }
  if (!item || typeof item !== "object") return null;
  const host = String(item.host ?? item.hostname ?? "").trim();
  if (!host) return null;
  const port = Number(item.port);
  const user = item.user ? String(item.user).trim() : "";
  const identityFile = item.identityFile ? String(item.identityFile).trim() : "";
  return {
    host,
    label: String(item.label ?? host).trim() || host,
    user: user || null,
    port: Number.isInteger(port) && port > 0 && port < 65536 ? port : null,
    identityFile: identityFile || null,
    builtin,
  };
}

/** 内置列表减去用户关闭的机器，再加上用户添加且启用的机器。同主机不重复。 */
export function mergeRemotes(builtinItems, userData) {
  const disabled = new Set((userData?.disabled ?? []).map((item) => String(item)));
  const merged = [];
  const seen = new Set();
  for (const item of builtinItems) {
    const host = normalizeHost(item, true);
    if (!host || disabled.has(host.host) || seen.has(host.host)) continue;
    merged.push(host);
    seen.add(host.host);
  }
  for (const item of userData?.hosts ?? []) {
    if (item?.enabled === false) continue;
    const host = normalizeHost(item, false);
    if (!host || seen.has(host.host)) continue;
    merged.push(host);
    seen.add(host.host);
  }
  return merged;
}

export function loadRemotes() {
  const builtinData = readJson(remotesFilePath());
  const builtin = Array.isArray(builtinData?.hosts) ? builtinData.hosts : Array.isArray(builtinData) ? builtinData : [];
  const userData = readJson(userRemotesPath()) ?? { disabled: [], hosts: [] };
  return mergeRemotes(builtin, userData);
}

function expandHome(file) {
  if (!file) return file;
  if (file === "~") return os.homedir();
  if (file.startsWith("~/")) return path.join(os.homedir(), file.slice(2));
  return file;
}

function isBlank(line) {
  const t = line.trim();
  return t === "" || t.startsWith("#");
}

function splitToml(text) {
  const lines = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const preamble = [];
  const sections = [];
  let current = null;
  for (const line of lines) {
    const sectionPath = sectionPathOf(line);
    if (sectionPath) {
      current = { path: sectionPath, header: line, body: [] };
      sections.push(current);
      continue;
    }
    if (current) current.body.push(line);
    else preamble.push(line);
  }
  return { preamble, sections };
}

function topAssignments(preamble) {
  const map = new Map();
  for (const line of preamble) {
    if (isBlank(line)) continue;
    const key = keyOf(line);
    if (key) map.set(key, line);
  }
  return map;
}

function baseUrlOf(text) {
  return text.match(/^\s*base_url\s*=\s*"([^"]+)"/m)?.[1] ?? null;
}

/** 只取出界面需要的供应商名、端点和密钥尾号，不返回完整密钥。 */
export function providerSnapshot(text) {
  const providerId = text.match(/^\s*model_provider\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  let section = "";
  if (providerId) {
    const escaped = providerId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = text.match(
      new RegExp(`\\[\\s*model_providers\\s*\\.\\s*(?:"${escaped}"|${escaped})\\s*\\]([\\s\\S]*?)(?=\\n\\s*\\[|$)`),
    );
    section = match?.[1] ?? "";
  }
  const name = section.match(/^\s*name\s*=\s*"([^"]+)"/m)?.[1] ?? providerId;
  const baseUrl = section.match(/base_url\s*=\s*"([^"]+)"/)?.[1] ?? baseUrlOf(text);
  const token = section.match(/experimental_bearer_token\s*=\s*"([^"]*)"/)?.[1] ?? "";
  let host = null;
  try {
    host = baseUrl ? new URL(baseUrl).host : null;
  } catch {
    host = null;
  }
  return {
    providerName: name,
    baseUrl,
    host,
    tokenTail: token.length >= 12 ? token.slice(-8) : null,
  };
}

function ensureTrailingNewline(text) {
  if (!text) return "";
  return text.endsWith("\n") ? text : `${text}\n`;
}

/**
 * 用本机配置里的供应商字段覆盖远程配置，其余 section 原样保留。
 * @returns {{text: string, changed: boolean, baseUrl: string|null, previousBaseUrl: string|null}}
 */
export function applyProviderSlice(remoteText, localText) {
  const local = splitToml(localText);
  const remote = splitToml(remoteText ?? "");
  const localTop = topAssignments(local.preamble);
  const previousBaseUrl = baseUrlOf(remoteText ?? "");

  const preamble = [];
  const seen = new Set();
  for (const line of remote.preamble) {
    const key = isBlank(line) ? null : keyOf(line);
    if (key && SYNC_TOP_KEYS.includes(key)) {
      if (localTop.has(key)) {
        preamble.push(localTop.get(key));
        seen.add(key);
      } else if (key === "model_catalog_json") {
        const current = line.match(/=\s*"([^"]+)"/)?.[1] ?? "";
        if (current === CATALOG_FILENAME || current.endsWith(`/${CATALOG_FILENAME}`)) continue;
        preamble.push(line);
      }
      continue;
    }
    preamble.push(line);
  }

  const missing = SYNC_TOP_KEYS.filter((key) => localTop.has(key) && !seen.has(key)).map((key) => localTop.get(key));
  if (missing.length) {
    let insertAt = preamble.length;
    while (insertAt > 0 && preamble[insertAt - 1].trim() === "") insertAt--;
    const pad = insertAt > 0 && preamble[insertAt - 1].trim() !== "" ? [""] : [];
    preamble.splice(insertAt, 0, ...pad, ...missing);
  }

  const localProviders = local.sections.filter((section) => section.path[0] === "model_providers");
  const sections = [];
  let inserted = false;
  for (const section of remote.sections) {
    if (section.path[0] === "model_providers") {
      if (!inserted) {
        sections.push(...localProviders);
        inserted = true;
      }
      continue;
    }
    sections.push(section);
  }
  if (!inserted) {
    const firstOther = sections.findIndex((section) => section.path[0] !== "model_providers");
    const at = firstOther === -1 ? sections.length : firstOther;
    sections.splice(at, 0, ...localProviders);
  }

  const out = [];
  out.push(...trimEdgeBlank(preamble));
  if (out.length && sections.length && out[out.length - 1].trim() !== "") out.push("");
  for (const section of sections) {
    if (out.length && out[out.length - 1].trim() !== "") out.push("");
    out.push(section.header);
    out.push(...section.body);
  }
  while (out.length && out[out.length - 1].trim() === "") out.pop();
  const text = ensureTrailingNewline(out.join("\n"));
  const previous = ensureTrailingNewline((remoteText ?? "").replace(/\r\n/g, "\n").replace(/\r/g, "\n"));
  return {
    text,
    changed: text !== previous,
    baseUrl: baseUrlOf(text),
    previousBaseUrl,
  };
}

function trimEdgeBlank(lines) {
  const copy = [...lines];
  while (copy.length && copy[0].trim() === "") copy.shift();
  while (copy.length && copy[copy.length - 1].trim() === "") copy.pop();
  return copy;
}

function catalogPayload(localText) {
  const file = localText.match(/^\s*model_catalog_json\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  if (!file) return null;
  if (file !== CATALOG_FILENAME && !file.endsWith(`/${CATALOG_FILENAME}`)) return null;
  const localPath = ccSwitchCatalogPath();
  if (!existsSync(localPath)) return null;
  return { name: CATALOG_FILENAME, content: readFileSync(localPath) };
}

function emptyHost(entry, error) {
  return {
    host: entry.host,
    label: entry.label,
    ok: false,
    changed: false,
    baseUrl: null,
    previousBaseUrl: null,
    providerName: null,
    tokenTail: null,
    restarted: 0,
    error,
  };
}

async function readRemoteConfig(entry) {
  const { stdout } = await execFileAsync(
    "ssh",
    sshArgs(
      entry,
      [
        "import base64, pathlib, sys",
        "p = pathlib.Path.home() / '.codex' / 'config.toml'",
        "data = p.read_bytes() if p.exists() else b''",
        "sys.stdout.write('CODEX_CFG_B64:' + base64.b64encode(data).decode() + '\\n')",
      ].join("\n"),
    ),
    { encoding: "utf8", timeout: 20000, maxBuffer: 8 * 1024 * 1024 },
  );
  const encoded = stdout.split("\n").map((item) => item.trim()).find((item) => item.startsWith("CODEX_CFG_B64:"));
  if (!encoded) throw new Error(stdout.trim().slice(-180) || "远程没有返回配置");
  return Buffer.from(encoded.slice("CODEX_CFG_B64:".length), "base64").toString("utf8");
}

export function sshArgs(entry, program) {
  const payload = Buffer.from(program, "utf8").toString("base64");
  const args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12"];
  if (entry.port) args.push("-p", String(entry.port));
  if (entry.identityFile) {
    args.push("-i", expandHome(entry.identityFile), "-o", "IdentitiesOnly=yes");
  }
  const target = entry.user ? `${entry.user}@${entry.host}` : entry.host;
  args.push(target, `python3 -c "import base64; exec(base64.b64decode('${payload}'))"`);
  return args;
}

function pyLiteral(value) {
  if (value == null) return "None";
  if (typeof value === "boolean") return value ? "True" : "False";
  return JSON.stringify(value);
}

function remoteProgram({ configB64, catalogB64, catalogName, dryRun }) {
  return `
import base64, json, os, pathlib, re, signal, subprocess, time
cfg_bytes = base64.b64decode(${JSON.stringify(configB64)})
catalog_b64 = ${pyLiteral(catalogB64)}
catalog_name = ${pyLiteral(catalogName)}
dry = ${dryRun ? "True" : "False"}
home = pathlib.Path.home() / ".codex"
cfg = home / "config.toml"
previous = cfg.read_text(encoding="utf-8") if cfg.exists() else ""
new_text = cfg_bytes.decode("utf-8")
changed = previous.replace("\\r\\n", "\\n").replace("\\r", "\\n") != new_text
old_url = None
m = re.search(r'^\\s*base_url\\s*=\\s*"([^"]+)"', previous, re.M)
if m:
    old_url = m.group(1)
restarted = 0
if changed and not dry:
    home.mkdir(parents=True, exist_ok=True)
    if cfg.exists():
        stamp = time.strftime("%Y%m%d_%H%M%S")
        cfg.with_name(cfg.name + ".bak_" + stamp).write_bytes(cfg.read_bytes())
    tmp = cfg.with_name(cfg.name + ".tmp")
    tmp.write_text(new_text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(cfg)
    if catalog_b64 and catalog_name:
        data = base64.b64decode(catalog_b64)
        target = home / catalog_name
        target.write_bytes(data)
        os.chmod(target, 0o600)
if not dry:
    me = os.environ.get("USER") or ""
    try:
        listing = subprocess.check_output(["ps", "-u", me, "-o", "pid=,args="], text=True)
    except Exception:
        listing = ""
    pids = []
    for line in listing.splitlines():
        line = line.strip()
        if not line:
            continue
        pid_s, _, args = line.partition(" ")
        if "app-server" in args and re.search(r"(^|[\\s/])codex(\\s|$)", args):
            try:
                pids.append(int(pid_s))
            except ValueError:
                pass
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.time() + 3
    alive = list(pids)
    while alive and time.time() < deadline:
        time.sleep(0.2)
        still = []
        for pid in alive:
            try:
                os.kill(pid, 0)
                still.append(pid)
            except ProcessLookupError:
                pass
        alive = still
    for pid in alive:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    restarted = len(pids)
print("CODEX_SYNC_JSON:" + json.dumps({"changed": changed, "restarted": restarted, "previousBaseUrl": old_url, "dryRun": dry}))
`;
}

async function pushHost(entry, content, catalog, dryRun) {
  const catalogB64 = catalog ? catalog.content.toString("base64") : null;
  const program = remoteProgram({
    configB64: Buffer.from(content, "utf8").toString("base64"),
    catalogB64,
    catalogName: catalog?.name ?? null,
    dryRun,
  });
  try {
    const { stdout } = await execFileAsync("ssh", sshArgs(entry, program), {
      encoding: "utf8",
      timeout: 25000,
      maxBuffer: 4 * 1024 * 1024,
    });
    const line = stdout.split("\n").map((item) => item.trim()).find((item) => item.startsWith("CODEX_SYNC_JSON:"));
    if (!line) throw new Error(stdout.trim().slice(-180) || "远程没有返回结果");
    const parsed = JSON.parse(line.slice("CODEX_SYNC_JSON:".length));
    const snap = providerSnapshot(content);
    return {
      host: entry.host,
      label: entry.label,
      ok: true,
      changed: !!parsed.changed,
      baseUrl: snap.baseUrl,
      previousBaseUrl: parsed.previousBaseUrl ?? null,
      providerName: snap.providerName,
      tokenTail: snap.tokenTail,
      restarted: parsed.restarted ?? 0,
      error: null,
    };
  } catch (err) {
    const detail = (err.stderr || err.message || String(err)).trim().split("\n").slice(-3).join(" ");
    return emptyHost(entry, detail.slice(0, 240));
  }
}

export async function syncRemotes({
  localText = null,
  dryRun = false,
  log = console.log,
} = {}) {
  const hosts = loadRemotes();
  if (!hosts.length) {
    log("  未配置远程主机，跳过 SSH 同步");
    return { hosts: [] };
  }
  const text = localText ?? (existsSync(codexConfigPath()) ? readFileSync(codexConfigPath(), "utf8") : "");
  if (!text.trim()) {
    throw new Error(`本机没有可同步的 Codex 配置: ${codexConfigPath()}`);
  }
  const catalog = catalogPayload(text);
  log(`\n🌐 同步供应商配置到 ${hosts.length} 台远程（只改模型与端点，不覆盖远程项目配置）`);
  const results = await Promise.all(
    hosts.map(async (entry) => {
      let remoteText = "";
      try {
        remoteText = await readRemoteConfig(entry);
      } catch (err) {
        const detail = (err.stderr || err.message || String(err)).trim().split("\n").slice(-2).join(" ");
        log(`  ❌ ${entry.label}: 读取失败 ${detail.slice(0, 180)}`);
        return emptyHost(entry, detail.slice(0, 240));
      }
      const applied = applyProviderSlice(remoteText, text);
      const snap = providerSnapshot(applied.text);
      if (dryRun) {
        log(
          applied.changed
            ? `  [dry-run] ${entry.label}: ${applied.previousBaseUrl ?? "-"} → ${applied.baseUrl ?? "-"}`
            : `  ✔ ${entry.label}: 已与本机一致 (${applied.baseUrl ?? "-"})`,
        );
        return {
          host: entry.host,
          label: entry.label,
          ok: true,
          changed: applied.changed,
          baseUrl: snap.baseUrl,
          previousBaseUrl: applied.previousBaseUrl,
          providerName: snap.providerName,
          tokenTail: snap.tokenTail,
          restarted: 0,
          error: null,
        };
      }
      const pushed = await pushHost(entry, applied.text, catalog, false);
      if (!pushed.ok) {
        log(`  ❌ ${entry.label}: ${pushed.error}`);
      } else if (!pushed.changed) {
        log(`  ✔ ${entry.label}: 已与本机一致 (${pushed.baseUrl ?? "-"})，已重启 ${pushed.restarted} 个 app-server`);
      } else {
        log(
          `  ✔ ${entry.label}: ${pushed.previousBaseUrl ?? "-"} → ${pushed.baseUrl ?? "-"}，已重启 ${pushed.restarted} 个 app-server`,
        );
      }
      return pushed;
    }),
  );
  return { hosts: results };
}

/** 只读取远程正在使用的供应商，返回名称、端点和密钥尾号。 */
export async function inspectRemotes() {
  const hosts = loadRemotes();
  const results = await Promise.all(
    hosts.map(async (entry) => {
      try {
        const text = await readRemoteConfig(entry);
        const snap = providerSnapshot(text);
        return {
          host: entry.host,
          label: entry.label,
          ok: true,
          changed: false,
          baseUrl: snap.baseUrl,
          previousBaseUrl: null,
          providerName: snap.providerName,
          tokenTail: snap.tokenTail,
          restarted: 0,
          error: null,
        };
      } catch (err) {
        const detail = (err.stderr || err.message || String(err)).trim().split("\n").slice(-2).join(" ");
        return emptyHost(entry, detail.slice(0, 240));
      }
    }),
  );
  return { hosts: results };
}
