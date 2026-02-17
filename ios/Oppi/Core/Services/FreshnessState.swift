import Foundation

enum FreshnessState: String, CaseIterable, Sendable {
    case live
    case syncing
    case offline
    case stale

    static func derive(
        lastSuccessfulSyncAt: Date?,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        staleAfter: TimeInterval,
        now: Date = Date()
    ) -> Self {
        if isSyncing {
            return .syncing
        }

        if lastSyncFailed {
            return .offline
        }

        guard let lastSuccessfulSyncAt else {
            return .offline
        }

        let staleInterval = max(1, staleAfter)
        let age = now.timeIntervalSince(lastSuccessfulSyncAt)
        return age > staleInterval ? .stale : .live
    }

    static func updatedLabel(lastSuccessfulSyncAt: Date?, now: Date = Date()) -> String {
        guard let lastSuccessfulSyncAt else {
            return "Updated never"
        }

        return "Updated \(lastSuccessfulSyncAt.relativeString(relativeTo: now))"
    }

    var accessibilityText: String {
        switch self {
        case .live:
            return "Live"
        case .syncing:
            return "Syncing"
        case .offline:
            return "Offline"
        case .stale:
            return "Stale"
        }
    }
}
