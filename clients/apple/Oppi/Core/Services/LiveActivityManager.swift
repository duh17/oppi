import ActivityKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LiveActivity")

/// Oppi's Live Activity: one counts-only card per server whose card is on
/// (`LiveActivitySettings`), saying how many threads (a top-level session with its subagents) run
/// and how many wait on you.
///
/// While Oppi runs it drives each card from the server's sessions. While Oppi is closed, a
/// server with push on drives the same card through the relay (protocol/push/spec.md "Live
/// Activity"); the server skips a device that holds a live stream, so the two never drive the
/// card at once. Every card is requested with `pushType: .token`, and every card's update token,
/// including those the relay started, goes to `LiveActivityRelaySync`.
///
/// A card the person dismissed stays away until that server's counts reach zero: this app
/// starts none for it, and the relay, told through `LiveActivityRelaySync`, lets no server
/// start one until the server ends it at zero. Dismissals survive the app being killed, and a
/// dismissed card that ActivityKit still lists when Oppi comes back counts as one.
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
    /// The counts this manager last sent each slot's card. ActivityKit's `content` is a
    /// synchronous call into the system, so `apply` compares against this instead. A card with
    /// no entry (adopted, or after a return to the foreground) gets one update.
    private var sentCounts: [String: Counts] = [:]
    /// Token and state watchers, by activity ID.
    private var watchers: [String: Task<Void, Never>] = [:]
    private var systemObservers: [Task<Void, Never>] = []
    @ObservationIgnored private var dismissals: Dismissals {
        didSet {
            guard dismissals != oldValue else { return }
            dismissals.save(to: defaults)
            relaySync.setDismissed(dismissals.slots)
        }
    }

    /// Slots whose card the person dismissed: no new card until the counts reach zero.
    var dismissedSlots: Set<String> { dismissals.slots }

    private let isEnabled: @MainActor (String) -> Bool
    private let serverDrivesCard: @MainActor (String) -> Bool
    private let relaySync: LiveActivityRelaySync
    private let defaults: UserDefaults

    init(
        isEnabled: @escaping @MainActor (String) -> Bool = { LiveActivitySettings.isEnabled(serverId: $0) },
        serverDrivesCard: @escaping @MainActor (String) -> Bool = { PushRegistration.isEnabled(serverId: $0) },
        relaySync: LiveActivityRelaySync = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.isEnabled = isEnabled
        self.serverDrivesCard = serverDrivesCard
        self.relaySync = relaySync
        self.defaults = defaults
        // Before any card is requested: a dismissal from before the app was killed holds.
        dismissals = Dismissals.load(from: defaults)
        relaySync.setDismissed(dismissals.slots)
    }

    // MARK: - Dismissals

    /// Dismissed slots, and the IDs of the dismissed cards already counted, so a dismissed card
    /// ActivityKit still lists counts once.
    struct Dismissals: Codable, Equatable {
        var slots: Set<String> = []
        var activityIds: Set<String> = []

        private static let key = "\(AppIdentifiers.subsystem).liveActivity.dismissals"

        static func load(from defaults: UserDefaults) -> Dismissals {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Dismissals.self, from: $0) } ?? Dismissals()
        }

        func save(to defaults: UserDefaults) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// A card as ActivityKit lists it.
    struct ListedCard: Equatable {
        let id: String
        let slot: String
        let state: ActivityState
        let counts: Counts
    }

    /// Listed cards the person dismissed that this app has not counted yet: dismissed while
    /// they showed work (this app and the relay end a card at zero), with no live card for
    /// the slot since.
    static func uncountedDismissals(in listed: [ListedCard], counted: Set<String>) -> [ListedCard] {
        let live = Set(listed.filter { $0.state == .active || $0.state == .stale }.map(\.slot))
        return listed.filter { card in
            card.state == .dismissed && card.counts != noCounts
                && !live.contains(card.slot) && !counted.contains(card.id)
        }
    }

    /// The person dismissed the card `activityId` for `slot`.
    func recordDismissal(slot: String, activityId: String) {
        dismissals.slots.insert(slot)
        dismissals.activityIds.insert(activityId)
    }

    // MARK: - Counts

    /// One count per thread (a top-level session with all its subagents), matching the server:
    /// a thread needs you while any session in it is blocked, else runs while any is working.
    static func counts(for sessions: [Session]) -> Counts {
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var blockedThreads = Set<String>()
        var workingThreads = Set<String>()
        for session in sessions {
            let kind = SessionStatusKind.resolve(session: session, seenAt: nil)
            if kind.isBlocked {
                blockedThreads.insert(threadRoot(session, byId: byId))
            } else if kind == .working {
                workingThreads.insert(threadRoot(session, byId: byId))
            }
        }
        var counts = noCounts
        counts.needsYou = blockedThreads.count
        counts.running = workingThreads.subtracting(blockedThreads).count
        return counts
    }

    /// The thread's top-level session id, or the topmost ancestor id when that session is gone.
    private static func threadRoot(_ session: Session, byId: [String: Session]) -> String {
        var current = session
        var seen: Set<String> = [session.id]
        while let parentId = current.parentSessionId {
            guard let parent = byId[parentId], seen.insert(parentId).inserted else { return parentId }
            current = parent
        }
        return current.id
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
        relaySync.publish()
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
        let relaySync = relaySync
        systemObservers.append(Task {
            for await token in Activity<OppiActivityAttributes>.pushToStartTokenUpdates {
                relaySync.setStartToken(token)
            }
        })
        // A state a relay had not accepted when the app was killed.
        relaySync.publish()
    }

    /// Back in the foreground: pick up cards started, ended, or dismissed while away, and send
    /// the relay any state it has not accepted.
    func recoverIfNeeded() {
        adoptExisting()
        // A relay may have moved the cards while away: send each card the counts once more.
        // This runs inside the scene's activation update, where ActivityKit's blocking calls
        // can trip the scene-update watchdog, so the sends run after that update finishes, when
        // `AppScenePhase` has seen the activation. A scene that deactivated meanwhile starts no card.
        Task { @MainActor [weak self] in
            guard let self else { return }
            sentCounts.removeAll()
            for serverId in countsByServer.keys { apply(serverId: serverId) }
        }
        relaySync.publish()
    }

    // MARK: - ActivityKit

    /// ActivityKit's authorization check and `Activity.request` block on a system queue, which
    /// deadlocks the launch scene update (watchdog 0x8BADF00D) while the scene is inactive, and a
    /// card cannot start in the background anyway. Until the scene is active, `apply` does not
    /// start a card; `recoverIfNeeded` applies every server then.
    private func apply(serverId: String) {
        guard let counts = countsByServer[serverId] else { return }
        let slot = LiveActivitySettings.slot(serverId: serverId, defaults: defaults)
        if counts == Self.noCounts {
            dismissals.slots.remove(slot)
            endCard(serverId: serverId)
            return
        }
        if let activity = activities[slot] {
            guard sentCounts[slot] != counts else { return }
            sentCounts[slot] = counts
            nonisolated(unsafe) let detached = activity
            Task { await detached.update(ActivityContent(state: counts, staleDate: nil)) }
            return
        }
        guard AppScenePhase.shared.phase == .active, !dismissals.slots.contains(slot),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: OppiActivityAttributes(slot: slot),
                content: ActivityContent(state: counts, staleDate: nil),
                pushType: .token
            )
            adopt(activity)
            sentCounts[slot] = counts
        } catch {
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func endCard(serverId: String) {
        let slot = LiveActivitySettings.slot(serverId: serverId, defaults: defaults)
        sentCounts.removeValue(forKey: slot)
        guard let activity = activities.removeValue(forKey: slot) else { return }
        end(activity, dismissal: .after(Date().addingTimeInterval(Self.dismissalDelay)))
        relaySync.removeActivity(slot: slot)
    }

    private func end(_ activity: Activity<OppiActivityAttributes>, dismissal: ActivityUIDismissalPolicy) {
        nonisolated(unsafe) let detached = activity
        Task { await detached.end(ActivityContent(state: Self.noCounts, staleDate: nil), dismissalPolicy: dismissal) }
    }

    /// Adopt every live card ActivityKit lists, count the dismissals that happened while Oppi
    /// was not running, and forget update tokens of cards that are gone.
    private func adoptExisting() {
        let listed = Activity<OppiActivityAttributes>.activities
        for activity in listed {
            adopt(activity)
        }
        let cards = listed.map {
            ListedCard(id: $0.id, slot: $0.attributes.slot, state: $0.activityState, counts: $0.content.state)
        }
        for card in Self.uncountedDismissals(in: cards, counted: dismissals.activityIds)
            where LiveActivitySettings.serverId(forSlot: card.slot, defaults: defaults).map(isEnabled) == true {
            logger.info("Live Activity dismissed while Oppi was not running")
            recordDismissal(slot: card.slot, activityId: card.id)
        }
        // Only cards ActivityKit still lists can come back through it.
        dismissals.activityIds.formIntersection(cards.map(\.id))
        relaySync.keepActivities(slots: Set(activities.keys))
    }

    /// Track a card. A newer card for the same server replaces the one held: it is the one
    /// the relay just started.
    private func adopt(_ activity: Activity<OppiActivityAttributes>) {
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        let slot = activity.attributes.slot
        guard LiveActivitySettings.serverId(forSlot: slot, defaults: defaults).map(isEnabled) == true else {
            // A card for a server whose card is off, or one this phone no longer knows.
            end(activity, dismissal: .immediate)
            return
        }
        let held = activities[slot]
        if held?.id == activity.id { return }
        if dismissals.slots.contains(slot) {
            guard relaySync.relayHoldsDismissal(slot) else {
                // A relay started it before it held the dismissal, or while it may be changing.
                end(activity, dismissal: .immediate)
                return
            }
            // The relay starts no card for a dismissed slot until a server ends it at zero:
            // this card is for new work.
            dismissals.slots.remove(slot)
        }
        if let held { end(held, dismissal: .immediate) }
        sentCounts.removeValue(forKey: slot)
        activities[slot] = activity
        watch(activity, slot: slot)
    }

    private func watch(_ activity: Activity<OppiActivityAttributes>, slot: String) {
        guard watchers[activity.id] == nil else { return }
        let relaySync = relaySync
        watchers[activity.id] = Task { [weak self] in
            let tokens = Task {
                for await token in activity.pushTokenUpdates {
                    relaySync.setActivityToken(token, slot: slot)
                }
            }
            // Track what the card shows (relay pushes move it too) so `sentCounts` never goes
            // stale against the card without a synchronous read of `activity.content`.
            let contents = Task { [weak self] in
                for await content in activity.contentUpdates {
                    guard let self, activities[slot]?.id == activity.id else { continue }
                    sentCounts[slot] = content.state
                }
            }
            defer {
                tokens.cancel()
                contents.cancel()
            }
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
        sentCounts.removeValue(forKey: slot)
        relaySync.removeActivity(slot: slot)
        logger.info("Live Activity ended (state=\(String(describing: state), privacy: .public))")
        // Apple's 8 hours ran out while work goes on: start a new card. A dismissed card
        // stays away until the work it counted is over.
        if state == .dismissed {
            recordDismissal(slot: slot, activityId: activity.id)
        } else if let serverId = LiveActivitySettings.serverId(forSlot: slot, defaults: defaults) {
            apply(serverId: serverId)
        }
    }
}
