import Foundation
import Testing
import UIKit

@testable import Oppi

/// Tests that the streaming delta-append path in AssistantMarkdownSegmentApplier
/// handles CommonMark inline syntax closure correctly.
///
/// When markdown inline syntax closes mid-stream (e.g., **bold**, `code`,
/// [link](url)), the rendered plain text changes at earlier positions (syntax
/// markers are consumed). The delta-append optimization must detect this and
/// fall back to full replacement instead of appending a wrong delta.
@Suite("Streaming markdown inline reparse")
@MainActor
struct StreamingInlineReparseTests {

    // MARK: - Helpers

    private func makeApplier() -> (UIStackView, AssistantMarkdownSegmentApplier) {
        let stackView = UIStackView()
        stackView.axis = .vertical
        let delegate = NoOpDelegate()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: delegate
        )
        return (stackView, applier)
    }

    private func streamTick(
        applier: AssistantMarkdownSegmentApplier,
        content: String,
        isStreaming: Bool = true
    ) {
        let blocks = parseCommonMark(content)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        let config = AssistantMarkdownContentView.Configuration.make(
            content: content,
            isStreaming: isStreaming,
            themeID: .dark
        )
        applier.apply(segments: segments, config: config)
    }

    private func extractPlainText(from stackView: UIStackView) -> String {
        stackView.arrangedSubviews.compactMap { view -> String? in
            (view as? UITextView)?.textStorage.string
        }.joined(separator: "\n---\n")
    }

    private func firstTextView(in stackView: UIStackView) -> UITextView? {
        stackView.arrangedSubviews.first { $0 is UITextView } as? UITextView
    }

    // MARK: - Bold closure

    @Test func boldClosureFallsBackToFullReplacement() {
        let (stackView, applier) = makeApplier()

        // Tick 1: unclosed bold — rendered as literal "Here is **bold text and"
        streamTick(applier: applier, content: "Here is **bold text and")
        let text1 = extractPlainText(from: stackView)
        #expect(text1.contains("**bold"), "Unclosed bold should render literal **")

        // Tick 2: bold closes — "**" markers consumed, text shifts
        streamTick(applier: applier, content: "Here is **bold text** and more")
        let text2 = extractPlainText(from: stackView)

        // The fix: text should be correct, not garbled
        #expect(text2.contains("bold text"), "Bold text should be present")
        #expect(text2.contains("and more"), "Continuation text should be present")
        #expect(!text2.contains("**"), "Literal ** should be gone after bold closes")
    }

    @Test func boldClosureWithSameRenderedLengthStillUpdates() {
        let (stackView, applier) = makeApplier()

        // Tick 1 plain text length: "A **bo" == 6
        streamTick(applier: applier, content: "A **bo")
        let text1 = extractPlainText(from: stackView)
        #expect(text1 == "A **bo")

        // Tick 2 rendered plain text length is also 6: "A bold"
        // The streaming fast path must not treat equal length as "no change".
        streamTick(applier: applier, content: "A **bold**")
        let text2 = extractPlainText(from: stackView)
        #expect(text2 == "A bold")
        #expect(!text2.contains("**"))
    }

    // MARK: - Inline code closure

    @Test func inlineCodeClosureFallsBackToFullReplacement() {
        let (stackView, applier) = makeApplier()

        // Tick 1: unclosed backtick
        streamTick(applier: applier, content: "Use `some_function and")
        let text1 = extractPlainText(from: stackView)
        #expect(text1.contains("`some_function"), "Unclosed code should render literal backtick")

        // Tick 2: backtick closes
        streamTick(applier: applier, content: "Use `some_function` and more")
        let text2 = extractPlainText(from: stackView)
        #expect(text2.contains("some_function"), "Code text should be present")
        #expect(text2.contains("and more"), "Continuation should be present")
    }

    @Test func inlineCodeClosureWithSameRenderedLengthStillUpdates() {
        let (stackView, applier) = makeApplier()

        streamTick(applier: applier, content: "A `cod")
        let text1 = extractPlainText(from: stackView)
        #expect(text1 == "A `cod")

        streamTick(applier: applier, content: "A `code`")
        let text2 = extractPlainText(from: stackView)
        #expect(text2 == "A code")
        #expect(!text2.contains("`"))
    }

    // MARK: - Inline math closure

    @Test func dollarMathClosureReplacesLiteralSourceWithAttachment() throws {
        let (stackView, applier) = makeApplier()

        streamTick(applier: applier, content: "Inline $x^2")
        let initial = try #require(firstTextView(in: stackView))
        #expect(initial.textStorage.string == "Inline $x^2")

        streamTick(applier: applier, content: "Inline $x^2$ done")
        let rendered = try #require(firstTextView(in: stackView))
        #expect(rendered.textStorage.string == "Inline \u{FFFC} done")
        #expect(rendered.textStorage.attribute(.attachment, at: 7, effectiveRange: nil) is NSTextAttachment)
    }

    // MARK: - Link closure

    @Test func linkClosureFallsBackToFullReplacement() {
        let (stackView, applier) = makeApplier()

        // Tick 1: unclosed link
        streamTick(applier: applier, content: "See [docs](https://example.com")
        let text1 = extractPlainText(from: stackView)
        // Unclosed link renders as literal text including brackets
        #expect(!text1.isEmpty)

        // Tick 2: link closes
        streamTick(applier: applier, content: "See [docs](https://example.com) for details")
        let text2 = extractPlainText(from: stackView)
        #expect(text2.contains("docs"), "Link text should be present")
        #expect(text2.contains("for details"), "Continuation should be present")
    }

    // MARK: - Plain text append (fast path still works)

    @Test func plainTextAppendUsesIncrementalPath() {
        let (stackView, applier) = makeApplier()

        // Tick 1: plain text
        streamTick(applier: applier, content: "Hello world")
        let text1 = extractPlainText(from: stackView)
        #expect(text1 == "Hello world")

        // Tick 2: more plain text appended
        streamTick(applier: applier, content: "Hello world and more")
        let text2 = extractPlainText(from: stackView)
        #expect(text2 == "Hello world and more")
    }

    @Test func overlappingAppendsProduceCorrectText() throws {
        let (stackView, applier) = makeApplier()

        // Initial content.
        streamTick(applier: applier, content: "Hello")

        // Tick 2 appends.
        streamTick(applier: applier, content: "Hello world")

        // Tick 3 appends again.
        streamTick(applier: applier, content: "Hello world again")

        let textView = try #require(firstTextView(in: stackView))
        #expect(
            textView.textStorage.string == "Hello world again",
            "Overlapping appends must produce the full text"
        )
    }

    @Test func tableHeaderDoesNotRemainAsTextAfterDelimiterArrives() throws {
        let (stackView, applier) = makeApplier()

        let intro = "Each phone-safe server setting is:\n\n"
        let header = "| Row | v1 | Control | Owner / API | Notes |\n"
        let body = """
        | --- | --- | --- | --- | --- |
        | Connection | yes | toggle | server | note |
        """

        streamTick(applier: applier, content: intro + header)
        #expect(extractPlainText(from: stackView).contains("| Row |"))
        #expect(stackView.arrangedSubviews.contains { $0 is NativeTableBlockView } == false)

        streamTick(applier: applier, content: intro + header + body)
        #expect(stackView.arrangedSubviews.contains { $0 is NativeTableBlockView })
        #expect(
            !extractPlainText(from: stackView).contains("| Row |"),
            "Raw table header must leave the prose text view once the delimiter makes a table"
        )
        #expect(extractPlainText(from: stackView).contains("Each phone-safe server setting is:"))
    }

    @Test func completedTableViewIsReusedWhenFollowingProseArrives() throws {
        let (stackView, applier) = makeApplier()
        let table = """
        | Row | v1 |
        | --- | --- |
        | Connection | yes |
        """

        streamTick(applier: applier, content: table)
        let tableView = try #require(stackView.arrangedSubviews.first { $0 is NativeTableBlockView })

        streamTick(applier: applier, content: table + "\n\nAfter the table.\n")
        let reused = try #require(stackView.arrangedSubviews.first { $0 is NativeTableBlockView })
        #expect(reused === tableView, "A finished table should stay mounted when prose follows")
        #expect(extractPlainText(from: stackView).contains("After the table."))
    }

    // MARK: - Stream finish renders correctly

    @Test func streamFinishProducesCorrectOutput() {
        let (stackView, applier) = makeApplier()

        // Stream with unclosed bold
        streamTick(applier: applier, content: "Here is **bold")

        // More text with bold still open
        streamTick(applier: applier, content: "Here is **bold text** and done")

        // Finish streaming
        streamTick(applier: applier, content: "Here is **bold text** and done", isStreaming: false)
        let finalText = extractPlainText(from: stackView)
        #expect(finalText.contains("bold text"), "Final text should have bold text")
        #expect(finalText.contains("and done"), "Final text should have continuation")
        #expect(!finalText.contains("**"), "No literal ** in final output")
    }

    // MARK: - Multiple reparse cycles

    @Test func multipleInlineClosuresHandledCorrectly() {
        let (stackView, applier) = makeApplier()

        // Tick 1: two unclosed bolds
        streamTick(applier: applier, content: "First **bold and second **also")

        // Tick 2: first bold closes
        streamTick(applier: applier, content: "First **bold** and second **also")

        // Tick 3: second bold closes
        streamTick(applier: applier, content: "First **bold** and second **also bold** end")
        let text = extractPlainText(from: stackView)
        #expect(text.contains("bold"), "Should have bold text")
        #expect(text.contains("end"), "Should have end text")
    }
}

