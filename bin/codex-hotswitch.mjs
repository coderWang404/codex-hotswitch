#!/usr/bin/env node
// codex-hotswitch — 不重启 Codex 应用，热切换 cc-switch 管理的第三方模型供应商。
import { parseArgs } from "node:util";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import {
  listCodexProviders,
  getCurrentProvider,
  findProvider,
  syncCurrentProvider,
  getCodexCommonConfig,
} from "../src/ccswitch-db.mjs";
import { switchProvider, isOfficialProvider } from "../src/switcher.mjs";
import { reloadAppServers, discoverCodexProcesses, waitForRespawn, selectTargets } from "../src/reloader.mjs";
import { watchConfig } from "../src/watcher.mjs";
import { loadRemotes, syncRemotes, inspectRemotes } from "../src/remote-sync.mjs";
import { findCodexBinary, readEffectiveConfig } from "../src/verify-client.mjs";
import { readFileSync } from "node:fs";
import { codexConfigPath, codexHome, ccSwitchDbPath } from "../src/paths.mjs";

const HELP = `codex-hotswitch — 不重启 Codex，热切换第三方模型供应商

用法:
  codex-hotswitch list                  列出所有 codex 供应商
  codex-hotswitch current               查看当前供应商与生效配置
  codex-hotswitch switch <名称/ID>      切换供应商并热重启 Codex（核心命令）
  codex-hotswitch reload                仅热重启 app-server（常用于 cc-switch 界面切换后）
  codex-hotswitch watch                 持续监控配置，切换后自动热重启（推荐常驻）
  codex-hotswitch sync-remote           把本机供应商配置同步到远程 Codex，并重启远程 app-server
  codex-hotswitch remote-status         查看远程正在使用的供应商和密钥尾号
  codex-hotswitch doctor                检查运行环境

选项:
  --scope <范围>        chatgpt（默认，主 app-server）| chatgpt-all（含 computer-use 会话）| all
  --drain <秒>          SIGTERM 平滑等待秒数（默认 8）
  --hard                跳过平滑退出，直接强制结束
  --force               cc-switch 正在运行时，仍强制从命令行切换（有卡片错位风险）
  --no-reload           只写配置，不重启 Codex
  --no-remote           不同步远程机器（内置机器见 src/remotes.json，自定义见 ~/.codex-hotswitch/remotes.json）
  --dry-run             只展示将写入的配置，不落盘
  --focus / --no-focus  重启后是否把 ChatGPT 窗口切到前台（默认 focus）
  --json                以 JSON 输出（供桌面 App / 脚本调用）
  -h, --help            显示帮助
`;

