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
}
