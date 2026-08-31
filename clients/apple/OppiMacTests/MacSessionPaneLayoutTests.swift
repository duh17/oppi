import Foundation
import Testing
@testable import Oppi

@Suite("Mac session pane layout")
struct MacSessionPaneLayoutTests {
    @Test func initialPaneOwnsTheRouteAndFocus() {
        let paneID = MacSessionPaneID(rawValue: "pane-a")
        let route = MacSessionPaneRoute.workspace(workspaceID: "workspace-a", sessionID: "session-a")
        let layout = MacSessionPaneLayout(initialRoute: route, paneID: paneID)

        #expect(layout.paneCount == 1)
        #expect(layout.focusedPaneID == paneID)
        #expect(layout.focusedPane?.route == route)
        #expect(layout.panes == [MacSessionPane(id: paneID, route: route)])
    }

    @Test func anyLeafCanSplitAlongEitherAxis() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        let splitAB = MacSessionPaneSplitID(rawValue: "split-ab")
        let splitBC = MacSessionPaneSplitID(rawValue: "split-bc")
        var layout = MacSessionPaneLayout(
            initialRoute: .workspace(workspaceID: "workspace-a", sessionID: "session-a"),
            paneID: paneA
        )

        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: .control(sessionID: "control-b"),
            newPaneID: paneB,
            splitID: splitAB,
            fraction: 0.4
        )
        try layout.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: .workspace(workspaceID: "workspace-c", sessionID: "session-c"),
            newPaneID: paneC,
            splitID: splitBC,
            fraction: 0.6
        )

        #expect(layout.panes.map(\.id) == [paneA, paneB, paneC])
        #expect(layout.focusedPaneID == paneC)
        #expect(layout.split(id: splitAB)?.axis == .horizontal)
        #expect(layout.split(id: splitAB)?.fraction == 0.4)
        #expect(layout.split(id: splitBC)?.axis == .vertical)
        #expect(layout.split(id: splitBC)?.fraction == 0.6)
    }

    @Test func fifthPaneIsRejectedWithoutChangingTheLayout() throws {
        let paneIDs = (0..<5).map { MacSessionPaneID(rawValue: "pane-\($0)") }
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneIDs[0])

        for index in 1..<MacSessionPaneLayout.maximumPaneCount {
            try layout.split(
                paneID: paneIDs[index - 1],
                axis: index.isMultiple(of: 2) ? .vertical : .horizontal,
                newRoute: route(index),
                newPaneID: paneIDs[index],
                splitID: MacSessionPaneSplitID(rawValue: "split-\(index)")
            )
        }
        let beforeRejectedSplit = layout

        do {
            try layout.split(
                paneID: paneIDs[0],
                axis: .horizontal,
                newRoute: route(4),
                newPaneID: paneIDs[4],
                splitID: MacSessionPaneSplitID(rawValue: "split-4")
            )
            Issue.record("Expected the fifth pane to be rejected")
        } catch {
            #expect(error as? MacSessionPaneLayoutError == .paneLimitReached)
        }

        #expect(layout == beforeRejectedSplit)
        #expect(layout.paneCount == MacSessionPaneLayout.maximumPaneCount)
    }

    @Test func closingFocusedPaneRebalancesAndFocusesItsVisualNeighbor() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        let outerSplit = MacSessionPaneSplitID(rawValue: "split-outer")
        let remainingSplit = MacSessionPaneSplitID(rawValue: "split-remaining")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB,
            splitID: outerSplit,
            fraction: 0.3
        )
        try layout.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: route(2),
            newPaneID: paneC,
            splitID: remainingSplit,
            fraction: 0.7
        )
        try layout.focus(paneB)

        try layout.close(paneID: paneB)

        #expect(layout.panes.map(\.id) == [paneA, paneC])
        #expect(layout.focusedPaneID == paneC)
        #expect(layout.split(id: remainingSplit) == nil)
        #expect(layout.split(id: outerSplit)?.axis == .horizontal)
        #expect(layout.split(id: outerSplit)?.fraction == 0.3)
    }

    @Test func closingUnfocusedPanePromotesItsSiblingSubtreeUnchanged() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        let outerSplit = MacSessionPaneSplitID(rawValue: "split-outer")
        let innerSplit = MacSessionPaneSplitID(rawValue: "split-inner")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB,
            splitID: outerSplit
        )
        try layout.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: route(2),
            newPaneID: paneC,
            splitID: innerSplit,
            fraction: 0.65
        )
        let siblingSubtree = try #require(layout.node(containingSplit: innerSplit))

        try layout.close(paneID: paneA)

        #expect(layout.root == siblingSubtree)
        #expect(layout.focusedPaneID == paneC)
        #expect(layout.panes.map(\.route) == [route(1), route(2)])
        #expect(layout.split(id: innerSplit)?.fraction == 0.65)
    }

    @Test func focusAndRouteChangesTargetStablePaneIDs() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB,
            splitID: MacSessionPaneSplitID(rawValue: "split-ab")
        )

        try layout.focus(paneA)
        try layout.setRoute(.control(sessionID: "control-a"), for: paneA)

        #expect(layout.focusedPaneID == paneA)
        #expect(layout.pane(id: paneA)?.route == .control(sessionID: "control-a"))
        #expect(layout.pane(id: paneB)?.route == route(1))

        do {
            try layout.focus(MacSessionPaneID(rawValue: "missing"))
            Issue.record("Expected focus of an unknown pane to be rejected")
        } catch {
            #expect(error as? MacSessionPaneLayoutError == .paneNotFound)
        }
    }

    @Test func codableRoundTripPreservesTreeRoutesIdentifiersAndFocus() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        let splitAB = MacSessionPaneSplitID(rawValue: "split-ab")
        let splitAC = MacSessionPaneSplitID(rawValue: "split-ac")
        var layout = MacSessionPaneLayout(
            initialRoute: .workspace(workspaceID: "workspace-a", sessionID: "session-a"),
            paneID: paneA
        )
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: .control(sessionID: "control-b"),
            newPaneID: paneB,
            splitID: splitAB,
            fraction: 0.35
        )
        try layout.split(
            paneID: paneA,
            axis: .vertical,
            newRoute: .workspace(workspaceID: "workspace-c", sessionID: "session-c"),
            newPaneID: paneC,
            splitID: splitAC,
            fraction: 0.55
        )
        try layout.focus(paneB)

        let data = try JSONEncoder().encode(layout)
        let restored = try JSONDecoder().decode(MacSessionPaneLayout.self, from: data)

        #expect(restored == layout)
        #expect(Set(restored.panes.map(\.id)).count == 3)
        #expect(Set(restored.panes.map(\.route)).count == 3)
        #expect(restored.focusedPaneID == paneB)
    }

    @Test func theOnlyPaneCannotBeClosed() {
        let paneID = MacSessionPaneID(rawValue: "pane-a")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneID)
        let beforeRejectedClose = layout

        do {
            try layout.close(paneID: paneID)
            Issue.record("Expected closing the only pane to be rejected")
        } catch {
            #expect(error as? MacSessionPaneLayoutError == .cannotCloseOnlyPane)
        }

        #expect(layout == beforeRejectedClose)
    }

    @Test func emptyPaneCanSplitWithoutARoute() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)

        try layout.split(paneID: paneA, axis: .horizontal, newPaneID: paneB)

        #expect(layout.paneCount == 2)
        #expect(layout.focusedPaneID == paneB)
        #expect(layout.pane(id: paneB)?.route == nil)
        #expect(layout.pane(id: paneA)?.route == route(0))
    }

    @Test func adjacentFocusFollowsSplitDirections() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB
        )
        try layout.focus(paneA)
        try layout.split(
            paneID: paneA,
            axis: .vertical,
            newRoute: nil,
            newPaneID: paneC
        )

        // A is top-left, C bottom-left, B right.
        try layout.focus(paneA)
        #expect(layout.adjacentPaneID(direction: .right) == paneB)
        #expect(layout.adjacentPaneID(direction: .down) == paneC)
        #expect(layout.adjacentPaneID(direction: .left) == nil)
        #expect(layout.adjacentPaneID(direction: .up) == nil)

        try layout.focus(paneB)
        #expect(layout.adjacentPaneID(direction: .left) == paneA || layout.adjacentPaneID(direction: .left) == paneC)
        #expect(layout.adjacentPaneID(direction: .right) == nil)

        try layout.focus(paneC)
        #expect(layout.adjacentPaneID(direction: .up) == paneA)
        #expect(layout.adjacentPaneID(direction: .right) == paneB)
    }

    @Test func emptyPaneCodableRoundTripPreservesNilRoute() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(paneID: paneA, axis: .vertical, newPaneID: paneB)

        let restored = try JSONDecoder().decode(
            MacSessionPaneLayout.self,
            from: try JSONEncoder().encode(layout)
        )

        #expect(restored == layout)
        #expect(restored.pane(id: paneB)?.route == nil)
    }

    private func route(_ index: Int) -> MacSessionPaneRoute {
        .workspace(workspaceID: "workspace-\(index)", sessionID: "session-\(index)")
    }
}
