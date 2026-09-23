// 切换供应商：生成配置 → 校验 → 原子写入 → 同步 cc-switch 状态。
import { readFileSync, writeFileSync, existsSync, copyFileSync, renameSync, unlinkSync } from "node:fs";
import path from "node:path";
import {
  codexConfigPath,
  codexHome,
  ccSwitchCatalogPath,
  CHATGPT_CODEX_BIN,
} from "./paths.mjs";
import { injectBearerToken, setCatalogJsonField } from "./toml-edit.mjs";
import { mergeCommonConfig, isCommonConfigSubset, extractSections } from "./common-config.mjs";
import { buildCatalog } from "./catalog.mjs";
import { findCodexBinary, readEffectiveConfig } from "./verify-client.mjs";

const OFFICIAL_IDS = new Set(["codex-official"]);

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/** 写文件：同目录临时文件 + rename，保证原子性。 */
function writeAtomic(filePath, content) {
  const dir = path.dirname(filePath);
  const tmp = path.join(dir, `.${path.basename(filePath)}.tmp-${process.pid}`);
  writeFileSync(tmp, content, { mode: 0o600 });
  renameSync(tmp, filePath);
}

/**
 * 判断该供应商是否启用 cc-switch 的"通用配置"合并
 * （对应 cc-switch provider_uses_common_config）。
 */
function providerUsesCommonConfig(provider, commonConfig) {
  if (!commonConfig?.trim()) return false;
  const explicit = provider.meta?.commonConfigEnabled;
  if (explicit !== undefined) return explicit === true;
  return isCommonConfigSubset(provider.config, commonConfig);
}

/**
 * 应用自身会往 config.toml 里持久化界面级配置（[desktop]、[marketplaces]、
 * [plugins]、项目信任 [projects.*]）。供应商存档里往往是旧快照，
 * 这里用 live 配置补齐，避免切换后丢失应用设置。
 */
const APP_MANAGED_NAMESPACES = ["desktop", "marketplaces", "plugins", "projects"];

/**
 * 依据 provider 记录生成最终的 config.toml 文本。
 * 顺序与 cc-switch 一致：provider config → 通用配置合并 → bearer token → catalog 字段；
 * 另外用 live 配置补齐应用管理的 section。
 */
export function buildProviderConfig({ provider, commonConfig, apiFormat, liveConfigText = null }) {
  if (!provider.config.trim()) {
    throw new Error(
      `供应商「${provider.name}」没有可用的 config 配置（可能是官方供应商，请用 cc-switch 界面切换）。`,
    );
  }

  let text = provider.config;

  // 1. 通用配置片段：cc-switch 在切换时"只合并、不剥离"
  //    （剥离只发生在供应商编辑界面取消勾选/legacy 迁移时）
  if (commonConfig && providerUsesCommonConfig(provider, commonConfig)) {
    text = mergeCommonConfig(text, commonConfig);
  }

  // 2. 继承 live 配置里由应用管理的 section（desktop / marketplaces / plugins）
  if (liveConfigText) {
    const inherited = extractSections(liveConfigText, APP_MANAGED_NAMESPACES);
    if (inherited) text = mergeCommonConfig(text, inherited);
  }

  // 2. bearer token（来自 provider.auth.OPENAI_API_KEY）
  const token =
    typeof provider.auth?.OPENAI_API_KEY === "string" && provider.auth.OPENAI_API_KEY.trim()
      ? provider.auth.OPENAI_API_KEY.trim()
      : null;
  if (token) text = injectBearerToken(text, token);

  // 3. 模型目录
  const catalog = buildCatalog({
    settings: { modelCatalog: provider.modelCatalog },
    configText: text,
    apiFormat,
    isOfficial: false,
  });
  if (catalog) {
    writeAtomic(ccSwitchCatalogPath(), `${JSON.stringify(catalog, null, 2)}\n`);
    text = setCatalogJsonField(text, true);
  } else {
    text = setCatalogJsonField(text, false);
  }

  return { text, catalog };
}

/**
 * 执行切换（不含重启）。
 * @returns {{backupPath: string|null, verified: boolean, effective: object|null, warnings: string[]}}
 */
export async function switchProvider({ provider, commonConfig, apiFormat, log = console.log, dryRun = false }) {
  const configPath = codexConfigPath();
  const warnings = [];

  const liveConfigText = existsSync(configPath) ? readFileSync(configPath, "utf8") : null;
  const { text, catalog } = buildProviderConfig({ provider, commonConfig, apiFormat, liveConfigText });

  log(`  目标供应商: ${provider.name} (${provider.id})`);
  if (catalog) log(`  模型目录: ${catalog.models.length} 个模型 (${catalog.models.map((m) => m.slug).join(", ")})`);

  if (dryRun) {
    return { backupPath: null, verified: false, effective: null, warnings, preview: text };
  }

  // 备份现有配置
  let backupPath = null;
  if (existsSync(configPath)) {
    backupPath = `${configPath}.bak_${timestamp()}`;
    copyFileSync(configPath, backupPath);
    log(`  已备份原配置: ${backupPath}`);
  }

  writeAtomic(configPath, text);
  log(`  已写入: ${configPath}`);

  // 校验：用一次性 app-server 读取生效配置
  const codexBin = findCodexBinary();
  if (!codexBin) {
    warnings.push("找不到 codex 二进制，跳过配置校验");
    return { backupPath, verified: false, effective: null, warnings };
  }
  const result = await readEffectiveConfig({ codexBin, codexHome: codexHome() });
  if (!result.ok) {
    warnings.push(`配置校验失败: ${result.error}（已写入的配置保留，可用备份回滚）`);
    return { backupPath, verified: false, effective: null, warnings };
  }

  const cfg = result.config;
  const effectiveProvider = cfg.model_provider ?? cfg.modelProvider ?? null;
  const effectiveModel = cfg.model ?? null;
  const providerTable =
    (effectiveProvider && (cfg.model_providers?.[effectiveProvider] ?? cfg.modelProviders?.[effectiveProvider])) ||
    null;
  log(`  生效配置: model_provider=${effectiveProvider} model=${effectiveModel}`);
  if (providerTable?.base_url) log(`  base_url: ${providerTable.base_url}`);

  // 校验 bearer token 是否随配置生效
  const token = provider.auth?.OPENAI_API_KEY?.trim();
  if (token && providerTable) {
    const effectiveToken = providerTable.experimental_bearer_token;
    if (!effectiveToken) {
      warnings.push("生效配置中未找到 experimental_bearer_token（可能该供应商使用其它鉴权方式）");
    } else if (effectiveToken !== token) {
      warnings.push("生效的 bearer token 与供应商配置不一致，请确认");
    } else {
      log(`  bearer token: 已生效 ✔`);
    }
  }

  // 校验 model 与供应商声明一致
  const expectedModel = (provider.config.match(/^\s*model\s*=\s*"([^"]+)"/m) ?? [])[1] ?? null;
  if (expectedModel && effectiveModel && expectedModel !== effectiveModel) {
    warnings.push(`生效模型 (${effectiveModel}) 与供应商声明 (${expectedModel}) 不一致（可能被其它配置层覆盖）`);
  }

  return {
    backupPath,
    verified: true,
    effective: {
      modelProvider: effectiveProvider,
      model: effectiveModel,
      baseUrl: providerTable?.base_url ?? null,
    },
    warnings,
  };
}

export function isOfficialProvider(provider) {
  return OFFICIAL_IDS.has(provider.id);
}
