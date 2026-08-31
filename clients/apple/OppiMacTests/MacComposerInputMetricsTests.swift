import AppKit
import Testing
@testable import Oppi

@Suite("Mac composer writing tools affordance")
@MainActor
struct MacComposerWritingToolsAffordanceTests {
    @Test func hidesAffordanceWithoutDisablingWritingTools() {
        let textView = MacComposerPasteTextView()
        MacComposerPasteTextView.hideWritingToolsAffordance(on: textView)

        #expect(textView.value(forKey: "allowsWritingToolsAffordance") as? Bool == false)
        #expect(textView.writingToolsBehavior == .default)
        #expect(textView.isEditable == true)
        #expect(textView.acceptsFirstResponder == true)
    }
}

@Suite("Mac composer input sizing")
struct MacComposerInputMetricsTests {
    @Test func emptyDraftUsesOneCompactLine() {
        let height = MacComposerInputMetrics.fittedHeight(
            text: "",
            font: .systemFont(ofSize: 13),
            width: 320
        )

        #expect(height == MacComposerInputMetrics.minimumHeight)
    }

    @Test func multilineDraftGrowsOnlyToTheScrollLimit() {
        let height = MacComposerInputMetrics.fittedHeight(
            text: Array(repeating: "A full line of composer text", count: 40).joined(separator: "\n"),
            font: .systemFont(ofSize: 13),
            width: 240
        )

        #expect(height == MacComposerInputMetrics.maximumHeight)
    }
}
