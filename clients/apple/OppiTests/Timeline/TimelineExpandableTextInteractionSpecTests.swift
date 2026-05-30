import Testing
@testable import Oppi

@Suite("Timeline expandable text interaction spec")
struct ExpandableTextInteractionSpecTests {
    @Test func noReviewCommentContextAndNoFullScreenDisablesEverything() {
        let spec = TimelineExpandableTextInteractionSpec.build(
            hasReviewCommentContext: false,
            supportsFullScreenPreview: false
        )

        #expect(!spec.inlineSelectionEnabled)
        #expect(!spec.enablesTapActivation)
        #expect(!spec.enablesPinchActivation)
        #expect(!spec.supportsFullScreenPreview)
    }

    @Test func reviewCommentContextWithoutFullScreenEnablesInlineSelectionOnly() {
        let spec = TimelineExpandableTextInteractionSpec.build(
            hasReviewCommentContext: true,
            supportsFullScreenPreview: false
        )

        #expect(spec.inlineSelectionEnabled)
        #expect(!spec.enablesTapActivation)
        #expect(!spec.enablesPinchActivation)
        #expect(!spec.supportsFullScreenPreview)
    }

    @Test func fullScreenPreferredDisablesInlineSelectionAndEnablesActivation() {
        let spec = TimelineExpandableTextInteractionSpec.build(
            hasReviewCommentContext: true,
            supportsFullScreenPreview: true
        )

        #expect(!spec.inlineSelectionEnabled)
        #expect(spec.enablesTapActivation)
        #expect(spec.enablesPinchActivation)
        #expect(spec.supportsFullScreenPreview)
    }
}
