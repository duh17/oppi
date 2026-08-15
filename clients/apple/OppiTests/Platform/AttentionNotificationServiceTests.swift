import Testing
@testable import Oppi

@Suite("AttentionNotificationService")
@MainActor
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

    @Test func tapBeforeNavigationHandlerIsDeliveredOnceWhenWired() {
        let service = AttentionNotificationService.shared
        service.onNavigateToSession = nil
        var deliveredSessionIds: [String] = []

        service.handleAskNotificationTap(sessionId: "ask-session")
        #expect(deliveredSessionIds.isEmpty)

        service.onNavigateToSession = { deliveredSessionIds.append($0) }
        #expect(deliveredSessionIds == ["ask-session"])

        service.onNavigateToSession = { deliveredSessionIds.append($0) }
        #expect(deliveredSessionIds == ["ask-session"])
        service.onNavigateToSession = nil
    }
}

@Suite("Session deep-link navigation policy")
struct SessionDeepLinkNavigationPolicyTests {
    @Test func unavailableNotificationDuringLaunchIsParked() {
        let disposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .resolving,
            startupComplete: false,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )

        #expect(disposition == .park)
    }

    @Test func parkedNotificationOpensAfterLaunchPopulatesSession() {
        let launchDisposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .resolving,
            startupComplete: false,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )
        let consumedDisposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: true,
            launchPhase: .ready,
            startupComplete: true,
            inviteBootstrapInFlight: false,
            parkingAllowed: false
        )

        #expect(launchDisposition == .park)
        #expect(consumedDisposition == .open)
    }

    @Test func unavailableNotificationParksAfterUIIsReadyWhileStartupContinues() {
        let disposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .ready,
            startupComplete: false,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )

        #expect(disposition == .park)
    }

    @Test func unavailableNotificationFallsBackAfterStartupCompletes() {
        let disposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .ready,
            startupComplete: true,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )

        #expect(disposition == .showWorkspaceRoot)
    }

    @Test @MainActor func startupCompletionIsMarkedAfterStartupWorkFinishes() async {
        var events: [String] = []

        await AppStartupSequence.run(
            startupWork: {
                events.append("session_refresh_started")
                await Task.yield()
                events.append("session_refresh_finished")
            },
            markComplete: {
                events.append("startup_complete")
            }
        )

        #expect(events == [
            "session_refresh_started",
            "session_refresh_finished",
            "startup_complete",
        ])
    }
}
