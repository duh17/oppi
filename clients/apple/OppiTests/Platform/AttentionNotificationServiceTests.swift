import Testing
@testable import Oppi

@Suite("AttentionNotificationService")
struct AttentionNotificationServiceTests {

    @Test func notifiesWhenAppIsBackgrounded() {
        #expect(
            AttentionNotificationService.shouldNotify(
                isAppActive: false,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenForegroundedForDifferentSession() {
        #expect(
            AttentionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s2",
                activeSessionId: "s1"
            )
        )
    }

    @Test func doesNotNotifyWhenForegroundedForActiveSession() {
        #expect(
            !AttentionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenForegroundedWithoutActiveSession() {
        #expect(
            AttentionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: nil
            )
        )
    }
}
