import ActivityKit
import Foundation

/// High-level phase for a session in the aggregate Live Activity.
enum SessionPhase: String, Codable, Hashable {
    case working
    /// Waiting on the person: an approval, a question, or a sign-in.
    /// `ContentState.primaryBlockedKind` says which.
    case blocked
    case awaitingReply
    /// An unseen done outcome. Green, and only while the result is unseen.
    case done
    case error
    case ended
}

/// ActivityKit attributes for Oppi's aggregate session Live Activity.
///
/// Shared between the main app (request/update/end) and widget extension (render).
struct PiSessionAttributes: ActivityAttributes {
    /// Static context — single aggregate activity, not tied to one session.
    let activityName: String

    /// Dynamic aggregate state across all tracked sessions.
    struct ContentState: Codable, Hashable {
        // Primary (highest-priority) session
        var primaryPhase: SessionPhase
        var primarySessionId: String?
        var primarySessionName: String
        var primaryTool: String?
        var primaryLastActivity: String?

        // Aggregate counters
        var totalActiveSessions: Int
        var sessionsAwaitingReply: Int
        var sessionsWorking: Int
        /// Sessions waiting on the person. Optional so an activity started before this field
        /// existed still decodes.
        var sessionsBlocked: Int?

        /// Why a `blocked` primary session waits: "permission", "question", or "auth".
        /// Optional for ActivityKit decode compatibility.
        var primaryBlockedKind: String?

        // Primary session change counters (optional for ActivityKit decode compatibility)
        var primaryMutatingToolCalls: Int?
        var primaryFilesChanged: Int?
        var primaryAddedLines: Int?
        var primaryRemovedLines: Int?

        // Active turn start (rendered with Text(timerInterval:) in widget)
        var sessionStartDate: Date?
    }
}
