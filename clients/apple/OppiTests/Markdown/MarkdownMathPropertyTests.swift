import Foundation
import Testing
@testable import Oppi

/// Laws the Markdown parser keeps for every corpus document
/// (`MarkdownCorpus`), and the math delimiter rules as a table.
@Suite("Markdown math rules and parser laws")
struct MarkdownMathPropertyTests {
    // MARK: - Delimiter rules

    /// Input, then the TeX of each formula the parser finds, in order.
    private static let ruleCases: [(String, [String])] = [
        ("Cost went from $7.76 to $49.56 (+$41.80).", []),
        ("Between $5 and $10, or (USD$3 - USD$4).", []),
        ("export PATH=$PATH:$HOME/bin", []),
        ("The $USD/$EUR rate and $x,$y pairs.", []),
        ("Take $x$2 times and $n$th item.", []),
        ("Then $n$-th, $x$. and ($y$)", ["n", "x", "y"]),
        ("a $x + y $ b and c $ x+y$ d.", []),
        (#"Costs \$5 and \$x$ but $a+b$."#, ["a+b"]),
        (#"Escaped closer $a\$b$ ends at the second."#, [#"a\$b"#]),
        ("Adjacent $$ and $$$ are not inline math.", []),
        ("Inline $$a*b*c$$ display and $x^2$.", ["a*b*c", "x^2"]),
        (#"Paren \(p*q*r\) and \\(not\\) and \(\)."#, ["p*q*r"]),
        ("Code `$x$` stays and $y$ does not.", ["y"]),
        ("价格 $5 到 $10，公式 $x^2$。", ["x^2"]),
        ("$x$é and $y$1 and $z$😀", ["z"]),
        ("😀$x_😀$😀", ["x_😀"]),
        ("$x[1]*y*z$ and $a[i](j)$", ["x[1]*y*z", "a[i](j)"]),
    ]

    @Test(arguments: ruleCases)
    func formulasFollowTheDelimiterRules(source: String, formulas: [String]) {
        #expect(Self.formulas(in: parseCommonMark(source)) == formulas, "\(source)")
    }

    @Test func displayBlocksOpenInsideQuotesAndListsAndReportClosure() {
        let blocks = parseCommonMark("> $$\n> a*b\n> $$\n\n1. step\n\n    $$\n    c\n    $$\n\n$$\nopen")
        guard case .blockQuote(let quoted) = blocks.first,
              case .math(let quote, true)? = quoted.first,
              case .orderedList(_, let items) = blocks.dropFirst().first,
              case .math(let listed, true)? = items.first?.last,
              case .math(let open, false) = blocks.last else {
            Issue.record("Expected quoted, listed and open math blocks, got \(blocks)")
            return
        }
        #expect([quote.latex, listed.latex, open.latex] == ["a*b", "c", "open"])
    }

    // MARK: - Streaming equals canonical

    @Test(arguments: [1, 7, 64])
    func streamingEveryCorpusDocumentEndsAtTheCanonicalParse(chunk: Int) {
        for entry in MarkdownCorpus.cases() where !entry.isOrg {
            Self.expectStreamingMatchesCanonical(entry.source, chunk: chunk, label: entry.name)
        }
    }

    @Test func streamingRandomCorpusConcatenationsEndAtTheCanonicalParse() {
        let sources = MarkdownCorpus.cases().filter { !$0.isOrg && $0.source.utf8.count < 4_000 }.map(\.source)
        var random = SeededGenerator(seed: 0x5EED)
        for round in 0 ..< 24 {
            let document = (0 ..< 3).map { _ in sources[Int(random.next() % UInt64(sources.count))] }
                .joined(separator: "\n\n")
            Self.expectStreamingMatchesCanonical(document, chunk: 1 + Int(random.next() % 40), label: "round \(round)")
        }
    }

    /// A table at the open tail resumes from its last finished row; every tick
    /// must still read exactly as a fresh parse of the text so far, including
    /// lazy rows, cells with math, escaped pipes and wiki links, and a table
    /// that a heading or a blank line ends.
    @Test(arguments: [1, 7, 64])
    func streamedTableReadsLikeAFreshParseOnEveryTick(chunk: Int) {
        let rows = (0 ..< 30).map { "| `src/f\($0).swift` | $\($0).50 | $x_{\($0)}$ | [[docs/n\($0).md|n\($0)]] \\| x |" }
        let source = """
        | File | Cost | Formula | Note |
        | --- | ---: | :---: | --- |
        \(rows.joined(separator: "\n"))
        lazy row without pipes
        | after | lazy | row | here |
        ## A heading ends it

        Prose before.

        Tree | Files
        —— | ——
        \(rows.prefix(8).joined(separator: "\n"))

        After the blank line.
        """
        var parser = CommonMarkStreamingParser()
        let bytes = Array(source.utf8)
        var end = 0
        var resumedAlignedTicks = 0
        while end < bytes.count {
            end = min(bytes.count, end + chunk)
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            let prefix = String(decoding: bytes[..<end], as: UTF8.self)
            let result = parser.parse(prefix)
            let streamed = result.blocks
            guard streamed == parseCommonMarkTail(prefix).blocks else {
                Issue.record("chunk \(chunk): tick at byte \(end) differs from a fresh parse")
                return
            }
            // A tick resumed from the checkpoint keeps the delimiter row's
            // alignments, not only its cells.
            if result.openTableUnchangedRows > 0, case .table(let headers, _, let alignments)? = streamed.last, headers.count == 4 {
                #expect(alignments == [nil, .right, .center, nil], "chunk \(chunk): byte \(end)")
                resumedAlignedTicks += 1
            }
        }
        #expect(resumedAlignedTicks > 0, "chunk \(chunk): no tick resumed the aligned table")
    }

    // MARK: - No math in code

    @Test func noCorpusLineFindsMathInsideACodeSpanOrFence() {
        for entry in MarkdownCorpus.cases() where !entry.isOrg {
            let fence = String(repeating: "`", count: Self.longestRun(of: "`", in: entry.source) + 3)
            #expect(Self.formulas(in: parseCommonMark("\(fence)\n\(entry.source)\n\(fence)")).isEmpty, "\(entry.name) fenced")
            for line in entry.source.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let ticks = String(repeating: "`", count: Self.longestRun(of: "`", in: String(line)) + 1)
                let source = "Before \(ticks) \(line) \(ticks) after"
                #expect(Self.formulas(in: parseCommonMark(source)).isEmpty, "\(entry.name): \(line)")
            }
        }
    }

    // MARK: - Linear time

    @Test func parseTimeGrowsLinearlyWithFormulaCount() {
        let unit = (0 ..< 50).map { "Line \($0) has **bold**, `code` and $x_{\($0)}$; it costs $5 and $10.\n" }
            .joined(separator: "\n")
        func time(_ copies: Int) -> Duration {
            let source = String(repeating: unit + "\n", count: copies)
            let clock = ContinuousClock()
            return (0 ..< 3).map { _ in clock.measure { _ = parseCommonMark(source) } }.min() ?? .zero
        }
        _ = time(1)
        let one = time(1)
        let sixteen = time(16)
        // Linear is 16x; a quadratic path is 256x. The slack absorbs a busy machine.
        #expect(sixteen < one * 48 + .milliseconds(5), "1 copy \(one), 16 copies \(sixteen)")
    }

    // MARK: - Helpers

    @Test func blockIdentityIsTheStartOffsetAndSurvivesGrowth() {
        var parser = CommonMarkStreamingParser()
        _ = parser.parse("Alpha\n\n## Be")
        let growing = parser.parse("Alpha\n\n## Beta\n\n- c")
        #expect(growing.blockIDs == [0, 7, 16])
        // The paragraph becomes a setext heading and keeps its identity.
        let paragraph = parser.parse("Alpha\n\n## Beta\n\n- c\n\nGamma")
        #expect(paragraph.blockIDs.last == 21)
        let changedKind = parser.parse("Alpha\n\n## Beta\n\n- c\n\nGamma\n===")
        #expect(changedKind.blockIDs == [0, 7, 16, 21])
        guard case .heading(1, _)? = changedKind.blocks.last else {
            Issue.record("Expected a setext heading, got \(changedKind.blocks)")
            return
        }
    }

    private static func expectStreamingMatchesCanonical(_ source: String, chunk: Int, label: String) {
        let canonical = parseCommonMarkLocated(source).map(\.block)
        var fresh = CommonMarkStreamingParser()
        let canonicalIDs = fresh.parse(source).blockIDs
        var parser = CommonMarkStreamingParser()
        let bytes = Array(source.utf8)
        var end = 0
        var last: [MarkdownBlock] = []
        // A link-reference definition changes blocks before it; the parser
        // reparses everything once it arrives, so only the end must match.
        let isRetroactive = source.contains("]:")
        while end < bytes.count {
            end = min(bytes.count, end + chunk)
            // A chunk boundary inside a scalar is not a string the stream sends.
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            let result = parser.parse(String(decoding: bytes[..<end], as: UTF8.self))
            last = result.blocks
            if end == bytes.count || isRetroactive { continue }
            #expect(
                Array(canonical.prefix(result.prefixBlocks.count)) == result.prefixBlocks,
                "\(label) chunk \(chunk): frozen blocks at byte \(end) are not the final ones"
            )
            #expect(
                Array(canonicalIDs.prefix(result.prefixBlocks.count)) == Array(result.blockIDs.prefix(result.prefixBlocks.count)),
                "\(label) chunk \(chunk): frozen block identities at byte \(end) are not the final ones"
            )
        }
        #expect(last == canonical, "\(label) chunk \(chunk): stream ends unlike the canonical parse")
    }

    static func formulas(in blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .math(let math, _): [math.latex]
            case .paragraph(let inlines), .heading(_, let inlines): formulas(in: inlines)
            case .blockQuote(let children): formulas(in: children)
            case .unorderedList(let items), .orderedList(_, let items): items.flatMap(formulas(in:))
            case .taskList(let items): items.flatMap { formulas(in: $0.content) }
            case .table(let headers, let rows, _): (headers + rows.flatMap { $0 }).flatMap(formulas(in:))
            case .codeBlock, .thematicBreak, .htmlBlock: []
            }
        }
    }

    static func formulas(in inlines: [MarkdownInline]) -> [String] {
        inlines.flatMap { inline -> [String] in
            switch inline {
            case .math(let math): [math.latex]
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .styled(_, let children),
                 .link(let children, _):
                formulas(in: children)
            case .text, .code, .image, .videoEmbed, .audioEmbed, .usdzEmbed, .softBreak, .hardBreak, .html: []
            }
        }
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for scalar in text {
            current = scalar == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

/// SplitMix64: the same documents on every run.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