/// Differential validation modeled after Codex's streaming Markdown suite.
/// Every committed chunk must produce exactly the same segments as a fresh,
/// canonical full-document render at that point in the stream.
@Suite("Streaming markdown differential rendering")
@MainActor
struct StreamingMarkdownDifferentialTests {
    @Test func incompleteDisplayBecomesOneFormulaOnlyAfterItsCloserStreamsIn() {
        let source = AssistantMarkdownSegmentSource()
        let incomplete = "Before\n\n$$\n\\mathcal L(\\theta)\n=\n-\\sum_{i=1}^{n}"
        let complete = incomplete + "\n$$\n### After"

        let partial = source.buildSegments(.make(
            content: incomplete,
            isStreaming: true,
            themeID: .dark
        ))
        #expect(!partial.contains { if case .latexBlock = $0 { return true }; return false })

        let settled = source.buildSegments(.make(
            content: complete,
            isStreaming: true,
            themeID: .dark
        ))
        let formulas = settled.compactMap { segment -> String? in
            guard case .latexBlock(let code) = segment else { return nil }
            return code
        }
        #expect(formulas.count == 1)
        #expect(formulas.first?.contains("\n=\n") == true)
        #expect(segmentsEqual(settled, canonicalSegments(content: complete, themeID: .dark)))
    }

