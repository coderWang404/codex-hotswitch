// 把本机 cc-switch 的供应商配置同步到远程。本机是唯一来源。
// 连不上的机器记为等待，调用方稍后重试；连上之后先比对指纹，不一致才写入。
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { loadRemotes } from "./remote-sync.mjs";
import { fingerprintSnapshot, readLocalSnapshot } from "./ccswitch-snapshot.mjs";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function pyLiteral(value) {
  if (value == null) return "None";
  return JSON.stringify(value);
}

function isPendingError(message) {
  return /timed out|timeout|Connection closed|Connection refused|No route to host|Operation timed out|Connection reset|Network is unreachable|Host is down/i.test(message);
}

export function remoteProgram({ mode, payloadB64 }) {
  return `
import base64, hashlib, json, os, pathlib, sqlite3, time
mode = ${JSON.stringify(mode)}
payload_b64 = ${pyLiteral(payloadB64)}

def stable(value):
    if isinstance(value, list):
        return "[" + ",".join(stable(item) for item in value) + "]"
    if isinstance(value, dict):
        parts = []
        for key in sorted(value):
            parts.append(json.dumps(key, ensure_ascii=False) + ":" + stable(value[key]))
        return "{" + ",".join(parts) + "}"
    return json.dumps(value, ensure_ascii=False)

def fingerprint(snapshot):
    return hashlib.sha256(stable(snapshot).encode("utf-8")).hexdigest()

def order_snapshot(snapshot):
    providers = list(snapshot.get("providers") or [])
    providers.sort(key=lambda item: (item.get("app_type") or "", item.get("id") or ""))
    endpoints = list(snapshot.get("endpoints") or [])
    endpoints.sort(key=lambda item: (item.get("app_type") or "", item.get("provider_id") or "", item.get("url") or ""))
    prompts = list(snapshot.get("prompts") or [])
    prompts.sort(key=lambda item: (item.get("app_type") or "", item.get("id") or ""))
    mcp_servers = list(snapshot.get("mcpServers") or [])
    mcp_servers.sort(key=lambda item: item.get("id") or "")
    ordered = dict(snapshot)
    ordered["providers"] = providers
    ordered["endpoints"] = endpoints
    ordered["prompts"] = prompts
    ordered["mcpServers"] = mcp_servers
    return ordered

def bit(value, fallback=0):
    if value is None or value == "":
        return fallback
    return 1 if value else 0

def text(value):
    return None if value is None else str(value)

SCHEMA = """
CREATE TABLE IF NOT EXISTS providers (
  id TEXT NOT NULL,
  app_type TEXT NOT NULL,
  name TEXT NOT NULL,
  settings_config TEXT NOT NULL,
  website_url TEXT,
  category TEXT,
  created_at INTEGER,
  sort_index INTEGER,
  notes TEXT,
  icon TEXT,
  icon_color TEXT,
  meta TEXT NOT NULL DEFAULT '{}',
  is_current INTEGER NOT NULL DEFAULT 0,
  in_failover_queue INTEGER NOT NULL DEFAULT 0,
  cost_multiplier TEXT NOT NULL DEFAULT '1.0',
  limit_daily_usd TEXT,
  limit_monthly_usd TEXT,
  provider_type TEXT,
  PRIMARY KEY (id, app_type)
);
CREATE TABLE IF NOT EXISTS provider_endpoints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider_id TEXT NOT NULL,
  app_type TEXT NOT NULL,
  url TEXT NOT NULL,
  added_at INTEGER
);
CREATE TABLE IF NOT EXISTS provider_health (
  provider_id TEXT NOT NULL,
  app_type TEXT NOT NULL,
  is_healthy INTEGER NOT NULL DEFAULT 1,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  last_success_at TEXT,
  last_failure_at TEXT,
  last_error TEXT,
  updated_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (provider_id, app_type)
);
CREATE TABLE IF NOT EXISTS prompts (
  id TEXT NOT NULL,
  app_type TEXT NOT NULL,
  name TEXT NOT NULL,
  content TEXT NOT NULL,
  description TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER,
  updated_at INTEGER,
  PRIMARY KEY (id, app_type)
);
CREATE TABLE IF NOT EXISTS mcp_servers (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  server_config TEXT NOT NULL,
  description TEXT,
  homepage TEXT,
  docs TEXT,
  tags TEXT NOT NULL DEFAULT '[]',
  enabled_claude INTEGER NOT NULL DEFAULT 0,
  enabled_codex INTEGER NOT NULL DEFAULT 0,
  enabled_gemini INTEGER NOT NULL DEFAULT 0,
  enabled_opencode INTEGER NOT NULL DEFAULT 0,
  enabled_hermes INTEGER NOT NULL DEFAULT 0,
  enabled_grokbuild INTEGER NOT NULL DEFAULT 0,
  enabled_mcode INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);
"""

CURRENT_FIELDS = [
    ("codex", "currentProviderCodex"),
    ("claude", "currentProviderClaude"),
    ("claudeDesktop", "currentProviderClaudeDesktop"),
    ("gemini", "currentProviderGemini"),
    ("grokbuild", "currentProviderGrokbuild"),
]
COMMON_KEYS = [
    "common_config_claude",
    "common_config_codex",
    "common_config_gemini",
    "common_config_opencode",
]

def table_exists(con, name):
    row = con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone()
    return row is not None

def columns_of(con, name):
    if not table_exists(con, name):
        return []
    return [row[1] for row in con.execute(f"PRAGMA table_info({name})")]

def read_snapshot(con, settings_path):
    providers = []
    if table_exists(con, "providers"):
        cols = set(columns_of(con, "providers"))
        wanted = ["id","app_type","name","settings_config","website_url","category","created_at","sort_index","notes","icon","icon_color","meta","is_current","in_failover_queue","cost_multiplier","limit_daily_usd","limit_monthly_usd","provider_type"]
        present = [name for name in wanted if name in cols]
        for row in con.execute("SELECT " + ",".join(present) + " FROM providers"):
            item = dict(zip(present, row))
            providers.append({
                "id": str(item.get("id")),
                "app_type": str(item.get("app_type")),
                "name": str(item.get("name")),
                "settings_config": text(item.get("settings_config")) or "{}",
                "website_url": text(item.get("website_url")),
                "category": text(item.get("category")),
                "created_at": item.get("created_at"),
                "sort_index": item.get("sort_index"),
                "notes": text(item.get("notes")),
                "icon": text(item.get("icon")),
                "icon_color": text(item.get("icon_color")),
                "meta": text(item.get("meta")) or "{}",
                "is_current": bit(item.get("is_current")),
                "in_failover_queue": bit(item.get("in_failover_queue")),
                "cost_multiplier": text(item.get("cost_multiplier")) or "1.0",
                "limit_daily_usd": text(item.get("limit_daily_usd")),
                "limit_monthly_usd": text(item.get("limit_monthly_usd")),
                "provider_type": text(item.get("provider_type")),
            })
    providers.sort(key=lambda item: (item["app_type"], item["id"]))
    endpoints = []
    if table_exists(con, "provider_endpoints"):
        for provider_id, app_type, url, added_at in con.execute("SELECT provider_id, app_type, url, added_at FROM provider_endpoints"):
            endpoints.append({
                "provider_id": str(provider_id),
                "app_type": str(app_type),
                "url": str(url),
                "added_at": added_at,
            })
    endpoints.sort(key=lambda item: (item["app_type"], item["provider_id"], item["url"]))
    prompts = []
    if table_exists(con, "prompts"):
        for row in con.execute("SELECT id, app_type, name, content, description, enabled, created_at, updated_at FROM prompts"):
            prompts.append({
                "id": str(row[0]),
                "app_type": str(row[1]),
                "name": str(row[2]),
                "content": text(row[3]) or "",
                "description": text(row[4]),
                "enabled": bit(row[5], 1),
                "created_at": row[6],
                "updated_at": row[7],
            })
    prompts.sort(key=lambda item: (item["app_type"], item["id"]))
    mcp_servers = []
    if table_exists(con, "mcp_servers"):
        cols = set(columns_of(con, "mcp_servers"))
        wanted = ["id","name","server_config","description","homepage","docs","tags","enabled_claude","enabled_codex","enabled_gemini","enabled_opencode","enabled_hermes","enabled_grokbuild","enabled_mcode"]
        present = [name for name in wanted if name in cols]
        for row in con.execute("SELECT " + ",".join(present) + " FROM mcp_servers"):
            item = dict(zip(present, row))
            mcp_servers.append({
                "id": str(item.get("id")),
                "name": str(item.get("name")),
                "server_config": text(item.get("server_config")) or "{}",
                "description": text(item.get("description")),
                "homepage": text(item.get("homepage")),
                "docs": text(item.get("docs")),
                "tags": text(item.get("tags")) or "[]",
                "enabled_claude": bit(item.get("enabled_claude")),
                "enabled_codex": bit(item.get("enabled_codex")),
                "enabled_gemini": bit(item.get("enabled_gemini")),
                "enabled_opencode": bit(item.get("enabled_opencode")),
                "enabled_hermes": bit(item.get("enabled_hermes")),
                "enabled_grokbuild": bit(item.get("enabled_grokbuild")),
                "enabled_mcode": bit(item.get("enabled_mcode")),
            })
    mcp_servers.sort(key=lambda item: item["id"])
    common = {key: None for key in COMMON_KEYS}
    if table_exists(con, "settings"):
        for key, value in con.execute("SELECT key, value FROM settings WHERE key IN ({})".format(",".join("?" for _ in COMMON_KEYS)), COMMON_KEYS):
            common[key] = text(value)
    current = {field: None for field, _key in CURRENT_FIELDS}
    if settings_path.exists():
        try:
            data = json.loads(settings_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        for field, key in CURRENT_FIELDS:
            value = data.get(key)
            current[field] = None if value in (None, "") else str(value)
    return {
        "providers": providers,
        "endpoints": endpoints,
        "prompts": prompts,
        "mcpServers": mcp_servers,
        "commonConfig": common,
        "current": current,
    }

def insert_rows(con, table, rows):
    if not rows:
        return
    present = set(columns_of(con, table))
    cols = [key for key in rows[0].keys() if key in present]
    if not cols:
        return
    sql = "INSERT INTO " + table + " (" + ",".join(cols) + ") VALUES (" + ",".join("?" for _ in cols) + ")"
    con.executemany(sql, [tuple(row.get(col) for col in cols) for row in rows])

def ensure_column(con, table, name, decl):
    if not table_exists(con, table):
        return
    if name not in set(columns_of(con, table)):
        con.execute("ALTER TABLE " + table + " ADD COLUMN " + name + " " + decl)

def apply_snapshot(con, settings_path, snapshot):
    con.executescript(SCHEMA)
    for name, decl in (
        ("website_url", "TEXT"),
        ("category", "TEXT"),
        ("created_at", "INTEGER"),
        ("sort_index", "INTEGER"),
        ("notes", "TEXT"),
        ("icon", "TEXT"),
        ("icon_color", "TEXT"),
        ("meta", "TEXT NOT NULL DEFAULT '{}'"),
        ("is_current", "INTEGER NOT NULL DEFAULT 0"),
        ("in_failover_queue", "INTEGER NOT NULL DEFAULT 0"),
        ("cost_multiplier", "TEXT NOT NULL DEFAULT '1.0'"),
        ("limit_daily_usd", "TEXT"),
        ("limit_monthly_usd", "TEXT"),
        ("provider_type", "TEXT"),
    ):
        ensure_column(con, "providers", name, decl)
    for name in ("enabled_hermes", "enabled_grokbuild", "enabled_mcode"):
        ensure_column(con, "mcp_servers", name, "INTEGER NOT NULL DEFAULT 0")
    con.execute("PRAGMA foreign_keys=OFF")
    for table in ("provider_endpoints", "provider_health", "providers", "prompts", "mcp_servers"):
        if table_exists(con, table):
            con.execute("DELETE FROM " + table)
    insert_rows(con, "providers", snapshot.get("providers") or [])
    insert_rows(con, "provider_endpoints", snapshot.get("endpoints") or [])
    insert_rows(con, "prompts", snapshot.get("prompts") or [])
    insert_rows(con, "mcp_servers", snapshot.get("mcpServers") or [])
    common = snapshot.get("commonConfig") or {}
    for key in COMMON_KEYS:
        value = common.get(key)
        if value is None:
            con.execute("DELETE FROM settings WHERE key=?", (key,))
        else:
            con.execute("DELETE FROM settings WHERE key=?", (key,))
            con.execute("INSERT INTO settings(key, value) VALUES(?, ?)", (key, value))
    data = {}
    if settings_path.exists():
        try:
            data = json.loads(settings_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
    current = snapshot.get("current") or {}
    for field, key in CURRENT_FIELDS:
        value = current.get(field)
        if value:
            data[key] = value
        else:
            data.pop(key, None)
    settings_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")
    os.chmod(settings_path, 0o600)
    con.commit()

home = pathlib.Path.home() / ".cc-switch"
db_path = home / "cc-switch.db"
settings_path = home / "settings.json"
existed = db_path.exists()
if mode != "write":
    home.mkdir(parents=True, exist_ok=True)
if not existed and mode != "write":
    empty = read_snapshot(sqlite3.connect(":memory:"), settings_path)
    print("CODEX_CC_JSON:" + json.dumps({"changed": False, "fingerprint": fingerprint(empty), "providerCount": 0, "hadDatabase": False}))
    raise SystemExit
home.mkdir(parents=True, exist_ok=True)
con = sqlite3.connect(db_path, timeout=8)
con.execute("PRAGMA busy_timeout=8000")
before = fingerprint(read_snapshot(con, settings_path)) if existed else None
changed = False
if mode == "write" and payload_b64:
    snapshot = order_snapshot(json.loads(base64.b64decode(payload_b64)))
    target = fingerprint(snapshot)
    if before != target:
        if existed:
            stamp = time.strftime("%Y%m%d_%H%M%S")
            backup = db_path.with_name(db_path.name + ".bak_" + stamp)
            backup.write_bytes(db_path.read_bytes())
        apply_snapshot(con, settings_path, snapshot)
        changed = True
snap = read_snapshot(con, settings_path)
after = fingerprint(snap)
count = len(snap.get("providers") or [])
con.close()
os.chmod(db_path, 0o600)
print("CODEX_CC_JSON:" + json.dumps({"changed": changed, "fingerprint": after, "providerCount": count, "hadDatabase": existed}))
`;
}

