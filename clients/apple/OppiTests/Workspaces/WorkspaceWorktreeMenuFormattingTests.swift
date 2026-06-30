import Testing
@testable import Oppi

@Suite("Workspace worktree menu formatting")
struct WorkspaceWorktreeMenuFormattingTests {
    @Test func formatsMainAndBranchTitles() {
        let main = makeWorktree(id: "main", isMain: true, branch: "main", sessionCount: 7)
        let feature = makeWorktree(id: "wt_feature", name: "feature-name", isMain: false, branch: "feat/demo", sessionCount: 2)

        #expect(WorkspaceWorktreeMenuFormatting.title(for: main) == "Main")
        #expect(WorkspaceWorktreeMenuFormatting.title(for: feature) == "feat/demo")
    }

    @Test func formatsSessionCountTextWhenAvailable() {
        let small = makeWorktree(id: "main", isMain: true, sessionCount: 7)
        let large = makeWorktree(id: "wt_large", isMain: false, sessionCount: 1_452)
        let unknown = makeWorktree(id: "wt_unknown", isMain: false, sessionCount: nil)

        #expect(WorkspaceWorktreeMenuFormatting.sessionCountText(for: small) == "7")
        #expect(WorkspaceWorktreeMenuFormatting.sessionCountText(for: large) == "1.5k")
        #expect(WorkspaceWorktreeMenuFormatting.sessionCountText(for: unknown) == nil)
    }

    @Test func accessibilityIncludesSessionCountWhenAvailable() {
        let one = makeWorktree(id: "main", isMain: true, sessionCount: 1)
        let many = makeWorktree(id: "wt_many", isMain: false, branch: "feat/demo", sessionCount: 3)
        let unknown = makeWorktree(id: "wt_unknown", isMain: false, branch: "feat/unknown", sessionCount: nil)

        #expect(WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: one) == "Main, 1 session")
        #expect(WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: many) == "feat/demo, 3 sessions")
        #expect(WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: unknown) == "feat/unknown")
    }

    private func makeWorktree(
        id: String,
        name: String = "Worktree",
        isMain: Bool,
        branch: String? = nil,
        sessionCount: Int?
    ) -> WorkspaceWorktree {
        WorkspaceWorktree(
            id: id,
            name: name,
            path: "/tmp/\(id)",
            branch: branch,
            headSha: nil,
            isMain: isMain,
            isGitRepo: true,
            sessionCount: sessionCount
        )
    }
}
