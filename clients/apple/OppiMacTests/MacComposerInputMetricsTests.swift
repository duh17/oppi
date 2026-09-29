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
    @Test func emptyDraftUsesOneLineOfTheInputFont() {
        let font = NSFont.systemFont(ofSize: 15)
        let height = MacComposerInputMetrics.fittedHeight(text: "", font: font, width: 320)

        #expect(height == MacComposerInputMetrics.minimumHeight(for: font))
    }

    @Test func multilineDraftGrowsOnlyToTheScrollLimit() {
        let font = NSFont.systemFont(ofSize: 15)
        let height = MacComposerInputMetrics.fittedHeight(
            text: Array(repeating: "A full line of composer text", count: 40).joined(separator: "\n"),
            font: font,
            width: 240
        )

        #expect(height == MacComposerInputMetrics.maximumHeight(for: font))
    }

    @Test func zoomedInputKeepsTheSameVisibleLineCount() {
        let small = NSFont.systemFont(ofSize: 13)
        let large = NSFont.systemFont(ofSize: 20)
        let smallLines = MacComposerInputMetrics.maximumHeight(for: small)
            / MacComposerInputMetrics.minimumHeight(for: small)
        let largeLines = MacComposerInputMetrics.maximumHeight(for: large)
            / MacComposerInputMetrics.minimumHeight(for: large)

        #expect(MacComposerInputMetrics.minimumHeight(for: large) > MacComposerInputMetrics.minimumHeight(for: small))
        #expect(abs(smallLines - largeLines) < 0.2)
    }
}
