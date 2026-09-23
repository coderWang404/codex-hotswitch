// 数据模型：与 codex-hotswitch --json 输出对应
import Foundation

struct ProviderSummary: Codable {
    let id: String
    let name: String
    let isCurrent: Bool
    let model: String?
    let catalogCount: Int
    let official: Bool
    let hasConfig: Bool
    let baseUrl: String?
    let host: String?
    let tokenTail: String?
}

struct LiveInfo: Codable {
    let providerId: String?
    let baseUrl: String?
    let host: String?
    let tokenTail: String?
    let model: String?
    let matchedIds: [String]?
    let liveProviderId: String?
}

struct ListResult: Codable {
    let ok: Bool
    let currentId: String?
    let providers: [ProviderSummary]
    let live: LiveInfo?
    let ccSwitchRunning: Bool?
    let error: String?
}

struct EffectiveInfo: Codable {
    let ok: Bool
    let modelProvider: String?
    let model: String?
    let baseUrl: String?
    let hasToken: Bool?
    let catalogJson: String?
    let error: String?
}

struct AppServerInfo: Codable {
    let pid: Int
    let owner: String
    let kind: String
    let topLevel: Bool
}

struct CurrentResult: Codable {
    let ok: Bool
    let current: ProviderRef?
    let configPath: String?
    let effective: EffectiveInfo?
    let appServers: [AppServerInfo]?
    let tuiCount: Int?
}

struct ProviderRef: Codable {
    let id: String
    let name: String
}

struct RemoteHostInfo: Codable {
    let host: String
    let label: String
    let ok: Bool
    let changed: Bool
    let baseUrl: String?
    let previousBaseUrl: String?
    let providerName: String?
    let tokenTail: String?
    let restarted: Int
    let error: String?
}

struct RemoteSyncInfo: Codable {
    let hosts: [RemoteHostInfo]
}

struct ReloadResult: Codable {
    let ok: Bool
    let current: ProviderRef?
    let reload: ReloadDetail?
    let remote: RemoteSyncInfo?
}

struct ReloadDetail: Codable {
    let targets: [ReloadTarget]?
    let terminated: Int?
    let killed: Int?
    let respawned: RespawnInfo?
    let dryRun: Bool?
    let tuiCount: Int?
}

struct ReloadTarget: Codable {
    let pid: Int
    let owner: String?
}

struct RespawnInfo: Codable {
    let pid: Int
}

struct SwitchResult: Codable {
    let ok: Bool
    let provider: ProviderSummary?
    let effective: EffectiveInfo?
    let verified: Bool?
    let backupPath: String?
    let synced: Bool?
    let warnings: [String]?
    let reload: ReloadDetail?
    let remote: RemoteSyncInfo?
    let error: String?
}

struct CheckItem: Codable {
    let ok: Bool
    let label: String
}

struct DoctorResult: Codable {
    let ok: Bool
    let checks: [CheckItem]
    let failed: Int
}

struct RemoteStatusResult: Codable {
    let ok: Bool
    let remote: RemoteSyncInfo
}
