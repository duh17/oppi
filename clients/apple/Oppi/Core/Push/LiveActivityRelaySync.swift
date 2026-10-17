import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Gives the push relay this phone's Live Activity tokens (protocol/push/spec.md "Live
/// Activity"), so a paired server can start, update, and end the card while Oppi is closed.
///
/// One call replaces the whole state at each relay registration: the push-to-start token,
/// when any server's card is on, the update token of each live card whose server has it on,
/// and the slots whose card the person dismissed, which the relay starts no card for until
/// that server's counts reach zero. Sent through the registration's App Attest–authenticated
/// path, debounced so a burst of token updates costs one request, and tried again until every
/// relay accepts it: until then a server may find no token for a card the phone shows.
@MainActor
final class LiveActivityRelaySync {
    static let shared = LiveActivityRelaySync()

    /// Pauses before each new try of an upload that failed. A newer state starts over.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(300)]

    typealias Put = @MainActor (PushRelayClient.LiveActivityState, PushRelayClient.Registration) async throws -> Void

    private var startToken: String?
    private var activityTokens: [String: String] = [:]
    private var dismissedSlots: Set<String> = []
    /// Dismissed slots in the state every relay last accepted.
    private var acceptedDismissals: Set<String> = []
    private var publishTask: Task<Void, Never>?

    private let registrations: @MainActor () -> [PushRelayClient.Registration]
    private let enabledSlots: @MainActor () -> Set<String>
    private let put: Put
    private let sleep: @MainActor (Duration) async throws -> Void

    init(
        registrations: @escaping @MainActor () -> [PushRelayClient.Registration] = { PushRelayRegistrationStore.all() },
        enabledSlots: @escaping @MainActor () -> Set<String> = { LiveActivitySettings.enabledSlots() },
        put: @escaping Put = { state, registration in
            guard let relay = URL(string: registration.relay) else { return }
            try await PushRelayClient(relay: relay).putLiveActivity(state, registration: registration)
        },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.registrations = registrations
        self.enabledSlots = enabledSlots
        self.put = put
        self.sleep = sleep
    }

    func setStartToken(_ token: Data) {
        let hex = token.hexString
        guard hex != startToken else { return }
        startToken = hex
        publish()
    }

    func setActivityToken(_ token: Data, slot: String) {
        let hex = token.hexString
        guard activityTokens[slot] != hex else { return }
        activityTokens[slot] = hex
        publish()
    }

    /// The card for `slot` ended: its token takes no more updates.
    func removeActivity(slot: String) {
        guard activityTokens.removeValue(forKey: slot) != nil else { return }
        publish()
    }

    /// Slots whose card the person dismissed and that have had no card since.
    func setDismissed(_ slots: Set<String>) {
        guard slots != dismissedSlots else { return }
        dismissedSlots = slots
        publish()
    }

    /// Every relay holds the dismissal of `slot`, so none starts a card for it until a server
    /// ends it at zero: a card the relay starts after this is for new work.
    func relayHoldsDismissal(_ slot: String) -> Bool {
        acceptedDismissals.contains(slot)
    }

    /// What the relay should hold now. Servers whose card is off contribute nothing, and with
    /// no card on anywhere the relay holds no start token, so it can start nothing.
    static func state(
        startToken: String?,
        activityTokens: [String: String],
        dismissedSlots: Set<String> = [],
        enabledSlots: Set<String>
    ) -> PushRelayClient.LiveActivityState {
        PushRelayClient.LiveActivityState(
            startToken: enabledSlots.isEmpty ? nil : startToken,
            activities: activityTokens
                .filter { enabledSlots.contains($0.key) && !dismissedSlots.contains($0.key) }
                .map { PushRelayClient.LiveActivityState.Activity(slot: $0.key, token: $0.value) }
                .sorted { $0.slot < $1.slot },
            dismissed: dismissedSlots.intersection(enabledSlots).sorted()
        )
    }

    /// Send the current state to every relay this phone registered with, after a short pause,
    /// and again to each relay that failed until it accepts or the retries run out. The task
    /// ends when the upload does, or when a newer state replaces it.
    @discardableResult
    func publish() -> Task<Void, Never> {
        publishTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(.seconds(1)) } catch { return }
            await self.upload()
        }
        publishTask = task
        return task
    }

    private func upload() async {
        let state = Self.state(
            startToken: startToken,
            activityTokens: activityTokens,
            dismissedSlots: dismissedSlots,
            enabledSlots: enabledSlots()
        )
        var pending = registrations()
        var delays = Self.retryDelays[...]
        // A newer state cancels this upload; it must not send the older one.
        while !Task.isCancelled {
            var failed: [PushRelayClient.Registration] = []
            for registration in pending {
                do {
                    try await put(state, registration)
                } catch PushRelayClient.RelayError.gone {
                    // A gone registration holds nothing; the next push registration replaces
                    // it and publishes again.
                } catch {
                    failed.append(registration)
                    logger.error("Live Activity tokens not sent to relay: \(String(describing: error), privacy: .public)")
                }
            }
            if Task.isCancelled { return }
            pending = failed
            if pending.isEmpty {
                acceptedDismissals = Set(state.dismissed)
                return
            }
            guard let delay = delays.popFirst() else { return }
            do { try await sleep(delay) } catch { return }
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