function sshPythonArgs(entry) {
  const args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12"];
  if (entry.port) args.push("-p", String(entry.port));
  if (entry.identityFile) {
    const file = entry.identityFile.startsWith("~/")
      ? path.join(os.homedir(), entry.identityFile.slice(2))
      : entry.identityFile;
    args.push("-i", file, "-o", "IdentitiesOnly=yes");
  }
  const target = entry.user ? `${entry.user}@${entry.host}` : entry.host;
  args.push(target, "python3", "-");
  return args;
}

function runRemote(entry, program) {
  return new Promise((resolve, reject) => {
    const child = spawn("ssh", sshPythonArgs(entry), { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      const error = new Error("Connection timed out");
      error.stderr = stderr;
      reject(error);
    }, 30000);
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const line = stdout.split("\n").map((item) => item.trim()).find((item) => item.startsWith("CODEX_CC_JSON:"));
      if (!line) {
        const error = new Error((stderr || stdout || `ssh exit ${code}`).trim().slice(-240));
        error.stderr = stderr;
        reject(error);
        return;
      }
      if (code !== 0) {
        const error = new Error((stderr || `ssh exit ${code}`).trim().slice(-240));
        error.stderr = stderr;
        reject(error);
        return;
      }
      resolve(JSON.parse(line.slice("CODEX_CC_JSON:".length)));
    });
    child.stdin.end(program);
  });
}

