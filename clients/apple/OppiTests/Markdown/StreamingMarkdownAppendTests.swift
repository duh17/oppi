import Foundation
import Testing
import UIKit

@testable import Oppi

/// The streaming parser owns the append verdict for the whole markdown path: a
/// tick is proved an append from the previous content's last bytes (never the
/// whole document) and anything else takes the canonical parse. These tests pin
/// the rendering contract (streamed == canonical at every tick) and the verdict
/// semantics the segment source and applier rely on.
@Suite("Streaming markdown append verdict")
@MainActor
struct StreamingMarkdownAppendTests {
    private static let fixtures: [(name: String, source: String)] = [
        (
            "prose",
            """
            The server keeps one parser per row.

            Each tick appends a few bytes of prose and the parser reuses the
            frozen prefix instead of re-reading the whole answer.
            """
        ),
        (
            "lists",
            """
            Steps:

            1. First item
            2. Second item with `code`
               - nested bullet
               - another nested bullet

            - loose bullet
            - last bullet
            """
        ),
        (
            "fenced code",
            """
            Before the fence.

            ```swift
            let value = 42
            print(value)
            ```

            After the fence.
            """
        ),
        (
            "table",
            """
            | Key | Value |
            | --- | --- |
            | alpha | beta |
            | gamma | delta |

            After the table.
            """
        ),
        (
            "link reference definition",
            """
            Read [the guide][ref] first.

            An unrelated paragraph.

            [ref]: https://example.com/guide

            Then [the guide][ref] again.
            """
        ),
        (
            "inline code and emphasis",
            """
            Use **bold** and `code` and *emphasis* inline.

            A second paragraph closes the document.
            """
        ),
    ]

    /// Every streamed prefix must render exactly like a canonical parse of the
    /// same content, and each longer prefix must report itself as an append.
    @Test(arguments: [1, 3, 8, 32, 4096])
    func streamedPrefixesMatchCanonicalParse(chunkSize: Int) {
        for fixture in Self.fixtures {
            var parser = CommonMarkStreamingParser()
            var previousUTF8Count: Int?

            for prefix in Self.prefixes(of: fixture.source, chunkSize: chunkSize) {
                let parsed = parser.parse(prefix)
                #expect(
                    parsed.blocks == parseCommonMark(prefix),
                    "\(fixture.name) diverged at \(prefix.utf8.count) UTF-8 bytes"
                )
                if let previousUTF8Count {
                    #expect(
                        parsed.appendedUTF8Range == previousUTF8Count..<prefix.utf8.count,
                        "\(fixture.name) lost the append verdict at \(prefix.utf8.count) UTF-8 bytes"
                    )
                } else {
                    #expect(parsed.appendedUTF8Range == nil)
                }
                previousUTF8Count = prefix.utf8.count
            }

