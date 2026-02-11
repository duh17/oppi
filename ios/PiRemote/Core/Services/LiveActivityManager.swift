import ActivityKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "LiveActivity")

/// Manages Live Activity lifecycle for pi sessions.
///
/// Start an activity when connecting to a session, update it with coarse
/// state changes, and end it when the session ends or the user disconnects.
///
/// Only one Live Activity at a time (matches v1 one-session-at-a-time policy).
@MainActor @Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private(set) var activeActivity: Activity<PiSessionAttributes>?
    private var startTime: Date?
    private var elapsedTimer: Task<Void, Never>?
    private var pushTokenTask: Task<Void, Never>?

    /// Current state snapshot (for the active activity).
    private var currentState = PiSessionAttributes.ContentState(
        status: "ready",
        activeTool: nil,
        pendingPermissions: 0,
        lastEvent: nil,
        elapsedSeconds: 0
    )

    /// Throttle: true when a push is pending, coalesces rapid updates.
    private var hasPendingPush = false
    private var pushThrottleTask: Task<Void, Never>?
    /// Minimum interval between ActivityKit updates (ActivityKit throttles at ~1/sec anyway).
    private let pushThrottleInterval: Duration = .seconds(1)

    private init() {}

    // MARK: - Lifecycle

    /// Start a Live Activity for a session.
    /// Call when WebSocket connects to a session.
    func start(sessionId: String, sessionName: String) {
        // End any existing activity first
        endIfNeeded()

        let authInfo = ActivityAuthorizationInfo()
        guard authInfo.areActivitiesEnabled else {
            logger.info("Live Activities not enabled (areActivitiesEnabled=false). User must enable in Settings → PiRemote → Live Activities")
            return
        }

        // Check frequent push permission too
        logger.info("Live Activities enabled, frequentPushesEnabled=\(authInfo.frequentPushesEnabled)")

        let attributes = PiSessionAttributes(
            sessionId: sessionId,
            sessionName: sessionName
        )

        currentState = PiSessionAttributes.ContentState(
            status: "ready",
            activeTool: nil,
            pendingPermissions: 0,
            lastEvent: "Connected",
            elapsedSeconds: 0
        )

        do {
            let content = ActivityContent(state: currentState, staleDate: nil)
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )

            self.activeActivity = activity
            self.startTime = Date()
            startElapsedTimer()
            observePushTokenUpdates(activity)

            logger.info("Live Activity started for session \(sessionId)")
        } catch {
            // Non-fatal: Live Activity is optional. Common failures:
            // - ActivityAuthorizationError.visibility: user disabled in Settings
            // - PermissionsError: missing entitlement or provisioning
            logger.info("Live Activity unavailable: \(error.localizedDescription)")
        }
    }

    /// End the current Live Activity.
    func endIfNeeded() {
        guard let activity = activeActivity else { return }

        elapsedTimer?.cancel()
        elapsedTimer = nil
        pushTokenTask?.cancel()
        pushTokenTask = nil
        pushThrottleTask?.cancel()
        pushThrottleTask = nil
        hasPendingPush = false
        startTime = nil

        let finalState = PiSessionAttributes.ContentState(
            status: "stopped",
            activeTool: nil,
            pendingPermissions: 0,
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
        logger.info("Live Activity ended")
    }

    // MARK: - State Updates

    /// Update from agent events. Coalesces updates to avoid excessive refreshes.
    func updateFromEvent(_ event: AgentEvent) {
        guard activeActivity != nil else { return }

        switch event {
        case .agentStart:
            currentState.status = "busy"
            currentState.lastEvent = "Agent started"

        case .agentEnd:
            currentState.status = "ready"
            currentState.activeTool = nil
            currentState.lastEvent = "Agent finished"

        case .toolStart(_, _, let tool, _):
            currentState.activeTool = tool
            currentState.lastEvent = tool

        case .toolEnd:
            currentState.activeTool = nil

        case .permissionRequest:
            currentState.pendingPermissions += 1

        case .permissionExpired:
            currentState.pendingPermissions = max(0, currentState.pendingPermissions - 1)

        case .sessionEnded:
            endIfNeeded()
            return

        case .error(_, let message):
            if !message.hasPrefix("Retrying (") {
                currentState.status = "error"
                currentState.lastEvent = "Error"
            }

        default:
            return // text/thinking deltas don't update Live Activity
        }

        pushUpdate()
    }

    /// Sync pending permission count from the store.
    func syncPermissionCount(_ count: Int) {
        guard activeActivity != nil else { return }
        currentState.pendingPermissions = count
        pushUpdate()
    }

    // MARK: - Private

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
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func observePushTokenUpdates(_ activity: Activity<PiSessionAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { [weak self] in
            if let initialToken = activity.pushToken {
                await self?.registerLiveActivityToken(initialToken)
            }

            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.registerLiveActivityToken(tokenData)
            }
        }
    }

    private func registerLiveActivityToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        logger.info("Live Activity push token updated: \(String(token.prefix(16)))...")
        await PushRegistration.shared.sendTokenToServer(token, tokenType: "liveactivity")
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