    @Test func singleLineDisplayClosureMatchesCanonicalRender() {
        assertIncrementalMatchesCanonical(chunks: [
            "Before\n\n$$ x",
            " $$\n",
            "### After\n",
        ])
    }

    @Test func representativeBlockStreamMatchesCanonicalRenderAfterEveryChunk() {
        assertIncrementalMatchesCanonical(chunks: [
            "# Heading\n",
            "\n",
            "First paragraph with a [link](https://example.com).\n",
            "continued on the next line.\n\n",
            "1. First item\n",
            "2. Second item\n\n",
            "> Quoted paragraph\n\n",
            "```swift\n",
            "let value = 42\n",
            "```\n\n",
            "| Key | Value |\n",
            "| --- | --- |\n",
            "| alpha | beta |\n",
            "\n<div>HTML block</div>\n",
        ])
    }

    @Test func growingSingleBlocksMatchCanonicalRenderAfterEveryChunk() {
        for chunks in [
            [
                "A paragraph that keeps growing\n",
                "without a blank line between chunks.\n",
                "It stays one top-level block.\n",
            ],
            [
                "| Key | Value |\n",
                "| --- | --- |\n",
                "| alpha | beta |\n",
                "| gamma | delta |\n",
            ],
        ] {
            assertIncrementalMatchesCanonical(chunks: chunks)
        }
    }

    @Test func referenceDefinitionRecomputesPreviouslyStableBlocks() {
        assertIncrementalMatchesCanonical(chunks: [
            "Earlier [reference][id].\n\n",
            "An unrelated paragraph.\n\n",
            "[id]: https://example.com/reference\n",
            "\n",
            "Later [reference][id].\n",
        ])
    }

    @Test func containerNestedReferenceDefinitionRecomputesStableBlocks() {
        assertIncrementalMatchesCanonical(chunks: [
            "Earlier [reference][id].\n\n",
            "An unrelated paragraph.\n\n",
            "> [id]: https://example.com/reference\n",
            "\n",
            "Later [reference][id].\n",
        ])
    }

    @Test func multilineReferenceLabelDoesNotBypassCanonicalValidation() {
        assertIncrementalMatchesCanonical(chunks: [
            "Earlier [multi line].\n\n",
            "An unrelated paragraph.\n\n",
            "[multi\n",
            "line]: https://example.com/reference\n",
            "\n",
            "Later [multi line].\n",
        ])
    }

