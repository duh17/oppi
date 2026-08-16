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
}
