import Testing
import UIKit
@testable import Oppi

@Suite("Chat file browser panel")
struct ChatFileBrowserPanelTests {
    @Test func trailingColumnFollowsRegularWidthNotAPointThreshold() {
        #expect(TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: .regular))
        #expect(TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: .compact) == false)
        #expect(TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: .unspecified) == false)
    }

    @Test func fileBrowserColumnStaysOnRegularWidthInEitherOrientation() {
        #expect(
            FileBrowserColumnPolicy.showsColumn(layoutMode: .adaptive, horizontalSizeClass: .regular)
        )
        #expect(
            FileBrowserColumnPolicy.showsColumn(layoutMode: .adaptive, horizontalSizeClass: .compact) == false
        )
        #expect(
            FileBrowserColumnPolicy.showsColumn(layoutMode: .compactOnly, horizontalSizeClass: .regular) == false
        )
    }

    @MainActor
    @Test func panelReaderUsesTheSessionCheckoutAndServer() throws {
        let inputs = ChatFilePanelInputs(
            sessionId: "session-1",
            workspaceId: "workspace-1",
            serverId: "server-1",
            worktreeId: "wt-agent",
            reviewCommentSelectionScope: nil,
            connection: ServerConnection(),
            apiClient: nil,
            fileIndexStore: FileIndexStore(),
            navigation: AppNavigation()
        )
        let root = makeTestAppRoot()

        // A tapped file pushes the full reader (own chrome and Edit) on the session checkout.
        let reader = try #require(
            ChatFilePanelViewController.debugBrowserForTesting(root: root, inputs: inputs, workspaceId: "workspace-1")
                .debugPushedReaderForTesting(path: "docs/notes.md", name: "notes.md", size: nil)
        )
        #expect(reader.worktreeId == "wt-agent")
        #expect(reader.serverId == "server-1")
        #expect(reader.source == .workspaceFile)
        #expect(reader.chromeMode == .pushed)
    }

    @Test func checkoutSubtitleNamesWorktreeOrWarnsWhenChatIsOnOne() {
        #expect(FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: .workspaceFile, worktreeId: "wt-agent", sessionWorktreeId: "wt-agent"
        ) == "Worktree wt-agent")
        #expect(FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: .workspaceFile, worktreeId: nil, sessionWorktreeId: "wt-agent"
        ) == "Main checkout")
        #expect(FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: .workspaceFile, worktreeId: nil, sessionWorktreeId: nil
        ) == nil)
        #expect(FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: .hostFile, worktreeId: "wt-agent", sessionWorktreeId: nil
        ) == nil)
    }
}
