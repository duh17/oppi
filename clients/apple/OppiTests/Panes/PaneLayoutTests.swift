import Foundation
import Testing
@testable import Oppi

/// The pane tree's operations, their split arithmetic, normalisation and limits.
@Suite("PaneLayout")
struct PaneLayoutTests: PaneFixtureBuilding {
    // MARK: Split

    @Test func splitInTheSameAxisTakesHalfOfTheTargetsShare() throws {
        let layout = try PaneLayout(single: leaf("a"))
            .split(id("a"), axis: .row, inserting: leaf("b"))
            .split(id("a"), axis: .row, inserting: leaf("c"))
        #expect(shape(layout.root) == "row[a 0.25, c 0.25, b 0.5]")
    }

    @Test func splitAcrossTheAxisWrapsTheTargetInItsShare() throws {
        let layout = try row(("a", 0.6), ("b", 0.4))
            .split(id("b"), axis: .column, inserting: leaf("c"))
        #expect(shape(layout.root) == "row[a 0.6, column[b 0.5, c 0.5] 0.4]")
    }

    @Test func splitLeavesFocusAloneAndMakesTheNewLeafLeastRecent() throws {
        let layout = try row(("a", 0.5), ("b", 0.5), focus: "b", recency: ["b", "a"])
            .split(id("a"), axis: .row, inserting: leaf("c"))
        #expect(layout.focus == id("b"))
        #expect(layout.recency == ids("b", "a", "c"))
    }

    @Test func splitRefusesANinthLeafAFourthLevelAndATakenId() throws {
        var eight = PaneLayout(single: leaf("l1"))
        for index in 2...8 {
            eight = try eight.split(id("l\(index - 1)"), axis: .row, inserting: leaf("l\(index)"))
        }
        #expect(eight.leaves.count == 8)
        #expect(throws: PaneLayoutError.tooManyLeaves(9)) {
            try eight.split(id("l1"), axis: .column, inserting: leaf("l9"))
        }

