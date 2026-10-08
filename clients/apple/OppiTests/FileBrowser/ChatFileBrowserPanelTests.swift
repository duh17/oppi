import SwiftUI
import Testing
@testable import Oppi

@Suite("Chat file browser panel")
struct ChatFileBrowserPanelTests {
    @Test func tabStoreDefaultsToChangedWhenSessionHasNoPreference() throws {
        let fixture = try makeDefaults()
        defer { fixture.cleanup() }
        let store = ChatFileBrowserPanelTabStore(defaults: fixture.defaults)

        #expect(store.tab(for: "session-1") == .changed)
    }

    @Test func tabStoreRemembersSelectionPerSession() throws {
        let fixture = try makeDefaults()
        defer { fixture.cleanup() }
        let store = ChatFileBrowserPanelTabStore(defaults: fixture.defaults)

        store.setTab(.all, for: "session-1")
        store.setTab(.changed, for: "session-2")

        #expect(store.tab(for: "session-1") == .all)
        #expect(store.tab(for: "session-2") == .changed)
    }

    @Test func tabStoreFallsBackToChangedForMissingOrInvalidSessionIds() throws {
        let fixture = try makeDefaults()
        defer { fixture.cleanup() }
        let store = ChatFileBrowserPanelTabStore(defaults: fixture.defaults)

        store.setTab(.all, for: "   ")

        #expect(store.tab(for: "") == .changed)
        #expect(store.tab(for: "   ") == .changed)
    }

    @Test func trailingColumnFollowsRegularWidthNotAPointThreshold() {
        #expect(TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: .regular))
        #expect(TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: .compact) == false)
        #expect(TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: nil) == false)
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

    @Test func changedFileRoutingOpensNonGitRelativePathsThroughSessionRawEndpoint() {
        #expect(
            SessionFileOpenRouting.mode(
                path: ".pi/skills/oppi-dev/scripts/oppi-workflow.sh",
                gitFile: nil
            ) == .sessionTouched
        )
    }

    @Test func changedFileRoutingKeepsGitFilesOnReviewDetail() {
        let gitFile = GitFileStatus(
            status: " M",
            path: "clients/apple/Oppi/Features/Chat/ChatView.swift",
            addedLines: 3,
            removedLines: 1
        )

        #expect(
            SessionFileOpenRouting.mode(path: gitFile.path, gitFile: gitFile) == .review
        )
    }

    @MainActor
    @Test func panelReadersUseTheSessionCheckoutAndServer() {
        let panel = ChatFileBrowserPanel(
            sessionId: "session-1",
            workspaceId: "workspace-1",
            changedFiles: ["docs/notes.md"],
            selectedTab: .constant(.all),
            serverId: "server-1",
            worktreeId: "wt-agent"
        )

        // All: a tapped file pushes the full reader (own chrome and Edit) on the session checkout.
        let reader = panel.debugAllFilesBrowserForTesting(workspaceId: "workspace-1")
            .debugCompactNavigationFileContentForTesting(
                path: "docs/notes.md",
                name: "notes.md",
                size: nil,
                store: .constant(FullScreenMarkdownViewportRestoreState())
            )
        #expect(reader.debugWorktreeIdForTesting == "wt-agent")
        #expect(reader.debugServerIdForTesting == "server-1")
        #expect(reader.debugSourceForTesting == .workspaceFile)
        #expect(reader.debugChromeModeForTesting == .pushed)

        // Changed: the review detail and its current-bytes reader stay on the same checkout.
        let file = WorkspaceReviewFile(
            path: "docs/notes.md",
            status: " M",
            addedLines: 1,
            removedLines: 0,
            isStaged: false,
            isUnstaged: true,
            isUntracked: false,
            selectedSessionTouched: true
        )
        let review = panel.debugChangedFilesListForTesting
            .debugReviewDetailForTesting(workspaceId: "workspace-1", file: file)
        #expect(review.debugWorktreeIdForTesting == "wt-agent")
        #expect(review.debugServerIdForTesting == "server-1")
        let current = review.debugCurrentFileContentForTesting()
        #expect(current.debugSourceForTesting == .workspaceFile)
        #expect(current.debugWorkspaceIdForTesting == "workspace-1")
        #expect(current.debugWorktreeIdForTesting == "wt-agent")
        #expect(current.debugServerIdForTesting == "server-1")
        #expect(current.debugSessionIdForTesting == "session-1")
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

    private struct DefaultsFixture {
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeDefaults() throws -> DefaultsFixture {
        let suiteName = "ChatFileBrowserPanelTests.\(UUID().uuidString)"
        let defaults = (try #require(UserDefaults(suiteName: suiteName)))
        defaults.removePersistentDomain(forName: suiteName)
        return DefaultsFixture(suiteName: suiteName, defaults: defaults)
    }
}
