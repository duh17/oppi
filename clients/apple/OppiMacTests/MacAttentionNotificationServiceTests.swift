import Foundation
import Testing
@testable import Oppi

@Suite("Mac attention notification service")
@MainActor
struct MacAttentionNotificationServiceTests {
    @Test func postsAskWhenAppIsNotKeyEvenForActiveSession() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = false
        service.activeSessionId = "s1"

        service.notifyAskIfNeeded(makeAsk(sessionId: "s1"))

        #expect(service._lastScheduledPayloadForTesting?.identifier == "ask-s1")
        #expect(
            service._lastScheduledPayloadForTesting?.categoryIdentifier
                == AttentionNotificationPolicy.askCategoryId
        )
        #expect(service._lastScheduledPayloadForTesting?.body == "Need a choice?")
    }

    @Test func postsAskWhenKeyForAnotherSession() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = true
        service.activeSessionId = "visible"

        service.notifyAskIfNeeded(makeAsk(sessionId: "background"))

        #expect(service._lastScheduledPayloadForTesting?.identifier == "ask-background")
        #expect(service._lastScheduledPayloadForTesting?.userInfo["sessionId"] == "background")
    }

    @Test func doesNotPostAskWhenKeyForActiveSession() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = true
        service.activeSessionId = "s1"

        service.notifyAskIfNeeded(makeAsk(sessionId: "s1"))

        #expect(service._lastScheduledPayloadForTesting == nil)
    }

    @Test func skipsReplayOfTheSameAsk() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = false

        let ask = makeAsk(sessionId: "s1", id: "ask-1")
        service.notifyAskIfNeeded(ask)
        service._lastScheduledPayloadForTesting = nil
        service.notifyAskIfNeeded(ask)

        #expect(service._lastScheduledPayloadForTesting == nil)
    }

    @Test func doesNotBannerReplayAfterForegroundSuppression() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = true
        service.activeSessionId = "s1"

        let ask = makeAsk(sessionId: "s1", id: "ask-1")
        service.notifyAskIfNeeded(ask)
        #expect(service._lastScheduledPayloadForTesting == nil)

        service._isAppActiveForTesting = false
        service.notifyAskIfNeeded(ask)
        #expect(service._lastScheduledPayloadForTesting == nil)
    }

    @Test func tapBeforeNavigationHandlerIsDeliveredOnceWhenWired() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        var deliveredSessionIds: [String] = []

        service.handleNotificationTap(sessionId: "ask-session")
        #expect(deliveredSessionIds.isEmpty)

        service.onNavigateToSession = { deliveredSessionIds.append($0) }
        #expect(deliveredSessionIds == ["ask-session"])

        service.onNavigateToSession = { deliveredSessionIds.append($0) }
        #expect(deliveredSessionIds == ["ask-session"])
        service.resetForTesting()
    }

    @Test func tapOpensMainWindowThenExistingSessionDeepLink() throws {
        var pending: URL?
        var opened: [String] = []
        var activated = 0

        MacAttentionBannerNavigation.perform(
            sessionId: "ask-session",
            setPendingURL: { pending = $0 },
            openWindow: { opened.append($0) },
            activateApp: { activated += 1 }
        )

        #expect(opened == [MacAttentionBannerNavigation.mainWindowId])
        let url = try #require(pending)
        #expect(MacSessionDeepLink.sessionId(from: url) == "ask-session")
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: MacSessionDeepLink.sessionId(from: url),
                knownSessionIDs: ["ask-session"],
                catalogReady: true
            ) == .selectSession("ask-session")
        )
        #expect(activated == 1)
    }

    @Test func notificationTapOpensMainWindowThenSessionDeepLink() throws {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        var pending: URL?
        var opened: [String] = []

        service.onNavigateToSession = { sessionId in
            MacAttentionBannerNavigation.perform(
                sessionId: sessionId,
                setPendingURL: { pending = $0 },
                openWindow: { opened.append($0) },
                activateApp: {}
            )
        }
        service.handleNotificationTap(sessionId: "ask-session")

        #expect(opened == ["main"])
        let url = try #require(pending)
        #expect(MacSessionDeepLink.sessionId(from: url) == "ask-session")
    }

    @Test func emptySessionIdDoesNotOpenWindowOrSetDeepLink() {
        var pending: URL? = URL(string: "https://example.com")
        var opened: [String] = []

        MacAttentionBannerNavigation.perform(
            sessionId: "",
            setPendingURL: { pending = $0 },
            openWindow: { opened.append($0) },
            activateApp: {}
        )

        #expect(opened.isEmpty)
        #expect(pending == URL(string: "https://example.com"))
    }

    @Test func visibleSessionIsTheHomeSelectionOnThePresentedWindow() {
        #expect(
            MacAttentionVisibleSession.id(
                section: .sessionHome,
                selectedSessionID: "s1",
                isMainWindowPresented: true
            ) == "s1"
        )
        #expect(
            MacAttentionVisibleSession.id(
                section: .sessionHome,
                selectedSessionID: nil,
                isMainWindowPresented: true
            ) == nil
        )
    }

    @Test(
        arguments: [
            MacSidebarSection.settings,
            .workspaces,
            .agents,
            .schedules,
            .skills,
            .extensions,
        ]
    )
    func leavingHomeClearsVisibleSession(section: MacSidebarSection) {
        #expect(
            MacAttentionVisibleSession.id(
                section: section,
                selectedSessionID: "s1",
                isMainWindowPresented: true
            ) == nil
        )
    }

    @Test func tearingDownMainWindowClearsVisibleSession() {
        #expect(
            MacAttentionVisibleSession.id(
                section: .sessionHome,
                selectedSessionID: "s1",
                isMainWindowPresented: false
            ) == nil
        )
    }

    @Test func keyAppBannersAskAfterLeavingTheVisibleSession() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = true
        service.activeSessionId = MacAttentionVisibleSession.id(
            section: .sessionHome,
            selectedSessionID: "s1",
            isMainWindowPresented: true
        )
        #expect(service.activeSessionId == "s1")
        #expect(
            !AttentionNotificationPolicy.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: service.activeSessionId
            )
        )

        service.activeSessionId = MacAttentionVisibleSession.id(
            section: .settings,
            selectedSessionID: "s1",
            isMainWindowPresented: true
        )
        #expect(service.activeSessionId == nil)

        service.notifyAskIfNeeded(makeAsk(sessionId: "s1"))
        #expect(service._lastScheduledPayloadForTesting?.identifier == "ask-s1")
    }

    @Test func keyMenuBarSuppressesNothingAfterWindowTeardown() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = true
        service.activeSessionId = MacAttentionVisibleSession.id(
            section: .sessionHome,
            selectedSessionID: "s1",
            isMainWindowPresented: true
        )
        #expect(service.activeSessionId == "s1")

        service.activeSessionId = MacAttentionVisibleSession.id(
            section: .sessionHome,
            selectedSessionID: "s1",
            isMainWindowPresented: false
        )
        #expect(service.activeSessionId == nil)

        service.notifyAskIfNeeded(makeAsk(sessionId: "s1"))
        #expect(service._lastScheduledPayloadForTesting?.identifier == "ask-s1")
    }

    @Test func macPainterPostsAskBannersOnly() throws {
        let source = try macSource("OppiMac/App/MacAttentionNotificationService.swift")
        #expect(source.contains("notifyAskIfNeeded"))
        #expect(source.contains("UNUserNotificationCenter"))
        #expect(!source.contains("notifySessionDone"))
        #expect(!source.contains("notifySessionError"))
        #expect(!source.contains("UIApplication"))
        #expect(!source.contains("UIKit"))
    }

    private func makeAsk(sessionId: String, id: String = "ask-1") -> AskRequest {
        AskRequest(
            id: id,
            sessionId: sessionId,
            questions: [
                AskQuestion(id: "q1", question: "Need a choice?", options: [], multiSelect: false),
            ],
            allowCustom: true,
            timeout: nil
        )
    }

    private func macSource(_ relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
