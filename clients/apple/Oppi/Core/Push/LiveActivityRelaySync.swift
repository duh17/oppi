import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Gives the push relay this phone's Live Activity state (protocol/push/spec.md "Live
/// Activity"), which alone decides which paired servers may drive a card while Oppi is closed.
///
/// One call replaces the whole state at each relay registration: one entry per server whose
/// card is on and whose send token lives at that registration, naming the permission that may
/// drive the card, its slot, the live card's update token, and whether the person dismissed it;
/// plus the push-to-start token while any entry is listed. A server left out (its card turned
/// off, push turned off, or an older permission) gets `409 no_activity` from the relay.
///
/// The state, and what each registration last accepted, survive the app being killed. An
/// upload is debounced so a burst of token updates costs one request, tried again until every
/// relay accepts it, and sent again at launch and on each return to the foreground while a
/// relay has not accepted the current state.
@MainActor
final class LiveActivityRelaySync {
    static let shared = LiveActivityRelaySync()

    /// Pauses before each new try of an upload that failed. A newer state starts over.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(300)]

    /// A server whose card is on, and the permission this phone minted for it.
    struct Card: Equatable, Sendable {
        let slot: String
        let registrationId: String
        let permissionId: String
    }

    typealias Put = @MainActor (PushRelayClient.LiveActivityState, PushRelayClient.Registration) async throws -> Void

    /// What survives the app being killed.
    struct Stored: Codable, Equatable {
        var startToken: String?
        /// Update token of each live card, by slot.
        var activityTokens: [String: String] = [:]
        /// The state each relay registration last accepted, by registration ID.
        var accepted: [String: PushRelayClient.LiveActivityState] = [:]
    }

    private static let storedKey = "\(AppIdentifiers.subsystem).liveActivity.relayState"

    private var stored: Stored {
        didSet {
            guard stored != oldValue, let data = try? JSONEncoder().encode(stored) else { return }
            defaults.set(data, forKey: Self.storedKey)
        }
    }

    /// Set by `LiveActivityManager`, which persists it.
    private var dismissedSlots: Set<String> = []
    private var publishTask: Task<Void, Never>?
    /// True from `publish()` until that upload ends: what a relay holds may be changing.
    private var uploading = false

    private let registrations: @MainActor () -> [PushRelayClient.Registration]
    private let cards: @MainActor () -> [Card]
    private let put: Put
    private let sleep: @MainActor (Duration) async throws -> Void
    private let defaults: UserDefaults

