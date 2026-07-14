import ActivityKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LiveActivity")

/// Manages the aggregate Live Activity across all tracked sessions.
///
/// v2 policy:
/// - Single aggregate activity (not one-per-session)
/// - Event-driven updates only
/// - Session phase model (`working`, `awaitingReply`, `error`, `ended`)
@MainActor @Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private struct SessionSnapshot {
        let id: String
        var name: String
        var status: SessionStatus
        var phaseHint: SessionPhase
        var activeTool: String?
        var lastActivity: String?
        var startDate: Date?
        var changeStats: SessionChangeStats?
        var updatedAt: Date
        /// When the session entered `.ready` status. Used for awaitingReply
        /// expiry so that `sync()` refreshing `updatedAt` doesn't keep the
        /// expiry window open indefinitely.
        var readySince: Date?
    }

    private struct ConnectionSnapshot {
        var sessionsById: [String: SessionSnapshot] = [:]
    }

    private struct SessionView {
        let id: String
        let name: String
        let phase: SessionPhase
        let activeTool: String?
        let lastActivity: String?
        let startDate: Date?
        let changeStats: SessionChangeStats?
        let updatedAt: Date
    }

    private struct DeliveredSnapshot: Equatable {
        let state: PiSessionAttributes.ContentState
        let staleDate: Date?
        let relevanceScore: Double

        init(from content: ActivityContent<PiSessionAttributes.ContentState>) {
            state = content.state
            staleDate = content.staleDate
            relevanceScore = content.relevanceScore
        }

        static func == (lhs: DeliveredSnapshot, rhs: DeliveredSnapshot) -> Bool {
            lhs.state == rhs.state
                && lhs.staleDate == rhs.staleDate
                && lhs.relevanceScore == rhs.relevanceScore
        }
    }

    private static let emptyState = PiSessionAttributes.ContentState(
        primaryPhase: .ended,
        primarySessionId: nil,
        primarySessionName: "Oppi",
        primaryTool: nil,
        primaryLastActivity: nil,
        totalActiveSessions: 0,
        sessionsAwaitingReply: 0,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        sessionStartDate: nil
    )

    private(set) var activeActivity: Activity<PiSessionAttributes>?

    /// Observes `activityStateUpdates` to detect system-initiated endings
    /// (8-hour limit, user removal from Lock Screen).
    private var activityObservationTask: Task<Void, Never>?

    private(set) var currentState: PiSessionAttributes.ContentState = LiveActivityManager.emptyState
    private var lastStateChangeAt = Date()
    private var connectionSnapshots: [String: ConnectionSnapshot] = [:]

    private var idleDismissTask: Task<Void, Never>?

    /// One-shot timer used to expire transient `.awaitingReply` UI without polling.
    private var awaitingReplyExpiryTask: Task<Void, Never>?
    private var awaitingReplyExpiryDate: Date?

    /// Throttle: true when a push is pending, coalesces rapid updates.
    private var hasPendingPush = false
    private var pushThrottleTask: Task<Void, Never>?

    private var lastDeliveredSnapshot: DeliveredSnapshot?

    /// Minimum interval between ActivityKit updates (ActivityKit throttles at ~1/sec anyway).
    private let pushThrottleInterval: Duration = .seconds(1)
    /// Brief grace period before ending the activity after all sessions go idle.
    /// Short enough to feel responsive, long enough to absorb rapid state flicker.
    private let idleDismissDelay: Duration = .seconds(5)
    /// Keep `.awaitingReply` visible briefly, then auto-dismiss if nothing else is active.
    private let awaitingReplyVisibilitySeconds: TimeInterval = 5
    /// Working/error/approval states should eventually go stale if we stop receiving events.
    private let staleIntervalSeconds: TimeInterval = 300
    /// How long the ended activity lingers on the Lock Screen after `activity.end()`.
    /// Keep it short — stale session info is not useful. 4 seconds is enough for
    /// a glance at the final state without the activity overstaying its welcome.
    private let lockScreenDismissDelaySeconds: TimeInterval = 4

    init() {}

    // MARK: - Public API

    /// Sync canonical session state for a server connection.
    func sync(connectionId: String, sessions: [Session]) {
        var snapshot = connectionSnapshots[connectionId] ?? ConnectionSnapshot()

        var nextById: [String: SessionSnapshot] = [:]

        for session in sessions {
            var entry = snapshot.sessionsById[session.id] ?? SessionSnapshot(
                id: session.id,
                name: session.displayTitle,
                status: session.status,
                phaseHint: baselinePhase(for: session.status),
                activeTool: nil,
                lastActivity: nil,
                startDate: nil,
                changeStats: session.changeStats,
                updatedAt: session.lastActivity,
                readySince: session.status == .ready ? session.lastActivity : nil
            )

            let previousStatus = entry.status

            entry.name = session.displayTitle
            entry.status = session.status
            entry.changeStats = session.changeStats
            if session.lastActivity > entry.updatedAt {
                entry.updatedAt = session.lastActivity
            }

            switch session.status {
            case .starting, .busy, .stopping:
                entry.phaseHint = .working
                entry.readySince = nil
                if let currentTurnStartedAt = session.currentTurnStartedAt {
                    entry.startDate = currentTurnStartedAt
                } else if !isWorkingStatus(previousStatus) || entry.startDate == nil {
                    // Fallback when we don't observe an explicit agentStart
                    // (e.g. app relaunch while session is already busy).
                    entry.startDate = session.lastActivity
                }
            case .ready:
                // Record when session first entered .ready so the awaitingReply
                // expiry window is anchored to the transition, not refreshed by
                // subsequent syncs.
                if entry.readySince == nil {
                    entry.readySince = Date()
                }
                if entry.phaseHint != .error {
                    entry.phaseHint = .awaitingReply
                }
                entry.activeTool = nil
                entry.startDate = nil
            case .error:
                entry.phaseHint = .error
                entry.activeTool = nil
                entry.startDate = nil
                if entry.lastActivity == nil {
                    entry.lastActivity = String(localized: "Attention needed")
                }
            case .stopped:
                entry.phaseHint = .ended
                entry.activeTool = nil
                entry.startDate = nil
                entry.lastActivity = String(localized: "Session ended")
            }

            if entry.lastActivity == nil {
                entry.lastActivity = defaultLastActivity(for: entry.phaseHint)
            }

            nextById[session.id] = entry
        }

        snapshot.sessionsById = nextById
        connectionSnapshots[connectionId] = snapshot

        // Nudge stale snapshots out if no session data remains for a connection.
        if sessions.isEmpty {
            connectionSnapshots.removeValue(forKey: connectionId)
        }

        refreshLifecycle()
    }

    /// Incremental event hinting for richer phase/tool transitions.
    func recordEvent(connectionId: String, event: AgentEvent) {
        var snapshot = connectionSnapshots[connectionId] ?? ConnectionSnapshot()

        func upsertSession(_ sessionId: String) -> SessionSnapshot {
            if let existing = snapshot.sessionsById[sessionId] {
                return existing
            }
            return SessionSnapshot(
                id: sessionId,
                name: fallbackSessionName(sessionId),
                status: .ready,
                phaseHint: .awaitingReply,
                activeTool: nil,
                lastActivity: nil,
                startDate: nil,
                changeStats: nil,
                updatedAt: Date(),
                readySince: Date()
            )
        }

        var didChange = true

        switch event {
        case .agentStart(let sessionId):
            var entry = upsertSession(sessionId)
            let now = Date()
            entry.status = .busy
            entry.phaseHint = .working
            entry.readySince = nil
            entry.startDate = now
            entry.lastActivity = String(localized: "Working")
            entry.updatedAt = now
            snapshot.sessionsById[sessionId] = entry

        case .agentEnd(let sessionId):
            var entry = upsertSession(sessionId)
            let now = Date()
            entry.status = .ready
            entry.phaseHint = .awaitingReply
            entry.readySince = now
            entry.activeTool = nil
            entry.startDate = nil
            entry.lastActivity = String(localized: "Your turn")
            entry.updatedAt = now
            snapshot.sessionsById[sessionId] = entry

        case .toolStart(let sessionId, let toolEventId, let tool, _, _):
            var entry = upsertSession(sessionId)
            let now = Date()
            entry.status = .busy
            entry.phaseHint = .working
            if entry.startDate == nil {
                entry.startDate = now
            }
            entry.activeTool = displayToolName(tool)
            entry.lastActivity = toolActivityLabel(tool, seed: toolEventId)
            entry.updatedAt = now
            snapshot.sessionsById[sessionId] = entry

        case .toolEnd(let sessionId, _, _, _, _):
            var entry = upsertSession(sessionId)
            entry.activeTool = nil
            entry.updatedAt = Date()
            snapshot.sessionsById[sessionId] = entry

        case .sessionEnded(let sessionId, _):
            var entry = upsertSession(sessionId)
            entry.status = .stopped
            entry.phaseHint = .ended
            entry.activeTool = nil
            entry.startDate = nil
            entry.lastActivity = String(localized: "Session ended")
            entry.updatedAt = Date()
            snapshot.sessionsById[sessionId] = entry

        case .error(let sessionId, let message):
            guard !message.hasPrefix("Retrying (") else {
                didChange = false
                break
            }
            var entry = upsertSession(sessionId)
            entry.status = .error
            entry.phaseHint = .error
            entry.startDate = nil
            entry.lastActivity = String(localized: "Attention needed")
            entry.updatedAt = Date()
            snapshot.sessionsById[sessionId] = entry

        case .textDelta,
             .thinkingDelta,
             .messageEnd,
             .cacheMiss,
             .toolUpdate,
             .toolOutput,
             .compactionStart,
             .compactionEnd,
             .retryStart,
             .retryEnd,
             .commandResult:
            didChange = false
        }

        guard didChange else {
            return
        }

        connectionSnapshots[connectionId] = snapshot
        refreshLifecycle()
    }

    func removeConnection(_ connectionId: String) {
        connectionSnapshots.removeValue(forKey: connectionId)
        refreshLifecycle()
    }

    /// End the current Live Activity.
    ///
    /// HIG: "Always end a Live Activity immediately when the task or event ends,
    /// and consider setting a custom dismissal time."
    /// We end immediately but use a Lock Screen dismissal window so users can
    /// glance at the final state. `.immediate` is reserved for explicit user action.
    func endIfNeeded(immediate: Bool = false) {
        guard let activity = activeActivity else { return }

        cleanupTimers()

        nonisolated(unsafe) let detachedActivity = activity
        let finalState = Self.emptyState
        let policy: ActivityUIDismissalPolicy = immediate
            ? .immediate
            : .after(Date().addingTimeInterval(lockScreenDismissDelaySeconds))

        Task {
            await detachedActivity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: policy
            )
        }

        activeActivity = nil
        currentState = finalState
        let dismissalLabel = immediate ? "immediate" : "after \(Int(self.lockScreenDismissDelaySeconds))s"
        logger.error("Live Activity ended (dismissal=\(dismissalLabel, privacy: .public))")
    }

    /// Reconcile ActivityKit state after app launch / foreground.
    ///
    /// Handles app lifecycle gaps where ActivityKit keeps a live activity
    /// but this singleton lost its in-memory `activeActivity` reference.
    func recoverIfNeeded() {
        refreshLifecycle()
    }

    private func cleanupTimers() {
        pushThrottleTask?.cancel()
        pushThrottleTask = nil
        idleDismissTask?.cancel()
        idleDismissTask = nil
        awaitingReplyExpiryTask?.cancel()
        awaitingReplyExpiryTask = nil
        awaitingReplyExpiryDate = nil
        activityObservationTask?.cancel()
        activityObservationTask = nil
        hasPendingPush = false
        lastDeliveredSnapshot = nil
        lastStateChangeAt = Date()
    }

    // MARK: - Lifecycle

    /// Reattach an existing ActivityKit activity if this process lost its
    /// in-memory `activeActivity` reference (app relaunch / suspension).
    private func recoverTrackedActivityReferenceIfNeeded() {
        if let existing = activeActivity,
           existing.activityState == .ended || existing.activityState == .dismissed {
            logger.error("Recovered stale activeActivity reference (state=\(String(describing: existing.activityState), privacy: .public))")
            cleanupTimers()
            activeActivity = nil
            currentState = Self.emptyState
        }

        guard activeActivity == nil else { return }

        guard let recovered = Activity<PiSessionAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) else { return }

        activeActivity = recovered
        observeActivityLifecycle(recovered)
        let recoveredContent = recovered.content
        currentState = recoveredContent.state
        lastStateChangeAt = recoveredStateChangeDate(from: recoveredContent)
        lastDeliveredSnapshot = DeliveredSnapshot(from: recoveredContent)
        logger.error("Recovered orphaned Live Activity reference (id=\(recovered.id, privacy: .public), state=\(String(describing: recovered.activityState), privacy: .public))")
    }

    private func endActivitiesIfPreferenceDisabled() {
        cleanupTimers()
        activeActivity = nil

        let activitiesToEnd = Activity<PiSessionAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard !activitiesToEnd.isEmpty else { return }

        let finalState = Self.emptyState
        for activity in activitiesToEnd {
            nonisolated(unsafe) let detachedActivity = activity
            Task {
                await detachedActivity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }

        logger.error(
            "Live Activities disabled by preference; ended \(activitiesToEnd.count, privacy: .public) activity(ies)"
        )
    }

    private func refreshLifecycle() {
        let liveActivitiesEnabled = AppPreferences.LiveActivity.isEnabled

        if liveActivitiesEnabled {
            recoverTrackedActivityReferenceIfNeeded()
        } else {
            endActivitiesIfPreferenceDisabled()
        }

        applyCurrentState(aggregateState())

        guard liveActivitiesEnabled else { return }

        scheduleAwaitingReplyExpiryIfNeeded()

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
        state.totalActiveSessions > 0
    }

    private func applyCurrentState(_ nextState: PiSessionAttributes.ContentState, now: Date = Date()) {
        if nextState != currentState {
            lastStateChangeAt = now
        }
        currentState = nextState
    }

    private func activityContent(for state: PiSessionAttributes.ContentState) -> ActivityContent<PiSessionAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: staleDate(for: state),
            relevanceScore: relevanceScore(for: state)
        )
    }

    private func recoveredStateChangeDate(
        from content: ActivityContent<PiSessionAttributes.ContentState>,
        now: Date = Date()
    ) -> Date {
        guard let staleDate = content.staleDate else {
            return now
        }
        return staleDate.addingTimeInterval(-staleIntervalSeconds)
    }

    private func scheduleAwaitingReplyExpiryIfNeeded() {
        let nextExpiry = nextAwaitingReplyExpiryDate()

        guard let nextExpiry else {
            awaitingReplyExpiryTask?.cancel()
            awaitingReplyExpiryTask = nil
            awaitingReplyExpiryDate = nil
            return
        }

        if let existing = awaitingReplyExpiryDate,
           abs(existing.timeIntervalSince(nextExpiry)) < 0.01,
           awaitingReplyExpiryTask != nil {
            return
        }

        awaitingReplyExpiryTask?.cancel()
        awaitingReplyExpiryDate = nextExpiry

        awaitingReplyExpiryTask = Task { [weak self] in
            let delay = max(0, nextExpiry.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled, let self else { return }

            self.awaitingReplyExpiryTask = nil
            self.awaitingReplyExpiryDate = nil

            self.refreshLifecycle()

            if !self.shouldShowLiveActivity(state: self.currentState) {
                self.endIfNeeded()
            }
        }
    }

    private func nextAwaitingReplyExpiryDate(now: Date = Date()) -> Date? {
        var earliest: Date?

        for snapshot in connectionSnapshots.values {
            for session in snapshot.sessionsById.values {
                guard session.status == .ready else { continue }
                let phase = phase(for: session)
                guard phase == .awaitingReply else { continue }

                let referenceDate = session.readySince ?? session.updatedAt
                let expiry = referenceDate.addingTimeInterval(awaitingReplyVisibilitySeconds)
                guard expiry > now else { continue }

                if let current = earliest {
                    if expiry < current {
                        earliest = expiry
                    }
                } else {
                    earliest = expiry
                }
            }
        }

        return earliest
    }

    private func ensureActivityStartedIfNeeded() {
        guard AppPreferences.LiveActivity.isEnabled else { return }

        // Check if our tracked activity was ended by the system (8-hour limit,
        // user removal). activityState is synchronously available.
        if let existing = activeActivity,
           existing.activityState == .ended || existing.activityState == .dismissed {
            logger.error("Detected system-ended activity, clearing stale reference")
            cleanupTimers()
            activeActivity = nil
            currentState = Self.emptyState
        }

        guard activeActivity == nil else { return }

        let authInfo = ActivityAuthorizationInfo()
        guard authInfo.areActivitiesEnabled else {
            logger.error("Live Activities not enabled (areActivitiesEnabled=false). User must enable in Settings → Oppi → Live Activities")
            return
        }

        let attributes = PiSessionAttributes(activityName: "Oppi")

        do {
            let content = activityContent(for: currentState)
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activeActivity = activity
            observeActivityLifecycle(activity)
            lastDeliveredSnapshot = DeliveredSnapshot(from: content)
            logger.error("Live Activity started")
        } catch {
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Watch for system-initiated activity endings (8-hour limit, user removal).
    /// When detected, nil out `activeActivity` so the next `refreshLifecycle()`
    /// can restart it if sessions are still active.
    private func observeActivityLifecycle(_ activity: Activity<PiSessionAttributes>) {
        activityObservationTask?.cancel()
        activityObservationTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                switch state {
                case .ended, .dismissed:
                    logger.error("Activity ended by system (state=\(String(describing: state), privacy: .public))")
                    if self.activeActivity?.id == activity.id {
                        self.cleanupTimers()
                        self.activeActivity = nil
                        self.currentState = Self.emptyState

                        // If we still have active sessions, restart the activity.
                        if self.shouldShowLiveActivity(state: self.aggregateState()) {
                            self.refreshLifecycle()
                        }
                    }
                case .pending, .active, .stale:
                    break
                @unknown default:
                    break
                }
            }
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

    // MARK: - Activity Updates

    /// Throttled push: coalesces rapid state changes into at most one
    /// ActivityKit update per `pushThrottleInterval`.
    private func pushUpdate() {
        guard AppPreferences.LiveActivity.isEnabled else { return }
        guard activeActivity != nil else { return }

        hasPendingPush = true

        guard pushThrottleTask == nil else { return }

        executePush()

        pushThrottleTask = Task { [weak self] in
            try? await Task.sleep(for: self?.pushThrottleInterval ?? .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            if self.hasPendingPush {
                self.executePush()
            }
            self.pushThrottleTask = nil
        }
    }

    private func executePush() {
        guard AppPreferences.LiveActivity.isEnabled else { return }
        guard let activity = activeActivity else { return }

        hasPendingPush = false

        let state = currentState
        let deliveredSnapshot = DeliveredSnapshot(from: activityContent(for: state))

        if deliveredSnapshot == lastDeliveredSnapshot {
            return
        }

        lastDeliveredSnapshot = deliveredSnapshot

        nonisolated(unsafe) let detachedActivity = activity
        let alertConfiguration: AlertConfiguration? = nil

        Task {
            await detachedActivity.update(
                ActivityContent(
                    state: state,
                    staleDate: deliveredSnapshot.staleDate,
                    relevanceScore: deliveredSnapshot.relevanceScore
                ),
                alertConfiguration: alertConfiguration
            )
        }
    }

    // MARK: - Aggregation

    private func aggregateState() -> PiSessionAttributes.ContentState {
        let sortedConnectionIds = connectionSnapshots.keys.sorted()

        var allSessions: [SessionSnapshot] = []

        for connectionId in sortedConnectionIds {
            guard let snapshot = connectionSnapshots[connectionId] else { continue }
            allSessions.append(contentsOf: snapshot.sessionsById.values)
        }

        let sessionViews = allSessions.map { session in
            SessionView(
                id: session.id,
                name: session.name,
                phase: phase(for: session),
                activeTool: session.activeTool,
                lastActivity: session.lastActivity,
                startDate: session.startDate,
                changeStats: session.changeStats,
                updatedAt: session.updatedAt
            )
        }

        let totalActiveSessions = sessionViews.filter { $0.phase != .ended }.count
        let sessionsAwaitingReply = sessionViews.filter { $0.phase == .awaitingReply }.count
        let sessionsWorking = sessionViews.filter { $0.phase == .working }.count

        let primary = sessionViews.max { lhs, rhs in
            let lhsPriority = phasePriority(lhs.phase)
            let rhsPriority = phasePriority(rhs.phase)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.updatedAt < rhs.updatedAt
        }

        if let primary {
            return PiSessionAttributes.ContentState(
                primaryPhase: primary.phase,
                primarySessionId: primary.id,
                primarySessionName: primary.name,
                primaryTool: primary.activeTool,
                primaryLastActivity: primary.lastActivity,
                totalActiveSessions: totalActiveSessions,
                sessionsAwaitingReply: sessionsAwaitingReply,
                sessionsWorking: sessionsWorking,
                primaryMutatingToolCalls: primary.changeStats?.mutatingToolCalls,
                primaryFilesChanged: primary.changeStats?.filesChanged,
                primaryAddedLines: primary.changeStats?.addedLines,
                primaryRemovedLines: primary.changeStats?.removedLines,
                sessionStartDate: primary.phase == .working ? primary.startDate : nil
            )
        }

        return Self.emptyState
    }

    private func phase(for session: SessionSnapshot) -> SessionPhase {
        switch session.status {
        case .starting, .busy, .stopping:
            return .working
        case .error:
            return .error
        case .stopped:
            return .ended
        case .ready:
            // Use readySince (anchored to the .ready transition) rather than
            // updatedAt (which sync() refreshes on every message). This ensures
            // the awaitingReply window doesn't get extended indefinitely.
            let referenceDate = session.readySince ?? session.updatedAt
            let age = Date().timeIntervalSince(referenceDate)
            if age <= awaitingReplyVisibilitySeconds,
               session.phaseHint != .error {
                return .awaitingReply
            }
            return .ended
        }
    }

    private func isWorkingStatus(_ status: SessionStatus) -> Bool {
        switch status {
        case .starting, .busy, .stopping:
            return true
        case .ready, .error, .stopped:
            return false
        }
    }

    private func baselinePhase(for status: SessionStatus) -> SessionPhase {
        switch status {
        case .starting, .busy, .stopping:
            return .working
        case .ready:
            return .awaitingReply
        case .error:
            return .error
        case .stopped:
            return .ended
        }
    }

    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .error: return 75
        case .working: return 50
        case .awaitingReply: return 25
        case .ended: return 0
        }
    }

    private func relevanceScore(for state: PiSessionAttributes.ContentState) -> Double {
        Double(phasePriority(state.primaryPhase))
    }

    private func staleDate(for state: PiSessionAttributes.ContentState) -> Date? {
        if state.primaryPhase == .awaitingReply {
            return nil
        }
        if state.primaryPhase == .ended {
            return nil
        }
        return lastStateChangeAt.addingTimeInterval(staleIntervalSeconds)
    }

    private func fallbackSessionName(_ sessionId: String) -> String {
        "Session \(String(sessionId.prefix(8)))"
    }

    private func defaultLastActivity(for phase: SessionPhase) -> String {
        switch phase {
        case .working: return String(localized: "Working")
        case .awaitingReply: return String(localized: "Your turn")
        case .error: return String(localized: "Attention needed")
        case .ended: return String(localized: "Session ended")
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

    private func toolActivityLabel(_ tool: String, seed: String) -> String {
        let options: [String]
        switch tool.lowercased() {
        case "bash":
            options = [
                String(localized: "Bashing"),
                String(localized: "Invoking"),
                String(localized: "Poking"),
                String(localized: "Tinkering"),
            ]
        case "read":
            options = [
                String(localized: "Scanning"),
                String(localized: "Inspecting"),
                String(localized: "Peeking"),
                String(localized: "Parsing"),
            ]
        case "write":
            options = [
                String(localized: "Drafting"),
                String(localized: "Composing"),
                String(localized: "Writing"),
                String(localized: "Authoring"),
            ]
        case "edit":
            options = [
                String(localized: "Patching"),
                String(localized: "Tweaking"),
                String(localized: "Refining"),
                String(localized: "Reworking"),
            ]
        default:
            let displayName = displayToolName(tool)
            guard !displayName.isEmpty else {
                return String(localized: "Working")
            }
            return displayName
        }

        let index = stableVariationIndex(seed: seed, count: options.count)
        return options[index]
    }

    private func stableVariationIndex(seed: String, count: Int) -> Int {
        guard count > 1 else { return 0 }

        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
