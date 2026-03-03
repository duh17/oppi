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
        fixture.assertExpandedInnerScrollViewsDoNotCompeteForVerticalScroll()

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

    @MainActor
    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func expandingToolRowsKeepsAnchoredOffsetStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(
                for: toolCase,
                sessionSuffix: "expand-anchored",
                useAnchoredCollectionView: true
            )
        )

        fixture.prepareDetachedViewport()
        let offsetBeforeExpand = fixture.offsetY

        fixture.expandTarget()

        let offsetAfterExpand = fixture.offsetY
        let expandDrift = abs(offsetAfterExpand - offsetBeforeExpand)
        #expect(expandDrift < 8.0,
                "Anchored expand drifted \(expandDrift)pt for \(toolCase.name)")
    }

    @MainActor
    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func collapsingToolRowsKeepsAnchoredOffsetStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(
                for: toolCase,
                sessionSuffix: "collapse-anchored",
                useAnchoredCollectionView: true
            )
        )

        fixture.prepareDetachedViewport()
        fixture.expandTarget()
        let offsetBeforeCollapse = fixture.offsetY

        fixture.collapseTarget()

        let offsetAfterCollapse = fixture.offsetY
        let collapseDrift = abs(offsetAfterCollapse - offsetBeforeCollapse)
        #expect(collapseDrift < 8.0,
                "Anchored collapse drifted \(collapseDrift)pt for \(toolCase.name)")
    }

    @MainActor
    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func expandedToolRowsFollowFullScreenSupportMatrix(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(for: toolCase, sessionSuffix: "fullscreen")
        )

        fixture.prepareDetachedViewport()
        fixture.expandTarget()

        let item = try #require(fixture.items.first { $0.id == toolCase.targetItemID })
        let config = try #require(
            fixture.harness.coordinator.toolRowConfiguration(itemID: toolCase.targetItemID, item: item)
        )
        let expandedContent = try #require(config.expandedContent)
        let policy = ToolTimelineRowInteractionPolicy.forExpandedContent(expandedContent)

        #expect(policy.supportsFullScreenPreview == toolCase.expectedSupportsFullScreenPreview)

        let fullScreenContent = ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: config,
            outputCopyText: config.copyOutputText,
            interactionPolicy: policy,
            terminalStream: nil
        )
        #expect((fullScreenContent != nil) == toolCase.expectedSupportsFullScreenPreview)
    }

    @MainActor
    @Test(arguments: TimelineStreamingScrollMatrixCase.allCases)
    func streamingScrollAndRenderingMatrix(_ matrixCase: TimelineStreamingScrollMatrixCase) {
        let runner = TimelineStreamingScrollScenarioRunner(
            sessionSuffix: matrixCase.name,
            followState: matrixCase.followState,
            useAnchoredCollectionView: matrixCase.followState == .detachedFollow
        )

        runner.runRound(
            content: matrixCase.content,
            highlightPhase: matrixCase.phase,
            toolEventID: "matrix-tool-\(matrixCase.name)",
            token: matrixCase.name
        )

        runner.assertFollowTransitions(step: "\(matrixCase.name)-follow")
    }

    @MainActor
    @Test func longDeterministicMixedContentStressScenario() {
        let runner = TimelineStreamingScrollScenarioRunner(
            sessionSuffix: "long-stress",
            followState: .detachedFollow,
            useAnchoredCollectionView: true
        )

        for round in 0..<18 {
            let content = TimelineStreamingContentKind.allCases[
                round % TimelineStreamingContentKind.allCases.count
            ]
            let phase = TimelineStreamingPhase.allCases[
                (round / 2) % TimelineStreamingPhase.allCases.count
            ]
            let token = "stress-\(round)-\(content.name)-\(phase.name)"

            runner.runRound(
                content: content,
                highlightPhase: phase,
                toolEventID: "stress-tool-\(round)",
                token: token
            )

            if round.isMultiple(of: 4) {
                runner.assertFollowTransitions(step: "stress-follow-\(round)")
            }
        }

        #expect(runner.harness.reducer.items.count > 50)
        #expect(timelineDuplicateIDs(in: runner.harness.reducer.items).isEmpty)
        #expect(!runner.harness.scrollController.isCurrentlyNearBottom)
    }
}
