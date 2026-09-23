// 监控 ~/.codex/config.toml：cc-switch（或其它工具）改写配置后自动触发热重启。
import Foundation
import CryptoKit

final class ConfigWatcher {
    private let configPath: String
    private let queue = DispatchQueue(label: "codex-hotswitch.watcher")
    private var timer: DispatchSourceTimer?
    private var lastHash: String?
    private var pendingWork: DispatchWorkItem?

    /// 检测到外部修改时回调（主线程）
    var onChanged: (() -> Void)?

    private(set) var isRunning = false

    init(configPath: String) {
        self.configPath = configPath
    }

    func start(interval: TimeInterval = 1.0) {
        guard !isRunning else { return }
        isRunning = true
        lastHash = Self.hashConfig(at: configPath)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        pendingWork?.cancel()
        pendingWork = nil
    }

    /// 忽略当前内容（用于自身刚刚写入配置后，避免自我触发）。
    func baselineNow() {
        queue.sync { lastHash = Self.hashConfig(at: configPath) }
    }

    private func tick() {
        let current = Self.hashConfig(at: configPath)
        guard let current else { return }
        if lastHash == nil {
            lastHash = current
            return
        }
        guard current != lastHash else { return }

        // 防抖：等文件稳定 300ms 再触发
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stable = Self.hashConfig(at: self.configPath)
            self.lastHash = stable
            DispatchQueue.main.async { self.onChanged?() }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static func hashConfig(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
