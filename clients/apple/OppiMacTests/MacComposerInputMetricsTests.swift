import AppKit
import Testing
@testable import Oppi

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
