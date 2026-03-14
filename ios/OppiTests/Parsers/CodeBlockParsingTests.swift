import Testing
@testable import Oppi

@Suite("lineNumberInfo")
struct LineNumberInfoTests {

    @Test func singleLine() {
        let (numbers, _) = lineNumberInfo(lineCount: 1, startLine: 1)
        #expect(numbers == "1")
    }

    @Test func multipleLines() {
        let (numbers, _) = lineNumberInfo(lineCount: 3, startLine: 1)
        #expect(numbers == "1\n2\n3")
    }

    @Test func startLineOffset() {
        let (numbers, _) = lineNumberInfo(lineCount: 3, startLine: 10)
        #expect(numbers == "10\n11\n12")
    }

    @Test func gutterWidthScalesWithDigits() {
        let (_, width1) = lineNumberInfo(lineCount: 1, startLine: 1)
        let (_, width3) = lineNumberInfo(lineCount: 100, startLine: 1)
        #expect(width3 > width1)
    }

    @Test func minimumTwoDigitWidth() {
        let (_, width) = lineNumberInfo(lineCount: 1, startLine: 1)
        #expect(width == 15.0)
    }

    @Test func threeDigitWidth() {
        let (_, width) = lineNumberInfo(lineCount: 100, startLine: 1)
        #expect(width == 22.5)
    }

    @Test func highStartLine() {
        let (numbers, width) = lineNumberInfo(lineCount: 2, startLine: 999)
        #expect(numbers == "999\n1000")
        #expect(width == 30.0)
    }
}
