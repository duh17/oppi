import SwiftUI
import Testing
@testable import Oppi

// Serialized: the observer tests post process-wide notifications.
@Suite("Workspace media overlay navigation", .serialized)
@MainActor
struct WorkspaceMediaOverlayNavigationTests {
    @Test func overlayDepthRefcountsAndClears() {
        #expect(WorkspaceMediaOverlayNavigationPolicy.overlayDepth(after: .begin, current: 0) == 1)
        #expect(WorkspaceMediaOverlayNavigationPolicy.overlayDepth(after: .begin, current: 1) == 2)
        #expect(WorkspaceMediaOverlayNavigationPolicy.overlayDepth(after: .end, current: 2) == 1)
        #expect(WorkspaceMediaOverlayNavigationPolicy.overlayDepth(after: .end, current: 1) == 0)
        #expect(WorkspaceMediaOverlayNavigationPolicy.overlayDepth(after: .end, current: 0) == 0)
        #expect(WorkspaceMediaOverlayNavigationPolicy.isOverlayActive(depth: 1))
        #expect(!WorkspaceMediaOverlayNavigationPolicy.isOverlayActive(depth: 0))
    }

    @Test func cancelledDismissalKeepsOverlay() {
        #expect(!WorkspaceMediaOverlayNavigationPolicy.shouldEndOverlay(cancelled: true))
        #expect(WorkspaceMediaOverlayNavigationPolicy.shouldEndOverlay(cancelled: false))
    }

    @Test func cancelledFullscreenHandoffKeepsOverlayUntilCommit() {
        var finished = 0
        var didEnd = 0
        let handoff = FullScreenEndHandoff(
            onDidEnd: { _ in didEnd += 1 },
            onTransitionFinished: { finished += 1 }
        )

        handoff.complete(
            cancelled: true,
            player: nil,
            isPlayingNow: false,
            hostIsAttached: true
        )
        #expect(finished == 0)
        #expect(didEnd == 0)

        handoff.complete(
            cancelled: false,
            player: nil,
            isPlayingNow: false,
            hostIsAttached: true
        )
        #expect(finished == 1)
        #expect(didEnd == 1)
    }