        let three = try PaneLayout(single: leaf("a"))
            .split(id("a"), axis: .row, inserting: leaf("b"))
            .split(id("b"), axis: .column, inserting: leaf("c"))
            .split(id("c"), axis: .row, inserting: leaf("d"))
        #expect(three.root.depth == 3)
        #expect(throws: PaneLayoutError.tooDeep(4)) {
            try three.split(id("d"), axis: .column, inserting: leaf("e"))
        }
        #expect(throws: PaneLayoutError.duplicateLeaf(id("a"))) {
            try three.split(id("d"), axis: .column, inserting: leaf("a"))
        }
    }

    // MARK: Close

    @Test func closedShareGoesToTheSiblingBeforeElseAfter() throws {
        let layout = row(("a", 0.2), ("b", 0.3), ("c", 0.5))
        #expect(shape(try layout.close(id("b")).root) == "row[a 0.5, c 0.5]")
        #expect(shape(try layout.close(id("a")).root) == "row[b 0.5, c 0.5]")
    }

    @Test func closingLeavesASplitWithOneChildThatGivesWayAndMergesUp() throws {
        // row[a, column[b, row[c, d]]]: closing b leaves the inner row in the outer row.
        let layout = try row(("a", 0.4), ("b", 0.6))
            .split(id("b"), axis: .column, inserting: leaf("c"))
            .split(id("c"), axis: .row, inserting: leaf("d"))
            .close(id("b"))
        #expect(shape(layout.root) == "row[a 0.4, c 0.3, d 0.3]")
    }

    @Test func closingTheFocusedLeafFocusesTheMostRecentAndClosesItsAttachedLeaves() throws {
        var layout = row(("a", 0.4), ("b", 0.3), ("c", 0.3), focus: "b", recency: ["b", "c", "a"])
        layout.root = layout.root.mapLeaves { leaf in
            guard leaf.id == id("c") else { return leaf }
            var attached = leaf
            attached.attachedTo = id("b")
            attached.origin = .attached
            return attached
        }
        let closed = try layout.close(id("b"))
        #expect(closed.leaves.map(\.id) == ids("a"))
        #expect(closed.focus == id("a"))
        #expect(closed.recency == ids("a"))
    }

    @Test func theLastLeafDoesNotClose() {
        #expect(throws: PaneLayoutError.lastLeaf) { try PaneLayout(single: leaf("a")).close(id("a")) }
    }

    // MARK: Move, swap, weights

    @Test func moveUsesTheSplitArithmeticAndKeepsFocusAndRecency() throws {
        let layout = row(("a", 0.5), ("b", 0.25), ("c", 0.25), focus: "a", recency: ["a", "c", "b"])
        let moved = try layout.move(id("a"), to: id("c"), edge: .bottom)
        #expect(shape(moved.root) == "row[b 0.75, column[c 0.5, a 0.5] 0.25]")
        #expect(moved.focus == id("a"))
        #expect(moved.recency == layout.recency)
        let leading = try layout.move(id("c"), to: id("a"), edge: .left)
        #expect(shape(leading.root) == "row[c 0.25, a 0.25, b 0.5]")
        #expect(throws: PaneLayoutError.sameLeaf) { try layout.move(id("a"), to: id("a"), edge: .right) }
    }

    @Test func swapTradesLeavesWhileSizesStayWithThePlaces() throws {
        let layout = row(("a", 0.7), ("b", 0.3), focus: "a")
        let swapped = try layout.swap(id("a"), id("b"))
        #expect(shape(swapped.root) == "row[b 0.7, a 0.3]")
        #expect(swapped.focus == id("a"))
    }

    @Test func setWeightsScalesToOneAndRefusesBadWeights() throws {
        let layout = row(("a", 0.5), ("b", 0.5))
        #expect(shape(try layout.setWeights(at: [], [3, 1]).root) == "row[a 0.75, b 0.25]")
        #expect(throws: PaneLayoutError.invalidWeights) { try layout.setWeights(at: [], [1, 0]) }
        #expect(throws: PaneLayoutError.invalidWeights) { try layout.setWeights(at: [], [1]) }
        #expect(throws: PaneLayoutError.notASplit([0])) { try layout.setWeights(at: [0], [1, 1]) }
    }

    // MARK: Open, zoom, collapse, focus

    @Test func openPushesOnTheTargetStackUnlessAlreadyOnTop() throws {
        let entry = PaneStackEntry(serverId: paneFixtureServer, route: .file(.host, path: "/tmp/a.md", line: nil))
        let layout = try row(("a", 0.5), ("b", 0.5)).open(entry, in: id("b")).open(entry, in: id("b"))
        #expect(layout.leaf(id("b"))?.stack.count == 2)
        #expect(layout.leaf(id("b"))?.stack.last == entry)
        #expect(layout.leaf(id("a"))?.stack.count == 1)
    }

    @Test func zoomFocusesItsLeafAndFocusingAnotherEndsIt() throws {
        let zoomed = try row(("a", 0.5), ("b", 0.5), focus: "a").zoom(id("b"))
        #expect(zoomed.zoomed == id("b"))
        #expect(zoomed.focus == id("b"))
        let refocused = try zoomed.focusing(id("a"))
        #expect(refocused.zoomed == nil)
        #expect(refocused.recency.first == id("a"))
        #expect(try zoomed.zoom(nil).zoomed == nil)
    }

    @Test func collapseRemembersItsShareAndExpandGivesItBack() throws {
        let layout = row(("a", 0.5), ("b", 0.3), ("c", 0.2), focus: "b", recency: ["b", "c", "a"])
        let collapsed = try layout.collapse(id("b"))
        #expect(collapsed.collapsed == [id("b"): 0.3])
        #expect(collapsed.focus == id("c"))
        // The siblings change while it is collapsed; expanding restores its share.
        let resized = try collapsed.setWeights(at: [], [0.6, 0.3, 0.1])
        let expanded = try resized.expand(id("b"))
        #expect(expanded.collapsed.isEmpty)
        #expect(shape(expanded.root) == "row[a 0.6, b 0.3, c 0.1]")
        // Focusing a collapsed leaf expands it.
        #expect(try collapsed.focusing(id("b")).collapsed.isEmpty)
    }

    @Test func collapseNeedsAnotherOpenLeaf() throws {
        #expect(throws: PaneLayoutError.lastLeaf) { try PaneLayout(single: leaf("a")).collapse(id("a")) }
        let oneOpen = try row(("a", 0.5), ("b", 0.5)).collapse(id("a"))
        #expect(throws: PaneLayoutError.lastLeaf) { try oneOpen.collapse(id("b")) }
    }

    // MARK: Normalisation

    @Test func normalisedRestoresTheInvariants() throws {
        let messy = PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(leaf("a")),
                .split(axis: .row, children: [.leaf(leaf("b")), .leaf(leaf("c"))], weights: [1, 3]),
                .split(axis: .column, children: [.leaf(leaf("d"))], weights: [7]),
            ], weights: [2, 1, -1]),
            focus: id("zz"),
            recency: ids("c", "c", "gone"),
            zoomed: id("gone"),
            collapsed: [id("gone"): 0.5, id("d"): 0.2]
        )
        let layout = try messy.normalised()
        // Bad weights become equal; the same-axis row merges up; the one-child column gives way.
        #expect(shape(layout.root) == "row[a 0.333, b 0.083, c 0.25, d 0.333]")
        #expect(layout.recency == ids("c", "a", "b", "d"))
        #expect(layout.focus == id("c"))
        #expect(layout.zoomed == nil)
        #expect(layout.collapsed == [id("d"): 0.2])
    }

    /// A saved zoom that would leave no way out comes back unzoomed: a
    /// collapsed leaf has a strip, no grip, and a lone leaf has neither.
    @Test func normalisedDropsAZoomWithNoGripToExitIt() throws {
        var collapsed = try row(("a", 0.5), ("b", 0.3), ("c", 0.2)).collapse(id("b"))
        collapsed.zoomed = id("b")
        #expect(try collapsed.normalised().zoomed == nil)
        #expect(try collapsed.normalised().collapsed == [id("b"): 0.3])
        var lone = PaneLayout(single: leaf("a"))
        lone.zoomed = id("a")
        #expect(try lone.normalised().zoomed == nil)
        // Closing the zoomed leaf's last neighbour ends its zoom too.
        let zoomed = try row(("a", 0.5), ("b", 0.5)).zoom(id("a"))
        #expect(try zoomed.normalised().zoomed == id("a"))
        #expect(try zoomed.close(id("b")).zoomed == nil)
    }

    @Test func normalisedRefusesWhatItCannotRepair() {
        let duplicate = PaneLayout(
            root: .split(axis: .row, children: [.leaf(leaf("a")), .leaf(leaf("a"))], weights: [1, 1]),
            focus: id("a")
        )
        #expect(throws: PaneLayoutError.duplicateLeaf(id("a"))) { try duplicate.normalised() }
        var empty = leaf("a")
        empty.stack = []
        #expect(throws: PaneLayoutError.emptyStack(id("a"))) { try PaneLayout(single: empty).normalised() }
    }

    @Test func paneIDsAreShortLowercaseSlugs() {
        #expect(PaneID("chat-1") != nil)
        #expect(PaneID("") == nil)
        #expect(PaneID("Chat") == nil)
        #expect(PaneID("a_b") == nil)
        #expect(PaneID(String(repeating: "a", count: 25)) == nil)
    }
}
