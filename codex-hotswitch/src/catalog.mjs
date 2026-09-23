// 模型目录生成：从 cc-switch 的 provider settings + config 文本生成
// Codex 可用的 model_catalog_json（算法移植自 cc-switch 源码 codex_config.rs）。
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TEMPLATE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "templates");
const loadTemplate = (name) => JSON.parse(readFileSync(path.join(TEMPLATE_DIR, name), "utf8"));

const NATIVE_TEMPLATE = loadTemplate("codex_native_responses_template.json");
const PROXY_CHAT_TEMPLATE = loadTemplate("gpt5_5_template.json");
const DEEPSEEK_VENDOR_CATALOG = loadTemplate("codex_deepseek_catalog_template.json").models ?? [];

/** Codex 认识的推理档位（与官方 gpt-5.5 模板一致）。 */
const REASONING_LEVEL_DESCRIPTIONS = [
  ["none", "Disable Thinking"],
  ["minimal", "Minimal reasoning"],
  ["low", "Fast responses with lighter reasoning"],
  ["medium", "Balances speed and reasoning depth for everyday tasks"],
  ["high", "Greater reasoning depth for complex problems"],
  ["xhigh", "Extra high reasoning depth for complex problems"],
  ["max", "Maximum reasoning depth for the hardest problems"],
  ["ultra", "Ultra reasoning depth"],
];

/** 已确认纯文本的模型（fail-open：不在名单中的模型都按支持图片处理）。 */
const CONFIRMED_TEXT_ONLY_TAILS = [
  "ark-code-latest",
  "deepseek-chat",
  "deepseek-reasoner",
  "glm-5.1",
  "glm-5.2",
  "glm-5.3",
  "kat-coder",
  "kat-coder-pro",
  "kat-coder-pro v1",
  "kat-coder-pro v2",
  "kat-coder-pro-v1",
  "kat-coder-pro-v2",
  "ling-2.5-1t",
  "longcat-2.0",
  "longcat-flash-chat",
  "minimax-m2.7",
  "minimax-m2.7-highspeed",
  "mimo-v2.5-pro",
  "qwen3-coder-480b",
  "qwen3-coder-480b-a35b-instruct",
  "qwen3-coder-flash",
  "qwen3-coder-next",
  "qwen3-coder-plus",
  "step-3.5-flash",
  "step-3.5-flash-2603",
  "us.deepseek.r1-v1",
];

const NATIVE_RESPONSES_HOSTS = [
  "bigmodel.cn",
  "z.ai",
  "xiaomimimo.com",
  "minimaxi.com",
  "minimax.io",
  "longcat.chat",
];
const NATIVE_RESPONSES_CHAT_PATH_MARKERS = ["/paas/v4"];
const DEEPSEEK_OFFICIAL_CATALOG_HOSTS = ["deepseek.com"];

