import Foundation
import Testing
@testable import Oppi

@Suite("Workspace git summary")
struct WorkspaceGitSummaryTests {
    @Test func decodesCatalogGitSummary() throws {
        let data = Data(#"""
        {
          "workspaceId":"w1",
          "activeCount":2,
          "stoppedCount":3,
          "hasAttention":false,
          "hasErrorRoot":false,
          "latestActivity":1500,
          "gitSummary":{
            "isGitRepo":true,
            "changedCount":14,
            "ahead":3,
            "behind":1
          }
        }
        """#.utf8)

        let summary = try JSONDecoder().decode(WorkspaceListSummary.self, from: data)

        #expect(summary.gitSummary == WorkspaceGitSummary(
            isGitRepo: true,
            changedCount: 14,
            ahead: 3,
            behind: 1
        ))
        #expect(summary.latestActivity == Date(timeIntervalSince1970: 1.5))
    }

    @Test func sidebarSummaryDescribesOnlyVisibleGitSignals() {
        let summary = WorkspaceSidebarGitSummary(
            changedCount: 14,
            aheadCount: 3,
            behindCount: 1
        )

        #expect(summary.isVisible)
        #expect(summary.accessibilityValue == "14 changed files, 3 commits not pushed, 1 commit behind")
        #expect(!WorkspaceSidebarGitSummary(
            changedCount: 0,
            aheadCount: 0,
            behindCount: 0
        ).isVisible)
    }
}
