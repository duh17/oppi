import Testing
@testable import Oppi

@Suite("Timeline expandable text interaction spec")
struct TimelineExpandableTextInteractionSpecTests {
    @Test func noSelectedTextAndNoFullScreenDisablesEverything() {
        let spec = TimelineExpandableTextInteractionSpec.build(
            hasSelectedTextContext: false,
            supportsFullScreenPreview: false
        )

        #expect(!spec.inlineSelectionEnabled)
        #expect(!spec.enablesTapActivation)
        #expect(!spec.enablesPinchActivation)
        #expect(!spec.supportsFullScreenPreview)
    }

    @Test func selectedTextWithoutFullScreenEnablesInlineSelectionOnly() {
        let spec = TimelineExpandableTextInteractionSpec.build(
            hasSelectedTextContext: true,
            supportsFullScreenPreview: false
        )

        #expect(spec.inlineSelectionEnabled)
        #expect(!spec.enablesTapActivation)
        #expect(!spec.enablesPinchActivation)
        #expect(!spec.supportsFullScreenPreview)
    }

    @Test func fullScreenPreferredDisablesInlineSelectionAndEnablesActivation() {
        let spec = TimelineExpandableTextInteractionSpec.build(
            hasSelectedTextContext: true,
            supportsFullScreenPreview: true
        )

        #expect(!spec.inlineSelectionEnabled)
        #expect(spec.enablesTapActivation)
        #expect(spec.enablesPinchActivation)
        #expect(spec.supportsFullScreenPreview)
    }
}
