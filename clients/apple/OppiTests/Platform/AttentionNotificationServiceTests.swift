import Testing
import UserNotifications
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

    @Test func navigationSessionIdReadsAskAndRemoteSessionPayloads() {
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.askCategoryId,
                userInfo: ["sessionId": "ask-session"]
            ) == "ask-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationPolicy.agentMessageCategoryId,
                userInfo: ["sessionId": "message-session"]
            ) == "message-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationPolicy.sessionFailedCategoryId,
                userInfo: ["sessionId": "failed-session"]
            ) == "failed-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.sessionBlockedCategoryId,
                userInfo: ["sessionId": "blocked-session", "event": "blocked", "kind": "permission"]
            ) == "blocked-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.askCategoryId,
                userInfo: ["sessionId": "  "]
            ) == nil
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: "OTHER",
                userInfo: ["sessionId": "ignored"]
            ) == nil
        )
    }

    @Test func openingASessionClearsOnlyThatSessionsNotificationsOnItsServer() {
        func notification(_ id: String, category: String, _ userInfo: [String: String]) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = category
            content.userInfo = userInfo
            return UNNotificationRequest(identifier: id, content: content, trigger: nil)
        }
        let message = AttentionNotificationPolicy.agentMessageCategoryId
        let delivered = [
            notification("push-message", category: message, ["serverId": "a", "sessionId": "s1"]),
            notification("push-blocked", category: AttentionNotificationService.sessionBlockedCategoryId, ["serverId": "a", "sessionId": "s1"]),
            notification("local-ask", category: AttentionNotificationService.askCategoryId, ["sessionId": "s1"]),
            notification("other-session", category: message, ["serverId": "a", "sessionId": "s2"]),
            notification("other-server", category: message, ["serverId": "b", "sessionId": "s1"]),
            notification("pairing", category: AttentionNotificationService.pairingApprovalCategoryId, ["serverId": "a"]),
        ]

        #expect(AttentionNotificationService.sessionNotificationIdentifiers(
            in: delivered,
            serverId: "a",
            sessionIds: ["s1"]
        ) == ["push-message", "push-blocked", "local-ask"])
    }

    @Test func becomingActiveClearsOnlyFallbackAlerts() {
        func notification(_ id: String, title: String, body: String, category: String = "") -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            return UNNotificationRequest(identifier: id, content: content, trigger: nil)
        }
        let fallback = PushAlertPresentation.fallback
        let delivered = [
            notification("fallback", title: fallback.title, body: fallback.body),
            notification(
                "agent-message",
                title: "Oppi",
                body: "Release notes are ready.",
                category: AttentionNotificationPolicy.agentMessageCategoryId
            ),
            notification(
                "question",
                title: "Question",
                body: fallback.body,
                category: AttentionNotificationService.sessionBlockedCategoryId
            ),
        ]

        #expect(AttentionNotificationService.fallbackNotificationIdentifiers(in: delivered) == ["fallback"])
    }
}

@Suite("Invite pairing gate")
struct InvitePairingGateTests {
    @Test func secondInviteProceedsWhilePreviousAttemptIsInFlight() {
        var gate = InvitePairingGate()
        let first = gate.beginIncoming()
        gate.markStarted(first)
        #expect(gate.inFlight)

        let second = gate.beginIncoming()
        #expect(gate.shouldRun(second))
        #expect(!gate.shouldRun(first))

        gate.markStarted(second)
        #expect(gate.inFlight)
        gate.markFinished(first)
        #expect(gate.inFlight)
        gate.markFinished(second)
        #expect(!gate.inFlight)
    }
}


@Suite("Session deep-link session resolution")
struct SessionDeepLinkSessionResolutionTests {
    @Test func fetchServerIdsPrefersActiveThenAskOwners() {
        #expect(
            SessionDeepLinkSessionResolution.fetchServerIds(
                activeServerId: "active",
                serverIdsWithPendingAsk: ["ask-owner", "active"]
            ) == ["active", "ask-owner"]
        )
        #expect(
            SessionDeepLinkSessionResolution.fetchServerIds(
                activeServerId: nil,
                serverIdsWithPendingAsk: ["ask-owner"]
            ) == ["ask-owner"]
        )
        #expect(
            SessionDeepLinkSessionResolution.fetchServerIds(
                activeServerId: "active",
                serverIdsWithPendingAsk: []
            ) == ["active"]
        )
    }
}