    @Test func themeChangeRebuildsTheStablePrefix() {
        let source = AssistantMarkdownSegmentSource()
        let content = "# Heading\n\nStable paragraph.\n\nMutable tail."

        _ = source.buildSegments(.make(content: content, isStreaming: true, themeID: .dark))
        let incremental = source.buildSegments(.make(content: content + " More.", isStreaming: true, themeID: .light))
        let canonical = canonicalSegments(content: content + " More.", themeID: .light)

        #expect(segmentsEqual(incremental, canonical))
    }

    @Test func sessionContextChangeRebuildsTheStablePrefix() throws {
        let source = AssistantMarkdownSegmentSource()
        let initial = "![diagram](/absolute/diagram.svg)\n\nMutable tail."
        let updated = initial + " More."
        let baseURL = try #require(URL(string: "https://server.example.com"))

        _ = source.buildSegments(.make(
            content: initial,
            isStreaming: true,
            themeID: .dark,
            workspaceID: "workspace-a",
            serverBaseURL: baseURL
        ))
        let incremental = source.buildSegments(.make(
            content: updated,
            isStreaming: true,
            themeID: .dark,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        ))
        let canonical = canonicalSegments(
            content: updated,
            themeID: .dark,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        #expect(segmentsEqual(incremental, canonical))
    }

    @Test func sourceContextChangeRebuildsTheStablePrefix() throws {
        let source = AssistantMarkdownSegmentSource()
        let initial = "![diagram](images/diagram.svg)\n\nMutable tail."
        let updated = initial + " More."
        let baseURL = try #require(URL(string: "https://server.example.com"))

        _ = source.buildSegments(.make(
            content: initial,
            isStreaming: true,
            themeID: .dark,
            workspaceID: "workspace-a",
            serverBaseURL: baseURL,
            sourceFilePath: "docs/one.md"
        ))
        let incremental = source.buildSegments(.make(
            content: updated,
            isStreaming: true,
            themeID: .dark,
            workspaceID: "workspace-b",
            serverBaseURL: baseURL,
            sourceFilePath: "guides/two.md"
        ))
        let canonical = canonicalSegments(
            content: updated,
            themeID: .dark,
            workspaceID: "workspace-b",
            serverBaseURL: baseURL,
            sourceFilePath: "guides/two.md"
        )

        #expect(segmentsEqual(incremental, canonical))
    }

    private func assertIncrementalMatchesCanonical(chunks: [String]) {
        let source = AssistantMarkdownSegmentSource()
        var content = ""

        for (index, chunk) in chunks.enumerated() {
            content += chunk
            let incremental = source.buildSegments(.make(
                content: content,
                isStreaming: true,
                themeID: .dark
            ))
            let canonical = canonicalSegments(content: content, themeID: .dark)
            #expect(
                segmentsEqual(incremental, canonical),
                "Incremental render diverged after chunk \(index): \(String(reflecting: chunk))"
            )
        }
    }

    private func canonicalSegments(
        content: String,
        themeID: ThemeID,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceFilePath: String? = nil
    ) -> [FlatSegment] {
        let sourceDirectory = sourceFilePath.flatMap { path -> String? in
            let directory = (path as NSString).deletingLastPathComponent
            return directory.isEmpty || directory == "." ? nil : directory
        }
        return FlatSegment.build(
            from: parseCommonMark(content),
            themeID: themeID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory
        )
    }

    private func segmentsEqual(_ lhs: [FlatSegment], _ rhs: [FlatSegment]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        return zip(lhs, rhs).allSatisfy { left, right in
            switch (left, right) {
            case (.text(let leftText), .text(let rightText)):
                return NSAttributedString(leftText).isEqual(to: NSAttributedString(rightText))
            case let (.codeBlock(leftLanguage, leftCode), .codeBlock(rightLanguage, rightCode)):
                return leftLanguage == rightLanguage && leftCode == rightCode
            case let (.table(leftHeaders, leftRows), .table(rightHeaders, rightRows)):
                return leftHeaders == rightHeaders && leftRows == rightRows
            case (.thematicBreak, .thematicBreak):
                return true
            case let (.image(leftAlt, leftURL), .image(rightAlt, rightURL)):
                return leftAlt == rightAlt && leftURL == rightURL
            case let (.mermaidDiagram(leftCode), .mermaidDiagram(rightCode)):
                return leftCode == rightCode
            case let (.latexBlock(leftCode), .latexBlock(rightCode)):
                return leftCode == rightCode
            default:
                return false
            }
        }
    }
}

private final class NoOpDelegate: NSObject, UITextViewDelegate {}
