import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Tool expansion scroll matrix")
@MainActor
struct ToolExpandScrollMatrixTests {
    @Test(arguments: ToolExpandScrollMatrixCase.unitFamilies)
    func expandingToolRowsDoesNotLockOuterScroll(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandingToolRowsDoesNotLockOuterScroll(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.unitFamilies)
    func collapsingExpandedToolRowsKeepsScrollStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertCollapsingExpandedToolRowsKeepsScrollStable(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.unitFamilies)
    func expandingToolRowsKeepsTappedHeaderPositionStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandingToolRowsKeepsTappedHeaderPositionStable(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.unitFamilies)
    func collapsingToolRowsKeepsAnchoredTopEdgeStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertCollapsingToolRowsKeepsAnchoredTopEdgeStable(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.unitFamilies)
    func expandedToolRowsHaveExpectedHeightEnvelope(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandedToolRowsHaveExpectedHeightEnvelope(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.unitFamilies)
    func expandedToolRowsFollowFullScreenSupportMatrix(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandedToolRowsFollowFullScreenSupportMatrix(toolCase)
    }

    @Test(arguments: TimelineStreamingScrollMatrixCase.allCases)
    func streamingScrollAndRenderingMatrix(_ matrixCase: TimelineStreamingScrollMatrixCase) {
        let runner = TimelineStreamingScrollScenarioRunner(
            sessionSuffix: matrixCase.name,
            followState: matrixCase.followState,
            useAnchoredCollectionView: true
        )

        runner.runRound(
            content: matrixCase.content,
            highlightPhase: matrixCase.phase,
            toolEventID: "matrix-tool-\(matrixCase.name)",
            token: matrixCase.name
        )

        runner.assertFollowTransitions(step: "\(matrixCase.name)-follow")
    }

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

@Suite(
    "Tool expansion scroll matrix remainder families",
    .tags(.perf),
    .enabled(if: ToolExpandScrollMatrixCase.runPerfFamilies)
)
@MainActor
struct ToolExpandScrollMatrixPerfFamilyTests {
    @Test(arguments: ToolExpandScrollMatrixCase.perfFamilies)
    func expandingToolRowsDoesNotLockOuterScroll(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandingToolRowsDoesNotLockOuterScroll(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.perfFamilies)
    func collapsingExpandedToolRowsKeepsScrollStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertCollapsingExpandedToolRowsKeepsScrollStable(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.perfFamilies)
    func expandingToolRowsKeepsTappedHeaderPositionStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandingToolRowsKeepsTappedHeaderPositionStable(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.perfFamilies)
    func collapsingToolRowsKeepsAnchoredTopEdgeStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertCollapsingToolRowsKeepsAnchoredTopEdgeStable(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.perfFamilies)
    func expandedToolRowsHaveExpectedHeightEnvelope(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandedToolRowsHaveExpectedHeightEnvelope(toolCase)
    }

    @Test(arguments: ToolExpandScrollMatrixCase.perfFamilies)
    func expandedToolRowsFollowFullScreenSupportMatrix(_ toolCase: ToolExpandScrollMatrixCase) throws {
        try assertExpandedToolRowsFollowFullScreenSupportMatrix(toolCase)
    }
}

@MainActor
private func assertExpandingToolRowsDoesNotLockOuterScroll(
    _ toolCase: ToolExpandScrollMatrixCase
) throws {
    let fixture = try #require(
        ToolExpandScrollMatrixFixture.make(
            for: toolCase,
            sessionSuffix: "expand",
            useAnchoredCollectionView: true
        )
    )

    fixture.prepareDetachedViewport()
    let topScreenYBefore = fixture.targetTopScreenY()

    fixture.expandTarget()
    fixture.assertExpandedInnerScrollViewsDoNotCompeteForVerticalScroll()

    // Top-edge anchoring: the tapped header should stay in place while
    // expansion grows downward.
    if let before = topScreenYBefore, let after = fixture.targetTopScreenY() {
        let topDrift = abs(after - before)
        #expect(topDrift < 8.0,
                "Header drifted \(topDrift)pt on expand for \(toolCase.name)")
    }
    let offsetAfterExpand = fixture.offsetY

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
private func assertCollapsingExpandedToolRowsKeepsScrollStable(
    _ toolCase: ToolExpandScrollMatrixCase
) throws {
    let fixture = try #require(
        ToolExpandScrollMatrixFixture.make(
            for: toolCase,
            sessionSuffix: "collapse",
            useAnchoredCollectionView: true
        )
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
private func assertExpandingToolRowsKeepsTappedHeaderPositionStable(
    _ toolCase: ToolExpandScrollMatrixCase
) throws {
    let fixture = try #require(
        ToolExpandScrollMatrixFixture.make(
            for: toolCase,
            sessionSuffix: "expand-anchored",
            useAnchoredCollectionView: true
        )
    )

    fixture.prepareDetachedViewport()
    let topScreenYBefore = fixture.targetTopScreenY()

    fixture.expandTarget()

    // Top-edge anchoring: the header stays in place so the row opens down.
    if let before = topScreenYBefore, let after = fixture.targetTopScreenY() {
        let topDrift = abs(after - before)
        #expect(topDrift < 8.0,
                "Anchored expand header drifted \(topDrift)pt for \(toolCase.name)")
    }
}

@MainActor
private func assertCollapsingToolRowsKeepsAnchoredTopEdgeStable(
    _ toolCase: ToolExpandScrollMatrixCase
) throws {
    let fixture = try #require(
        ToolExpandScrollMatrixFixture.make(
            for: toolCase,
            sessionSuffix: "collapse-anchored",
            useAnchoredCollectionView: true
        )
    )

    fixture.prepareDetachedViewport()
    fixture.expandTarget()
    let topScreenYBeforeCollapse = fixture.targetTopScreenY()

    fixture.collapseTarget()

    // Top-edge anchoring: the header stays in place while the expanded
    // body shrinks below it.
    if let before = topScreenYBeforeCollapse, let after = fixture.targetTopScreenY() {
        let topDrift = abs(after - before)
        #expect(topDrift < 8.0,
                "Anchored collapse top-edge drifted \(topDrift)pt for \(toolCase.name)")
    }
}

