import Foundation

/// Server metadata returned by `GET /server/info`.
///
/// Contains identification, uptime, platform details, and aggregate stats
/// for the server detail view.
struct ServerInfo: Codable, Sendable, Equatable {
    let name: String
    let version: String
    let uptime: Int              // seconds since server start
    let os: String               // "darwin", "linux"
    let arch: String             // "arm64", "x64"
    let hostname: String
    let nodeVersion: String
    let piVersion: String
    let configVersion: Int
    let identity: IdentityInfo?
    let runtimeUpdate: RuntimeUpdateInfo?
    let uploadProtocol: UploadProtocolInfo?
    let capabilities: Capabilities?
    let stats: ServerStats

    struct IdentityInfo: Codable, Sendable, Equatable {
        let fingerprint: String
        let keyId: String
        let algorithm: String
    }

    struct RuntimeUpdateInfo: Codable, Sendable, Equatable {
        let packageName: String
        let currentVersion: String
        let latestVersion: String?
        let pendingVersion: String?
        let updateAvailable: Bool
        let canUpdate: Bool
        let checking: Bool
        let updateInProgress: Bool
        let restartRequired: Bool
        let lastCheckedAt: Int?
        let checkError: String?
        let lastUpdatedAt: Int?
        let lastUpdateError: String?
    }

    struct UploadProtocolInfo: Codable, Sendable, Equatable {
        let version: Int
        let maxFileBytes: Int
        let maxTurnBytes: Int
    }

    struct Capabilities: Codable, Sendable, Equatable {
        let workspaceStream: CapabilityVersion?
        let sessionStream: CapabilityVersion?
        let sessionAudioStream: CapabilityVersion?
        let sessionProjection: CapabilityVersion?
    }

    struct CapabilityVersion: Codable, Sendable, Equatable {
        let version: Int
    }

    struct ServerStats: Codable, Sendable, Equatable {
        let workspaceCount: Int
        let activeSessionCount: Int
        let totalSessionCount: Int
        let skillCount: Int
        let modelCount: Int
    }
}

// MARK: - Presentation Helpers

extension ServerInfo.Capabilities {
    static let requiredSplitStreamCapabilityNames = [
        "workspaceStream",
        "sessionStream",
        "sessionProjection",
    ]

    static func missingRequiredSplitStreamCapabilities(in capabilities: ServerInfo.Capabilities?) -> [String] {
        guard let capabilities else { return requiredSplitStreamCapabilityNames }

        var missing: [String] = []
        if capabilities.workspaceStream?.version ?? 0 < 1 {
            missing.append("workspaceStream")
        }
        if capabilities.sessionStream?.version ?? 0 < 1 {
            missing.append("sessionStream")
        }
        if capabilities.sessionProjection?.version ?? 0 < 1 {
            missing.append("sessionProjection")
        }
        return missing
    }

    var missingRequiredSplitStreamCapabilities: [String] {
        Self.missingRequiredSplitStreamCapabilities(in: self)
    }

    var hasRequiredSplitStreamCapabilities: Bool {
        missingRequiredSplitStreamCapabilities.isEmpty
    }
}

extension ServerInfo {
    /// Human-readable uptime (e.g. "2d 14h", "3h 25m", "45s").
    var uptimeLabel: String {
        let days = uptime / 86400
        let hours = (uptime % 86400) / 3600
        let minutes = (uptime % 3600) / 60
        let seconds = uptime % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Human-readable OS + architecture (e.g. "macOS arm64").
    var platformLabel: String {
        let osName: String
        switch os {
        case "darwin": osName = "macOS"
        case "linux": osName = "Linux"
        case "win32": osName = "Windows"
        default: osName = os
        }
        return "\(osName) \(arch)"
    }
}
