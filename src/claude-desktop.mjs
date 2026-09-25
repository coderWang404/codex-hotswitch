// Claude Desktop 第三方模式：跟随 cc-switch 的 claude-desktop 供应商。
// cc-switch 把当前供应商写进 Claude-3p 的 configLibrary；桌面进程只在启动时读取，
// 所以切换后要退出并重新打开 Claude.app，下一次请求才会走新网关。
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import { ccSwitchDbPath, ccSwitchSettingsPath } from "./paths.mjs";

export const CLAUDE_DESKTOP_PROFILE_ID = "00000000-0000-4000-8000-000000157210";
const OFFICIAL_ID = "claude-desktop-official";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function sqliteJson(dbPath, sql) {
  const out = execFileSync("sqlite3", ["-json", dbPath, sql], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  const trimmed = out.trim();
  if (!trimmed) return [];
  return JSON.parse(trimmed);
}

function sqliteExec(dbPath, sql) {
  execFileSync("sqlite3", [dbPath, sql], { encoding: "utf8" });
}

export function claudeDesktopSupportDir() {
  return path.join(os.homedir(), "Library", "Application Support", "Claude-3p");
}

export function claudeDesktopProfilePath() {
  return path.join(claudeDesktopSupportDir(), "configLibrary", `${CLAUDE_DESKTOP_PROFILE_ID}.json`);
}

function metaPath() {
  return path.join(claudeDesktopSupportDir(), "configLibrary", "_meta.json");
}

function desktopConfigPath(dirName) {
  return path.join(os.homedir(), "Library", "Application Support", dirName, "claude_desktop_config.json");
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function writeAtomic(filePath, content) {
  mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const tmp = path.join(path.dirname(filePath), `.${path.basename(filePath)}.tmp-${process.pid}`);
  writeFileSync(tmp, content, { mode: 0o600 });
  renameSync(tmp, filePath);
}

function hostOf(url) {
  if (!url) return null;
  try {
    return new URL(url).host;
  } catch {
    return null;
  }
}

function tokenTail(token) {
  return typeof token === "string" && token.length > 0 ? token.slice(-8) : null;
}

function parseSettings(raw) {
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
}

export function listClaudeDesktopProviders() {
  const db = ccSwitchDbPath();
  if (!existsSync(db)) {
    throw new Error(`找不到 cc-switch 数据库: ${db}`);
  }
  const rows = sqliteJson(
    db,
    "SELECT id, name, is_current, settings_config FROM providers WHERE app_type='claude-desktop' ORDER BY sort_index, created_at",
  );
  return rows.map((row) => {
    const settings = parseSettings(row.settings_config);
    const env = settings.env && typeof settings.env === "object" ? settings.env : {};
    const baseUrl = typeof env.ANTHROPIC_BASE_URL === "string" ? env.ANTHROPIC_BASE_URL : null;
    const token = typeof env.ANTHROPIC_AUTH_TOKEN === "string" ? env.ANTHROPIC_AUTH_TOKEN : "";
    const model = typeof settings.model === "string"
      ? settings.model
      : (typeof env.ANTHROPIC_MODEL === "string" ? env.ANTHROPIC_MODEL : null);
    const official = row.id === OFFICIAL_ID || !baseUrl;
    return {
      id: String(row.id),
      name: String(row.name),
      isCurrent: !!row.is_current,
      model,
      catalogCount: 0,
      official,
      hasConfig: !!baseUrl && !!token,
      baseUrl,
      host: hostOf(baseUrl),
      tokenTail: tokenTail(token),
      env,
    };
  });
}

export function currentClaudeDesktopId() {
  const settingsPath = ccSwitchSettingsPath();
  if (existsSync(settingsPath)) {
    try {
      const id = JSON.parse(readFileSync(settingsPath, "utf8")).currentProviderClaudeDesktop;
      if (id) return String(id);
    } catch {
      /* 回退数据库 */
    }
  }
  return listClaudeDesktopProviders().find((item) => item.isCurrent)?.id ?? null;
}

export function findClaudeDesktopProvider(query) {
  const providers = listClaudeDesktopProviders();
  const q = query.trim().toLowerCase();
  return (
    providers.find((item) => item.id.toLowerCase() === q) ??
    providers.find((item) => item.name.toLowerCase() === q) ??
    providers.find((item) => item.name.toLowerCase().includes(q)) ??
    null
  );
}

export function readAppliedProfile() {
  const filePath = claudeDesktopProfilePath();
  if (!existsSync(filePath)) return null;
  const data = readJson(filePath);
  const baseUrl = typeof data.inferenceGatewayBaseUrl === "string" ? data.inferenceGatewayBaseUrl : null;
  const token = typeof data.inferenceGatewayApiKey === "string" ? data.inferenceGatewayApiKey : "";
  return {
    baseUrl,
    host: hostOf(baseUrl),
    tokenTail: tokenTail(token),
    provider: data.inferenceProvider ?? null,
    scheme: data.inferenceGatewayAuthScheme ?? null,
  };
}

function providerProfile(provider) {
  const baseUrl = provider.env?.ANTHROPIC_BASE_URL;
  const token = provider.env?.ANTHROPIC_AUTH_TOKEN;
  if (!baseUrl || !token) {
    throw new Error(`「${provider.name}」没有直连地址或密钥。官方登录和需要本地代理转换的供应商，请在 cc-switch 里切换。`);
  }
  return {
    coworkEgressAllowedHosts: ["*"],
    disableDeploymentModeChooser: true,
    inferenceGatewayApiKey: token,
    inferenceGatewayAuthScheme: "bearer",
    inferenceGatewayBaseUrl: baseUrl,
    inferenceProvider: "gateway",
  };
}

function ensureMeta() {
  const filePath = metaPath();
  let meta = { appliedId: CLAUDE_DESKTOP_PROFILE_ID, entries: [] };
  if (existsSync(filePath)) {
    try {
      meta = readJson(filePath);
    } catch {
      meta = { appliedId: CLAUDE_DESKTOP_PROFILE_ID, entries: [] };
    }
  }
  const entries = Array.isArray(meta.entries) ? meta.entries : [];
  if (!entries.some((entry) => entry?.id === CLAUDE_DESKTOP_PROFILE_ID)) {
    entries.push({ id: CLAUDE_DESKTOP_PROFILE_ID, name: "CC Switch" });
  }
  meta.appliedId = CLAUDE_DESKTOP_PROFILE_ID;
  meta.entries = entries;
  writeAtomic(filePath, `${JSON.stringify(meta, null, 2)}\n`);
}

function ensureDeploymentMode() {
  for (const dirName of ["Claude", "Claude-3p"]) {
    const filePath = desktopConfigPath(dirName);
    if (!existsSync(filePath)) {
      if (dirName === "Claude") {
        writeAtomic(filePath, `${JSON.stringify({ deploymentMode: "3p" }, null, 2)}\n`);
      }
      continue;
    }
    let data;
    try {
      data = readJson(filePath);
    } catch {
      continue;
    }
    if (data.deploymentMode === "3p") continue;
    data.deploymentMode = "3p";
    writeAtomic(filePath, `${JSON.stringify(data, null, 2)}\n`);
  }
}

export function syncClaudeDesktopCurrent(providerId) {
  const db = ccSwitchDbPath();
  const safe = providerId.replace(/'/g, "''");
  sqliteExec(
    db,
    `UPDATE providers SET is_current = CASE WHEN id='${safe}' AND app_type='claude-desktop' THEN 1 ELSE 0 END WHERE app_type='claude-desktop';`,
  );
  const settingsPath = ccSwitchSettingsPath();
  const settings = existsSync(settingsPath) ? JSON.parse(readFileSync(settingsPath, "utf8")) : {};
  settings.currentProviderClaudeDesktop = providerId;
  writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
}

export function applyClaudeDesktopProvider(provider) {
  const profile = providerProfile(provider);
  ensureMeta();
  ensureDeploymentMode();
  writeAtomic(claudeDesktopProfilePath(), `${JSON.stringify(profile, null, 2)}\n`);
  return readAppliedProfile();
}

export function claudeDesktopSummary(provider) {
  return {
    id: provider.id,
    name: provider.name,
    isCurrent: provider.id === currentClaudeDesktopId(),
    model: provider.model,
    catalogCount: 0,
    official: provider.official,
    hasConfig: provider.hasConfig,
    baseUrl: provider.baseUrl,
    host: provider.host,
    tokenTail: provider.tokenTail,
  };
}

function mainClaudePids() {
  let out = "";
  try {
    out = execFileSync("ps", ["-ax", "-o", "pid=,command="], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  } catch {
    return [];
  }
  const pids = [];
  for (const line of out.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(.*)$/);
    if (!match) continue;
    const command = match[2];
    if (!command.includes("/Applications/Claude.app/Contents/MacOS/Claude")) continue;
    if (command.includes("Helper") || command.includes("chrome_crashpad_handler")) continue;
    pids.push(Number(match[1]));
  }
  return pids;
}

async function waitFor(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(200);
  }
  return false;
}

/** 退出并重新打开 Claude.app，让它重新读取第三方网关配置。 */
export async function restartClaudeDesktop({ log = console.log } = {}) {
  const before = mainClaudePids();
  if (!before.length) {
    log("  当前没有运行中的 Claude Desktop，下次打开时生效。");
    return { wasRunning: false, restarted: false, pid: null };
  }
  log(`  正在重新打开 Claude Desktop（pid ${before.join(", ")}）…`);
  try {
    execFileSync("osascript", ["-e", 'tell application "Claude" to quit'], { stdio: "ignore" });
  } catch {
    /* 下面再按 pid 结束 */
  }
  const gone = await waitFor(() => mainClaudePids().length === 0, 8000);
  if (!gone) {
    for (const pid of mainClaudePids()) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        /* 进程可能已经退出 */
      }
    }
    await waitFor(() => mainClaudePids().length === 0, 4000);
  }
  execFileSync("open", ["-a", "Claude"], { stdio: "ignore" });
  let pid = null;
  await waitFor(() => {
    pid = mainClaudePids().find((item) => !before.includes(item)) ?? null;
    return pid != null;
  }, 12000);
  if (!pid) throw new Error("Claude Desktop 已退出，但没有重新打开。");
  log(`  Claude Desktop 已重新打开（pid ${pid}）。`);
  return { wasRunning: true, restarted: true, pid };
}
