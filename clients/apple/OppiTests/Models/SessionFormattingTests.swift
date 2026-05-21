import Testing
@testable import Oppi

@Suite("SessionFormatting")
struct SessionFormattingTests {

    @Test func compactCountKeepsSmallValuesExact() {
        #expect(SessionFormatting.compactCount(0) == "0")
        #expect(SessionFormatting.compactCount(46) == "46")
        #expect(SessionFormatting.compactCount(999) == "999")
    }

    @Test func compactCountAbbreviatesThousands() {
        #expect(SessionFormatting.compactCount(1_000) == "1k")
        #expect(SessionFormatting.compactCount(1_452) == "1.5k")
        #expect(SessionFormatting.compactCount(12_000) == "12k")
    }

    @Test func compactCountRoundsToNextUnitNearThreshold() {
        #expect(SessionFormatting.compactCount(999_499) == "999k")
        #expect(SessionFormatting.compactCount(999_500) == "1M")
        #expect(SessionFormatting.compactCount(1_500_000) == "1.5M")
    }

    @Test func compactCountPreservesNegativeSign() {
        #expect(SessionFormatting.compactCount(-1_452) == "-1.5k")
    }
}