function hostResult(entry, extra) {
  return {
    host: entry.host,
    label: entry.label,
    ok: false,
    changed: false,
    pending: false,
    providerCount: null,
    error: null,
    ...extra,
  };
}

export async function syncCcSwitch({ dryRun = false, log = console.log, hosts = null, snapshot = null } = {}) {
  const selected = new Set((hosts ?? []).filter(Boolean));
  const entries = loadRemotes().filter((entry) => !selected.size || selected.has(entry.host) || selected.has(entry.label));
  if (!entries.length) {
    log("  没有需要同步的远程机器");
    return { hosts: [] };
  }
  const local = snapshot ?? readLocalSnapshot();
  const fingerprint = fingerprintSnapshot(local);
  const payloadB64 = Buffer.from(JSON.stringify(local), "utf8").toString("base64");
  log(`\n⇄ 核对 ${entries.length} 台远程的 cc-switch（以本机为准）`);
  const results = await Promise.all(entries.map(async (entry) => {
    try {
      const current = await runRemote(entry, remoteProgram({ mode: "read", payloadB64: null }));
      if (current.fingerprint === fingerprint) {
        log(`  ✔ ${entry.label}: cc-switch 已一致（${current.providerCount ?? 0} 个供应商）`);
        return hostResult(entry, {
          ok: true,
          providerCount: current.providerCount ?? 0,
        });
      }
      if (dryRun) {
        log(`  [dry-run] ${entry.label}: cc-switch 将更新为 ${local.providers.length} 个供应商`);
        return hostResult(entry, { ok: true, changed: true, providerCount: local.providers.length });
      }
      const written = await runRemote(entry, remoteProgram({ mode: "write", payloadB64 }));
      if (written.fingerprint !== fingerprint) {
        const again = await runRemote(entry, remoteProgram({ mode: "read", payloadB64: null }));
        if (again.fingerprint === fingerprint) {
          log(`  ✔ ${entry.label}: cc-switch 已更新（${again.providerCount ?? 0} 个供应商）`);
          return hostResult(entry, { ok: true, changed: true, providerCount: again.providerCount ?? local.providers.length });
        }
        return hostResult(entry, { pending: true, error: "等待复核" });
      }
      log(`  ✔ ${entry.label}: cc-switch 已更新（${written.providerCount ?? 0} 个供应商）`);
      return hostResult(entry, {
        ok: true,
        changed: true,
        providerCount: written.providerCount ?? local.providers.length,
      });
    } catch (err) {
      const detail = (err.stderr || err.message || String(err)).trim().split("\n").slice(-2).join(" ");
      const pending = isPendingError(detail);
      log(pending ? `  ⏳ ${entry.label}: 未连接，稍后重试` : `  ❌ ${entry.label}: ${detail.slice(0, 180)}`);
      return hostResult(entry, {
        pending,
        error: pending ? "等待连接" : detail.slice(0, 240),
      });
    }
  }));
  return { hosts: results, fingerprint };
}

