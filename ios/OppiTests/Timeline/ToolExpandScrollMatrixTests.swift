import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Tool expansion scroll matrix")
struct ToolExpandScrollMatrixTests {
    @MainActor
    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func expandingToolRowsDoesNotLockOuterScroll(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(for: toolCase, sessionSuffix: "expand")
        )

        fixture.prepareDetachedViewport()
        let offsetBeforeExpand = fixture.offsetY

        fixture.expandTarget()
        fixture.assertExpandedInnerScrollViewsDoNotBounceVertically()

        let offsetAfterExpand = fixture.offsetY
        let expandDrift = abs(offsetAfterExpand - offsetBeforeExpand)
        #expect(expandDrift < 8.0,
                "Expand drifted \(expandDrift)pt for \(toolCase.name)")

        let upwardTarget = fixture.clampOffsetY(offsetAfterExpand - 220)
        fixture.setOffsetY(upwardTarget)
        let upwardDrift = abs(fixture.offsetY - upwardTarget)
        #expect(upwardDrift < 5.0,
                "Scroll up snapped by \(upwardDrift)pt for \(toolCase.name)")

        let downwardTarget = fixture.clampOffsetY(offsetAfterExpand + 220)
        fixture.setOffsetY(downwardTarget)
        let downwardDrift = abs(fixture.offsetY - downwardTarget)
        #expect(downwardDrift < 5.0,
                "Scroll down snapped by \(downwardDrift)pt for \(toolCase.name)")
    }

    @MainActor
    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func collapsingExpandedToolRowsKeepsScrollStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(for: toolCase, sessionSuffix: "collapse")
        )

        fixture.prepareDetachedViewport()
        fixture.expandTarget()
        fixture.collapseTarget()

        let offsetAfterCollapse = fixture.offsetY

        let upwardTarget = fixture.clampOffsetY(offsetAfterCollapse - 280)
        fixture.setOffsetY(upwardTarget)
        let upwardDrift = abs(fixture.offsetY - upwardTarget)
        #expect(upwardDrift < 5.0,
                "Post-collapse upward scroll snapped by \(upwardDrift)pt for \(toolCase.name)")

        let downwardTarget = fixture.clampOffsetY(offsetAfterCollapse + 180)
        fixture.setOffsetY(downwardTarget)
        let downwardDrift = abs(fixture.offsetY - downwardTarget)
        #expect(downwardDrift < 5.0,
                "Post-collapse downward scroll snapped by \(downwardDrift)pt for \(toolCase.name)")
    }
}