            #expect(previousUTF8Count == fixture.source.utf8.count)
        }
    }

    // MARK: - Verdict semantics

    @Test func unchangedContentIsAnEmptyAppend() {
        var parser = CommonMarkStreamingParser()
        let source = "Alpha paragraph.\n\nStreaming tail."
        _ = parser.parse(source)

        let repeated = parser.parse(source)

        #expect(repeated.appendedUTF8Range == source.utf8.count..<source.utf8.count)
        #expect(repeated.blocks == parseCommonMark(source))
    }

    @Test func shorterContentIsNotAnAppend() {
        var parser = CommonMarkStreamingParser()
        let source = "Alpha paragraph.\n\nStreaming tail that gets truncated."
        _ = parser.parse(source)

        let shrunk = parser.parse("Alpha paragraph.\n\nStreaming")

        #expect(shrunk.appendedUTF8Range == nil)
        #expect(shrunk.blocks == parseCommonMark("Alpha paragraph.\n\nStreaming"))
    }

    @Test func longerReplacementWithoutSharedPrefixIsNotAnAppend() {
        var parser = CommonMarkStreamingParser()
        let first = "Finalized paragraph.\n\nStreaming tail"
        _ = parser.parse(first)

        let replacement = """
        Completely different lead paragraph.

        Streaming tail grows with a new prefix.
        """
        #expect(replacement.utf8.count > first.utf8.count)

        let parsed = parser.parse(replacement)

        #expect(parsed.appendedUTF8Range == nil)
        #expect(parsed.blocks == parseCommonMark(replacement))
    }

    /// The verdict samples only the last 64 bytes of the previous content, so a
    /// longer replacement that repeats them at the same offset reads as an
    /// append. Rendering stays correct because the segment source is reset when
    /// the row's item identity changes; see
    /// `anotherItemsTextAfterResetRendersCanonically`.
    @Test func replacementThatRepeatsTheSampleWindowReadsAsAnAppend() {
        let sharedTail = String(repeating: "shared closing sentence. ", count: 3)
        let alpha = "# Alpha\n\nAlpha only paragraph.\n\n" + sharedTail
        let bravo = "# Bravo\n\nBravo only paragraph.\n\n" + sharedTail + " More text."
        #expect(bravo.utf8.count > alpha.utf8.count)

        var parser = CommonMarkStreamingParser()
        _ = parser.parse(alpha)

        let parsed = parser.parse(bravo)

        #expect(parsed.appendedUTF8Range == alpha.utf8.count..<bravo.utf8.count)
    }

    /// Same document after a reset: the frozen prefix of the previous item is
    /// gone, so the new item renders canonically even though its tail matches.
    /// This is the reset the assistant row performs when a reused cell switches
    /// item; the control below shows why it is required.
    @Test func anotherItemsTextAfterResetRendersCanonically() {
        let sharedTail = String(repeating: "shared closing sentence. ", count: 3)
        let heads = Self.paddedToSameLength(
            "# Alpha\n\nAlpha only paragraph.\n\n",
            "# Bravo\n\nBravo only paragraph.\n\n"
        )
        let alpha = heads.alpha + sharedTail
        let bravo = heads.bravo + sharedTail + " More text."

        // Control: without the reset, the previous item's frozen prefix survives.
        let stale = AssistantMarkdownSegmentSource()
        _ = stale.buildSegments(.make(content: alpha, isStreaming: true, themeID: .dark))
        let staleSegments = stale.buildSegments(.make(content: bravo, isStreaming: true, themeID: .dark))
        #expect(Self.plainText(of: staleSegments).contains("Alpha"))

        let source = AssistantMarkdownSegmentSource()
        _ = source.buildSegments(.make(content: alpha, isStreaming: true, themeID: .dark))
        source.reset()
        let streamed = source.buildSegments(.make(content: bravo, isStreaming: true, themeID: .dark))

        let canonical = FlatSegment.build(from: parseCommonMark(bravo), themeID: .dark)
        #expect(Self.plainText(of: streamed) == Self.plainText(of: canonical))
        #expect(Self.plainText(of: streamed).contains("Bravo"))
        #expect(!Self.plainText(of: streamed).contains("Alpha"))
    }

    // MARK: - Canonical-path triggers

    @Test func displayMathSplitAcrossTicksForcesCanonicalParse() {
        var parser = CommonMarkStreamingParser()
        _ = parser.parse("Before math.\n\n$")

        let complete = "Before math.\n\n$$x^2$$"
        let parsed = parser.parse(complete)

        #expect(parsed.strategy == .full)
        #expect(parsed.prefixBlocks.isEmpty)
        #expect(parsed.blocks == parseCommonMark(complete))
    }

    @Test func referenceDefinitionSplitAcrossTicksForcesCanonicalParse() {
        var parser = CommonMarkStreamingParser()
        _ = parser.parse("Read [the guide][ref].\n\nAn unrelated paragraph.\n\n[ref]")

        let complete = """
        Read [the guide][ref].

        An unrelated paragraph.

        [ref]: https://example.com/guide

        Then [the guide][ref] again.
        """
        let parsed = parser.parse(complete)

        #expect(parsed.strategy == .full)
        #expect(parsed.blocks == parseCommonMark(complete))
    }

    /// A replacement rescans the whole document, so an earlier delimiter does
    /// not leave the parser stuck on the canonical path.
    @Test func replacementRescansAndLetsLaterTicksReuseTheTail() {
        var parser = CommonMarkStreamingParser()
        _ = parser.parse("Math.\n\n$$x$$")

        let replacement = "Plain prose.\n\nSecond paragraph.\n"
        let replaced = parser.parse(replacement)
        #expect(replaced.appendedUTF8Range == nil)
        #expect(replaced.blocks == parseCommonMark(replacement))

        let grown = parser.parse(replacement + "\nThird paragraph.\n")
        #expect(grown.strategy == .tailOnly)
        #expect(grown.blocks == parseCommonMark(replacement + "\nThird paragraph.\n"))
    }

    // MARK: - Applier

    /// The applier trusts the parser's verdict: a neutral append converts only
    /// the new suffix, while a tick that rewrites earlier text replaces the tail.
    @Test func neutralAppendAppliesDeltaAndEarlierRewriteReplaces() throws {
        let view = AssistantMarkdownContentView()
        view.apply(configuration: .make(content: "Hello", isStreaming: true, themeID: .dark))
        #expect(view.debugStreamingFullNSConversionCountForTesting == 0)

        view.apply(configuration: .make(content: "Hello world", isStreaming: true, themeID: .dark))
        #expect(view.debugStreamingDeltaNSConversionCountForTesting == 1)
        #expect(view.debugStreamingFullNSConversionCountForTesting == 0)

        view.apply(configuration: .make(content: "Hello world and then some", isStreaming: true, themeID: .dark))
        #expect(view.debugStreamingDeltaNSConversionCountForTesting == 2)
        #expect(view.debugStreamingFullNSConversionCountForTesting == 0)

        view.apply(configuration: .make(content: "Jello world and then some", isStreaming: true, themeID: .dark))
        #expect(view.debugStreamingFullNSConversionCountForTesting == 1)

        let textView = try #require(timelineAllTextViews(in: view).first)
        #expect(timelineRenderedText(of: textView) == "Jello world and then some")
    }

    // MARK: - Helpers

    private static func prefixes(of source: String, chunkSize: Int) -> [String] {
        let characters = Array(source)
        var result: [String] = []
        var content = ""
        var offset = 0
        while offset < characters.count {
            let end = min(offset + chunkSize, characters.count)
            content.append(contentsOf: characters[offset..<end])
            offset = end
            result.append(content)
        }
        return result
    }

    private static func paddedToSameLength(
        _ alpha: String,
        _ bravo: String
    ) -> (alpha: String, bravo: String) {
        let width = max(alpha.utf8.count, bravo.utf8.count)
        func pad(_ text: String) -> String {
            text + String(repeating: "x", count: width - text.utf8.count)
        }
        return (pad(alpha), pad(bravo))
    }

    private static func plainText(of segments: [FlatSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text):
                return String(text.characters)
            case .codeBlock(_, let code):
                return "code:\(code)"
            case .table(let headers, let rows):
                return "table:\(headers.count)x\(rows.count)"
            case .thematicBreak:
                return "break"
            case .image(let alt, _):
                return "image:\(alt)"
            case .mermaidDiagram(let code):
                return "mermaid:\(code)"
            case .latexBlock(let code):
                return "latex:\(code)"
            default:
                return "other"
            }
        }.joined(separator: "\n")
    }
}