/** 本地配置一变就推送；没连上的机器保持等待，连上后先检查再更新。 */
export function startCcSwitchFollow({ intervalMs = 1500, retryMs = 8000, dryRun = false, log = console.log } = {}) {
  let stopped = false;
  let lastFingerprint = null;
  let pending = new Set();
  let bootstrapped = false;
  let busy = false;
  let lastAttempt = 0;
  const timer = setInterval(async () => {
    if (stopped || busy) return;
    let fingerprint = null;
    try {
      fingerprint = fingerprintSnapshot(readLocalSnapshot());
    } catch (err) {
      log(`  ⚠️ 读取本机 cc-switch 失败: ${err.message}`);
      return;
    }
    const localChanged = fingerprint !== lastFingerprint;
    const retryDue = pending.size > 0 && Date.now() - lastAttempt > retryMs;
    if (!localChanged && bootstrapped && !retryDue) return;
    busy = true;
    lastAttempt = Date.now();
    const hosts = !localChanged && bootstrapped ? [...pending] : null;
    try {
      if (localChanged) await sleep(400);
      const stable = fingerprintSnapshot(readLocalSnapshot());
      lastFingerprint = stable;
      const result = await syncCcSwitch({ dryRun, log, hosts, snapshot: readLocalSnapshot() });
      bootstrapped = true;
      const seen = new Set((result.hosts ?? []).map((item) => item.host));
      if (!hosts) pending = new Set();
      for (const item of result.hosts ?? []) {
        if (item.pending) pending.add(item.host);
        else pending.delete(item.host);
      }
      if (hosts) {
        for (const host of hosts) {
          if (!seen.has(host)) pending.add(host);
        }
      }
    } catch (err) {
      log(`  ⚠️ cc-switch 同步失败: ${err.message}`);
    } finally {
      busy = false;
    }
  }, intervalMs);
  if (typeof timer.unref === "function") timer.unref();
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}
