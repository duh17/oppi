import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Tool expansion scroll matrix")
@MainActor
struct ToolExpandScrollMatrixTests {
    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func expandingToolRowsDoesNotLockOuterScroll(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(for: toolCase, sessionSuffix: "expand")
        )

        fixture.prepareDetachedViewport()
        let bottomScreenYBefore = fixture.targetBottomScreenY()

        fixture.expandTarget()
        fixture.assertExpandedInnerScrollViewsDoNotCompeteForVerticalScroll()

        // Bottom-edge anchoring: the bottom of the cell should stay at
        // the same screen position after expansion (expand grows upward).
        if let before = bottomScreenYBefore, let after = fixture.targetBottomScreenY() {
            let bottomDrift = abs(after - before)
            #expect(bottomDrift < 8.0,
                    "Bottom-edge drifted \(bottomDrift)pt for \(toolCase.name)")
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

    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func expandingToolRowsKeepsAnchoredBottomEdgeStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(
                for: toolCase,
                sessionSuffix: "expand-anchored",
                useAnchoredCollectionView: true
            )
        )

        fixture.prepareDetachedViewport()
        let bottomScreenYBefore = fixture.targetBottomScreenY()

        fixture.expandTarget()

        // Bottom-edge anchoring: the bottom of the cell stays in place.
        if let before = bottomScreenYBefore, let after = fixture.targetBottomScreenY() {
            let bottomDrift = abs(after - before)
            #expect(bottomDrift < 8.0,
                    "Anchored expand bottom-edge drifted \(bottomDrift)pt for \(toolCase.name)")
        }
    }

    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func collapsingToolRowsKeepsAnchoredBottomEdgeStable(_ toolCase: ToolExpandScrollMatrixCase) throws {
        let fixture = try #require(
            ToolExpandScrollMatrixFixture.make(
                for: toolCase,
                sessionSuffix: "collapse-anchored",
                useAnchoredCollectionView: true
            )
        )

        fixture.prepareDetachedViewport()
        fixture.expandTarget()
        let bottomScreenYBeforeCollapse = fixture.targetBottomScreenY()

        fixture.collapseTarget()

        // Bottom-edge anchoring: the bottom of the cell stays in place.
        if let before = bottomScreenYBeforeCollapse, let after = fixture.targetBottomScreenY() {
            let bottomDrift = abs(after - before)
            #expect(bottomDrift < 8.0,
                    "Anchored collapse bottom-edge drifted \(bottomDrift)pt for \(toolCase.name)")
        }
    }

    @Test(arguments: ToolExpandScrollMatrixCase.allCases)
    func expandedToolRowsHaveExpectedHeightEnvelope(_ toolCase: ToolExpandScrollMatrixCase) throws {
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
