import ActivityKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LiveActivity")

/// Oppi's Live Activity: one counts-only card per server whose card is on
/// (`LiveActivitySettings`), saying how many top-level sessions run and how many wait on you.
///
/// While Oppi runs it drives each card from the server's sessions. While Oppi is closed, a
/// server with push on drives the same card through the relay (protocol/push/spec.md "Live
/// Activity"); the server skips a device that holds a live stream, so the two never drive the
/// card at once. Every card is requested with `pushType: .token`, and every card's update token,
/// including those the relay started, goes to `LiveActivityRelaySync`.
@MainActor @Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    typealias Counts = OppiActivityAttributes.ContentState

    static let noCounts = Counts(running: 0, needsYou: 0)
    /// An ended card leaves the Lock Screen this long after it ends; the relay uses the same.
    static let dismissalDelay: TimeInterval = 30

    /// Counts of each synced server whose card is on, by server ID.
    private(set) var countsByServer: [String: Counts] = [:]
    /// The card for each slot.
    private var activities: [String: Activity<OppiActivityAttributes>] = [:]
    /// Token and state watchers, by activity ID.
    private var watchers: [String: Task<Void, Never>] = [:]
    private var systemObservers: [Task<Void, Never>] = []
    /// Slots whose card the person dismissed: no new card until the counts reach zero.
    private var dismissedSlots: Set<String> = []

    private let isEnabled: @MainActor (String) -> Bool
    private let serverDrivesCard: @MainActor (String) -> Bool

    init(
        isEnabled: @escaping @MainActor (String) -> Bool = { LiveActivitySettings.isEnabled(serverId: $0) },
        serverDrivesCard: @escaping @MainActor (String) -> Bool = { PushRegistration.isEnabled(serverId: $0) }
    ) {
        self.isEnabled = isEnabled
        self.serverDrivesCard = serverDrivesCard
    }

    // MARK: - Counts

    /// Running and waiting top-level sessions. Subagents never count, matching the server.
    static func counts(for sessions: [Session]) -> Counts {
        var counts = noCounts
        for session in sessions where session.parentSessionId == nil {
            let kind = SessionStatusKind.resolve(session: session, seenAt: nil)
            if kind == .working {
                counts.running += 1
            } else if kind.isBlocked {
                counts.needsYou += 1
            }
        }
        return counts
    }

    // MARK: - Inputs

    /// The server's current sessions. `connectionId` is the server ID.
    func sync(connectionId serverId: String, sessions: [Session]) {
        guard isEnabled(serverId) else {
            countsByServer.removeValue(forKey: serverId)
            endCard(serverId: serverId)
            return
        }
        countsByServer[serverId] = Self.counts(for: sessions)
        apply(serverId: serverId)
    }

    /// The app stopped following this server. A server with push on keeps the card current;
    /// otherwise nothing would, so it ends.
    func removeConnection(_ serverId: String) {
        countsByServer.removeValue(forKey: serverId)
        if !(isEnabled(serverId) && serverDrivesCard(serverId)) {
            endCard(serverId: serverId)
        }
    }

    /// The server's card or push setting changed.
    func settingsChanged(serverId: String) {
        if !isEnabled(serverId) {
            countsByServer.removeValue(forKey: serverId)
            endCard(serverId: serverId)
        }
        LiveActivityRelaySync.shared.publish()
    }

    /// Watch for cards the relay starts and for the push-to-start token. Call once at launch,
    /// including a background launch: iOS wakes Oppi so it can report a pushed card's token.
    func startObservingSystem() {
        guard systemObservers.isEmpty else { return }
        adoptExisting()
        systemObservers.append(Task { [weak self] in
            for await activity in Activity<OppiActivityAttributes>.activityUpdates {
                self?.adopt(activity)
            }
        })
        systemObservers.append(Task {
            for await token in Activity<OppiActivityAttributes>.pushToStartTokenUpdates {
                LiveActivityRelaySync.shared.setStartToken(token)
            }
        })
    }

    /// Back in the foreground: pick up cards started or ended while away.
    func recoverIfNeeded() {
        adoptExisting()
        for serverId in countsByServer.keys { apply(serverId: serverId) }
    }

    // MARK: - ActivityKit

    private func apply(serverId: String) {
        guard let counts = countsByServer[serverId] else { return }
        let slot = LiveActivitySettings.slot(serverId: serverId)
        if counts == Self.noCounts {
            dismissedSlots.remove(slot)
            endCard(serverId: serverId)
            return
        }
        if let activity = activities[slot] {
            guard activity.content.state != counts else { return }
            nonisolated(unsafe) let detached = activity
            Task { await detached.update(ActivityContent(state: counts, staleDate: nil)) }
            return
        }
        guard !dismissedSlots.contains(slot), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: OppiActivityAttributes(slot: slot),
                content: ActivityContent(state: counts, staleDate: nil),
                pushType: .token
            )
            adopt(activity)
        } catch {
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func endCard(serverId: String) {
        let slot = LiveActivitySettings.slot(serverId: serverId)
        guard let activity = activities.removeValue(forKey: slot) else { return }
        end(activity, dismissal: .after(Date().addingTimeInterval(Self.dismissalDelay)))
        LiveActivityRelaySync.shared.removeActivity(slot: slot)
    }

    private func end(_ activity: Activity<OppiActivityAttributes>, dismissal: ActivityUIDismissalPolicy) {
        nonisolated(unsafe) let detached = activity
        Task { await detached.end(ActivityContent(state: Self.noCounts, staleDate: nil), dismissalPolicy: dismissal) }
    }

    private func adoptExisting() {
        for activity in Activity<OppiActivityAttributes>.activities {
            adopt(activity)
        }
    }

    /// Track a card. A newer card for the same server replaces the one held: it is the one
    /// the relay just started.
    private func adopt(_ activity: Activity<OppiActivityAttributes>) {
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        let slot = activity.attributes.slot
        guard LiveActivitySettings.serverId(forSlot: slot).map(isEnabled) == true else {
            // A card for a server whose card is off, or one this phone no longer knows.
            end(activity, dismissal: .immediate)
            return
        }
        if let held = activities[slot] {
            guard held.id != activity.id else { return }
            end(held, dismissal: .immediate)
        }
        activities[slot] = activity
        watch(activity, slot: slot)
    }

    private func watch(_ activity: Activity<OppiActivityAttributes>, slot: String) {
        guard watchers[activity.id] == nil else { return }
        watchers[activity.id] = Task { [weak self] in
            let tokens = Task {
                for await token in activity.pushTokenUpdates {
                    LiveActivityRelaySync.shared.setActivityToken(token, slot: slot)
                }
            }
            defer { tokens.cancel() }
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                self?.cardEnded(activity, slot: slot, state: state)
                return
            }
        }
    }

    /// Apple ended the card (its 8 hours ran out), the person dismissed it, or someone ended it.
    private func cardEnded(_ activity: Activity<OppiActivityAttributes>, slot: String, state: ActivityState) {
        watchers.removeValue(forKey: activity.id)
        guard activities[slot]?.id == activity.id else { return }
        activities.removeValue(forKey: slot)
        LiveActivityRelaySync.shared.removeActivity(slot: slot)
        logger.info("Live Activity ended (state=\(String(describing: state), privacy: .public))")
        // Apple's 8 hours ran out while work goes on: start a new card. A dismissed card
        // stays away until the work it counted is over.
        if state == .dismissed {
            dismissedSlots.insert(slot)
        } else if let serverId = LiveActivitySettings.serverId(forSlot: slot) {
            apply(serverId: serverId)
        }
    }
}
