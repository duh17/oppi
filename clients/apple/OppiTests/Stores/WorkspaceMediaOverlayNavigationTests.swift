import SwiftUI
import Testing
@testable import Oppi

@Suite("Workspace media overlay navigation")
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
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1",
                workspaceId: "ws-b"
            )
        )
        navigation.beginMediaOverlay(activeServerId: "server-b")
        #expect(navigation.workspaceNavigationPresentation == .stack)

        navigation.endMediaOverlay(currentServerId: "server-b")
        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspaceNavigationPresentation == .split)
        #expect(navigation.splitDetailTarget == .session(
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
        navigation.openWorkspaceSession(session)
        #expect(navigation.workspaceStackRouteElements.count == 1)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.clearWorkspaceSelections()

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
        navigation.openWorkspaceSession(session, workspace: workspace)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == nil)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.selectedWorkspaceFilter = workspace
        navigation.clearWorkspaceSelections()

        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")

        #expect(navigation.endMediaOverlay(currentServerId: "server-a") == "server-b")
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitSelectedWorkspace == nil)
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
        navigation.openWorkspaceSession(session, workspace: workspace)

        #expect(navigation.splitSelectedWorkspace == nil)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitDetailTarget == .session(session))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.splitSelectedWorkspace = workspace
        navigation.selectedWorkspaceFilter = workspace
        navigation.splitDetailTarget = nil

        let restoreServer = navigation.endMediaOverlay(currentServerId: "server-a")
        #expect(restoreServer == "server-b")
        #expect(navigation.splitSelectedWorkspace == nil)
        #expect(navigation.selectedWorkspaceFilter == nil)
        #expect(navigation.splitDetailTarget == .session(session))
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
        navigation.openWorkspace(workspace)
        navigation.openWorkspaceSession(session, workspace: workspace)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspace)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.clearWorkspaceSelections()

        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspace)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.workspaceStackRouteElements.count == 2)
        #expect(navigation.selectedWorkspaceFilter == workspace)
    }

    @Test func fullscreenOverlayIgnoresStackSplitFlips() {
        let navigation = readyNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1",
                workspaceId: "ws-b"
            )
        )

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.setWorkspaceNavigationPresentation(.split)

        #expect(navigation.workspaceNavigationPresentation == .stack)
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.splitDetailTarget == nil)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.workspaceNavigationPresentation == .stack)
        #expect(navigation.workspaceStackRouteElements.count == 1)
    }

    @Test func nestedOverlayEndsWaitForMatchingBegins() {
        let navigation = readyNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1"
            )
        )

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.clearWorkspaceSelections()
        #expect(navigation.workspaceStackRouteElements.count == 1)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.isMediaOverlayActive)

        navigation.clearWorkspaceSelections()
        #expect(navigation.workspaceStackRouteElements.count == 1)
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(!navigation.isMediaOverlayActive)
    }

    @Test func overlayDoesNotTrapLaterUserPops() {
        let navigation = readyNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: "server-b",
                sessionId: "chat-1"
            )
        )
        navigation.beginMediaOverlay(activeServerId: "server-b")
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)

        navigation.popWorkspaceStack(toDepth: 0)
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
        navigation.openWorkspace(workspace)
        navigation.openWorkspaceSession(session, workspace: workspace)
        #expect(navigation.workspaceStackRouteElements.count == 2)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // Back pops the chat before AVKit's end callback arrives.
        navigation.popWorkspaceStack(toDepth: 1)

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
        navigation.openWorkspaceSession(session)
        #expect(navigation.splitDetailTarget == .session(session))

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // The split detail root's Back closes the chat column; it is a root
        // close, not a pushed path pop.
        navigation.showSessionInboxInSplit()
        #expect(navigation.splitDetailTarget == nil)
        #expect(!navigation.isMediaOverlayActive)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.splitDetailTarget == nil)
    }

    @Test func userBackFromPushedSplitDetailDuringFullscreenEndsTheOverlayAndStands() {
        let navigation = readyNavigation()
        let root = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-1",
            workspaceId: "ws-b"
        )
        let pushed = WorkspaceSessionNavTarget(
            serverId: "server-b",
            sessionId: "chat-2",
            workspaceId: "ws-b"
        )
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(root)
        navigation.openReferencedSession(pushed)
        #expect(navigation.splitDetailPathElements.count == 1)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.popSplitDetail(toDepth: 0)

        #expect(navigation.splitDetailPathElements.isEmpty)
        #expect(navigation.splitDetailTarget == .session(root))
        #expect(!navigation.isMediaOverlayActive)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.splitDetailPathElements.isEmpty)
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
        navigation.openWorkspace(workspace)
        navigation.openWorkspaceSession(session, workspace: workspace)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // Opening a workspace from the sidebar is the person's navigation.
        navigation.openWorkspace(workspace)

        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.splitDetailTarget == nil)
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.splitDetailTarget == nil)
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
        navigation.openWorkspace(workspace)
        navigation.openWorkspaceSession(session, workspace: workspace)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // All Sessions from the drawer or the server switcher.
        navigation.showAllWorkspaceSessions()

        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.splitDetailTarget == nil)
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.splitDetailTarget == nil)
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
        navigation.openWorkspace(workspace)
        navigation.openWorkspaceSession(first, workspace: workspace)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // Opening another session from the inbox replaces the detail target.
        navigation.openWorkspaceSession(second, workspace: workspace)

        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.splitDetailTarget == .session(second))
        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.splitDetailTarget == .session(second))
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
        navigation.openWorkspaceSession(chat)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        // The sidebar opens a chat on another server, and the shell switches
        // to that server, before AVKit's end arrives.
        navigation.openWorkspaceSession(otherServerChat)
        #expect(!navigation.isMediaOverlayActive)

        // The late end must not put server-b back under server-a's chat.
        #expect(navigation.endMediaOverlay(currentServerId: "server-a") == nil)
        #expect(navigation.splitDetailTarget == .session(otherServerChat))
    }

    private func readyNavigation() -> AppNavigation {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        return navigation
    }
}
