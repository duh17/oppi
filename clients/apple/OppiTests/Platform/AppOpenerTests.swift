import Foundation
import LocalAuthentication
import Testing
@testable import Oppi

/// Every entry point delivers one `AppOpenRequest` to one owner. These tests
/// drive the owner through each entry point and assert the route, the server,
/// and the parking, never which closure ran.
@Suite("AppOpener")
@MainActor
struct AppOpenerTests {
    // MARK: - Entry point → request

    @Test func localAskBannerTapCarriesItsServer() throws {
        let request = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.askCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [
                "kind": "ask",
                "askId": "ask-1",
                "sessionId": "child",
                "serverId": "server-b",
            ]
        ))

        #expect(request == .session(SessionOpen(
            serverId: "server-b",
            sessionId: "child",
            origin: .externalURL
        )))
    }

    @Test func remotePushTapCarriesItsServerAndWorkspace() throws {
        let request = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.sessionBlockedCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: [
                "event": "session.status",
                "serverId": "server-b",
                "sessionId": "child",
                "workspaceId": "workspace-b",
            ]
        ))

        #expect(request == .session(SessionOpen(
            serverId: "server-b",
            sessionId: "child",
            workspaceId: "workspace-b",
            origin: .externalURL
        )))
    }

    @Test func pairingNotificationMapsOpenApproveAndDeny() throws {
        let base = [
            "serverId": "server-a",
            "approvalId": "approval-1",
        ]
        let open = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.pairingApprovalCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: base
        ))
        let approve = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.pairingApprovalCategoryId,
            actionIdentifier: AttentionNotificationService.pairingApproveActionId,
            userInfo: base
        ))
        let deny = try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.pairingApprovalCategoryId,
            actionIdentifier: AttentionNotificationService.pairingDenyActionId,
            userInfo: base
        ))

        #expect(open == .pairing(serverId: "server-a", approvalId: "approval-1", action: .open))
        #expect(approve == .pairing(serverId: "server-a", approvalId: "approval-1", action: .approve))
        #expect(deny == .pairing(serverId: "server-a", approvalId: "approval-1", action: .deny))
        #expect(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.deviceEnrolledCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: ["serverId": "server-a"]
        ) == nil)
    }

    @Test func urlsMapToTheirOneRequest() throws {
        func request(_ raw: String) throws -> AppOpenRequest {
            AppOpenRequest(url: try #require(URL(string: raw)), origin: .externalURL)
        }

        #expect(try request("oppi://session/a%20b") == .session(SessionOpen(
            sessionId: "a b",
            origin: .externalURL
        )))
        #expect(try request("oppi://session/child?workspaceId=w1") == .session(SessionOpen(
            sessionId: "child",
            workspaceId: "w1",
            origin: .externalURL
        )))
        #expect(try request("oppi://workspace?path=/tmp/project&name=Project") == .createWorkspace(
            WorkspaceDeepLink.Payload(path: "/tmp/project", name: "Project", serverFingerprint: nil)
        ))
        #expect(try request("oppi://connect?v=3&invite=abc") == .invite(
            URL(string: "oppi://connect?v=3&invite=abc")!
        ))
        #expect(try request("https://example.com/docs") == .webLink(
            URL(string: "https://example.com/docs")!
        ))
        #expect(try request("mailto:support@example.com") == .system(
            URL(string: "mailto:support@example.com")!
        ))

        let reference = ResourceReference(
            target: "Build Notes",
            sourceServerID: "server-a",
            workspaceID: "workspace-a",
            sourceSessionID: "source",
            fileCandidatePath: "Build Notes.md"
        )
        let referenceURL = try #require(ResourceReferenceURL.make(reference))
        #expect(try request(referenceURL.absoluteString) == .resourceReference(reference))
    }

    @Test func malformedSessionURLsStayInvites() throws {
        // `oppi://session` with a nested path and a non-connect oppi link both
        // fall through to the invite route, which drops silently unless it
        // looks like a connect/pair link.
        for raw in ["oppi://session/a/b", "oppi://nonsense"] {
            let url = try #require(URL(string: raw))
            #expect(AppOpenRequest(url: url, origin: .externalURL) == .invite(url), Comment(rawValue: raw))
            #expect(!InAppInviteLink.claims(url), Comment(rawValue: raw))
        }
    }

    // MARK: - Warm and cold

    @Test func pushTapOpensTheSessionAndItsAskCard() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.setAskDialog(sessionId: "child", on: "server-a")

        harness.opener.open(try #require(AttentionNotificationService.openRequest(
            categoryIdentifier: AttentionNotificationService.askCategoryId,
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: ["sessionId": "child", "serverId": "server-a"]
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(harness.connection("server-a").focusedSessionId == "child")
        #expect(harness.connection("server-a").askRequestStore.pending(for: "child") != nil)
    }

    @Test func coldLaunchParksTheRequestUntilLaunchFinishes() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.opener._parkedRequestForTesting != nil)

        harness.opener.launchDidFinish()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    @Test func twoRequestsBeforeLaunchOpenOnlyTheLast() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("first", workspaceId: "w1", to: "server-a")
        harness.addSession("second", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "first",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "second",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.launchDidFinish()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "second")
    }

    @Test func workspaceURLAtColdLaunchOpensTheCreateFormOnItsServer() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        let url = try #require(URL(string: "oppi://workspace?path=/tmp/project&name=Project"))

        harness.opener.open(AppOpenRequest(url: url, origin: .externalURL))
        await harness.settle()
        #expect(harness.navigation.pendingWorkspaceDeepLink == nil)

        harness.opener.launchDidFinish()
        await harness.settle()

        let payload = try #require(harness.navigation.pendingWorkspaceDeepLink)
        #expect(payload.path == "/tmp/project")
        #expect(payload.name == "Project")
        #expect(payload.resolvedServerId == "server-a")
        #expect(harness.coordinator.activeServerId == "server-a")
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    // MARK: - In-app links

    @Test func timelineSessionLinkKeepsTheBackStackAndPreparesTheTarget() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("source", workspaceId: "w1", to: "server-a")
        harness.addSession("target", workspaceId: "w1", to: "server-a")
        harness.setAskDialog(sessionId: "target", on: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "w1"
        ))

        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/target")),
            origin: .inAppHyperlink,
            sourceServerID: "server-a"
        ))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.count == 2)
        harness.expectSessionRoute(serverId: "server-a", sessionId: "target")
        #expect(harness.connection("server-a").askRequestStore.pending(for: "target") != nil)
    }

    @Test func extensionSurfaceSessionLinkNavigatesLikeATimelineLink() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("source", workspaceId: "chat-workspace", to: "server-a")
        harness.addSession("target", workspaceId: "chat-workspace", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "chat-workspace"
        ))

        // A widget's `oppi://session/<id>` link from the chat carries the
        // chat's server and workspace, exactly like a timeline link.
        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/target?workspaceId=chat-workspace")),
            origin: .inAppHyperlink,
            sourceServerID: "server-a"
        ))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.count == 2)
        let route = try #require(harness.lastSessionRoute)
        #expect(route.sessionId == "target")
        #expect(route.workspaceId == "chat-workspace")
    }

    @Test func selfLinkToTheVisibleChatDoesNothing() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("source", workspaceId: "w1", to: "server-a")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "source",
            workspaceId: "w1"
        ))
        let connection = harness.connection("server-a")
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.focusSession("source")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "source",
            origin: .inAppHyperlink
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func staleInAppLinkIsDroppedInsteadOfGuessed() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("other", workspaceId: "w1", to: "server-b")
        harness.addSession("target", workspaceId: "w1", to: "server-b")

        // The source server does not have the session: do not fall back to a
        // global guess.
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "target",
            origin: .inAppHyperlink
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.coordinator.activeServerId == "server-a")
    }

    @Test func inAppLinkWithoutASourceUsesTheUniqueMatch() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("target", workspaceId: "w1", to: "server-b")

        harness.opener.open(.session(SessionOpen(
            sessionId: "target",
            origin: .inAppHyperlink
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-b", sessionId: "target")
    }

    // MARK: - Servers

    @Test func pushForAnotherServerSwitchesAndRoutesThere() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a"), makeServer("server-b")])
        harness.addSession("child", workspaceId: "workspace-b", to: "server-b")
        #expect(harness.coordinator.activeServerId == "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-b",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-b")
        harness.expectSessionRoute(serverId: "server-b", sessionId: "child")
    }

    @Test func sceneSessionURLResolvesThroughTheCachedStores() async throws {
        // A session created by the share extension is not in memory until the
        // app asks its server for it.
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.coordinator._getSessionRecordForTesting = { _, id in
            makeTestSession(id: id, workspaceId: "w1", status: .busy)
        }

        harness.opener.open(AppOpenRequest(
            url: try #require(URL(string: "oppi://session/shared-session")),
            origin: .externalURL
        ))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "shared-session")
    }

    @Test func unknownServerShowsAToastAndDropsTheRequest() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])

        harness.opener.open(.session(SessionOpen(
            serverId: "unpaired-server",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.connection("server-a").extensionToast == "Server not found for this session link")
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    @Test func unreachableServerKeepsTheRequestAndRetriesOnTheNextForeground() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        #expect(harness.connection("server-a").extensionToast == "Could not reach server-a")
        #expect(harness.opener._parkedRequestForTesting != nil)

        // Still down: one more foreground attempt, still parked.
        harness.opener.sceneDidBecomeActive()
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        harness.unreachableServers = []
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    @Test func aNewerRequestReplacesTheParkedOne() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("first", workspaceId: "w1", to: "server-a")
        harness.addSession("second", workspaceId: "w1", to: "server-a")
        harness.unreachableServers = ["server-a"]

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "first",
            origin: .externalURL
        )))
        await harness.settle()
        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "second",
            origin: .externalURL
        )))
        await harness.settle()

        harness.unreachableServers = []
        harness.opener.sceneDidBecomeActive()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "second")
    }

    // MARK: - App Lock and scoped locks

    @Test(arguments: [
        AppLockUnlockOutcome.success,
        AppLockUnlockOutcome.cancelled,
        AppLockUnlockOutcome.backgrounded,
    ])
    func lockedOpenWaitsForUnlock(_ outcome: AppLockUnlockOutcome) async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately,
            authOutcomes: outcome == .success ? [.success] : [.cancelled]
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        switch outcome {
        case .success:
            #expect(await harness.appLock.unlock())
            await harness.settle()
            harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
        case .cancelled:
            #expect(!(await harness.appLock.unlock()))
            await harness.settle()
            #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        case .backgrounded:
            harness.appLock.appDidEnterBackground()
            await harness.settle()
            #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
        }
    }

    @Test func aLockedOpenNeverPairsOrNavigatesBehindTheCover() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a")],
            appLockTimeout: .immediately
        )
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        harness.opener.open(.webLink(try #require(URL(string: "https://example.com/docs"))))
        await harness.settle()

        #expect(harness.recorder.browserURLs.isEmpty)
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func cancelledScopedUnlockLeavesServerAndRouteAlone() async throws {
        let harness = OpenerHarness(
            servers: [makeServer("server-a"), makeServer("server-b")],
            authOutcomes: [.cancelled]
        )
        harness.addSession("current", workspaceId: "w1", to: "server-a")
        harness.addSession("locked", workspaceId: "w2", to: "server-b")
        harness.navigation.openWorkspaceSession(.init(
            serverId: "server-a",
            sessionId: "current",
            workspaceId: "w1"
        ))
        harness.scopedLock.lock(.session(serverId: "server-b", sessionId: "locked"), workspaceId: "w2")

        harness.opener.open(.session(SessionOpen(
            serverId: "server-b",
            sessionId: "locked",
            origin: .externalURL
        )))
        await harness.settle()

        #expect(harness.coordinator.activeServerId == "server-a")
        harness.expectSessionRoute(serverId: "server-a", sessionId: "current")
        #expect(harness.opener._parkedRequestForTesting == nil)
    }

    // MARK: - Invites

    @Test func inviteRunsDuringLaunchWithoutWaiting() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        let url = try #require(URL(string: "oppi://connect?v=3&invite=bogus"))

        harness.opener.open(.invite(url))
        await harness.settle()

        #expect(harness.connection("server-a").extensionToast == "Unsupported invite link format")
    }

    @Test func sessionRequestDuringInviteBootstrapOpensAfterItFinishes() async throws {
        // The invite holds the app; a session tap that arrives then must not be
        // lost. This is the regression for the one-shot launch consume.
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        harness.addSession("child", workspaceId: "w1", to: "server-a")

        let attempt = harness.opener.invitePairingGate.beginIncoming()
        harness.opener.invitePairingGate.markStarted(attempt)

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "child",
            origin: .externalURL
        )))
        await harness.settle()
        #expect(harness.navigation.workspaceStackRouteElements.isEmpty)

        harness.opener.invitePairingGate.markFinished(attempt)
        harness.opener.drainParkedIfPossible()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "child")
    }

    // MARK: - Siri and Quick Session

    @Test func siriReceiptOpensWithTheCreatedRowAndDraft() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        let receipt = IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: "Write the release notes",
            session: makeTestSession(id: "created", workspaceId: "w1", status: .busy)
        )
        harness.intentTrigger.enqueue(receipt)

        harness.opener.open(.session(SessionOpen(
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            origin: .externalURL,
            startedSessionRequestID: receipt.requestID
        )))
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "created")
        #expect(harness.connection("server-a").sessionStore.session(id: "created") != nil)
        let key = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "w1",
            sessionID: "created"
        ))
        #expect(harness.composerDraftStore.record(for: key)?.payload.text == "Write the release notes")
        #expect(harness.intentTrigger.peek() == nil)
    }

    @Test func leftoverSiriReceiptOpensAtLaunch() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.addSession("created", workspaceId: "w1", to: "server-a")
        harness.intentTrigger.enqueue(IntentSessionOpenTrigger.Receipt(
            requestID: harness.intentTrigger.issueRequestID(),
            serverId: "server-a",
            sessionId: "created",
            workspaceId: "w1",
            unsentPrompt: nil,
            session: nil
        ))

        harness.opener.launchDidFinish()
        await harness.settle()

        harness.expectSessionRoute(serverId: "server-a", sessionId: "created")
    }

    @Test func quickSessionWaitsForLaunchAndDropsWhenOneIsShowing() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")], launch: false)
        harness.navigation.launchPhase = .ready
        harness.navigation.showOnboarding = false

        harness.opener.open(.quickSession(QuickSessionStart(mode: .dictation)))
        await harness.settle()
        #expect(!harness.navigation.showQuickSession)

        harness.opener.launchDidFinish()
        await harness.settle()
        #expect(harness.navigation.showQuickSession)
        #expect(harness.navigation.pendingQuickSessionStart?.mode == .dictation)

        // A second request while the sheet is up is dropped, never queued.
        harness.opener.open(.quickSession(QuickSessionStart(mode: .liveVoice)))
        await harness.settle()
        #expect(harness.navigation.pendingQuickSessionStart?.mode == .dictation)
    }

    // MARK: - Web and system links

    @Test func webLinkFollowsTheBrowserPreference() async throws {
        let harness = OpenerHarness(servers: [makeServer("server-a")])
        let url = try #require(URL(string: "https://example.com/docs"))

        harness.opener._browserLinkPreferenceForTesting = .inApp
        harness.opener.open(.webLink(url))
        await harness.settle()

        harness.opener._browserLinkPreferenceForTesting = .external
        harness.opener.open(.webLink(url))
        await harness.settle()

        #expect(harness.recorder.browserURLs == [url])
        #expect(harness.recorder.systemURLs == [url])
    }

    @Test func webLinkAndSystemLinkNeverWaitForLaunch() async throws {
        let harness = OpenerHarness(servers: [], launch: false)
        let web = try #require(URL(string: "https://example.com/docs"))
        let mail = try #require(URL(string: "mailto:support@example.com"))
        harness.opener._browserLinkPreferenceForTesting = .external

        harness.opener.open(.webLink(web))
        await harness.settle()
        harness.opener.open(.system(mail))
        await harness.settle()

        #expect(harness.recorder.systemURLs == [web, mail])
        #expect(harness.opener._parkedRequestForTesting == nil)
    }
}

