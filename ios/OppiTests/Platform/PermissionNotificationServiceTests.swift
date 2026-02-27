import Testing
@testable import Oppi

@Suite("PermissionNotificationService")
struct PermissionNotificationServiceTests {

    @Test func notifiesWhenAppIsBackgrounded() {
        #expect(
            PermissionNotificationService.shouldNotify(
                isAppActive: false,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenForegroundedForDifferentSession() {
        #expect(
            PermissionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s2",
                activeSessionId: "s1"
            )
        )
    }

    @Test func doesNotNotifyWhenForegroundedForActiveSession() {
        #expect(
            !PermissionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenForegroundedWithoutActiveSession() {
        #expect(
            PermissionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: nil
            )
        )
    }
}