    @Test func overlayCatchUpAppliesMeasuredPresentationAfterUnfreeze() {
        let navigation = readyNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1",
                workspaceId: "ws-b"
            )))
        navigation.beginMediaOverlay(activeServerId: "server-b")
        #expect(navigation.workspaceNavigationPresentation == .stack)

        navigation.endMediaOverlay(currentServerId: "server-b")
        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspaceNavigationPresentation == .split)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true).last == .session(
            WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1",
                workspaceId: "ws-b"
            )
        ))
    }

    @Test func overlayRestoresALostRouteAndForeignServer() {
        #expect(
            WorkspaceMediaOverlayNavigationPolicy.shouldRestoreRoute(
                overlayActive: true,
                snapshotPathCount: 1,
                currentPathCount: 0
            )
        )
        #expect(
            !WorkspaceMediaOverlayNavigationPolicy.shouldRestoreRoute(
                overlayActive: false,
                snapshotPathCount: 1,
                currentPathCount: 0
            )
        )
        #expect(
            WorkspaceMediaOverlayNavigationPolicy.shouldRestoreServer(
                snapshotServerId: "server-b",
                currentServerId: "server-a"
            )
        )
        #expect(
            !WorkspaceMediaOverlayNavigationPolicy.shouldRestoreServer(
                snapshotServerId: "server-b",
                currentServerId: "server-b"
            )
        )
        #expect(
            !WorkspaceMediaOverlayNavigationPolicy.shouldRestoreServer(
                snapshotServerId: nil,
                currentServerId: "server-a"
            )
        )
    }

    @Test func fullscreenOverlayRestoresChatIfTheStackIsCleared() {
        let navigation = readyNavigation()
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.open(.chat(session))
        #expect(navigation.workspaceStackRouteElements.count == 1)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.open(.place(.allSessions), from: .external)

        #expect(navigation.isMediaOverlayActive)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")

        let restoreServer = navigation.endMediaOverlay(currentServerId: "server-a")
        #expect(restoreServer == "server-b")
        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")
    }

    @Test func overlayAfterAllSessionsSessionDoesNotInsertWorkspaceLayer() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.open(.chat(session), from: .screen(workspace: workspace))
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.currentPlace == .allSessions)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.open(.place(.allSessions), from: .external)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.currentPlace == .allSessions)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")

        #expect(navigation.endMediaOverlay(currentServerId: "server-a") == "server-b")
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.currentPlace == .allSessions)
    }

    @Test func overlayAfterSplitAllSessionsSessionDoesNotInsertWorkspaceLayer() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.open(.chat(session), from: .screen(workspace: workspace))

        #expect(navigation.currentPlace == .allSessions)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox, .session(session)])

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.mainPaneRoute = PaneStack(place: .sessions(workspace))

        let restoreServer = navigation.endMediaOverlay(currentServerId: "server-a")
        #expect(restoreServer == "server-b")
        #expect(navigation.currentPlace == .allSessions)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox, .session(session)])
    }

    @Test func overlayRestoresLostVisitedWorkspaceChatRoute() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.open(.place(.sessions(workspace)))
        navigation.open(.chat(session), from: .screen(workspace: workspace))
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.currentPlace == .sessions(workspace))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.open(.place(.allSessions), from: .external)

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.currentPlace == .sessions(workspace))
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.currentPlace == .sessions(workspace))
    }

    @Test func fullscreenOverlayIgnoresStackSplitFlips() {
        let navigation = readyNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1",
                workspaceId: "ws-b"
            )))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspaceNavigationPresentation == .stack)
        #expect(navigation.workspaceStackRouteElements.count == 1)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.workspaceNavigationPresentation == .stack)
        #expect(navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func nestedOverlayEndsWaitForMatchingBegins() {
        let navigation = readyNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1"
            )))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.open(.place(.allSessions), from: .external)
        #expect(navigation.workspaceStackRouteElements.count == 1)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.isMediaOverlayActive)

        navigation.open(.place(.allSessions), from: .external)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(!navigation.isMediaOverlayActive)
    }

    @Test func overlayDoesNotTrapLaterUserPops() {
        let navigation = readyNavigation()
        navigation.open(.chat(WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1"
            )))
        navigation.beginMediaOverlay(activeServerId: "server-b")
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)

        navigation.popShownStack(toDepth: 0)
        #expect(navigation.workspaceStackRouteElements.isEmpty)
        #expect(navigation.workspaceStackDiagnosticContext == .inboxAll)
    }

    @Test func userBackDuringFullscreenEndsTheOverlayAndStands() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.open(.place(.sessions(workspace)))
        navigation.open(.chat(session), from: .screen(workspace: workspace))
        #expect(navigation.workspaceStackRouteElements.count == 2)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // Back pops the chat before AVKit's end callback arrives.
        navigation.popShownStack(toDepth: 1)

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "workspace_inbox_filtered")
        #expect(!navigation.isMediaOverlayActive)

        // A late end must not push the chat back under the workspace list.
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == nil)
    }

    @Test func userBackFromSplitChatDuringFullscreenEndsTheOverlayAndStands() {
        let navigation = readyNavigation()
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.open(.chat(session))
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox, .session(session)])

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // The chat's Back pops it off its list.
        navigation.popShownStack(toDepth: 0)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox])
        #expect(!navigation.isMediaOverlayActive)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox])
    }

    @Test func ipadSidebarWorkspaceOpenDuringFullscreenEndsTheOverlayAndStands() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.open(.place(.sessions(workspace)))
        navigation.open(.chat(session), from: .screen(workspace: workspace))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // Opening a workspace from the sidebar is the person's navigation.
        navigation.open(.place(.sessions(workspace)))

        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.workspace(workspace)])
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.workspace(workspace)])
    }

    @Test func ipadAllSessionsDuringFullscreenEndsTheOverlayAndStands() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let session = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.open(.place(.sessions(workspace)))
        navigation.open(.chat(session), from: .screen(workspace: workspace))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // All Sessions from the drawer or the server switcher.
        navigation.open(.place(.allSessions))

        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox])
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.inbox])
    }

    @Test func ipadInboxSessionOpenDuringFullscreenEndsTheOverlayAndStands() {
        let navigation = readyNavigation()
        let workspace = WorkspaceNavTarget(
            serverId: "server-b",
            workspace: makeTestWorkspace(id: "ws-b")
        )
        let first = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        let second = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-2",
            workspaceId: "ws-b"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.open(.place(.sessions(workspace)))
        navigation.open(.chat(first), from: .screen(workspace: workspace))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // Opening another session from the list replaces the chat over it.
        navigation.open(.chat(second), from: .screen(workspace: workspace))

        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.workspace(workspace), .session(second)])
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true) == [.workspace(workspace), .session(second)])
    }

    @Test func anotherServersChatDuringFullscreenKeepsItsServerAfterTheLateEnd() {
        let navigation = readyNavigation()
        let chat = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        let otherServerChat = WorkspaceSessionNavTarget(
            serverId: "server-a",
            sessionId: "chat-a",
            workspaceId: "ws-a"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.open(.chat(chat))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // The sidebar opens a chat on another server, and the shell switches
        // to that server, before AVKit's end arrives.
        navigation.open(.chat(otherServerChat))
        #expect(!navigation.isMediaOverlayActive)

        // The late end must not put server-b back under server-a's chat.
        #expect(navigation.endMediaOverlay(currentServerId: "server-a") == nil)
        #expect(navigation.mainPaneRoute.shellRoutes(split: true).last == .session(otherServerChat))
    }

    // MARK: The app root's observer

    private func makeRoot(serverNames: [String]) throws -> (root: AppRootEnvironment, servers: [PairedServer]) {
        let servers = try serverNames.map { name in
            try #require(PairedServer(from: ServerCredentials(
                host: "\(name).overlay.test",
                port: 7749,
                token: "sk_test",
                name: name,
                scheme: .https,
                serverFingerprint: "sha256:overlay-\(name)",
                tlsCertFingerprint: "sha256:overlay-\(name)-leaf"
            )))
        }
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview(servers)
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        #expect(coordinator.restoreActiveServer(servers[0].id))
        let root = makeTestAppRoot(coordinator: coordinator)
        root.navigation.app.launchPhase = .ready
        root.navigation.app.showOnboarding = false
        return (root, servers)
    }

    @Test func fullscreenNotificationsFreezeAndReleaseTheRootNavigation() async throws {
        let (root, servers) = try makeRoot(serverNames: ["alpha"])
        let observer = WorkspaceMediaOverlayObserver(root: root)
        // The observer lives for the whole body, whatever the build's codegen does with `observer`
        // (`withExtendedLifetime` has no async form, so the scope's end holds it).
        defer { withExtendedLifetime(observer) {} }

        WorkspaceMediaOverlayPost.begin()
        #expect(await waitForMainActorCondition { root.navigation.isMediaOverlayActive })

        WorkspaceMediaOverlayPost.end()
        #expect(await waitForMainActorCondition { !root.navigation.isMediaOverlayActive })
        #expect(root.coordinator.activeServerId == servers[0].id)
    }

    @Test func fullscreenEndBringsBackTheServerTheOverlayBegan() async throws {
        let (root, servers) = try makeRoot(serverNames: ["alpha", "beta"])
        let observer = WorkspaceMediaOverlayObserver(root: root)
        defer { withExtendedLifetime(observer) {} }

        WorkspaceMediaOverlayPost.begin()
        #expect(await waitForMainActorCondition { root.navigation.isMediaOverlayActive })
        // Something switched the active server while AVKit covered the app.
        #expect(root.coordinator.restoreActiveServer(servers[1].id))
        #expect(root.coordinator.activeServerId == servers[1].id)

        WorkspaceMediaOverlayPost.end()
        #expect(await waitForMainActorCondition { root.coordinator.activeServerId == servers[0].id })
        #expect(!root.navigation.isMediaOverlayActive)
    }

    @Test func aReleasedObserverIgnoresFullscreen() async throws {
        let (root, _) = try makeRoot(serverNames: ["alpha"])
        var observer: WorkspaceMediaOverlayObserver? = WorkspaceMediaOverlayObserver(root: root)
        withExtendedLifetime(observer) {}
        observer = nil

        WorkspaceMediaOverlayPost.begin()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { !root.navigation.isMediaOverlayActive })
    }

    private func readyNavigation() -> SceneNavigation {
        let navigation = SceneNavigation()
        navigation.app.launchPhase = .ready
        navigation.app.showOnboarding = false
        return navigation
    }
}