    init(
        registrations: @escaping @MainActor () -> [PushRelayClient.Registration] = { PushRelayRegistrationStore.all() },
        cards: @escaping @MainActor () -> [Card] = { LiveActivityRelaySync.enabledCards() },
        put: @escaping Put = { state, registration in
            guard let relay = URL(string: registration.relay) else { return }
            try await PushRelayClient(relay: relay).putLiveActivity(state, registration: registration)
        },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        defaults: UserDefaults = .standard
    ) {
        self.registrations = registrations
        self.cards = cards
        self.put = put
        self.sleep = sleep
        self.defaults = defaults
        stored = defaults.data(forKey: Self.storedKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// Servers whose card is on and whose push registration left this phone a send token.
    static func enabledCards() -> [Card] {
        LiveActivitySettings.enabledServers().compactMap { serverId, slot in
            guard let sendToken = PushSendTokenStore.load(serverId: serverId)?.sendToken,
                  let permission = PushRelayClient.permission(ofSendToken: sendToken) else { return nil }
            return Card(slot: slot, registrationId: permission.registrationId, permissionId: permission.permissionId)
        }
    }

    func setStartToken(_ token: Data) {
        let hex = token.hexString
        guard hex != stored.startToken else { return }
        stored.startToken = hex
        publish()
    }

    func setActivityToken(_ token: Data, slot: String) {
        let hex = token.hexString
        guard stored.activityTokens[slot] != hex else { return }
        stored.activityTokens[slot] = hex
        publish()
    }

    /// The card for `slot` ended: its token takes no more updates.
    func removeActivity(slot: String) {
        guard stored.activityTokens.removeValue(forKey: slot) != nil else { return }
        publish()
    }

    /// Forget the tokens of cards that ended while Oppi was not running.
    func keepActivities(slots: Set<String>) {
        let kept = stored.activityTokens.filter { slots.contains($0.key) }
        guard kept != stored.activityTokens else { return }
        stored.activityTokens = kept
        publish()
    }

    /// Slots whose card the person dismissed and that have had no card since.
    func setDismissed(_ slots: Set<String>) {
        guard slots != dismissedSlots else { return }
        dismissedSlots = slots
        publish()
    }

    /// Every relay holds the dismissal of `slot`, and nothing it holds is changing: no relay
    /// starts a card for the slot until a server ends it at zero, so a card a relay starts now
    /// is for new work. False while an upload is in flight or a relay has not accepted the
    /// current dismissals.
    func relayHoldsDismissal(_ slot: String) -> Bool {
        guard !uploading else { return false }
        var listed = false
        for registration in registrations() {
            guard let accepted = stored.accepted[registration.registrationId],
                  accepted.dismissedSlots == state(for: registration).dismissedSlots else { return false }
            listed = listed || accepted.dismissedSlots.contains(slot)
        }
        return listed
    }

    /// What one registration should hold now: its own servers' cards, and the start token only
    /// while it lists one, so a relay with nothing listed can start nothing.
    static func state(
        startToken: String?,
        activityTokens: [String: String],
        dismissedSlots: Set<String>,
        cards: [Card],
        registrationId: String
    ) -> PushRelayClient.LiveActivityState {
        let listed = cards.filter { $0.registrationId == registrationId }
        return PushRelayClient.LiveActivityState(
            startToken: listed.isEmpty ? nil : startToken,
            activities: listed
                .map { card in
                    let dismissed = dismissedSlots.contains(card.slot)
                    return PushRelayClient.LiveActivityState.Activity(
                        permissionId: card.permissionId,
                        slot: card.slot,
                        token: dismissed ? nil : activityTokens[card.slot],
                        dismissed: dismissed
                    )
                }
                .sorted { $0.slot < $1.slot }
        )
    }

    private func state(for registration: PushRelayClient.Registration) -> PushRelayClient.LiveActivityState {
        Self.state(
            startToken: stored.startToken,
            activityTokens: stored.activityTokens,
            dismissedSlots: dismissedSlots,
            cards: cards(),
            registrationId: registration.registrationId
        )
    }

    /// Send the current state, after a short pause, to every relay registration that has not
    /// accepted it, and again to each that failed until it accepts or the retries run out. The
    /// task ends when the upload does, or when a newer state replaces it.
    @discardableResult
    func publish() -> Task<Void, Never> {
        publishTask?.cancel()
        uploading = true
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(.seconds(1))
                await self.upload()
            } catch {}
            // A newer publish owns the flag once it has replaced this task.
            if !Task.isCancelled { self.uploading = false }
        }
        publishTask = task
        return task
    }

    private func upload() async {
        let current = registrations()
        stored.accepted = stored.accepted.filter { id, _ in current.contains { $0.registrationId == id } }
        var pending = current
        var delays = Self.retryDelays[...]
        // A newer state cancels this upload; it must not send the older one.
        while !Task.isCancelled {
            var failed: [PushRelayClient.Registration] = []
            for registration in pending {
                let state = state(for: registration)
                if stored.accepted[registration.registrationId] == state { continue }
                do {
                    try await put(state, registration)
                    stored.accepted[registration.registrationId] = state
                } catch PushRelayClient.RelayError.gone {
                    // A gone registration holds nothing and can start nothing; the next push
                    // registration replaces it and publishes again.
                    stored.accepted[registration.registrationId] = state
                } catch {
                    failed.append(registration)
                    logger.error("Live Activity state not sent to relay: \(String(describing: error), privacy: .public)")
                }
                if Task.isCancelled { return }
            }
            pending = failed
            guard !pending.isEmpty, let delay = delays.popFirst() else { return }
            do { try await sleep(delay) } catch { return }
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
