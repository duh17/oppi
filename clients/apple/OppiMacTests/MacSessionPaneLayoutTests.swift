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
            fraction: 0.4,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        try layout.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: .workspace(workspaceID: "workspace-c", sessionID: "session-c"),
            newPaneID: paneC,
            splitID: splitBC,
            fraction: 0.6,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )

        #expect(layout.panes.map(\.id) == [paneA, paneB, paneC])
        #expect(layout.focusedPaneID == paneC)
        #expect(layout.split(id: splitAB)?.axis == .horizontal)
        #expect(layout.split(id: splitAB)?.fraction == 0.4)
        #expect(layout.split(id: splitBC)?.axis == .vertical)
        #expect(layout.split(id: splitBC)?.fraction == 0.6)
    }

    @Test func splitIsRejectedWhenGeometryIsUnknown() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        let beforeRejectedSplit = layout

        do {
            try layout.split(
                paneID: paneA,
                axis: .horizontal,
                newRoute: route(1),
                newPaneID: paneB
            )
            Issue.record("Expected unknown geometry to be rejected")
        } catch {
            #expect(error as? MacSessionPaneLayoutError == .paneTooSmall)
        }

        #expect(layout == beforeRejectedSplit)
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: nil,
                windowSize: nil,
                axis: .horizontal
            ) == .paneTooSmall
        )
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: nil,
                windowSize: usefulSize(),
                axis: .horizontal
            ) == .paneTooSmall
        )
    }

    @Test func splitIsRejectedWhenThePaneIsTooNarrow() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        let beforeRejectedSplit = layout
        let paneSize = MacSessionPaneMeasuredSize(width: 500, height: 700)

        do {
            try layout.split(
                paneID: paneA,
                axis: .horizontal,
                newRoute: route(1),
                newPaneID: paneB,
                paneSize: paneSize,
                windowSize: MacSessionPaneMeasuredSize(width: 1_200, height: 800)
            )
            Issue.record("Expected a too-narrow pane to be rejected")
        } catch {
            #expect(error as? MacSessionPaneLayoutError == .paneTooSmall)
        }

        #expect(layout == beforeRejectedSplit)
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: paneSize,
                windowSize: MacSessionPaneMeasuredSize(width: 1_200, height: 800),
                axis: .horizontal
            ) == .paneTooSmall
        )
        #expect(MacSessionPaneSplitAdmission.Rejection.paneTooSmall.message.contains("too small"))
        #expect(!MacSessionPaneSplitAdmission.Rejection.paneTooSmall.message.contains("4"))
        #expect(!MacSessionPaneSplitAdmission.Rejection.paneTooSmall.message.contains("four"))
    }

    @Test func splitIsRejectedWhenTheWindowIsTooShort() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        let windowSize = MacSessionPaneMeasuredSize(width: 1_200, height: 400)

        do {
            try layout.split(
                paneID: paneA,
                axis: .vertical,
                newRoute: route(1),
                paneSize: windowSize,
                windowSize: windowSize
            )
            Issue.record("Expected a too-short window to be rejected")
        } catch {
            #expect(error as? MacSessionPaneLayoutError == .paneTooSmall)
        }

        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: windowSize,
                windowSize: windowSize,
                axis: .vertical
            ) == .windowTooSmall
        )
        #expect(MacSessionPaneSplitAdmission.Rejection.windowTooSmall.message.contains("window"))
        #expect(MacSessionPaneSplitAdmission.Rejection.windowTooSmall.message.contains("too small"))
        #expect(!MacSessionPaneSplitAdmission.Rejection.windowTooSmall.message.contains("4"))
    }

    @Test func admissionSubtractsTheDividerBeforeApplyingFraction() {
        let paintedFit = MacSessionPaneMeasuredSize(width: 652, height: 700)
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: paintedFit,
                windowSize: MacSessionPaneMeasuredSize(width: 1_200, height: 800),
                axis: .horizontal
            ) == nil
        )

        let paintedTooSmall = MacSessionPaneMeasuredSize(width: 651, height: 700)
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: paintedTooSmall,
                windowSize: MacSessionPaneMeasuredSize(width: 1_200, height: 800),
                axis: .horizontal
            ) == .paneTooSmall
        )

        // Old math used paneAlong * fraction before subtracting the divider and
        // would admit 800pt at 0.4. Painted leaves are (800-12)*0.4 = 315.2.
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: MacSessionPaneMeasuredSize(width: 800, height: 700),
                windowSize: MacSessionPaneMeasuredSize(width: 2_400, height: 1_400),
                axis: .horizontal,
                fraction: 0.4
            ) == .paneTooSmall
        )

        let leaves = MacSessionPaneSplitAdmission.paintedLeafLengths(along: 652, fraction: 0.5)
        #expect(abs(leaves.first - 320) < 0.001)
        #expect(abs(leaves.second - 320) < 0.001)
    }

    @Test func aStaleOversizedPaneDoesNotAdmitWhenTheWindowCannotHoldTheChildren() {
        #expect(
            MacSessionPaneSplitAdmission.evaluate(
                paneSize: MacSessionPaneMeasuredSize(width: 1_200, height: 800),
                windowSize: MacSessionPaneMeasuredSize(width: 500, height: 800),
                axis: .horizontal
            ) == .windowTooSmall
        )
    }

    @Test func paintedLeafSizeDoesNotUseTheWholeWindow() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        let window = MacSessionPaneMeasuredSize(width: 2_400, height: 1_400)
        let paintedB = try #require(layout.paintedSize(of: paneB, in: window))
        #expect(abs(paintedB.width - 1_194) < 0.001)
        #expect(paintedB.height == 1_400)
        #expect(paintedB.width < window.width)
    }

    @Test func usablePaneGeometryAllowsASplit() throws {
        var layout = MacSessionPaneLayout(
            initialRoute: route(0),
            paneID: MacSessionPaneID(rawValue: "pane-a")
        )
        try layout.split(
            paneID: layout.focusedPaneID,
            axis: .horizontal,
            newRoute: route(1),
            paneSize: MacSessionPaneMeasuredSize(width: 800, height: 700),
            windowSize: MacSessionPaneMeasuredSize(width: 1_200, height: 800)
        )
        #expect(layout.paneCount == 2)
    }

    @Test func minimumUsefulPaneMatchesNarrowComposerWidth() {
        #expect(
            MacSessionPaneSplitAdmission.minimumPaneWidth
                == Double(MacSessionShellLayoutPolicy.timelineMinimumWidth)
        )
        #expect(MacComposerActionLayout.minimumPaneWidth == MacSessionShellLayoutPolicy.timelineMinimumWidth)
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
            fraction: 0.3,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        try layout.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: route(2),
            newPaneID: paneC,
            splitID: remainingSplit,
            fraction: 0.7,
            paneSize: usefulSize(),
            windowSize: usefulSize()
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
            splitID: outerSplit,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        try layout.split(
            paneID: paneB,
            axis: .vertical,
            newRoute: route(2),
            newPaneID: paneC,
            splitID: innerSplit,
            fraction: 0.65,
            paneSize: usefulSize(),
            windowSize: usefulSize()
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
            splitID: MacSessionPaneSplitID(rawValue: "split-ab"),
            paneSize: usefulSize(),
            windowSize: usefulSize()
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
            fraction: 0.35,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        try layout.split(
            paneID: paneA,
            axis: .vertical,
            newRoute: .workspace(workspaceID: "workspace-c", sessionID: "session-c"),
            newPaneID: paneC,
            splitID: splitAC,
            fraction: 0.55,
            paneSize: usefulSize(),
            windowSize: usefulSize()
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

        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newPaneID: paneB,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )

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
            newPaneID: paneB,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        try layout.focus(paneA)
        try layout.split(
            paneID: paneA,
            axis: .vertical,
            newRoute: nil,
            newPaneID: paneC,
            paneSize: usefulSize(),
            windowSize: usefulSize()
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

    @Test func dividerMovementUpdatesTheStoredFraction() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let splitID = MacSessionPaneSplitID(rawValue: "split-ab")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB,
            splitID: splitID,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )

        try layout.setFraction(0.35, for: splitID)

        #expect(layout.split(id: splitID)?.fraction == 0.35)
        let restored = try JSONDecoder().decode(
            MacSessionPaneLayout.self,
            from: try JSONEncoder().encode(layout)
        )
        #expect(restored.split(id: splitID)?.fraction == 0.35)
        #expect(restored == layout)
    }

    @Test func emptyPaneCodableRoundTripPreservesNilRoute() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .vertical,
            newPaneID: paneB,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )

        let restored = try JSONDecoder().decode(
            MacSessionPaneLayout.self,
            from: try JSONEncoder().encode(layout)
        )

        #expect(restored == layout)
        #expect(restored.pane(id: paneB)?.route == nil)
    }

    @Test func nestedHorizontalChildNeedsTwoLeafMinimaNotOne() throws {
        let paneA = MacSessionPaneID(rawValue: "pane-a")
        let paneB = MacSessionPaneID(rawValue: "pane-b")
        let paneC = MacSessionPaneID(rawValue: "pane-c")
        var layout = MacSessionPaneLayout(initialRoute: route(0), paneID: paneA)
        try layout.split(
            paneID: paneA,
            axis: .horizontal,
            newRoute: route(1),
            newPaneID: paneB,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )
        try layout.split(
            paneID: paneB,
            axis: .horizontal,
            newRoute: route(2),
            newPaneID: paneC,
            paneSize: usefulSize(),
            windowSize: usefulSize()
        )

        guard case .split(let root) = layout.root else {
            Issue.record("expected a root split")
            return
        }
        let firstMin = MacSessionPaneSplitAdmission.subtreeMinimumSize(of: root.first).width
        let secondMin = MacSessionPaneSplitAdmission.subtreeMinimumSize(of: root.second).width
        #expect(firstMin == 320)
        #expect(secondMin == 320 + 12 + 320)

        let squeezedNested = MacSessionPaneSplitAdmission.paintedSplitLengths(
            along: 1_320,
            fraction: 0.75,
            firstMinimum: firstMin,
            secondMinimum: secondMin
        )
        #expect(squeezedNested.first >= 0)
        #expect(squeezedNested.second >= 0)
        #expect(squeezedNested.second + 0.001 >= secondMin || squeezedNested.overflows)
        #expect(squeezedNested.first + 0.001 >= firstMin || squeezedNested.overflows)
    }

    @Test func nestedSplitPaintDoesNotProduceANegativeLeaf() {
        let nestedMin = 320.0 + 12.0 + 320.0
        let painted = MacSessionPaneSplitAdmission.paintedSplitLengths(
            along: 327,
            fraction: 0.5,
            firstMinimum: 320,
            secondMinimum: 320
        )
        #expect(painted.first >= 0)
        #expect(painted.second >= 0)
        #expect(painted.overflows)
        let paintedTotal = painted.first + painted.second + 12.0
        #expect(abs(paintedTotal - nestedMin) < 0.001)
    }

    private func route(_ index: Int) -> MacSessionPaneRoute {
        .workspace(workspaceID: "workspace-\(index)", sessionID: "session-\(index)")
    }

    private func usefulSize() -> MacSessionPaneMeasuredSize {
        MacSessionPaneMeasuredSize(width: 2_400, height: 1_400)
    }
}
