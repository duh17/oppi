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

/// Server-level health combines live transports with the last catalog sync.
/// A focused-session WebSocket is only one signal; the app-event stream and
/// successful REST refreshes also prove the server is reachable.
struct ServerHealth: Equatable, Sendable {
    enum TransportState: String, Equatable, Sendable {
        case disconnected
        case connecting
        case connected

        static func combine(_ states: [TransportState]) -> TransportState {
            if states.contains(.connected) { return .connected }
            if states.contains(.connecting) { return .connecting }
            return .disconnected
        }
    }

    let freshnessState: FreshnessState
    let freshnessLabel: String
    let transportState: TransportState
    let hasCachedCatalog: Bool

    static func derive(
        freshnessState: FreshnessState,
        freshnessLabel: String,
        transportStates: [TransportState],
        hasCachedCatalog: Bool
    ) -> ServerHealth {
        ServerHealth(
            freshnessState: freshnessState,
            freshnessLabel: freshnessLabel,
            transportState: TransportState.combine(transportStates),
            hasCachedCatalog: hasCachedCatalog
        )
    }
}
