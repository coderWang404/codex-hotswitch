// 路径解析：CODEX_HOME 与 cc-switch 数据目录。
import os from "node:os";
import path from "node:path";

export function home() {
  return process.env.CODEX_HOMESWITCH_HOME || os.homedir();
}

/** cc-switch 管理的 Codex 配置目录（尊重 CODEX_HOME 环境变量）。 */
export function codexHome() {
  return process.env.CODEX_HOME?.trim() || path.join(os.homedir(), ".codex");
}

export function codexConfigPath() {
  return path.join(codexHome(), "config.toml");
}

export function codexAuthPath() {
  return path.join(codexHome(), "auth.json");
}

/** cc-switch 生成的模型目录文件（所有供应商共用同一路径）。 */
export function ccSwitchCatalogPath() {
  return path.join(codexHome(), "cc-switch-model-catalog.json");
}

export function ccSwitchDir() {
  return path.join(os.homedir(), ".cc-switch");
}

export function ccSwitchDbPath() {
  return path.join(ccSwitchDir(), "cc-switch.db");
}

export function ccSwitchSettingsPath() {
  return path.join(ccSwitchDir(), "settings.json");
}

/** ChatGPT 桌面应用内置的 codex 二进制（app-server 的父进程标识）。 */
export const CHATGPT_CODEX_BIN = "/Applications/ChatGPT.app/Contents/Resources/codex";
