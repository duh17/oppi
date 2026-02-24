import ActivityKit
import Foundation

/// High-level phase for a session in the aggregate Live Activity.
enum SessionPhase: String, Codable, Hashable {
    case working
    case awaitingReply
    case needsApproval
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

        // Top of FIFO permission queue
        var topPermissionId: String?
        var topPermissionTool: String?
        var topPermissionSummary: String?
        var topPermissionSession: String?
        var pendingApprovalCount: Int

        // Rendered with Text(timerInterval:) in widget (system-managed timer)
        var sessionStartDate: Date?
    }
}
