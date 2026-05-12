import Testing
@testable import Oppi

@Suite("SessionRowMetricsFormatting")
struct SessionRowMetricsFormattingTests {
    @Test func lineDelta_showsAddedAndRemoved() {
        let stats = SessionChangeStats(
            mutatingToolCalls: 1,
            filesChanged: 4,
            changedFiles: [],
            addedLines: 20,
            removedLines: 151
        )

        let result = SessionRowMetricsFormatting.lineDelta(stats)

        #expect(result?.addedText == "+20")
        #expect(result?.removedText == "-151")
        #expect(result?.accessibilityLabel == "20 lines added, 151 lines removed")
    }

    @Test func lineDelta_hidesWhenNoLineChanges() {
        let stats = SessionChangeStats(
            mutatingToolCalls: 1,
            filesChanged: 1,
            changedFiles: [],
            addedLines: 0,
            removedLines: 0
        )

        #expect(SessionRowMetricsFormatting.lineDelta(stats) == nil)
    }

    @Test func filesTouchedAccessibilityLabel_pluralizes() {
        #expect(SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(1) == "1 file touched")
        #expect(SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(4) == "4 files touched")
    }

    @Test func compactionAccessibilityLabel_pluralizes() {
        #expect(SessionRowMetricsFormatting.compactionAccessibilityLabel(1) == "1 compaction")
        #expect(SessionRowMetricsFormatting.compactionAccessibilityLabel(2) == "2 compactions")
    }
}
