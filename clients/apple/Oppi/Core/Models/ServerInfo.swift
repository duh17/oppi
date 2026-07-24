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
    let images: ImageSettingsInfo?
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

    struct ImageSettingsInfo: Codable, Sendable, Equatable {
        let autoResize: Bool?
    }

    struct Capabilities: Codable, Sendable, Equatable {
        let sessionStream: CapabilityVersion?
        let dictationStream: CapabilityVersion?
        let appEventStream: CapabilityVersion?
        let extensionNativeUI: ExtensionNativeUICapability?
        var controlSessions: CapabilityVersion? = nil
    }

    struct CapabilityVersion: Codable, Sendable, Equatable {
        let version: Int
    }

    struct ExtensionNativeUICapability: Codable, Sendable, Equatable {
        let version: Int
        let capabilities: [String]
    }

    struct ServerStats: Codable, Sendable, Equatable {
        let workspaceCount: Int
        let activeSessionCount: Int
        let totalSessionCount: Int
        let skillCount: Int
        let modelCount: Int
    }
}

/// Aggregated consumer/provider quota windows from `GET /server/provider-quotas`.
struct ProviderQuotasInfo: Codable, Sendable, Equatable {
    let providers: [ProviderQuota]
    let fetchedAt: Int

    var presentableProviders: [ProviderQuota] {
        providers.filter(\.shouldPresentSection)
    }

    func quota(forProviderId providerId: String) -> ProviderQuota? {
        let needle = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providers.first {
            $0.providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    func providerBadges(for provider: String) -> [ProviderQuota.ProviderBadge] {
        quota(forProviderId: provider)?.providerBadges ?? []
    }
}

struct ProviderQuota: Codable, Sendable, Equatable, Identifiable {
    var id: String { providerId }

    let providerId: String
    let displayName: String
    let authenticated: Bool
    let planType: String?
    let windows: [Window]
    let credits: Credits?
    let prepaidBalanceCents: Int?
    let fetchedAt: Int
    let error: String?

    struct Window: Codable, Sendable, Equatable, Identifiable {
        var id: String { key }

        let key: String
        let shortLabel: String
        let title: String
        let usedPercent: Double
        let remainingPercent: Double
        let limitWindowSeconds: Int?
        let resetAt: Int?
        let includeWeekdayInReset: Bool

        var resetDate: Date? {
            guard let resetAt else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(resetAt))
        }
    }

    struct Credits: Codable, Sendable, Equatable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: String?
    }

    enum BadgeTone: Sendable, Equatable {
        case green
        case orange
        case red
    }

    struct ProviderBadge: Sendable, Equatable {
        let label: String
        let tone: BadgeTone
    }

    var hasAnyUsageWindow: Bool {
        !windows.isEmpty
    }

    var shouldPresentSection: Bool {
        authenticated || error != nil || hasAnyUsageWindow
    }

    var planLabel: String? {
        guard let planType else { return nil }
        let normalized = planType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        switch normalized.lowercased() {
        case "prolite": return "Pro Lite"
        case "free_workspace": return "Free Workspace"
        case "supergrok": return "SuperGrok"
        default:
            return normalized
                .split(separator: "_")
                .map { part in
                    let lower = part.lowercased()
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    static func badgeTone(for remainingPercent: Double) -> BadgeTone {
        if remainingPercent <= 20 { return .red }
        if remainingPercent <= 50 { return .orange }
        return .green
    }

    var providerBadges: [ProviderBadge] {
        guard authenticated else { return [] }
        return windows.map { window in
            ProviderBadge(
                label: "\(window.shortLabel) \(Int(window.remainingPercent.rounded()))%",
                tone: Self.badgeTone(for: window.remainingPercent)
            )
        }
    }
}

// MARK: - Presentation Helpers

extension ServerInfo.Capabilities {
    static let requiredSplitStreamCapabilityNames = [
        "sessionStream",
    ]

    static func missingRequiredSplitStreamCapabilities(in capabilities: ServerInfo.Capabilities?) -> [String] {
        guard let capabilities else { return requiredSplitStreamCapabilityNames }

        var missing: [String] = []
        if capabilities.sessionStream?.version ?? 0 < 1 {
            missing.append("sessionStream")
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
    var agentVersionLabel: String {
        runtimeUpdate?.currentVersion ?? piVersion
    }

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
