import ActivityKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LiveActivity")

/// Manages Live Activity lifecycle for pi sessions.
///
/// Foreground v1 policy: only show while the session needs attention
/// (working, approvals, error). Idle/ready states auto-dismiss.
///
/// Only one Live Activity at a time (matches v1 one-session-at-a-time policy).
///
/// **v1: Local-only updates.** The activity is updated via ActivityKit when the
/// app is in foreground/recent memory. Push-based updates (for when the app is
/// killed) require APNs infrastructure and will be added later.
@MainActor @Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private(set) var activeActivity: Activity<PiSessionAttributes>?
    private var startTime: Date?
    private var elapsedTimer: Task<Void, Never>?

    private var sessionId: String?
    private var sessionName: String?
    private var idleDismissTask: Task<Void, Never>?

    /// Current state snapshot (for the active activity).
    private var currentState = PiSessionAttributes.ContentState(
        status: "ready",
        activeTool: nil,
        pendingPermissions: 0,
        pendingPermissionSession: nil,
        pendingPermissionTool: nil,
        pendingPermissionSummary: nil,
        pendingPermissionReason: nil,
        pendingPermissionRisk: nil,
        lastEvent: nil,
        elapsedSeconds: 0
    )

    /// Last pushed pending-permission count, used to trigger Dynamic Island alerts
    /// only when new approvals arrive.
    private var lastPushedPermissionCount = 0

    /// Throttle: true when a push is pending, coalesces rapid updates.
    private var hasPendingPush = false
    private var pushThrottleTask: Task<Void, Never>?
    /// Minimum interval between ActivityKit updates (ActivityKit throttles at ~1/sec anyway).
    private let pushThrottleInterval: Duration = .seconds(1)
    /// End the activity shortly after returning to idle, so brief gaps don't flicker.
    private let idleDismissDelay: Duration = .seconds(60)
    /// Mark state stale if we fail to update for this long.
    private let staleIntervalSeconds: TimeInterval = 90

    private init() {}

    // MARK: - Lifecycle

    /// Set active session context.
    ///
    /// Does not always start a Live Activity immediately.
    /// The activity appears only for actionable states (working/approval/error).
    func start(sessionId: String, sessionName: String) {
        let switchedSession = self.sessionId != nil && self.sessionId != sessionId
        self.sessionId = sessionId
        self.sessionName = sessionName

        if switchedSession {
            endIfNeeded()
            currentState = PiSessionAttributes.ContentState(
                status: "ready",
                activeTool: nil,
                pendingPermissions: 0,
                pendingPermissionSession: nil,
                pendingPermissionTool: nil,
                pendingPermissionSummary: nil,
                pendingPermissionReason: nil,
                pendingPermissionRisk: nil,
                lastEvent: nil,
                elapsedSeconds: 0
            )
        }

        refreshLifecycle()
    }

    /// End the current Live Activity.
    func endIfNeeded() {
        guard let activity = activeActivity else { return }

        elapsedTimer?.cancel()
        elapsedTimer = nil
        pushThrottleTask?.cancel()
        pushThrottleTask = nil
        idleDismissTask?.cancel()
        idleDismissTask = nil
        hasPendingPush = false
        lastPushedPermissionCount = 0
        startTime = nil

        let finalState = PiSessionAttributes.ContentState(
            status: "stopped",
            activeTool: nil,
            pendingPermissions: 0,
            pendingPermissionSession: nil,
            pendingPermissionTool: nil,
            pendingPermissionSummary: nil,
            pendingPermissionReason: nil,
            pendingPermissionRisk: nil,
            lastEvent: "Session ended",
            elapsedSeconds: currentState.elapsedSeconds
        )

        Task {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .after(.now + 300) // Stay on Lock Screen 5 min
            )
        }

        activeActivity = nil
        logger.error("Live Activity ended")
    }

    // MARK: - State Updates

    /// Update from agent events. Coalesces updates to avoid excessive refreshes.
    func updateFromEvent(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            currentState.status = "busy"
            currentState.lastEvent = "Working"

        case .agentEnd:
            currentState.status = "ready"
            currentState.activeTool = nil
            currentState.lastEvent = "Ready"

        case .toolStart(_, _, let tool, _):
            currentState.status = "busy"
            currentState.activeTool = tool
            currentState.lastEvent = "Running \(displayToolName(tool))"

        case .toolEnd:
            currentState.activeTool = nil

        case .permissionRequest:
            currentState.pendingPermissions += 1
            currentState.lastEvent = "Approval required"

        case .permissionExpired:
            currentState.pendingPermissions = max(0, currentState.pendingPermissions - 1)
            if currentState.pendingPermissions == 0 {
                currentState.pendingPermissionSession = nil
                currentState.pendingPermissionTool = nil
                currentState.pendingPermissionSummary = nil
                currentState.pendingPermissionReason = nil
                currentState.pendingPermissionRisk = nil
            }

        case .sessionEnded:
            endIfNeeded()
            return

        case .error(_, let message):
            if !message.hasPrefix("Retrying (") {
                currentState.status = "error"
                currentState.lastEvent = "Attention needed"
            }

        default:
            return // text/thinking deltas don't update Live Activity
        }

        refreshLifecycle()
    }

    /// Sync pending permissions from the canonical store.
    ///
    /// Keeps Live Activity permission state accurate across all resolution paths
    /// (allow/deny/expiry/cancel), including cross-session requests.
    func syncPermissions(
        _ pending: [PermissionRequest],
        sessions: [Session],
        activeSessionId: String?
    ) {
        currentState.pendingPermissions = pending.count

        if let top = pending.sorted(by: shouldPrioritizePermission).first {
            currentState.pendingPermissionSession = sessionLabel(for: top.sessionId, sessions: sessions)
            currentState.pendingPermissionTool = top.tool
            currentState.pendingPermissionSummary = permissionSummaryForLiveActivity(top)
            currentState.pendingPermissionReason = top.reason
            currentState.pendingPermissionRisk = top.risk.rawValue

            if top.sessionId == activeSessionId {
                currentState.lastEvent = "Approval required"
            } else if let session = currentState.pendingPermissionSession {
                currentState.lastEvent = "Approval required in \(session)"
            } else {
                currentState.lastEvent = "Approval required"
            }
        } else {
            currentState.pendingPermissionSession = nil
            currentState.pendingPermissionTool = nil
            currentState.pendingPermissionSummary = nil
            currentState.pendingPermissionReason = nil
            currentState.pendingPermissionRisk = nil
        }

        refreshLifecycle()
    }

    // MARK: - Private

    private func refreshLifecycle() {
        let shouldShow = shouldShowLiveActivity(state: currentState)
        if shouldShow {
            idleDismissTask?.cancel()
            idleDismissTask = nil
            ensureActivityStartedIfNeeded()
            pushUpdate()
            return
        }

        guard activeActivity != nil else { return }
        scheduleIdleDismiss()
    }

    private func shouldShowLiveActivity(state: PiSessionAttributes.ContentState) -> Bool {
        if state.pendingPermissions > 0 { return true }
        switch state.status {
        case "busy", "stopping", "error":
            return true
        default:
            return false
        }
    }

    private func ensureActivityStartedIfNeeded() {
        guard activeActivity == nil else { return }

        let authInfo = ActivityAuthorizationInfo()
        guard authInfo.areActivitiesEnabled else {
            logger.error("Live Activities not enabled (areActivitiesEnabled=false). User must enable in Settings → Oppi → Live Activities")
            return
        }

        let sid = sessionId ?? "unknown"
        let sname = sessionName ?? "Session"
        let attributes = PiSessionAttributes(sessionId: sid, sessionName: sname)

        do {
            let content = ActivityContent(state: currentState, staleDate: Date().addingTimeInterval(staleIntervalSeconds))
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activeActivity = activity
            startTime = Date()
            startElapsedTimer()
            logger.error("Live Activity started for session \(sid, privacy: .public)")
        } catch {
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleIdleDismiss() {
        guard idleDismissTask == nil else { return }
        idleDismissTask = Task { [weak self] in
            try? await Task.sleep(for: self?.idleDismissDelay ?? .seconds(60))
            guard !Task.isCancelled, let self else { return }
            self.idleDismissTask = nil
            if !self.shouldShowLiveActivity(state: self.currentState) {
                self.endIfNeeded()
            }
        }
    }

    private func shouldPrioritizePermission(_ lhs: PermissionRequest, _ rhs: PermissionRequest) -> Bool {
        if lhs.risk.severity != rhs.risk.severity {
            return lhs.risk.severity > rhs.risk.severity
        }
        if lhs.timeoutAt != rhs.timeoutAt {
            return lhs.timeoutAt < rhs.timeoutAt
        }
        return lhs.id < rhs.id
    }

    private func sessionLabel(for sessionId: String, sessions: [Session]) -> String {
        if let session = sessions.first(where: { $0.id == sessionId }),
           let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Session \(String(sessionId.prefix(8)))"
    }

    private func permissionSummaryForLiveActivity(_ request: PermissionRequest) -> String {
        switch request.risk {
        case .critical, .high:
            return "Open Oppi to review command"
        case .medium, .low:
            let trimmed = request.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Approval requested" }
            return String(trimmed.prefix(80))
        }
    }

    private func displayToolName(_ tool: String) -> String {
        let lowered = tool.lowercased()
        switch lowered {
        case "bash": return "Bash"
        case "read": return "Read"
        case "write": return "Write"
        case "edit": return "Edit"
        default:
            return tool.isEmpty ? "tool" : tool
        }
    }

    /// Throttled push: coalesces rapid state changes into at most one
    /// ActivityKit update per `pushThrottleInterval`.  Eliminates the
    /// "Reporter disconnected" flood during fast streaming.
    private func pushUpdate() {
        guard activeActivity != nil else { return }

        // Mark dirty — the throttle task will pick up the latest state
        hasPendingPush = true

        // If a throttle window is already open, the pending flag is enough
        guard pushThrottleTask == nil else { return }

        // Fire immediately for the first update, then throttle
        executePush()

        pushThrottleTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pushThrottleInterval ?? .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            // If more updates arrived during the throttle window, push once more
            if self.hasPendingPush {
                self.executePush()
            }
            self.pushThrottleTask = nil
        }
    }

    private func executePush() {
        guard let activity = activeActivity else { return }
        hasPendingPush = false

        let state = currentState
        let shouldAlertForPermission = state.pendingPermissions > lastPushedPermissionCount
        lastPushedPermissionCount = state.pendingPermissions

        let alertConfiguration: AlertConfiguration?
        if shouldAlertForPermission {
            alertConfiguration = AlertConfiguration(
                title: "Approval required",
                body: "Open Oppi to review command and risk",
                sound: .default
            )
        } else {
            alertConfiguration = nil
        }

        Task {
            await activity.update(
                .init(state: state, staleDate: Date().addingTimeInterval(staleIntervalSeconds)),
                alertConfiguration: alertConfiguration
            )
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30)) // Update elapsed every 30s
                guard !Task.isCancelled else { break }
                guard let self, let startTime = self.startTime else { break }

                self.currentState.elapsedSeconds = Int(Date().timeIntervalSince(startTime))
                self.pushUpdate()
            }
        }
    }
}
