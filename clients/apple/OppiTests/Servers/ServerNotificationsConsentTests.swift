import Testing
@testable import Oppi

@Suite("Server notifications consent")
struct ServerNotificationsConsentTests {
    /// Counts reach the relay for any server whose push is on, even while it is offline and
    /// the relay host is unknown, so only push decides whether Live Activities asks first.
    @Test func liveActivityAsksWheneverPushIsOnWhateverTheHost() {
        for host in ["relay.example", nil] {
            let consent = ServerNotificationsSection.consentForLiveActivityOn(pushEnabled: true, relayHost: host)
            guard case .liveActivity = consent else {
                Issue.record("push on, host \(host ?? "nil"): expected a Live Activities consent, got \(String(describing: consent))")
                continue
            }
        }
        #expect(ServerNotificationsSection.consentForLiveActivityOn(pushEnabled: false, relayHost: "relay.example") == nil)
        #expect(ServerNotificationsSection.consentForLiveActivityOn(pushEnabled: false, relayHost: nil) == nil)
    }
}