function normalizeModelId(value) {
  return value.trim().replace(/^models\//, "").trim().toLowerCase();
}

function isConfirmedTextOnly(model) {
  const normalized = normalizeModelId(model);
  const tail = normalized.split("/").pop() ?? normalized;
  return CONFIRMED_TEXT_ONLY_TAILS.includes(tail);
}

function imageInputCapability(model, declaredSupport) {
  if (declaredSupport === true) return "supported";
  if (declaredSupport === false) return "unsupported";
  if (isConfirmedTextOnly(model)) return "unsupported";
  return "unknown";
}

function catalogInputModalities(model, declaredModalities) {
  const declaredSupport = Array.isArray(declaredModalities)
    ? declaredModalities.some((m) => String(m).trim().toLowerCase() === "image")
    : undefined;
  const cap = imageInputCapability(model, declaredSupport);
  return cap === "unsupported" ? ["text"] : ["text", "image"];
}

function firstDefined(obj, keys) {
  for (const key of keys) {
    if (obj[key] !== undefined && obj[key] !== null) return obj[key];
  }
  return undefined;
}

function parsePositiveInt(value) {
  const n = typeof value === "number" ? value : Number.parseInt(value, 10);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : undefined;
}

/** 把 provider settings.modelCatalog.models 解析成内部 spec 列表。 */
export function catalogModelSpecs(settings) {
  const models = settings?.modelCatalog?.models;
  if (!Array.isArray(models)) return [];

  const seen = new Set();
  const specs = [];
  for (const cfg of models) {
    if (!cfg || typeof cfg !== "object") continue;
    const model = typeof cfg.model === "string" ? cfg.model.trim() : "";
    if (!model || seen.has(model)) continue;
    seen.add(model);

    const displayNameRaw = firstDefined(cfg, ["displayName", "display_name"]);
    const displayName =
      typeof displayNameRaw === "string" && displayNameRaw.trim() ? displayNameRaw.trim() : undefined;

    const contextWindow = parsePositiveInt(firstDefined(cfg, ["contextWindow", "context_window"]));
    const supportsParallel = firstDefined(cfg, [
      "supportsParallelToolCalls",
      "supports_parallel_tool_calls",
    ]);

    const inputModalitiesRaw = firstDefined(cfg, ["inputModalities", "input_modalities"]);
    const inputModalities = Array.isArray(inputModalitiesRaw)
      ? inputModalitiesRaw.filter((m) => typeof m === "string").map((m) => m.trim()).filter(Boolean)
      : undefined;

    const baseInstructionsRaw = firstDefined(cfg, ["baseInstructions", "base_instructions"]);
    const baseInstructions =
      typeof baseInstructionsRaw === "string" && baseInstructionsRaw.trim()
        ? baseInstructionsRaw.trim()
        : undefined;

    const reasoningLevelsRaw = firstDefined(cfg, ["reasoningLevels", "reasoning_levels"]);
    const reasoningLevels = Array.isArray(reasoningLevelsRaw)
      ? reasoningLevelsRaw
          .filter((l) => typeof l === "string")
          .map((l) => l.trim())
          .filter(Boolean)
      : undefined;

    const defaultReasoningRaw = firstDefined(cfg, [
      "defaultReasoningLevel",
      "default_reasoning_level",
    ]);
    const defaultReasoningLevel =
      typeof defaultReasoningRaw === "string" && defaultReasoningRaw.trim()
        ? defaultReasoningRaw.trim()
        : undefined;

    specs.push({
      model,
      displayName,
      contextWindow,
      supportsParallelToolCalls:
        typeof supportsParallel === "boolean" ? supportsParallel : undefined,
      inputModalities: inputModalities?.length ? inputModalities : undefined,
      baseInstructions,
      reasoningLevels: reasoningLevels?.length ? reasoningLevels : undefined,
      defaultReasoningLevel,
    });
  }
  return specs;
}

function extractBaseUrlFromConfig(configText) {
  const m = configText.match(/^\s*base_url\s*=\s*"((?:[^"\\]|\\.)*)"/m);
  return m ? m[1].replace(/\\"/g, '"') : null;
}

function extractTopLevelInt(configText, key) {
  const m = configText.match(new RegExp(`^\\s*${key}\\s*=\\s*(\\d+)`, "m"));
  return m ? Number.parseInt(m[1], 10) : undefined;
}

function hostMatches(url, hosts) {
  if (!url) return false;
  let host;
  try {
    host = new URL(url.includes("://") ? url : `https://${url}`).hostname.toLowerCase();
  } catch {
    host = url.toLowerCase();
  }
  return hosts.some((h) => host === h || host.endsWith(`.${h}`) || url.toLowerCase().includes(h));
}

function isNativeResponsesUrl(baseUrl) {
  if (!hostMatches(baseUrl, NATIVE_RESPONSES_HOSTS)) return false;
  const lower = baseUrl.toLowerCase();
  if (lower.includes("/chat/completions") || /\/v\d+\/chat\b/.test(lower)) return false;
  return !NATIVE_RESPONSES_CHAT_PATH_MARKERS.some((marker) => lower.includes(marker));
}

/**
 * 解析 catalog 工具 profile：'NativeResponses' | 'Anthropic' | 'ProxyChat'
 * （对应 cc-switch 的 resolve_codex_catalog_tool_profile，覆盖常见路径）
 */
export function resolveCatalogProfile({ apiFormat, configText, isOfficial }) {
  if (isOfficial) return "NativeResponses";
  const baseUrl = extractBaseUrlFromConfig(configText || "");
  const format = (apiFormat || "").trim().toLowerCase();
  if (format === "anthropic") return "Anthropic";
  if (format === "openai_responses") return "NativeResponses";
  if (format === "openai_chat") return "ProxyChat";
  // 无 apiFormat：按 base_url / wire_api 推断
  if (baseUrl && isNativeResponsesUrl(baseUrl)) return "NativeResponses";
  const wireApi = (configText || "").match(/^\s*wire_api\s*=\s*"([^"]+)"/m)?.[1]?.toLowerCase();
  if (wireApi === "responses") return "NativeResponses";
  return "ProxyChat";
}

function canonicalEfforts(levels) {
  return REASONING_LEVEL_DESCRIPTIONS.filter(([effort]) => levels.includes(effort)).map(
    ([effort]) => effort,
  );
}

