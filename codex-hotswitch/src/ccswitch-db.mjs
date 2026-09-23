// 读取 / 同步 cc-switch 的 SQLite 数据库（只依赖系统自带 sqlite3 CLI）。
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { ccSwitchDbPath, ccSwitchSettingsPath } from "./paths.mjs";

function sqliteJson(dbPath, sql) {
  const out = execFileSync("sqlite3", ["-json", dbPath, sql], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const trimmed = out.trim();
  if (!trimmed) return [];
  return JSON.parse(trimmed);
}

function sqliteExec(dbPath, sql) {
  execFileSync("sqlite3", [dbPath, sql], { encoding: "utf8" });
}

/**
 * 列出 cc-switch 中所有 codex 供应商。
 * 返回 [{ id, name, isCurrent, category, auth, config, modelCatalog }]
 */
export function listCodexProviders() {
  const db = ccSwitchDbPath();
  if (!existsSync(db)) {
    throw new Error(`找不到 cc-switch 数据库: ${db}\n请先安装并运行过 cc-switch。`);
  }
  const rows = sqliteJson(
    db,
    "SELECT id, name, is_current, category, settings_config, meta FROM providers WHERE app_type='codex' ORDER BY sort_index, created_at",
  );
  return rows.map((row) => {
    let settings = {};
    try {
      settings = JSON.parse(row.settings_config || "{}");
    } catch {
      settings = {};
    }
    let meta = {};
    try {
      meta = JSON.parse(row.meta || "{}");
    } catch {
      meta = {};
    }
    return {
      id: row.id,
      name: row.name,
      isCurrent: !!row.is_current,
      category: row.category ?? null,
      auth: settings.auth ?? {},
      config: typeof settings.config === "string" ? settings.config : "",
      modelCatalog: settings.modelCatalog ?? null,
      meta,
    };
  });
}

/** 从 settings.json 读取 cc-switch 当前选中的 codex 供应商 id。 */
export function currentProviderIdFromSettings() {
  const p = ccSwitchSettingsPath();
  if (!existsSync(p)) return null;
  try {
    const s = JSON.parse(readFileSync(p, "utf8"));
    return s.currentProviderCodex ?? null;
  } catch {
    return null;
  }
}

/** 读取 cc-switch 的 Codex 通用配置片段（可能为空）。 */
export function getCodexCommonConfig() {
  const db = ccSwitchDbPath();
  if (!existsSync(db)) return null;
  const rows = sqliteJson(db, "SELECT value FROM settings WHERE key='common_config_codex'");
  const value = rows[0]?.value;
  return typeof value === "string" && value.trim() ? value : null;
}

/** 当前生效的供应商（以 settings.json 为准，回退到数据库 is_current）。 */
export function getCurrentProvider() {
  const providers = listCodexProviders();
  const settingsId = currentProviderIdFromSettings();
  return (
    providers.find((p) => p.id === settingsId) ??
    providers.find((p) => p.isCurrent) ??
    null
  );
}

export function findProvider(query) {
  const providers = listCodexProviders();
  const q = query.trim().toLowerCase();
  return (
    providers.find((p) => p.id.toLowerCase() === q) ??
    providers.find((p) => p.name.toLowerCase() === q) ??
    providers.find((p) => p.name.toLowerCase().includes(q)) ??
    providers.find((p) => p.id.toLowerCase().includes(q)) ??
    null
  );
}

/**
 * 把"当前供应商"状态同步回 cc-switch，保证两边认知一致。
 * 最佳努力：失败只警告，不影响主流程。
 */
export function syncCurrentProvider(providerId) {
  const db = ccSwitchDbPath();
  let ok = true;
  try {
    sqliteExec(
      db,
      `UPDATE providers SET is_current = CASE WHEN id='${providerId.replace(/'/g, "''")}' AND app_type='codex' THEN 1 ELSE 0 END WHERE app_type='codex';`,
    );
  } catch (err) {
    console.warn(`[warn] 同步 cc-switch 数据库 is_current 失败: ${err.message}`);
    ok = false;
  }
  try {
    const p = ccSwitchSettingsPath();
    if (existsSync(p)) {
      const s = JSON.parse(readFileSync(p, "utf8"));
      s.currentProviderCodex = providerId;
      writeFileSync(p, `${JSON.stringify(s, null, 2)}\n`);
    }
  } catch (err) {
    console.warn(`[warn] 同步 cc-switch settings.json 失败: ${err.message}`);
    ok = false;
  }
  return ok;
}
