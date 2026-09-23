// 本地 cc-switch 的配置切片：供应商、端点、提示词、MCP、通用配置和当前选中项。
// 用量日志、健康检查、技能目录和本机代理不在这里，避免把机器自己的运行数据当成配置。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { ccSwitchDbPath, ccSwitchSettingsPath } from "./paths.mjs";

const CURRENT_FIELDS = [
  ["codex", "currentProviderCodex"],
  ["claude", "currentProviderClaude"],
  ["claudeDesktop", "currentProviderClaudeDesktop"],
  ["gemini", "currentProviderGemini"],
  ["grokbuild", "currentProviderGrokbuild"],
];

const COMMON_KEYS = [
  "common_config_claude",
  "common_config_codex",
  "common_config_gemini",
  "common_config_opencode",
];

function sqliteJson(dbPath, sql) {
  const out = execFileSync("sqlite3", ["-json", dbPath, sql], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const trimmed = out.trim();
  if (!trimmed) return [];
  return JSON.parse(trimmed);
}

function cmp(left, right) {
  const a = left ?? "";
  const b = right ?? "";
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

function bit(value, fallback = 0) {
  if (value == null || value === "") return fallback;
  return value ? 1 : 0;
}

function text(value) {
  return value == null ? null : String(value);
}

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stable(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

export function fingerprintSnapshot(snapshot) {
  return createHash("sha256").update(stable(snapshot)).digest("hex");
}

export function readLocalSnapshot() {
  const db = ccSwitchDbPath();
  if (!existsSync(db)) {
    throw new Error(`找不到 cc-switch 数据库: ${db}`);
  }
  const providers = sqliteJson(
    db,
    `SELECT id, app_type, name, settings_config, website_url, category, created_at, sort_index,
            notes, icon, icon_color, meta, is_current, in_failover_queue, cost_multiplier,
            limit_daily_usd, limit_monthly_usd, provider_type
     FROM providers`,
  ).map((row) => ({
    id: String(row.id),
    app_type: String(row.app_type),
    name: String(row.name),
    settings_config: text(row.settings_config) ?? "{}",
    website_url: text(row.website_url),
    category: text(row.category),
    created_at: row.created_at == null ? null : Number(row.created_at),
    sort_index: row.sort_index == null ? null : Number(row.sort_index),
    notes: text(row.notes),
    icon: text(row.icon),
    icon_color: text(row.icon_color),
    meta: text(row.meta) ?? "{}",
    is_current: bit(row.is_current),
    in_failover_queue: bit(row.in_failover_queue),
    cost_multiplier: text(row.cost_multiplier) ?? "1.0",
    limit_daily_usd: text(row.limit_daily_usd),
    limit_monthly_usd: text(row.limit_monthly_usd),
    provider_type: text(row.provider_type),
  }));
  providers.sort((a, b) => cmp(a.app_type, b.app_type) || cmp(a.id, b.id));

  const endpoints = sqliteJson(
    db,
    "SELECT provider_id, app_type, url, added_at FROM provider_endpoints",
  ).map((row) => ({
    provider_id: String(row.provider_id),
    app_type: String(row.app_type),
    url: String(row.url),
    added_at: row.added_at == null ? null : Number(row.added_at),
  }));
  endpoints.sort((a, b) =>
    cmp(a.app_type, b.app_type) ||
    cmp(a.provider_id, b.provider_id) ||
    cmp(a.url, b.url),
  );

  const prompts = sqliteJson(
    db,
    "SELECT id, app_type, name, content, description, enabled, created_at, updated_at FROM prompts",
  ).map((row) => ({
    id: String(row.id),
    app_type: String(row.app_type),
    name: String(row.name),
    content: text(row.content) ?? "",
    description: text(row.description),
    enabled: bit(row.enabled, 1),
    created_at: row.created_at == null ? null : Number(row.created_at),
    updated_at: row.updated_at == null ? null : Number(row.updated_at),
  }));
  prompts.sort((a, b) => cmp(a.app_type, b.app_type) || cmp(a.id, b.id));

  const mcpServers = sqliteJson(
    db,
    `SELECT id, name, server_config, description, homepage, docs, tags,
            enabled_claude, enabled_codex, enabled_gemini, enabled_opencode,
            enabled_hermes, enabled_grokbuild, enabled_mcode
     FROM mcp_servers`,
  ).map((row) => ({
    id: String(row.id),
    name: String(row.name),
    server_config: text(row.server_config) ?? "{}",
    description: text(row.description),
    homepage: text(row.homepage),
    docs: text(row.docs),
    tags: text(row.tags) ?? "[]",
    enabled_claude: bit(row.enabled_claude),
    enabled_codex: bit(row.enabled_codex),
    enabled_gemini: bit(row.enabled_gemini),
    enabled_opencode: bit(row.enabled_opencode),
    enabled_hermes: bit(row.enabled_hermes),
    enabled_grokbuild: bit(row.enabled_grokbuild),
    enabled_mcode: bit(row.enabled_mcode),
  }));
  mcpServers.sort((a, b) => cmp(a.id, b.id));

  const commonRows = sqliteJson(
    db,
    `SELECT key, value FROM settings WHERE key IN (${COMMON_KEYS.map((key) => `'${key}'`).join(",")})`,
  );
  const commonConfig = {};
  for (const key of COMMON_KEYS) commonConfig[key] = null;
  for (const row of commonRows) commonConfig[row.key] = text(row.value);

  const current = {};
  for (const [field] of CURRENT_FIELDS) current[field] = null;
  const settingsPath = ccSwitchSettingsPath();
  if (existsSync(settingsPath)) {
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    for (const [field, key] of CURRENT_FIELDS) {
      current[field] = settings[key] == null || settings[key] === "" ? null : String(settings[key]);
    }
  }

  return { providers, endpoints, prompts, mcpServers, commonConfig, current };
}

export function localFingerprint() {
  return fingerprintSnapshot(readLocalSnapshot());
}
