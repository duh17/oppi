import Foundation
import Testing
@testable import Oppi

/// Lane assignment for the Git panel's commit graph. Rows stack into one
/// drawing, so each row's outgoing lanes must be exactly the lanes the next
/// rows pick up, and branches forked from one commit must share a lane
/// instead of widening the graph.
@Suite("Git graph layout")
struct CommitGraphLayoutTests {
    private func commit(_ sha: String, _ parents: String...) -> CommitGraphCommit {
        CommitGraphCommit(sha: sha, shortSha: sha, parents: parents, message: sha, date: "", refs: [])
    }

    @Test func linearHistoryStaysInOneLane() {
        let layout = CommitGraphLayout(commits: [commit("c", "b"), commit("b", "a"), commit("a")])

        #expect(layout.laneCount == 1)
        #expect(layout.rows.map(\.column) == [0, 0, 0])
        #expect(layout.rows.map(\.continuesFromAbove) == [false, true, true])
        #expect(layout.rows.map(\.outgoing) == [[0], [0], []])
    }

    @Test func branchesFromOneBaseJoinItsLaneInsteadOfWideningTheGraph() {
        // Topological order: main's tip, then two branches' commits, then the
        // base all three grew from.
        let layout = CommitGraphLayout(commits: [
            commit("main", "base"),
            commit("feat1", "base"),
            commit("feat2b", "feat2a"),
            commit("feat2a", "base"),
            commit("base"),
        ])

        // feat1 is a tip in a new lane and bends straight into main's lane.
        #expect(layout.rows[1].column == 1)
        #expect(!layout.rows[1].continuesFromAbove)
        #expect(layout.rows[1].outgoing == [0])
        // feat2 reuses the freed lane and runs down it until its fork point.
        #expect(layout.rows[2].column == 1)
        #expect(layout.rows[3].column == 1)
        #expect(layout.rows[3].outgoing == [0])
        #expect(layout.rows[3].passing == [0])
        #expect(layout.rows[4].column == 0)
        #expect(layout.rows[4].passing.isEmpty)
        #expect(layout.laneCount == 2)
    }

    @Test func mergeOpensALaneForItsSecondParentUntilTheParentRow() {
        let layout = CommitGraphLayout(commits: [
            commit("merge", "main1", "side1"),
            commit("side1", "base"),
            commit("main1", "base"),
            commit("base"),
        ])

        #expect(layout.rows[0].outgoing == [0, 1])
        // The side commit takes the lane the merge opened; main's lane passes.
        #expect(layout.rows[1].column == 1)
        #expect(layout.rows[1].continuesFromAbove)
        #expect(layout.rows[1].passing == [0])
        #expect(layout.rows[1].outgoing == [1])
        // Main's commit finds the base already waited for and bends into that
        // lane, where the base's dot then sits.
        #expect(layout.rows[2].column == 0)
        #expect(layout.rows[2].passing == [1])
        #expect(layout.rows[2].outgoing == [1])
        #expect(layout.rows[3].column == 1)
        #expect(layout.rows[3].passing.isEmpty)
        #expect(layout.laneCount == 2)
    }

    @Test func aParentOffThePageKeepsItsLaneOpenToTheBottom() {
        let layout = CommitGraphLayout(commits: [commit("b", "a")])

        #expect(layout.rows[0].outgoing == [0])
    }
}
