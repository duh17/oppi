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
    let stats: ServerStats

    struct IdentityInfo: Codable, Sendable, Equatable {
        let fingerprint: String
        let keyId: String
        let algorithm: String
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
