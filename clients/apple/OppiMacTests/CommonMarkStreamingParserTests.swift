import Testing
@testable import Oppi

@Suite("CommonMark streaming parser")
struct CommonMarkStreamingParserTests {
    @Test func appendParsesOnlyTheUnfinalizedTail() {
        var parser = CommonMarkStreamingParser()
        let initialSource = """
        Finalized paragraph.

        Streaming tail
        """
        let initial = parser.parse(initialSource)
        #expect(initial.strategy == .full)
        #expect(initial.blocks == parseCommonMark(initialSource))

        let appendedSource = initialSource + " grows."
        let appended = parser.parse(appendedSource)
        #expect(appended.strategy == .tailOnly)
        #expect(appended.blocks == parseCommonMark(appendedSource))
    }

    @Test(arguments: [
        "See [the guide].\n\n[the guide]: https://example.com",
        "Before math.\n\n$$x^2$$",
        #"Before math.\n\n\[x^2\]"#,
    ])
    func definitionsAndDisplayMathFailClosedToFullParse(source: String) {
        var parser = CommonMarkStreamingParser()
        _ = parser.parse("Finalized paragraph.\n\nStreaming tail")

        let result = parser.parse(source)

        #expect(result.strategy == .full)
        #expect(result.blocks == parseCommonMark(source))
    }

    @Test func rewrittenLongerPrefixFallsBackToFullParse() {
        var parser = CommonMarkStreamingParser()
        let initialSource = """
        Finalized paragraph.

        Streaming tail
        """
        let initial = parser.parse(initialSource)
        #expect(initial.strategy == .full)
        #expect(!initial.prefixBlocks.isEmpty)

        let rewrittenSource = """
        Completely different lead paragraph.

        Streaming tail grows with a new prefix.
        """
        #expect(rewrittenSource.utf8.count > initialSource.utf8.count)

        let rewritten = parser.parse(rewrittenSource)
        #expect(rewritten.strategy == .full)
        #expect(rewritten.blocks == parseCommonMark(rewrittenSource))
    }

    @Test func sameLengthReplacementFallsBackToFullParse() {
        var parser = CommonMarkStreamingParser()
        let initialSource = "Alpha paragraph.\n\nStreaming tail"
        let rewrittenSource = "Omega paragraph.\n\nStreaming tail"
        #expect(initialSource.utf8.count == rewrittenSource.utf8.count)

        let initial = parser.parse(initialSource)
        #expect(initial.strategy == .full)
        #expect(!initial.prefixBlocks.isEmpty)

        let rewritten = parser.parse(rewrittenSource)
        #expect(rewritten.strategy == .full)
        #expect(rewritten.blocks == parseCommonMark(rewrittenSource))
    }
}
