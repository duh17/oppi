import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Gives the push relay this phone's Live Activity tokens (protocol/push/spec.md "Live
/// Activity"), so a paired server can start, update, and end the card while Oppi is closed.
///
/// One call replaces the whole state at each relay registration: the push-to-start token,
/// when any server's card is on, and the update token of each live card whose server has it
/// on. Sent through the registration's App Attest–authenticated path, debounced so a burst of
/// token updates costs one request.
@MainActor
final class LiveActivityRelaySync {
    static let shared = LiveActivityRelaySync()

    private var startToken: String?
    private var activityTokens: [String: String] = [:]
    private var publishTask: Task<Void, Never>?

    private init() {}

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

    /// What the relay should hold now. Servers whose card is off contribute nothing, and with
    /// no card on anywhere the relay holds no start token, so it can start nothing.
    static func state(
        startToken: String?,
        activityTokens: [String: String],
        enabledSlots: Set<String>
    ) -> PushRelayClient.LiveActivityState {
        PushRelayClient.LiveActivityState(
            startToken: enabledSlots.isEmpty ? nil : startToken,
            activities: activityTokens
                .filter { enabledSlots.contains($0.key) }
                .map { PushRelayClient.LiveActivityState.Activity(slot: $0.key, token: $0.value) }
                .sorted { $0.slot < $1.slot }
        )
    }

    /// Send the current state to every relay this phone registered with, after a short pause.
    func publish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let state = Self.state(
                startToken: self.startToken,
                activityTokens: self.activityTokens,
                enabledSlots: LiveActivitySettings.enabledSlots()
            )
            for registration in PushRelayRegistrationStore.all() {
                guard let relay = URL(string: registration.relay) else { continue }
                do {
                    try await PushRelayClient(relay: relay).putLiveActivity(state, registration: registration)
                } catch {
                    // A gone registration comes back with the next push registration, which
                    // publishes again.
                    logger.error("Live Activity tokens not sent to relay: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