function applyReasoningLevelOverride(entry, templateDefault, spec) {
  if (!spec.reasoningLevels) return false;
  const canonical = canonicalEfforts(spec.reasoningLevels);
  if (!canonical.length) return false;
  entry.supported_reasoning_levels = canonical.map((effort) => ({
    effort,
    description: REASONING_LEVEL_DESCRIPTIONS.find(([e]) => e === effort)[1],
  }));
  const defaultLevel =
    (spec.defaultReasoningLevel && canonical.includes(spec.defaultReasoningLevel)
      ? spec.defaultReasoningLevel
      : undefined) ??
    (templateDefault && canonical.includes(templateDefault) ? templateDefault : undefined) ??
    canonical[canonical.length - 1];
  if (defaultLevel) entry.default_reasoning_level = defaultLevel;
  return true;
}

/** 从模板生成单条 catalog entry（移植 codex_catalog_model_entry）。 */
function buildCatalogEntry(template, spec, priority, profile, defaultContextWindow) {
  const entry = structuredClone(template);
  const displayName = spec.displayName || spec.model;
  const contextWindow = spec.contextWindow ?? defaultContextWindow;

  entry.slug = spec.model;
  entry.display_name = displayName;
  entry.description = displayName;
  entry.context_window = contextWindow;
  entry.max_context_window = contextWindow;
  entry.priority = 1000 + priority;
  entry.additional_speed_tiers = [];
  entry.service_tiers = [];
  entry.availability_nux = null;
  entry.upgrade = null;
  entry.input_modalities = catalogInputModalities(spec.model, spec.inputModalities);

  if (profile !== "ProxyChat") {
    for (const key of ["apply_patch_tool_type", "web_search_tool_type", "tools", "model_messages"]) {
      delete entry[key];
    }
    entry.shell_type = "shell_command";
    if (spec.baseInstructions) entry.base_instructions = spec.baseInstructions;
    if (spec.supportsParallelToolCalls !== undefined) {
      entry.supports_parallel_tool_calls = spec.supportsParallelToolCalls;
    }
  }

  applyReasoningLevelOverride(entry, template?.default_reasoning_level, spec);
  return entry;
}

/** 从官方 vendor catalog 生成 entry（deepseek 官方网关镜像路径）。 */
function buildVendorEntry(vendorModels, spec, priority) {
  const matched = vendorModels.find(
    (m) => typeof m?.slug === "string" && m.slug.toLowerCase() === spec.model.toLowerCase(),
  );
  const entry = structuredClone(matched ?? vendorModels[0] ?? {});
  const vendorDefault = entry.default_reasoning_level;

  if (!matched) {
    const displayName = spec.displayName || spec.model;
    entry.slug = spec.model;
    entry.display_name = displayName;
    entry.description = displayName;
    entry.priority = 1000 + priority;
    entry.input_modalities = catalogInputModalities(spec.model, spec.inputModalities);
  }

  if (spec.displayName) entry.display_name = spec.displayName;
  if (spec.contextWindow !== undefined) {
    entry.context_window = spec.contextWindow;
    entry.max_context_window = spec.contextWindow;
  }
  if (spec.supportsParallelToolCalls !== undefined) {
    entry.supports_parallel_tool_calls = spec.supportsParallelToolCalls;
  }
  if (spec.inputModalities) entry.input_modalities = spec.inputModalities;
  if (spec.baseInstructions) entry.base_instructions = spec.baseInstructions;

  applyReasoningLevelOverride(entry, vendorDefault, spec);
  return entry;
}

/**
 * 生成完整的 model catalog 对象；无可用模型时返回 null。
 * @returns {{models: object[]} | null}
 */
export function buildCatalog({ settings, configText, apiFormat, isOfficial = false }) {
  const specs = catalogModelSpecs(settings);
  if (!specs.length) return null;

  const profile = resolveCatalogProfile({ apiFormat, configText, isOfficial });
  const baseUrl = extractBaseUrlFromConfig(configText || "");

  // deepseek 官方网关：镜像官方 models.json（仅 NativeResponses profile）
  if (profile === "NativeResponses" && hostMatches(baseUrl, DEEPSEEK_OFFICIAL_CATALOG_HOSTS)) {
    if (DEEPSEEK_VENDOR_CATALOG.length) {
      return {
        models: specs.map((spec, i) => buildVendorEntry(DEEPSEEK_VENDOR_CATALOG, spec, i)),
      };
    }
  }

  const template = profile === "ProxyChat" ? PROXY_CHAT_TEMPLATE : NATIVE_TEMPLATE;
  const defaultContextWindow = extractTopLevelInt(configText || "", "model_context_window") ?? 128000;
  return {
    models: specs.map((spec, i) => buildCatalogEntry(template, spec, i, profile, defaultContextWindow)),
  };
}
