// 通过临时 app-server 实例校验写入后的配置（只读，不触碰正在运行的实例）。
import { spawn, execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { CHATGPT_CODEX_BIN } from "./paths.mjs";

/** 找到一个可用的 codex 二进制：优先 ChatGPT 应用内置，其次 npm 全局安装。 */
export function findCodexBinary() {
  const candidates = [
    CHATGPT_CODEX_BIN,
    "/usr/local/bin/codex",
    "/opt/homebrew/bin/codex",
    `${process.env.HOME}/.local/bin/codex`,
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  // npm 全局：扫描 nvm / fnm 版本目录
  try {
    const found = execSync(
      `ls -d ${process.env.HOME}/.nvm/versions/node/*/bin/codex ${process.env.HOME}/.local/share/fnm/*/bin/codex 2>/dev/null | head -1`,
      { encoding: "utf8" },
    ).trim();
    if (found) return found;
  } catch {
    /* ignore */
  }
  return null;
}

/**
 * 启动一次性 app-server，读取生效配置。
 * @returns {Promise<{ok: boolean, config?: object, error?: string}>}
 */
export function readEffectiveConfig({ codexBin, codexHome, timeoutMs = 20000 }) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (v) => {
      if (!settled) {
        settled = true;
        resolve(v);
      }
    };

    const child = spawn(codexBin, ["app-server", "--listen", "stdio://"], {
      env: { ...process.env, CODEX_HOME: codexHome, RUST_LOG: "error" },
      stdio: ["pipe", "pipe", "pipe"],
    });

    let buffer = "";
    let nextId = 1;
    const pending = new Map();
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
      done({ ok: false, error: "校验超时" });
    }, timeoutMs);
    timer.unref?.();

    function request(method, params) {
      const id = nextId++;
      return new Promise((res, rej) => {
        const reqTimer = setTimeout(() => {
          if (pending.has(id)) {
            pending.delete(id);
            rej(new Error(`timeout: ${method}`));
          }
        }, timeoutMs - 2000);
        reqTimer.unref?.();
        pending.set(id, { res, rej, timer: reqTimer });
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      });
    }

    child.stdout.on("data", (d) => {
      buffer += d.toString("utf8");
      let idx;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id !== undefined && pending.has(msg.id)) {
          const { res, rej, timer: reqTimer } = pending.get(msg.id);
          clearTimeout(reqTimer);
          pending.delete(msg.id);
          if (msg.error) rej(new Error(JSON.stringify(msg.error)));
          else res(msg.result);
        }
      }
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      done({ ok: false, error: `无法启动 codex 二进制: ${err.message}` });
    });

    (async () => {
      try {
        await request("initialize", {
          clientInfo: { name: "codex-hotswitch", title: "verify", version: "1.0.0" },
          capabilities: { experimentalApi: false },
        });
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "initialized", params: {} })}\n`);
        const res = await request("config/read", {});
        clearTimeout(timer);
        try {
          child.kill("SIGTERM");
        } catch {
          /* ignore */
        }
        done({ ok: true, config: res.config ?? {} });
      } catch (err) {
        clearTimeout(timer);
        try {
          child.kill("SIGKILL");
        } catch {
          /* ignore */
        }
        done({ ok: false, error: err.message });
      }
    })();
  });
}