@MainActor
private func assertExpandedToolRowsHaveExpectedHeightEnvelope(
    _ toolCase: ToolExpandScrollMatrixCase
) throws {
    let fixture = try #require(
        ToolExpandScrollMatrixFixture.make(for: toolCase, sessionSuffix: "height-envelope")
    )

    fixture.prepareDetachedViewport()
    fixture.expandTarget()
    let cell = try #require(fixture.collectionView.cellForItem(at: fixture.targetIndexPath))
    let height = cell.frame.height

    switch toolCase {
    case .voiceStreamingText, .voiceFinalCard:
        #expect(height < 260, "Voice rows should be compact, got \(height)pt")
    case .extensionMutation, .extensionStructured, .extensionMarkdown, .extensionLookup, .customText:
        #expect(height < 520, "Custom extension rows should stay bounded, got \(height)pt")
    case .writeCode, .readCode, .bashOutput, .editDiff, .readMarkdown, .readMedia:
        #expect(height < 760, "Expanded tool row exceeded viewport envelope, got \(height)pt")
    }
}

@MainActor
private func assertExpandedToolRowsFollowFullScreenSupportMatrix(
    _ toolCase: ToolExpandScrollMatrixCase
) throws {
    let fixture = try #require(
        ToolExpandScrollMatrixFixture.make(for: toolCase, sessionSuffix: "fullscreen")
    )

    fixture.prepareDetachedViewport()
    fixture.expandTarget()

    let item = try #require(fixture.items.first { $0.id == toolCase.targetItemID })
    let config = try #require(
        fixture.harness.coordinator.toolRowConfiguration(itemID: toolCase.targetItemID, item: item)
            as? ToolTimelineRowConfiguration
    )
    let expandedContent = try #require(config.expandedContent)
    let policy = ToolTimelineRowInteractionPolicy.forExpandedContent(expandedContent, isDone: config.isDone)

    #expect(policy.supportsFullScreenPreview == toolCase.expectedSupportsFullScreenPreview)

    let fullScreenContent = ToolTimelineRowFullScreenSupport.fullScreenContent(
        configuration: config,
        outputCopyText: config.copyOutputText,
        interactionPolicy: policy,
        terminalStream: nil,
        sourceStream: nil
    )
    #expect((fullScreenContent != nil) == toolCase.expectedSupportsFullScreenPreview)
}
