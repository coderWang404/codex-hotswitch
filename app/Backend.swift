// 后端桥接：定位 Node 与内置脚本，执行 CLI 命令并解析 JSON。
import Foundation

enum BackendError: LocalizedError {
    case nodeNotFound
    case scriptNotFound
    case commandFailed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            return "未找到 Node.js。请安装 Node 18+ 或在本 App 的设置中指定路径。"
        case .scriptNotFound:
            return "未找到内置的 codex-hotswitch 脚本，App 可能未完整打包。"
        case .commandFailed(let message):
            return message
        case .badOutput(let raw):
            return "无法解析命令输出: \(raw.prefix(200))"
        }
    }
}

final class Backend {
    static let shared = Backend()

    private(set) var nodePath: String?
    private(set) var scriptPath: String?

    private init() {
        nodePath = Self.resolveNodePath()
        scriptPath = Self.resolveScriptPath()
    }

    // MARK: - 路径解析

    static func resolveScriptPath() -> String? {
        // 1. 环境变量覆盖（开发调试用）
        if let override = ProcessInfo.processInfo.environment["CODEX_HOTSWITCH_SCRIPT"],
           FileManager.default.isExecutableFile(atPath: override) || FileManager.default.fileExists(atPath: override) {
            return override
        }
        // 2. App 内置副本
        if let resource = Bundle.main.resourceURL {
            let bundled = resource.appendingPathComponent("codex-hotswitch/bin/codex-hotswitch.mjs").path
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return nil
    }

    static func resolveNodePath() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        if let override = UserDefaults.standard.string(forKey: "nodePath"), !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return override
        }

        let fixed = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.local/bin/node",
            "\(home)/.bun/bin/node",
        ]
        for path in fixed where fm.isExecutableFile(atPath: path) { return path }

        // nvm：取版本号最大的一个
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = versions.sorted { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedDescending
            }
            for version in sorted {
                let candidate = "\(nvmRoot)/\(version)/bin/node"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        // fnm
        let fnmRoot = "\(home)/Library/Application Support/fnm/node-versions"
        if let versions = try? fm.contentsOfDirectory(atPath: fnmRoot) {
            for version in versions.sorted(by: >) {
                let candidate = "\(fnmRoot)/\(version)/installation/bin/node"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        // 登录 shell 兜底（GUI App 不继承终端 PATH）
        if let shellNode = Self.nodeFromLoginShell() { return shellNode }
        return nil
    }

    private static func nodeFromLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    // MARK: - 执行

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(extraPath):\(existing)"
        } else {
            env["PATH"] = extraPath
        }
        env["LANG"] = "zh_CN.UTF-8"
        return env
    }

    /// 同步执行 CLI（内部会切到后台线程由调用方负责）。
    func run(_ arguments: [String], timeout: TimeInterval = 90) throws -> Data {
        guard let nodePath else { throw BackendError.nodeNotFound }
        guard let scriptPath else { throw BackendError.scriptNotFound }
        if ProcessInfo.processInfo.environment["CODEX_HOTSWITCH_DEBUG"] != nil {
            FileHandle.standardError.write("RUN \(nodePath) \(scriptPath) \(arguments)\n".data(using: .utf8)!)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [scriptPath] + arguments + ["--json"]
        process.environment = environment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // 超时看门狗
        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        defer { watchdog.cancel() }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if ProcessInfo.processInfo.environment["CODEX_HOTSWITCH_DEBUG"] != nil {
            FileHandle.standardError.write("EXIT \(process.terminationStatus) out=\(outData.count)B err=\(errData.count)B\n".data(using: .utf8)!)
        }
        if process.terminationStatus != 0, outData.isEmpty {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendError.commandFailed(message?.isEmpty == false ? message! : "命令执行失败（退出码 \(process.terminationStatus)）")
        }
        return outData
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.badOutput(raw)
        }
    }

    // MARK: - 便捷命令

    func list() throws -> ListResult {
        try decode(ListResult.self, from: run(["list"]))
    }

    func current() throws -> CurrentResult {
        try decode(CurrentResult.self, from: run(["current"]))
    }

    func switchProvider(_ identifier: String, scope: String, focus: Bool, force: Bool = false, remote: Bool = true) throws -> SwitchResult {
        var args = ["switch", identifier, "--scope", scope]
        if !focus { args.append("--no-focus") }
        if force { args.append("--force") }
        if !remote { args.append("--no-remote") }
        return try decode(SwitchResult.self, from: run(args, timeout: 180))
    }

    func reload(scope: String, focus: Bool = true, remote: Bool = true) throws -> ReloadResult {
        var args = ["reload", "--scope", scope]
        if !focus { args.append("--no-focus") }
        if !remote { args.append("--no-remote") }
        return try decode(ReloadResult.self, from: run(args, timeout: 180))
    }

    func doctor() throws -> DoctorResult {
        try decode(DoctorResult.self, from: run(["doctor"], timeout: 40))
    }

    func remoteStatus() throws -> RemoteSyncInfo {
        let result = try decode(RemoteStatusResult.self, from: run(["remote-status"], timeout: 40))
        return result.remote
    }

    var isReady: Bool { nodePath != nil && scriptPath != nil }

    var diagnosticMessage: String? {
        if nodePath == nil { return BackendError.nodeNotFound.errorDescription }
        if scriptPath == nil { return BackendError.scriptNotFound.errorDescription }
        return nil
    }
}
