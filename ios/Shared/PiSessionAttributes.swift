import ActivityKit
import Foundation

/// ActivityKit attributes for a pi coding session.
///
/// Shared between the main app (which starts/updates/ends the activity)
/// and the widget extension (which renders the Lock Screen + Dynamic Island UI).
///
/// Design principle: summary-only. No token-level streaming — just coarse
/// state updates (busy/ready, active tool, pending permissions).
struct PiSessionAttributes: ActivityAttributes {
    /// Static context — set once when activity starts.
    let sessionId: String
    let sessionName: String

    /// Dynamic state — updated as the session progresses.
    struct ContentState: Codable, Hashable {
        var status: String                 // "busy", "stopping", "ready", "stopped", "error"
        var activeTool: String?            // Current tool being executed (nil when idle)
        var pendingPermissions: Int        // Count of pending permission requests
        var pendingPermissionSession: String? // Session label for the top pending request
        var pendingPermissionTool: String? // Tool for the top pending request
        var pendingPermissionSummary: String? // Command/action summary for the top pending request
        var pendingPermissionReason: String? // Policy reason for the top pending request
        var pendingPermissionRisk: String? // low/medium/high/critical
        var lastEvent: String?             // Human-readable last action ("Editing auth.ts")
        var elapsedSeconds: Int            // Total session time
    }
}
