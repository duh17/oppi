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

    @Test func overlayFreezesMeasuredPresentation() {
        #expect(
            WorkspaceMediaOverlayNavigationPolicy.effectivePresentation(
                measured: .split,
                overlayActive: true,
                frozen: .stack
            ) == .stack
        )
        #expect(
            WorkspaceMediaOverlayNavigationPolicy.effectivePresentation(
                measured: .split,
                overlayActive: false,
                frozen: .stack
            ) == .split
        )
        #expect(!WorkspaceMediaOverlayNavigationPolicy.shouldApplyMeasuredPresentation(overlayActive: true))
        #expect(WorkspaceMediaOverlayNavigationPolicy.shouldApplyMeasuredPresentation(overlayActive: false))
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
        #expect(navigation.workspacePath.count == 1)

        navigation.beginMediaOverlay(activeServerId: "server-b")
        navigation.workspacePath = NavigationPath()

        #expect(navigation.isMediaOverlayActive)
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")

        let restoreServer = navigation.endMediaOverlay(currentServerId: "server-a")
        #expect(restoreServer == "server-b")
        #expect(!navigation.isMediaOverlayActive)
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "chat-1")
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
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.splitDetailTarget == nil)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.workspaceNavigationPresentation == .stack)
        #expect(navigation.workspacePath.count == 1)
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
        navigation.workspacePath = NavigationPath()
        #expect(navigation.workspacePath.count == 1)

        #expect(navigation.endMediaOverlay(currentServerId: "server-b") == nil)
        #expect(navigation.isMediaOverlayActive)

        navigation.workspacePath = NavigationPath()
        #expect(navigation.workspacePath.count == 1)
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

        navigation.workspacePath = NavigationPath()
        #expect(navigation.workspacePath.count == 0)
        #expect(navigation.workspaceStackDiagnosticContext == .inboxAll)
    }

    private func readyNavigation() -> AppNavigation {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        return navigation
    }
}
