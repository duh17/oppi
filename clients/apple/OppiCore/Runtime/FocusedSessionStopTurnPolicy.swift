import Foundation

/// Timeline mutation required by a graceful stop-turn lifecycle message.
enum FocusedSessionStopTurnTimelineEffect: Equatable, Sendable {
    case requested(message: String)
    case confirmed(message: String, finalizeTerminalArtifacts: Bool)
    case failed(message: String)
}

/// Platform-neutral policy for graceful turn abort feedback and reconciliation.
enum FocusedSessionStopTurnPolicy {
    static let reconciliationDelay: Duration = .seconds(10)

    static func timelineEffect(for message: ServerMessage) -> FocusedSessionStopTurnTimelineEffect? {
        switch message {
        case .stopRequested(_, let reason):
            return .requested(message: reason ?? "Stopping…")
        case .stopConfirmed(_, let reason):
            return .confirmed(
                message: reason ?? "Stop confirmed",
                finalizeTerminalArtifacts: true
            )
        case .stopFailed(_, let reason):
            return .failed(message: "Stop failed: \(reason)")
        default:
            return nil
        }
    }
}
