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

    /// A parser that outlives its item must be reset: its append verdict proves
    /// continuity from the tail bytes only, so the previous item's frozen prefix
    /// would survive. The assistant row and the tool-expanded surface clear the
    /// view when the item changes; this is the source-level reset they perform.
    @Test func anotherItemsTextAfterResetRendersCanonically() {
        let sharedTail = String(repeating: "shared closing sentence. ", count: 3)
        let heads = Self.paddedToSameLength(
            "# Alpha\n\nAlpha only paragraph.\n\n",
            "# Bravo\n\nBravo only paragraph.\n\n"
        )
        let alpha = heads.alpha + sharedTail
        let bravo = heads.bravo + sharedTail + " More text."

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

    // MARK: - Tail-scoped work

    /// Fence fixtures the byte scan cannot answer on its own: a fence opened
    /// inside a list item that the list's end closes, a fence still open inside
    /// the last list item, and a `~~~` fence whose content holds ``` lines.
    /// cmark's parse decides all of them, so the streaming verdict is checked
    /// against it rather than against a second scan.
    private static let fenceFixtures: [(name: String, source: String)] = [
        (
            "fence in a list item closed by the list end",
            """
            - The item introduces a fence

              ```
              code that never closes inside the item

            A following paragraph ends the list and the fence with it.
            """
        ),
        (
            "fence open inside the last list item",
            """
            1. First step

            2. Second step

               ```swift
               let a = 1
               let b = 2
               ```
            """
        ),
        (
            "fence open inside a nested list item",
            """
            - Outer item

              - Inner item

                ~~~
                nested fence content
                ~~~
            """
        ),
        (
            "tilde fence holding backtick lines",
            """
            Before the tilde fence.

            ~~~
            ```
            not a closer
            ~~~

            After the tilde fence.
            """
        ),
    ]

    /// Streaming reads only the open tail for fence parity. The frozen prefix
    /// ends at a top-level block boundary, so the tail decides on its own — and
    /// it has to agree with cmark, not just with the whole-document scan.
    @Test func tailFenceScanMatchesWhatCmarkParses() {
        for fixture in Self.fixtures + Self.fenceFixtures {
            var parser = CommonMarkStreamingParser()

            for prefix in Self.prefixes(of: fixture.source, chunkSize: 17) {
                let parsed = parser.parse(prefix)
                let verdict = AssistantMarkdownSegmentSource.hasUnclosedCodeFence(
                    prefix,
                    fromUTF8Offset: parsed.tailUTF8Offset,
                    endsInCodeBlock: AssistantMarkdownSegmentSource.endsInCodeBlock(parsed.tailBlocks.last)
                )
                #expect(
                    verdict == Self.cmarkEndsInsideAFence(prefix),
                    "\(fixture.name) fence parity diverged at \(prefix.utf8.count) UTF-8 bytes"
                )
                // Reading from the open tail must agree with reading the whole
                // document under the same parse verdict.
                #expect(
                    verdict == AssistantMarkdownSegmentSource.hasUnclosedCodeFence(
                        prefix,
                        fromUTF8Offset: 0,
                        endsInCodeBlock: AssistantMarkdownSegmentSource.endsInCodeBlock(parsed.tailBlocks.last)
                    ),
                    "\(fixture.name) tail offset changed the fence verdict at \(prefix.utf8.count) UTF-8 bytes"
                )
            }
        }
    }

    /// Fence parity as cmark sees it: the content ends inside an open fence when
    /// a sentinel line at the last line's own indentation is swallowed by the
    /// trailing code block instead of starting another block. The sentinel keeps
    /// that indentation so a fence nested in the final list item is judged inside
    /// its item, not at column zero where the list would end.
    ///
    /// Assumes a fenced block: an indented code block would also swallow it.
    private static func cmarkEndsInsideAFence(_ content: String) -> Bool {
        guard trailingCodeBlockText(parseCommonMark(content)) != nil else { return false }

        let sentinel = containerPrefix(ofLastLineIn: content) + "probe paragraph"
        let probed = parseCommonMark(content + "\n" + sentinel + "\n")
        guard let code = trailingCodeBlockText(probed) else { return false }
        return code.contains("probe paragraph")
    }

    /// Leading whitespace of the last non-blank line: the depth a following line
    /// must keep to stay inside the same list item.
    private static func containerPrefix(ofLastLineIn content: String) -> String {
        let lastLine = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let lastLine else { return "" }
        return String(lastLine.prefix { $0 == " " || $0 == "\t" })
    }

    /// Code text of the block the region ends with, following the last item of a
    /// trailing list.
    private static func trailingCodeBlockText(_ blocks: [MarkdownBlock]) -> String? {
        guard let block = blocks.last else { return nil }
        switch block {
        case .codeBlock(_, let code):
            return code
        case .unorderedList(let items):
            return trailingCodeBlockText(items.last ?? [])
        case .orderedList(_, let items):
            return trailingCodeBlockText(items.last ?? [])
        case .taskList(let items):
            return trailingCodeBlockText(items.last?.content ?? [])
        case .heading, .paragraph, .blockQuote, .thematicBreak, .table, .htmlBlock:
            return nil
        }
    }

    /// `1. First step\n\n2` is a list plus the paragraph `2`. The next tick's `2.`
    /// rejoins the list cmark already had, so freezing the list there makes the
    /// stream show a second list (and a blank line a canonical build has none).
    @Test func orderedListStaysInTheOpenTailWhileItsNextMarkerArrives() {
        var parser = CommonMarkStreamingParser()
        let started = "Steps:\n\n1. First step\n\n2"
        #expect(
            parser.parse(started).prefixBlocks.isEmpty,
            "a lone ordinal after a blank line must not freeze the list above it"
        )

        let secondItem = started + ". Second step"
        let grown = parser.parse(secondItem)
        guard case .orderedList(_, let items)? = grown.tailBlocks.last else {
            Issue.record("the two-item list is not the open tail: \(String(reflecting: grown.tailBlocks))")
            return
        }
        #expect(items.count == 2, "the second item rejoined the streamed list")
        #expect(grown.blocks == parseCommonMark(secondItem))

        // A paragraph after the list ends the ambiguity: the list is stable again.
        let settledContent = secondItem + "\n\nAfter the list."
        let settled = parser.parse(settledContent)
        #expect(!settled.prefixBlocks.isEmpty)
        #expect(settled.blocks == parseCommonMark(settledContent))
    }

    /// A fence inside the last list item keeps streaming as a `.codeBlock`, and
    /// the applier only updates that trailing code view while the content still
    /// ends inside the fence: the verdict has to follow the last item down, and
    /// the streamed code text has to grow tick by tick.
    @Test(arguments: [
        // The review's own shape: one item whose fence stays open to the end.
        "1. step\n\n   ```swift\n   let a = 1\n   let b = 2\n   ```\n",
        // A fence in the last item of a longer list.
        "1. First step\n\n2. Second step\n\n   ```swift\n   let a = 1\n   let b = 2\n   ```\n\n3. Third step\n",
    ])
    func fenceNestedInTheLastListItemKeepsStreaming(document: String) {
        let source = AssistantMarkdownSegmentSource()
        var previousCode: String?

        for prefix in Self.prefixes(of: document, chunkSize: 3) {
            let segments = source.buildSegments(.make(content: prefix, isStreaming: true, themeID: .dark))
            let open = Self.cmarkEndsInsideAFence(prefix)
            #expect(
                source.lastBuildHasUnclosedCodeFence == open,
                "nested fence verdict diverged at \(prefix.utf8.count) UTF-8 bytes"
            )
            guard open else { continue }

            guard case .codeBlock(_, let code)? = segments.last else {
                Issue.record("the last segment of an open nested fence is not a code block: \(String(reflecting: prefix))")
                continue
            }
            if let previousCode {
                #expect(code.hasPrefix(previousCode), "the streamed code block restarted at \(prefix.utf8.count) UTF-8 bytes")
            }
            previousCode = code
        }

        #expect(previousCode?.contains("let b = 2") == true)
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

    /// The same content can arrive with a new reader text size (or typography
    /// revision) while a row streams. An unchanged tick is not a neutral append:
    /// the tail still has to be restyled.
    @Test func unchangedTickRestylesTailWhenReaderTextSizeChanges() throws {
        let view = AssistantMarkdownContentView()
        let content = "Streaming prose that stays put."
        view.apply(configuration: .make(content: content, isStreaming: true, themeID: .dark))
        let initial = try #require(timelineAllTextViews(in: view).first)
        let initialSize = try #require(Self.firstFontSize(of: initial))
        let fullBefore = view.debugStreamingFullNSConversionCountForTesting

        view.apply(configuration: .make(
            content: content,
            isStreaming: true,
            themeID: .dark,
            readerPreferences: FullScreenReaderPreferences(textScale: 1.3)
        ))

        let restyled = try #require(timelineAllTextViews(in: view).first)
        let restyledSize = try #require(Self.firstFontSize(of: restyled))
        #expect(restyledSize > initialSize, "reader text size did not reach the tail")
        #expect(
            view.debugStreamingFullNSConversionCountForTesting == fullBefore + 1,
            "an unchanged tick with new styling must replace the tail"
        )
        #expect(timelineRenderedText(of: restyled) == content)
    }

    /// A setext underline restyles the line above it without changing one
    /// character, so that tick is not a neutral append: the tail has to be
    /// rebuilt as a heading.
    @Test func setextUnderlineRestylesTheStreamedTail() throws {
        let view = AssistantMarkdownContentView()
        let plain = "Prose line"
        view.apply(configuration: .make(content: plain, isStreaming: true, themeID: .dark))
        let body = try #require(timelineAllTextViews(in: view).first)
        let bodySize = try #require(Self.firstFontSize(of: body))

        view.apply(configuration: .make(content: plain + "\n===", isStreaming: true, themeID: .dark))
        let heading = try #require(timelineAllTextViews(in: view).first)
        let headingSize = try #require(Self.firstFontSize(of: heading))
        #expect(timelineRenderedText(of: heading) == plain)
        #expect(headingSize > bodySize, "a setext underline must restyle the tail as a heading")

        view.apply(configuration: .make(content: plain + "\n===\n\nAfter", isStreaming: true, themeID: .dark))
        let grown = try #require(timelineAllTextViews(in: view).first)
        #expect(timelineRenderedText(of: grown).contains("After"))
    }

    /// One tick can carry the underline and the paragraph after it. The prefixes
    /// match character for character, so only the last paragraph's attributes
    /// reveal that the prose above turned into a heading.
    @Test func singleTickSetextUnderlineRestylesTheStreamedTail() throws {
        let view = AssistantMarkdownContentView()
        let plain = "Prose line"
        view.apply(configuration: .make(content: plain, isStreaming: true, themeID: .dark))
        let body = try #require(timelineAllTextViews(in: view).first)
        let bodySize = try #require(Self.firstFontSize(of: body))

        view.apply(configuration: .make(content: plain + "\n===\n\nAfter", isStreaming: true, themeID: .dark))

        let grown = try #require(timelineAllTextViews(in: view).first)
        let headingSize = try #require(Self.firstFontSize(of: grown))
        #expect(timelineRenderedText(of: grown) == plain + "\n\nAfter")
        #expect(headingSize > bodySize, "a one-tick setext underline must restyle the streamed prose")
    }

    /// `-` is ordinary prose mid-line, so only a line-leading marker can restyle
    /// anything already on screen. Treating every dash as markup would send most
    /// ticks through the O(tail) comparison.
    @Test func dashIsMarkupOnlyAtTheStartOfALine() {
        func neutral(_ previous: String, _ appended: String) -> Bool {
            let content = previous + appended
            return StreamingMarkdownDelta.appendedSourceIsMarkdownNeutral(
                content,
                range: previous.utf8.count..<content.utf8.count
            )
        }

        #expect(neutral("Some prose", " - and more prose"))
        #expect(neutral("A clause", " - a second clause\nmore prose"))
        #expect(neutral("Some prose\n", "\n- item") == false)
        #expect(neutral("Some prose", "\n---") == false)
        #expect(neutral("Some prose", "\n===") == false)
        #expect(neutral("Some prose\n", "  - item") == false)
        #expect(neutral("Some prose\n", "    - indented code"))
        #expect(neutral("Some prose", " more *emphasis") == false)
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

    private static func firstFontSize(of textView: UITextView) -> CGFloat? {
        guard let attributed = textView.attributedText, attributed.length > 0 else { return nil }
        return (attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
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