/** cc-switch 是否正在运行（它在运行时会把自己的内存状态回填到卡片，外部改配置有错位风险）。 */
function isCcSwitchRunning() {
  try {
    execFileSync("pgrep", ["-f", "CC Switch.app/Contents/MacOS/cc-switch"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function makeLogger(jsonMode) {
  const noop = () => {};
  return {
    log: jsonMode ? noop : console.log,
    warn: jsonMode ? noop : console.log,
  };
}

function fmtCurrent(p) {
  return p ? `${p.name} (${p.id})` : "(未知)";
}

function modelOf(configText) {
  return (configText?.match(/^\s*model\s*=\s*"([^"]+)"/m) ?? [])[1] ?? null;
}

function hostOf(url) {
  if (!url) return null;
  try {
    return new URL(url.includes("://") ? url : `https://${url}`).host;
  } catch {
    return null;
  }
}

function tokenTailOf(token) {
  return typeof token === "string" && token.length > 0 ? token.slice(-8) : null;
}

export function providerSummary(p) {
  const baseUrl = p.config.match(/^\s*base_url\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  return {
    id: p.id,
    name: p.name,
    isCurrent: !!p.isCurrent,
    model: modelOf(p.config),
    catalogCount: p.modelCatalog?.models?.length ?? 0,
    official: isOfficialProvider(p),
    hasConfig: !!p.config.trim(),
    baseUrl,
    host: hostOf(baseUrl),
    tokenTail: tokenTailOf(p.auth?.OPENAI_API_KEY),
  };
}

/** 解析 config.toml 中实际生效的供应商表（base_url / token）。 */
function liveProviderInfo(configText) {
  const providerId = configText.match(/^\s*model_provider\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  const lines = configText.split(/\r?\n/);
  const esc = (v) => v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const header = providerId
    ? new RegExp(`^\\s*\\[\\s*model_providers\\s*\\.\\s*(?:"${esc(providerId)}"|${esc(providerId)})\\s*\\]`)
    : null;
  let start = -1;
  if (header) {
    for (let i = 0; i < lines.length; i++) {
      if (header.test(lines[i])) { start = i; break; }
    }
  }
  if (start === -1) return { providerId, baseUrl: null, tokenTail: null, host: null, model: null };
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\s*\[/.test(lines[i])) { end = i; break; }
  }
  const body = lines.slice(start + 1, end).join("\n");
  const baseUrl = body.match(/base_url\s*=\s*"([^"]+)"/)?.[1] ?? null;
  const token = body.match(/experimental_bearer_token\s*=\s*"([^"]+)"/)?.[1] ?? null;
  return {
    providerId,
    baseUrl,
    tokenTail: tokenTailOf(token),
    host: hostOf(baseUrl),
    model: configText.match(/^\s*model\s*=\s*"([^"]+)"/m)?.[1] ?? null,
  };
}

function printProviderTable(summaries, currentId) {
  if (!summaries.length) {
    console.log("没有找到任何 codex 供应商。");
    return;
  }
  const nameW = Math.max(...summaries.map((p) => [...p.name].length), 4);
  for (const p of summaries) {
    const mark = p.id === currentId ? "●" : "○";
    const pad = " ".repeat(Math.max(0, nameW - [...p.name].length));
    const catalog = p.catalogCount ? ` | 目录 ${p.catalogCount} 模型` : "";
    const host = p.host ? ` | ${p.host}` : "";
    console.log(`  ${mark} ${p.name}${pad}  model=${p.model ?? "-"}${host}${catalog}  [${p.id}]`);
  }
  console.log("\n  ● = 当前供应商。切换: codex-hotswitch switch <名称>");
}

async function effectiveConfig() {
  const bin = findCodexBinary();
  if (!bin) return { ok: false, error: "未找到 codex 二进制" };
  const res = await readEffectiveConfig({ codexBin: bin, codexHome: codexHome() });
  if (!res.ok) return { ok: false, error: res.error };
  const cfg = res.config;
  const pid = cfg.model_provider ?? cfg.modelProvider ?? null;
  const table = pid ? (cfg.model_providers?.[pid] ?? cfg.modelProviders?.[pid]) : null;
  return {
    ok: true,
    modelProvider: pid,
    model: cfg.model ?? null,
    baseUrl: table?.base_url ?? null,
    hasToken: !!table?.experimental_bearer_token,
    catalogJson: cfg.model_catalog_json ?? null,
  };
}

async function cmdList(opts) {
  const { log } = opts;
  const providers = listCodexProviders();
  const current = getCurrentProvider();
  const summaries = providers.map(providerSummary);
  const currentId = current?.id ?? null;

  // 实际生效的配置（config.toml 是 Codex 真正读取的文件）
  let live = null;
  const configPath = codexConfigPath();
  if (existsSync(configPath)) {
    try {
      live = liveProviderInfo(readFileSync(configPath, "utf8"));
    } catch {
      live = null;
    }
  }
  const matchedIds = live
    ? summaries
        .filter((s) => s.baseUrl && s.baseUrl === live.baseUrl && s.tokenTail && s.tokenTail === live.tokenTail)
        .map((s) => s.id)
    : [];
  const liveProviderId = matchedIds.includes(currentId) ? currentId : (matchedIds[0] ?? null);

  log(`\nCodex 供应商（共 ${providers.length} 个）:\n`);
  if (!opts.json) printProviderTable(summaries, currentId);
  return {
    command: "list",
    currentId,
    providers: summaries,
    live: live ? { ...live, matchedIds, liveProviderId } : null,
    ccSwitchRunning: isCcSwitchRunning(),
  };
}

async function cmdCurrent(opts) {
  const { log } = opts;
  const current = getCurrentProvider();
  log(`\ncc-switch 当前供应商: ${fmtCurrent(current)}`);
  log(`配置文件: ${codexConfigPath()}`);
  const eff = await effectiveConfig();
  if (eff.ok) {
    log(`实际生效: model_provider=${eff.modelProvider} model=${eff.model}`);
    if (eff.baseUrl) log(`          base_url=${eff.baseUrl}`);
  } else {
    log(`实际生效: (读取失败: ${eff.error})`);
  }
  const { appServers, tuis } = discoverCodexProcesses();
  log(`\n运行中的 app-server: ${appServers.length} 个`);
  for (const p of appServers) log(`  - pid ${p.pid} [${p.owner}/${p.kind}]`);
  if (tuis.length) log(`终端 codex 会话: ${tuis.length} 个（需要自行重启才能生效）`);
  return {
    command: "current",
    current: current ? { id: current.id, name: current.name } : null,
    configPath: codexConfigPath(),
    effective: eff,
    appServers: appServers.map((p) => ({ pid: p.pid, owner: p.owner, kind: p.kind, topLevel: p.topLevel })),
    tuiCount: tuis.length,
  };
}

function doReloadHuman(opts, { targets, terminated, killed, respawned }) {
  const { log } = opts;
  if (!targets.length) {
    log(`  ℹ️  没有运行中的 app-server。下次启动 Codex 时自动使用新配置。`);
    return;
  }
  log(`\n✅ 已重启 ${terminated + killed} 个 app-server（平滑 ${terminated}${killed ? `，强制 ${killed}` : ""}）`);
  if (killed) {
    log(`   ⚠️  强制结束会让界面显示恢复页：点一次「Restart ChatGPT」即可（不会丢失对话）。`);
  } else if (respawned) {
    log(`   🎉 应用已自动拉起新的 app-server (pid ${respawned.pid})，新供应商已生效。`);
  } else {
    log(`   ℹ️  点击 ChatGPT 里任意对话（或新建对话）即可让新供应商生效，无需重启应用。`);
  }
}

async function doReload(opts) {
  const { log } = opts;
  const { appServers, tuis } = discoverCodexProcesses();
  const targets = selectTargets(appServers, opts.scope);
  log(`\n♻️  热重启 Codex app-server（scope=${opts.scope}）...`);
  if (tuis.length) {
    log(`  ⚠️  检测到 ${tuis.length} 个终端 codex 会话：它们需要自行重启才能生效`);
  }
  if (!targets.length) {
    const result = { targets: [], terminated: 0, killed: 0, respawned: null, tuiCount: tuis.length };
    doReloadHuman(opts, result);
    return result;
  }
  if (opts.dryRun) {
    log(`  [dry-run] 将重启以下进程：${targets.map((t) => t.pid).join(", ")}`);
    return {
      targets: targets.map((t) => ({ pid: t.pid, owner: t.owner })),
      terminated: 0,
      killed: 0,
      respawned: null,
      dryRun: true,
      tuiCount: tuis.length,
    };
  }
  const knownPids = appServers.map((p) => p.pid);
  const result = await reloadAppServers({
    scope: opts.scope,
    drainTimeoutMs: opts.drainMs,
    hard: opts.hard,
    log: opts.log, // JSON 模式下为 no-op，避免污染 stdout
  });
  const killed = result.outcomes.filter((o) => o.outcome === "killed").length;
  const terminated = result.outcomes.filter((o) => o.outcome === "terminated").length;
  let respawned = null;
  if (!killed && terminated) {
    // ChatGPT 在窗口获得焦点时会重连并自动拉起新 app-server（实测）。
    // 需要等应用先感知到连接断开，再激活窗口，否则焦点事件会早于断连状态。
    const focusChatGPT = () => {
      if (!opts.focus) return;
      try {
        execFileSync("open", ["-a", "ChatGPT"]);
      } catch {
        /* 忽略 */
      }
    };
    focusChatGPT();
    respawned = await waitForRespawn(knownPids, { scope: opts.scope, timeoutMs: 4000 });
    if (!respawned) {
      // 再试一次：有些情况下第一次激活时应用尚未处理完断连
      focusChatGPT();
      respawned = await waitForRespawn(knownPids, { scope: opts.scope, timeoutMs: 6000 });
    }
  }
  const out = {
    targets: targets.map((t) => ({ pid: t.pid, owner: t.owner })),
    terminated,
    killed,
    respawned: respawned ? { pid: respawned.pid } : null,
    tuiCount: tuis.length,
  };
  doReloadHuman(opts, out);
  return out;
}

async function cmdSwitch(query, opts) {
  const { log } = opts;
  const provider = findProvider(query);
  if (!provider) {
    throw new Error(`找不到供应商「${query}」。可用: codex-hotswitch list`);
  }
  if (isOfficialProvider(provider)) {
    throw new Error(
      `「${provider.name}」是官方供应商，涉及 ChatGPT 登录态（auth.json），请用 cc-switch 界面切换，然后运行 codex-hotswitch reload`,
    );
  }

  // cc-switch 运行时，外部直接改 live 配置会被它回填到"它以为的当前卡片"，造成卡片内容错位。
  if (isCcSwitchRunning() && !opts.force) {
    throw new Error(
      `cc-switch 正在运行，为避免它把你的配置回填到错误的供应商卡片，本工具默认不直接切换。\n` +
        `  推荐做法：在 cc-switch 界面点击「${provider.name}」——本工具的「自动跟随」会自动热重启 Codex（效果完全一样）。\n` +
        `  如果确认要强制从命令行切换：加 --force（并建议随后在 cc-switch 里核对当前卡片）`,
    );
  }

  log(`\n🔀 切换到 ${fmtCurrent(provider)}`);
  const common = getCodexCommonConfig();
  const result = await switchProvider({
    provider,
    commonConfig: common,
    apiFormat: provider.meta?.apiFormat,
    dryRun: opts.dryRun,
    log,
  });

  if (opts.dryRun) {
    log("\n--- 将写入的 config.toml (dry-run) ---\n");
    log(result.preview);
    return { command: "switch", dryRun: true, provider: providerSummary(provider), preview: result.preview };
  }

  for (const w of result.warnings) log(`  ⚠️  ${w}`);

  let synced = false;
  if (!process.env.CODEX_HOME?.trim()) {
    synced = syncCurrentProvider(provider.id);
    if (synced) {
      log(`  已同步 cc-switch 当前供应商标记`);
    } else {
      log(`  ⚠️ 同步 cc-switch 当前供应商标记失败！这会让 cc-switch 后续把配置回填到错误的卡片，请手动在 cc-switch 里核对当前卡片`);
    }
  } else {
    log(`  已指定 CODEX_HOME，跳过 cc-switch 状态同步`);
  }

  let reload = null;
  if (opts.reload) {
    reload = await doReload(opts);
  } else {
    log(`  已跳过重启（--no-reload）。新开 Codex 会话时生效。`);
  }

  const remote = await maybeSyncRemotes(opts);

  return {
    command: "switch",
    provider: providerSummary(provider),
    effective: result.effective,
    verified: result.verified,
    backupPath: result.backupPath,
    synced,
    warnings: result.warnings,
    reload,
    remote,
  };
}

async function maybeSyncRemotes(opts) {
  if (!opts.remote) return null;
  return syncRemotes({ dryRun: opts.dryRun, log: opts.log });
}

async function cmdReload(opts) {
  const { log } = opts;
  const current = getCurrentProvider();
  log(`\n当前供应商: ${fmtCurrent(current)}`);
  const remote = await maybeSyncRemotes(opts);
  const reload = await doReload(opts);
  return {
    command: "reload",
    current: current ? { id: current.id, name: current.name } : null,
    reload,
    remote,
  };
}

async function cmdSyncRemote(opts) {
  const remote = await syncRemotes({ dryRun: opts.dryRun, log: opts.log });
  return { command: "sync-remote", remote };
}

async function cmdRemoteStatus(opts) {
  const remote = await inspectRemotes();
  for (const host of remote.hosts) {
    if (!host.ok) {
      opts.log(`  ❌ ${host.label}: ${host.error ?? "读取失败"}`);
      continue;
    }
    const endpoint = hostOf(host.baseUrl) ?? host.baseUrl ?? "-";
    opts.log(`  ${host.label}: ${host.providerName ?? "-"} · ${endpoint} · key …${host.tokenTail ?? "-"}`);
  }
  return { command: "remote-status", remote };
}

async function cmdWatch(opts) {
  await watchConfig({
    intervalMs: 800,
    scope: opts.scope,
    drainTimeoutMs: opts.drainMs,
    dryRun: opts.dryRun,
    syncRemote: opts.remote,
    json: opts.json,
    log: opts.json
      ? (line) => process.stdout.write(`${JSON.stringify({ event: "log", message: line })}\n`)
      : console.log,
  });
  return null;
}

function cmdDoctor(opts) {
  const { log } = opts;
  log("\n🩺 环境检查\n");
  const checks = [];
  const db = ccSwitchDbPath();
  checks.push({ ok: existsSync(db), label: `cc-switch 数据库: ${db}` });
  const cfg = codexConfigPath();
  checks.push({ ok: existsSync(cfg), label: `Codex 配置: ${cfg}` });
  const nodeVer = process.versions.node;
  checks.push({ ok: Number(nodeVer.split(".")[0]) >= 18, label: `Node.js: v${nodeVer}` });
  try {
    execFileSync("sqlite3", ["--version"], { stdio: "ignore" });
    checks.push({ ok: true, label: "sqlite3 CLI: 可用" });
  } catch {
    checks.push({ ok: false, label: "sqlite3 CLI: 不可用（macOS 自带，若缺失请 brew install sqlite）" });
  }
  const bin = findCodexBinary();
  checks.push({ ok: !!bin, label: `codex 二进制: ${bin ?? "未找到"}` });
  const remotes = loadRemotes();
  checks.push({
    ok: remotes.length > 0,
    label: remotes.length
      ? `远程主机: ${remotes.map((item) => item.label).join(", ")}（SSH 密钥走 ~/.ssh/config）`
      : "远程主机: 未配置 src/remotes.json",
  });
  const { appServers, tuis } = discoverCodexProcesses();
  checks.push({ ok: true, label: `运行中的 app-server: ${appServers.length} 个` });
  if (tuis.length) checks.push({ ok: true, label: `终端 codex 会话: ${tuis.length} 个（切换后需自行重启）` });

  for (const c of checks) log(`  ${c.ok ? "✅" : "❌"} ${c.label}`);
  const failed = checks.filter((c) => !c.ok).length;
  log(failed ? `\n有 ${failed} 项需要处理。` : "\n一切就绪。");
  return { command: "doctor", checks, failed };
}

async function main() {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      scope: { type: "string", default: "chatgpt" },
      drain: { type: "string" },
      hard: { type: "boolean", default: false },
      force: { type: "boolean", default: false },
      "no-reload": { type: "boolean", default: false },
      "no-remote": { type: "boolean", default: false },
      "dry-run": { type: "boolean", default: false },
      json: { type: "boolean", default: false },
      focus: { type: "boolean" },
      "no-focus": { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });

  const json = values.json;
  const { log, warn } = makeLogger(json);
  const opts = {
    json,
    log: json ? log : console.log,
    warn: json ? warn : console.log,
    scope: ["all", "chatgpt-all", "chatgpt"].includes(values.scope) ? values.scope : "chatgpt",
    drainMs: values.drain ? Math.max(0, Number(values.drain)) * 1000 : 8000,
    reload: !values["no-reload"],
    remote: !values["no-remote"],
    hard: values.hard,
    force: values.force,
    dryRun: values["dry-run"],
    focus: values["no-focus"] ? false : values.focus !== false,
  };

  const [command, arg] = positionals;
  if (values.help || !command) {
    if (json) console.log(JSON.stringify({ command: "help", text: HELP }));
    else console.log(HELP);
    return;
  }

  let result;
  switch (command) {
    case "list":
      result = await cmdList(opts);
      break;
    case "current":
      result = await cmdCurrent(opts);
      break;
    case "switch":
      if (!arg) throw new Error("用法: codex-hotswitch switch <名称/ID>");
      result = await cmdSwitch(arg, opts);
      break;
    case "reload":
      result = await cmdReload(opts);
      break;
    case "sync-remote":
      result = await cmdSyncRemote(opts);
      break;
    case "remote-status":
      result = await cmdRemoteStatus(opts);
      break;
    case "watch":
      result = await cmdWatch(opts);
      break;
    case "doctor":
      result = cmdDoctor(opts);
      break;
    default:
      throw new Error(`未知命令: ${command}`);
  }

  if (json && result != null) {
    console.log(JSON.stringify({ ok: true, ...result }));
  }
}

main().catch((err) => {
  const json = process.argv.includes("--json");
  if (json) console.log(JSON.stringify({ ok: false, error: String(err.message ?? err) }));
  else console.error(`\n❌ ${err.message}`);
  process.exit(1);
});