enum AppLockUnlockOutcome: String, Sendable, CaseIterable {
    case success
    case cancelled
    case backgrounded
}

// MARK: - Fixture

@MainActor
private final class LinkRecorder {
    var browserURLs: [URL] = []
    var systemURLs: [URL] = []
}

@MainActor
private final class StubAuthenticator {
    private var outcomes: [DeviceOwnerAuthentication.Outcome]

    init(outcomes: [DeviceOwnerAuthentication.Outcome]) {
        self.outcomes = outcomes
    }

    func authenticate() -> DeviceOwnerAuthentication.Outcome {
        outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }
}

@MainActor
private final class OpenerHarness {
    let serverStore = ServerStore()
    let coordinator: ConnectionCoordinator
    let navigation = AppNavigation()
    let composerDraftStore: ComposerDraftStore
    let appLock: AppLockService
    let scopedLock: ScopedLockService
    let intentTrigger: IntentSessionOpenTrigger
    let recorder: LinkRecorder
    let opener: AppOpener
    var unreachableServers: Set<String> = []
    private var connections: [String: ServerConnection] = [:]

    init(
        servers: [PairedServer],
        appLockTimeout: AppLockTimeout = .off,
        authOutcomes: [DeviceOwnerAuthentication.Outcome] = [.success],
        launch: Bool = true
    ) {
        let recorder = LinkRecorder()
        self.recorder = recorder
        let lockDefaults = UserDefaults(suiteName: "AppOpenerTests-lock-\(UUID().uuidString)")!
        AppLockSettings.setTimeout(appLockTimeout, in: lockDefaults)
        let authenticator = StubAuthenticator(outcomes: authOutcomes)
        let appLock = AppLockService(
            defaults: lockDefaults,
            monotonicNow: { 10_000 },
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in authenticator.authenticate() },
            didTurnOn: {}
        )
        self.appLock = appLock
        let scopedDefaults = UserDefaults(suiteName: "AppOpenerTests-scoped-\(UUID().uuidString)")!
        scopedLock = ScopedLockService(defaults: scopedDefaults, appLock: appLock, didLock: { _ in })

