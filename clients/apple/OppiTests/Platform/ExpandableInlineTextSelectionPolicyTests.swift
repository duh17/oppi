import Testing
@testable import Oppi

@Suite("Expandable inline text selection policy")
struct ExpandableInlineTextSelectionPolicyTests {
    @Test func disablesInlineSelectionWhenFullScreenAffordanceExists() {
        #expect(!ExpandableInlineTextSelectionPolicy.allowsInlineSelection(hasFullScreenAffordance: true))
    }

    @Test func keepsInlineSelectionWhenNoFullScreenAffordanceExists() {
        #expect(ExpandableInlineTextSelectionPolicy.allowsInlineSelection(hasFullScreenAffordance: false))
    }
}
