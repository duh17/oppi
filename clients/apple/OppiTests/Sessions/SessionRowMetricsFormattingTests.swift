import Testing
@testable import Oppi

@Suite("SessionRowMetricsFormatting")
struct SessionRowMetricsFormattingTests {
    @Test func filesTouchedAccessibilityLabel_pluralizes() {
        #expect(SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(1) == "1 file touched")
        #expect(SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(4) == "4 files touched")
    }

    @Test func compactionAccessibilityLabel_pluralizes() {
        #expect(SessionRowMetricsFormatting.compactionAccessibilityLabel(1) == "1 compaction")
        #expect(SessionRowMetricsFormatting.compactionAccessibilityLabel(2) == "2 compactions")
    }
}
