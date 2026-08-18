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

    @Test func navigationSessionIdReadsAskAndRemoteSessionPayloads() {
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.askCategoryId,
                userInfo: ["sessionId": "ask-session"]
            ) == "ask-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.sessionDoneCategoryId,
                userInfo: ["sessionId": "ended-session"]
            ) == "ended-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.sessionErrorCategoryId,
                userInfo: ["sessionId": "error-session"]
            ) == "error-session"
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

@Suite("Session notification open path")
@MainActor
struct SessionNotificationOpenPathTests {
    @Test func tapOpensBusySessionWithStreamJSONAskAndRoute() async throws {
        let sessionId = AttentionNotificationService.navigationSessionId(
            categoryIdentifier: AttentionNotificationService.askCategoryId,
            userInfo: ["sessionId": "child"]
        )
        let openedSessionId = try #require(sessionId)

        let (connection, _) = makeTestConnection(sessionId: "parent")
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(
            makeTestSession(id: "parent", workspaceId: "w1", status: .busy)
        )
        connection.sessionStore.upsert(
            makeTestSession(id: openedSessionId, workspaceId: "w1", status: .stopped)
        )

        var streamConnects = 0
        connection._connectStreamForTesting = {
            streamConnects += 1
            return AsyncStream { _ in }
        }
        connection._getSessionRecordForTesting = { id in
            makeTestSession(id: id, workspaceId: "w1", name: "Child", status: .busy)
        }
        connection._getSessionDialogsForTesting = { _ in
            APIClient.SessionDialogsResponse(
                dialogs: [
                    ExtensionUIRequest.DialogSnapshot(
                        id: "ask-live",
                        method: "ask",
                        questions: [
                            AskQuestion(
                                id: "q1",
                                question: "Answer me",
                                options: [],
                                multiSelect: false
                            ),
                        ],
                        allowCustom: true
                    ),
                ],
                serverNow: 1
            )
        }

        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.openWorkspaceSession(.init(
            serverId: "server-1",
            sessionId: "parent",
            workspaceId: "w1"
        ))

        await SessionNotificationOpen.openResolved(
            sessionId: openedSessionId,
            serverId: "server-1",
            connection: connection,
            navigation: navigation,
            source: .externalURL
        )

        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "child")
        #expect(navigation.workspacePath.count == 1)
        #expect(connection.focusedSessionId == "child")
        #expect(connection.sessionStore.session(id: "child")?.status == .busy)
        #expect(connection.focusedSessionStreamURLForTesting?.path == "/workspaces/w1/sessions/child/stream")
        #expect(streamConnects == 1)
        #expect(ChatView.resolvedComposerAskRequest(
            connection.askRequestStore.pending(for: "child"),
            hasReviewComment: false
        )?.id == "ask-live")

        connection.disconnectStream()
    }
}