        // The Keychain may hold servers other suites paired; this fixture's
        // list lives only in memory.
        serverStore.replaceServersForPreview(servers)
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        self.coordinator = coordinator
        composerDraftStore = ComposerDraftStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "AppOpenerTests-drafts-\(UUID().uuidString).json"),
            saveDelay: .seconds(60)
        )
        intentTrigger = IntentSessionOpenTrigger(
            defaults: UserDefaults(suiteName: "AppOpenerTests-intent-\(UUID().uuidString)")!,
            promptFileURL: FileManager.default.temporaryDirectory
                .appending(path: "AppOpenerTests-prompt-\(UUID().uuidString).json")
        )

        let opener = AppOpener(
            coordinator: coordinator,
            navigation: navigation,
            composerDraftStore: composerDraftStore,
            appLock: appLock,
            scopedLock: scopedLock,
            intentSessionOpenTrigger: intentTrigger,
            browserPresent: { recorder.browserURLs.append($0) },
            systemOpen: { recorder.systemURLs.append($0) }
        )
        self.opener = opener
        if !servers.isEmpty {
            installConnection(for: servers[0].id, activate: true)
        }
        if launch {
            opener.launchDidFinish()
        }
        opener._serverReadyForTesting = { [weak self] serverId in
            guard let self else { return false }
            guard !self.unreachableServers.contains(serverId) else { return false }
            guard self.serverStore.server(for: serverId) != nil else { return false }
            self.installConnection(for: serverId, activate: true)
            return true
        }
    }

    func connection(_ serverId: String) -> ServerConnection {
        installConnection(for: serverId)
    }

    func addSession(_ sessionId: String, workspaceId: String, to serverId: String) {
        connection(serverId).sessionStore.upsert(makeTestSession(
            id: sessionId,
            workspaceId: workspaceId,
            status: .busy
        ))
    }

    func setAskDialog(sessionId: String, on serverId: String) {
        let connection = connection(serverId)
        connection._getSessionDialogsForTesting = { _ in
            APIClient.SessionDialogsResponse(
                dialogs: [
                    ExtensionUIRequest.DialogSnapshot(
                        id: "ask-\(sessionId)",
                        method: "ask",
                        questions: [
                            AskQuestion(id: "q1", question: "Answer me", options: [], multiSelect: false),
                        ],
                        allowCustom: true
                    ),
                ],
                serverNow: 1
            )
        }
    }

    var lastSessionRoute: WorkspaceSessionNavTarget? {
        guard case .session(let target)? = navigation.workspaceStackRouteElements.last else {
            return nil
        }
        return target
    }

    func expectSessionRoute(
        serverId: String,
        sessionId: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let route = lastSessionRoute
        #expect(route?.serverId == serverId, sourceLocation: sourceLocation)
        #expect(route?.sessionId == sessionId, sourceLocation: sourceLocation)
    }

    func settle() async {
        await opener._waitForOpenToSettleForTesting()
        await opener.invitePairingTask?.value
    }

    /// Seeds the fixture connection. Seeding never changes the active server:
    /// only a successful switch (or the first paired server) does.
    @discardableResult
    private func installConnection(
        for serverId: String,
        activate: Bool = false
    ) -> ServerConnection {
        let connection: ServerConnection
        if let existing = connections[serverId] {
            connection = existing
        } else {
            connection = ServerConnection()
            if let server = serverStore.server(for: serverId) {
                connection.configure(credentials: server.credentials)
            }
            connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
            // Prefetch must not overwrite the row a test seeded with its own
            // workspace; it re-upserts whatever the store already holds.
            connection._getSessionTraceForTesting = { [weak connection] id in
                let stored = connection?.sessionStore.session(id: id)
                return (stored ?? makeTestSession(id: id, workspaceId: "w1", status: .busy), [])
            }
            connections[serverId] = connection
        }
        // Every fixture is reachable to lookups; seeding never changes which
        // one is active.
        let active = coordinator.activeServerId
        coordinator.installPreviewConnection(connection, serverId: serverId)
        if !activate, let active, active != serverId, let activeConnection = connections[active] {
            coordinator.installPreviewConnection(activeConnection, serverId: active)
        }
        return connection
    }
}

private func makeServer(_ id: String) -> PairedServer {
    let credentials = ServerCredentials(
        host: "\(id).test",
        port: 7749,
        token: "sk_test",
        name: id,
        scheme: .https,
        serverFingerprint: id
    )
    guard let server = PairedServer(from: credentials, sortOrder: 0) else {
        preconditionFailure("Failed to create PairedServer for test")
    }
    return server
}
