import Testing
@testable import Oppi

@Suite("Workspace Home Navigation")
struct WorkspaceHomeNavigationTests {
    @Test func openAffordanceIdentifierUsesStableWorkspaceName() {
        #expect(
            WorkspaceHomeView.workspaceOpenAccessibilityIdentifier(workspaceName: "Nav Workspace")
                == "workspace.open.Nav Workspace"
        )
    }

    @Test func rowBodyExpandsInNormalModeAndNavigatesInE2EMode() {
        #expect(!WorkspaceHomeView.shouldOpenWorkspaceFromRowBody(isE2EInviteMode: false))
        #expect(WorkspaceHomeView.shouldOpenWorkspaceFromRowBody(isE2EInviteMode: true))
    }

    @Test func compactWorkspaceHomeKeepsInlineSessionPreviews() {
        let mode = WorkspaceHomeListPresentationMode(navigationPresentation: .stack)

        #expect(mode.showsInlineSessionPreviews)
        #expect(mode.rowBodyAction(isE2EInviteMode: false) == .toggleSessionPreviews)
        #expect(mode.rowBodyAction(isE2EInviteMode: true) == .openWorkspace)
    }

    @Test func splitWorkspaceHomeHidesInlineSessionPreviews() {
        let mode = WorkspaceHomeListPresentationMode(navigationPresentation: .split)

        #expect(!mode.showsInlineSessionPreviews)
        #expect(mode.rowBodyAction(isE2EInviteMode: false) == .openWorkspace)
        #expect(mode.rowBodyAction(isE2EInviteMode: true) == .openWorkspace)
    }

    @Test func workspaceHomePreviewCandidatesOmitStoppedSessions() {
        let ready = makeTestSession(id: "ready", status: .ready)
        let busy = makeTestSession(id: "busy", status: .busy)
        let stopped = makeTestSession(id: "stopped", status: .stopped)

        let candidates = WorkspaceHomePreviewPlanner.previewableSessions([stopped, ready, busy])

        #expect(candidates.map(\.id) == ["ready", "busy"])
    }
}
