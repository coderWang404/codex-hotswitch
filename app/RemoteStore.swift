// 内置 SSH 机器来自软件自带的 remotes.json。
// 用户添加的机器、以及内置机器的开关，写在 ~/.codex-hotswitch/remotes.json。
// 命令行同步读的是同一份文件。
import Foundation

struct RemoteMachine: Equatable {
    var label: String
    var host: String
    var user: String?
    var port: Int?
    var identityFile: String?
    var builtin: Bool
    var enabled: Bool

    var detail: String {
        var text = ""
        if let user, !user.isEmpty { text += "\(user)@" }
        text += host
        if let port, port != 22 { text += ":\(port)" }
        return text
    }
}

final class RemoteStore {
    static let shared = RemoteStore()

    private(set) var machines: [RemoteMachine] = []

    private init() { reload() }

    func reload() {
        machines = Self.load()
    }

    func setEnabled(host: String, enabled: Bool) {
        guard let index = machines.firstIndex(where: { $0.host == host }) else { return }
        machines[index].enabled = enabled
        save()
    }

    func add(label: String, host: String, user: String?, port: Int?, identityFile: String?) throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanHost.contains(where: \.isWhitespace) else {
            throw RemoteStoreError.invalidHost
        }
        if machines.contains(where: { $0.host == cleanHost }) {
            throw RemoteStoreError.duplicate
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        machines.append(RemoteMachine(
            label: cleanLabel.isEmpty ? cleanHost : cleanLabel,
            host: cleanHost,
            user: emptyToNil(user),
            port: port,
            identityFile: emptyToNil(identityFile),
            builtin: false,
            enabled: true
        ))
        save()
    }

    func remove(host: String) {
        machines.removeAll { $0.host == host && !$0.builtin }
        save()
    }

    private func save() {
        let disabled = machines.filter { $0.builtin && !$0.enabled }.map(\.host)
        let hosts = machines.filter { !$0.builtin }.map { machine -> [String: Any] in
            var item: [String: Any] = [
                "label": machine.label,
                "host": machine.host,
                "enabled": machine.enabled,
            ]
            if let user = machine.user { item["user"] = user }
            if let port = machine.port { item["port"] = port }
            if let identityFile = machine.identityFile { item["identityFile"] = identityFile }
            return item
        }
        let payload: [String: Any] = ["disabled": disabled, "hosts": hosts]
        let url = Self.userFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func load() -> [RemoteMachine] {
        let builtin = loadBuiltin()
        let user = loadUserFile()
        let disabled = Set(user.disabled)
        var machines = builtin.map { item in
            RemoteMachine(
                label: item.label,
                host: item.host,
                user: item.user,
                port: item.port,
                identityFile: item.identityFile,
                builtin: true,
                enabled: !disabled.contains(item.host)
            )
        }
        let seen = Set(machines.map(\.host))
        for item in user.hosts where !seen.contains(item.host) {
            machines.append(item)
        }
        return machines
    }

    private static func loadBuiltin() -> [RemoteMachine] {
        guard let url = builtinFileURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = json["hosts"] as? [[String: Any]] else {
            return fallbackBuiltin
        }
        return hosts.compactMap(parseBuiltin)
    }

    private static func loadUserFile() -> (disabled: [String], hosts: [RemoteMachine]) {
        guard let data = try? Data(contentsOf: userFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }
        let disabled = json["disabled"] as? [String] ?? []
        let hosts = (json["hosts"] as? [[String: Any]] ?? []).compactMap(parseCustom)
        return (disabled, hosts)
    }

    private static func parseBuiltin(_ item: [String: Any]) -> RemoteMachine? {
        guard let host = item["host"] as? String, !host.isEmpty else { return nil }
        return RemoteMachine(
            label: (item["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host,
            host: host,
            user: item["user"] as? String,
            port: item["port"] as? Int,
            identityFile: item["identityFile"] as? String,
            builtin: true,
            enabled: true
        )
    }

    private static func parseCustom(_ item: [String: Any]) -> RemoteMachine? {
        guard let host = item["host"] as? String, !host.isEmpty else { return nil }
        return RemoteMachine(
            label: (item["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host,
            host: host,
            user: emptyToNil(item["user"] as? String),
            port: item["port"] as? Int,
            identityFile: emptyToNil(item["identityFile"] as? String),
            builtin: false,
            enabled: item["enabled"] as? Bool ?? true
        )
    }

    private static var builtinFileURL: URL? {
        guard let script = Backend.shared.scriptPath else { return nil }
        let url = URL(fileURLWithPath: script)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src/remotes.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-hotswitch/remotes.json")
    }

    private static let fallbackBuiltin: [RemoteMachine] = []
}

enum RemoteStoreError: LocalizedError {
    case invalidHost
    case duplicate

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "主机地址不能为空，也不能包含空格"
        case .duplicate: return "这台机器已经在列表里"
        }
    }
}

private func emptyToNil(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
