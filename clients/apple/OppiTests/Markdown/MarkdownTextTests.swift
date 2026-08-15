import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

// MARK: - FlatSegment.build

@Suite("FlatSegment.build")
struct FlatSegmentBuildTests {
    private func textSegmentString(_ segments: [FlatSegment]) -> String? {
        guard segments.count == 1, case .text(let attributed) = segments[0] else { return nil }
        return String(attributed.characters)
    }

    private func inlineMathAttachments(in segments: [FlatSegment]) -> [NSTextAttachment] {
        guard let first = segments.first, case .text(let attributed) = first else { return [] }
        let rendered = NSAttributedString(attributed)
        var attachments: [NSTextAttachment] = []
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                attachments.append(attachment)
            }
        }
        return attachments
    }

    @Test func emptyBlocksProduceNoSegments() {
        let segments = FlatSegment.build(from: [], themeID: .dark)
        #expect(segments.isEmpty)
    }

    @Test func singleParagraphProducesTextSegment() {
        let blocks: [MarkdownBlock] = [.paragraph([.text("Hello")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text = segments[0] {} else { Issue.record("Expected .text segment") }
    }

    @Test func codeBlockProducesCodeSegment() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "swift", code: "let x = 1")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .codeBlock(let lang, let code) = segments[0] {
            #expect(lang == "swift")
            #expect(code == "let x = 1")
        } else {
            Issue.record("Expected .codeBlock segment")
        }
    }

    @Test func mermaidCodeBlockProducesMermaidDiagramSegment() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "mermaid", code: "graph TD\n    A-->B")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .mermaidDiagram(let code) = segments[0] {
            #expect(code == "graph TD\n    A-->B")
        } else {
            Issue.record("Expected .mermaidDiagram segment, got \(segments[0])")
        }
    }

    @Test func mermaidCodeBlockWithMmdAlias() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "mmd", code: "sequenceDiagram\n    A->>B: Hello")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .mermaidDiagram = segments[0] {} else {
            Issue.record("Expected .mermaidDiagram for 'mmd' language")
        }
    }

    @Test func nonMermaidCodeBlockStaysAsCodeBlock() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: "python", code: "print('hi')")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .codeBlock(let lang, _) = segments[0] {
            #expect(lang == "python")
        } else {
            Issue.record("Expected .codeBlock segment for python")
        }
    }

    @Test func displayMathParagraphWithBracketDelimitersPromotesToLatexSegment() {
        let markdown = #"""
        \[
        \text{hit_rate} = \frac{\text{cacheRead}}{\text{cacheRead} + \text{uncachedInput}}
        \]
        """#

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        if case .latexBlock(let code) = segments[0] {
            #expect(code.contains(#"\frac"#))
            #expect(!code.contains(#"\["#))
            #expect(!code.contains(#"\]"#))
        } else {
            Issue.record("Expected .latexBlock segment, got \(segments[0])")
        }
    }

    @Test func displayMathParagraphWithDollarDelimitersPromotesToLatexSegment() {
        let markdown = #"""
        $$
        x = \frac{1}{2}
        $$
        """#

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        if case .latexBlock(let code) = segments[0] {
            #expect(code == #"x = \frac{1}{2}"#)
        } else {
            Issue.record("Expected .latexBlock segment, got \(segments[0])")
        }
    }

    @Test func exactPhysicalDeviceDisplayPayloadProducesFormulaSegmentsAndFollowingHeading() throws {
        let markdown = #"""
        ### 1. Inline and display LaTeX

        Inline expressions: $E=mc^2$, \(e^{i\pi}+1=0\), and \(\nabla\!\cdot\!\mathbf E=\rho/\varepsilon_0\).

        A larger display block:

        $$
        \mathcal L(\theta)
        =
        -\sum_{i=1}^{n}\log
        \left(
        \frac{\exp(z_{i,y_i}/\tau)}
        {\sum_{j=1}^{K}\exp(z_{i,j}/\tau)}
        \right)
        +\lambda\lVert\theta\rVert_2^2
        $$

        A matrix-heavy expression:

        \[
        \begin{aligned}
        \mathbf H &= \mathbf X^\top\mathbf W\mathbf X+\lambda\mathbf I,\\
        \Delta\theta &= -\mathbf H^{-1}\nabla_\theta\mathcal L,\\
        \begin{bmatrix}x_{t+1}\\v_{t+1}\end{bmatrix}
        &=
        \begin{bmatrix}1&\Delta t\\0&1\end{bmatrix}
        \begin{bmatrix}x_t\\v_t\end{bmatrix}
        +
        \begin{bmatrix}\frac12\Delta t^2\\\Delta t\end{bmatrix}a_t.
        \end{aligned}
        \]

        **LATEX-END ANCHOR** — rendering should not move the earlier anchor.

        ### 2. Raster image and SVG
        """#

        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
        let formulas = segments.compactMap { segment -> String? in
            guard case .latexBlock(let source) = segment else { return nil }
            return source
        }
        let prose = segments.compactMap { segment -> String? in
            guard case .text(let attributed) = segment else { return nil }
            return NSAttributedString(attributed).string
        }.joined(separator: "\n")

        #expect(formulas.count == 2)
        let firstFormula = try #require(formulas.first)
        let secondFormula = try #require(formulas.dropFirst().first)
        #expect(firstFormula.contains("\n=\n"))
        #expect(firstFormula.contains(#"\mathcal L(\theta)"#))
        #expect(secondFormula.contains(#"\begin{aligned}"#))
        #expect(secondFormula.contains(#"\begin{bmatrix}"#))
        #expect(!prose.contains("$$"))
        #expect(!prose.contains(#"\begin{aligned}"#))
        #expect(prose.contains("LATEX-END ANCHOR"))
        #expect(prose.contains("2. Raster image and SVG"))
    }

    @MainActor
    @Test func displayMathIntegratesAlignedMatrixAndCasesEnvironmentsWithVisibleGeometry() throws {
        let markdown = #"""
        $$
        \begin{aligned}
        A &= \begin{bmatrix}1&2\\3&4\end{bmatrix} \\
        f(x) &= \begin{cases}x^2,&x\ge0\\-x,&x<0\end{cases}
        \end{aligned}
        $$
        """#

        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
        guard case .latexBlock(let source) = try #require(segments.first) else {
            Issue.record("Expected integrated aligned/matrix/cases display")
            return
        }

        let validation = TeXMathParser().parseValidated(source)
        #expect(validation.diagnostics.isEmpty, "Supported environment diagnostics: \(validation.diagnostics)")
        #expect(validation.isRenderable)

        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        view.layoutIfNeeded()
        view.applyAsFormulaSync(code: source, palette: ThemeID.dark.palette)
        view.layoutIfNeeded()

        let imageView = try #require(timelineAllImageViews(in: view).first {
            timelineViewIsVisible($0) && $0.image != nil
        })
        let image = try #require(imageView.image)
        #expect(image.size.width > AppFont.messageBody.pointSize * 4)
        #expect(image.size.height > AppFont.messageBody.lineHeight * 3)
        #expect(view.bounds.height >= imageView.bounds.height)
    }

    @Test func malformedAndUnclosedDisplayDelimitersFallBackToExactVisibleSource() {
        let cases = [
            ("Before\n\n$$\n\\frac{a\nAfter", ["$$", #"\frac{a"#]),
            ("Before\n\n\\[\n\\begin{matrix}1&2\nAfter", [#"\["#, #"\begin{matrix}"#]),
            ("Before\n\n$$\n\\frac{a\n$$\nAfter", ["$$", #"\frac{a"#]),
        ]

        for (markdown, expectedFragments) in cases {
            let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
            #expect(!segments.contains { if case .latexBlock = $0 { return true }; return false })
            let visible = segments.compactMap { segment -> String? in
                guard case .text(let attributed) = segment else { return nil }
                return String(attributed.characters)
            }.joined(separator: "\n")
            #expect(visible.contains("Before"))
            #expect(visible.contains("After"))
            for fragment in expectedFragments {
                #expect(visible.contains(fragment))
            }
        }
    }

    @Test func multipleInlineFormulasRenderWhileCodeLinksCurrencyAndEscapesStayLiteral() {
        let markdown = #"""
        A $x$ B \(y_0\) C $z^2$; keep `$code^2$`, [price](https://example.com/$value$), \$escaped$, and $5.00$.
        """#
        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
        guard let first = segments.first, case .text(let attributed) = first else {
            Issue.record("Expected one inline text segment")
            return
        }
        let rendered = NSAttributedString(attributed).string

        #expect(inlineMathAttachments(in: segments).count == 3)
        #expect(rendered.contains("$code^2$"))
        #expect(rendered.contains("$escaped$"))
        #expect(rendered.contains("$5.00$"))
    }

    @Test func physicalDevicePayloadRendersBothInlineFormsAndPromotesDisplayMath() throws {
        let markdown = #"""
        Inline math: $x^2 + y^2 = z^2$ and \(\alpha \leq \beta\).

        $$
        \frac{1}{2} + \frac{1}{3} = \frac{5}{6}
        $$
        """#

        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)

        #expect(segments.count == 2)
        let attachments = inlineMathAttachments(in: segments)
        #expect(attachments.count == 2)
        #expect(attachments.allSatisfy { $0.image?.size.width ?? 0 > 0 })
        #expect(attachments.allSatisfy {
            ($0.image?.size.height ?? 0) >= AppFont.messageBody.pointSize * 0.75
        })
        guard case .text(let prose) = try #require(segments.first) else {
            Issue.record("Expected inline formulas inside the prose text segment")
            return
        }
        let renderedProse = NSAttributedString(prose).string
        #expect(renderedProse.hasPrefix("Inline math: "))
        #expect(renderedProse.hasSuffix(" and \u{FFFC}."))

        guard case .latexBlock(let displaySource) = try #require(segments.last) else {
            Issue.record("Expected displayed formula segment")
            return
        }
        #expect(displaySource == #"\frac{1}{2} + \frac{1}{3} = \frac{5}{6}"#)
    }

    @Test func inlineMathPreservesMarkdownAndRejectsFalsePositives() throws {
        let markdown = #"""
        **Result:** $x^2$; see [proof](https://example.com/$value$), keep `$code^2$`, escaped \$y^2$, and prices $5 today and $6 tomorrow.
        """#
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(inlineMathAttachments(in: segments).count == 1)
        guard case .text(let attributed) = try #require(segments.first) else {
            Issue.record("Expected one text segment")
            return
        }
        let rendered = NSAttributedString(attributed)
        #expect(rendered.string.contains("Result:"))
        #expect(rendered.string.contains("proof"))
        #expect(rendered.string.contains("$code^2$"))
        #expect(rendered.string.contains("$y^2$"))
        #expect(rendered.string.contains("$5 today and $6 tomorrow"))
        #expect(attributed.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com/$value$"])
        #expect(attributed.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func inlineDollarLatexArrowRendersAsFormulaAttachment() {
        let segments = FlatSegment.build(
            from: parseCommonMark("A $\\rightarrow$ B\n"),
            themeID: .dark
        )
        #expect(inlineMathAttachments(in: segments).count == 1)
        #expect(textSegmentString(segments) == "A \u{FFFC} B")
    }

    @Test func inlineEscapedParenLatexRendersAsFormulaAttachment() {
        let segments = FlatSegment.build(
            from: parseCommonMark("A \\(\\alpha \\leq \\beta\\) B\n"),
            themeID: .dark
        )
        #expect(inlineMathAttachments(in: segments).count == 1)
        #expect(textSegmentString(segments) == "A \u{FFFC} B")
    }

    @Test func inlineDollarLatexTextChainRendersAsFormulaAttachment() {
        let blocks = parseCommonMark("$\\text{First} \\rightarrow \\text{Second} \\rightarrow \\text{Done}$\n")
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(inlineMathAttachments(in: segments).count == 1)
        #expect(textSegmentString(segments) == "\u{FFFC}")
    }

    @Test func bareLatexTextChainRendersPlainly() {
        let blocks = parseCommonMark("\\text{Alpha} \\rightarrow \\text{Beta}\n")
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(textSegmentString(segments) == "Alpha → Beta")
    }

    @Test func inlineLatexAttachmentPreservesNonLatinText() {
        let blocks = parseCommonMark("$\\text{第一步} \\rightarrow \\text{第二步}$\n")
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(inlineMathAttachments(in: segments).count == 1)
    }

    @Test func inlineLatexSymbolsAndOperatorsRenderAsFormulaAttachment() {
        let blocks = parseCommonMark("$\\alpha \\leq \\beta \\rightarrow \\gamma$\n")
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(inlineMathAttachments(in: segments).count == 1)
    }

    @Test func inlineDollarCurrencyRemainsPlainText() {
        let blocks = parseCommonMark("Costs $5 today and $6 tomorrow\n")
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(textSegmentString(segments) == "Costs $5 today and $6 tomorrow")
    }

    @Test func escapedInlineDelimitersRemainLiteralText() {
        let markdown = #"Literal \\(not math\\), escaped \$x^2$, and $5.00$."#
        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
        #expect(inlineMathAttachments(in: segments).isEmpty)
        #expect(textSegmentString(segments) == #"Literal \(not math\), escaped $x^2$, and $5.00$."#)
    }

    @Test func unmatchedDollarLatexRemainsPlainText() {
        let blocks = parseCommonMark("A $\\text{partial} value\n")
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(textSegmentString(segments) == "A $\\text{partial} value")
    }

    @Test func bracketDelimitedPlainTextParagraphStaysText() {
        let markdown = """
        [
        this is not latex
        ]
        """

        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("this is not latex"))
        } else {
            Issue.record("Expected .text segment, got \(segments[0])")
        }
    }

    @Test func tableProducesTableSegment() {
        let blocks: [MarkdownBlock] = [.table(headers: [[.text("A")]], rows: [[[.text("1")]]])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .table(let headers, let rows) = segments[0] {
            #expect(headers.map { plainText(from: $0) } == ["A"])
            #expect(rows.map { $0.map { plainText(from: $0) } } == [["1"]])
        }
    }

    @Test func thematicBreakProducesBreakSegment() {
        let blocks: [MarkdownBlock] = [.thematicBreak]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .thematicBreak = segments[0] {} else { Issue.record("Expected .thematicBreak") }
    }

    @Test func adjacentParagraphsMergeIntoSingleTextSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("First")]),
            .paragraph([.text("Second")]),
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Adjacent text blocks should be merged into one .text segment
        #expect(segments.count == 1, "Adjacent paragraphs should merge into a single .text segment")
        if case .text(let attr) = segments[0] {
            let plainText = String(attr.characters)
            #expect(plainText.contains("First"))
            #expect(plainText.contains("Second"))
        }
    }

    @Test func codeBlockBreaksTextMerging() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("Before")]),
            .codeBlock(language: "js", code: "x()"),
            .paragraph([.text("After")]),
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Should be: text("Before"), codeBlock, text("After")
        #expect(segments.count == 3)
        if case .text = segments[0] {} else { Issue.record("Expected text") }
        if case .codeBlock = segments[1] {} else { Issue.record("Expected codeBlock") }
        if case .text = segments[2] {} else { Issue.record("Expected text") }
    }

    @Test func headingProducesTextSegment() {
        let blocks: [MarkdownBlock] = [.heading(level: 1, inlines: [.text("Title")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text == "Title")
        }
    }

    @Test func blockQuoteProducesTextWithQuoteMarker() {
        let blocks: [MarkdownBlock] = [.blockQuote([.paragraph([.text("Quoted")])])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("▎"))
            #expect(text.contains("Quoted"))
        }
    }

    @Test func unorderedListRendersWithBullets() {
        let blocks: [MarkdownBlock] = [
            .unorderedList([
                [.paragraph([.text("Item A")])],
                [.paragraph([.text("Item B")])],
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("•"))
            #expect(text.contains("Item A"))
            #expect(text.contains("Item B"))
        }
    }

    @Test func orderedListRendersWithNumbers() {
        let blocks: [MarkdownBlock] = [
            .orderedList(start: 1, [
                [.paragraph([.text("First")])],
                [.paragraph([.text("Second")])],
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("1."))
            #expect(text.contains("2."))
            #expect(text.contains("First"))
            #expect(text.contains("Second"))
        }
    }

    @Test func orderedListWithNonOneStart() {
        let blocks: [MarkdownBlock] = [
            .orderedList(start: 5, [
                [.paragraph([.text("Fifth")])],
                [.paragraph([.text("Sixth")])],
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("5."))
            #expect(text.contains("6."))
        }
    }

    @Test func orderedListSplitByFencedCodeBlockContinuesNumbering() {
        let markdown = """
        1. In `file.swift`, add:

        ```swift
        let value = 1
        ```

        2. Add helpers:
        """
        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)

        #expect(segments.count == 3)
        guard case .text(let firstItem) = segments[0],
              case .codeBlock(let language, let code) = segments[1],
              case .text(let secondItem) = segments[2] else {
            Issue.record("Expected text/code/text segments, got \(segments)")
            return
        }

        #expect(String(firstItem.characters).hasPrefix("  1. In file.swift, add:"))
        #expect(language == "swift")
        #expect(code == "let value = 1")
        #expect(String(secondItem.characters).hasPrefix("  2. Add helpers:"))
    }

    @Test func orderedListNestedBulletsKeepParentContinuationIndent() {
        let markdown = """
        1. Application services
           - SessionLifecycleService
           - SessionListService
           - WorkspaceService
        """
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        #expect(segments.count == 1)
        guard case .text(let attr) = segments.first else {
            Issue.record("Expected .text segment")
            return
        }

        let lines = String(attr.characters).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == [
            "  1. Application services",
            "       • SessionLifecycleService",
            "       • SessionListService",
            "       • WorkspaceService",
        ])
    }

    @Test func htmlBlockRendersAsMonospaced() {
        let blocks: [MarkdownBlock] = [.htmlBlock("<div>hello</div>")]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("<div>hello</div>"))
        }
    }

    // MARK: - Inline formatting in AttributedString

    @Test func inlineCodeRendersInText() {
        let blocks: [MarkdownBlock] = [.paragraph([.text("Use "), .code("foo()"), .text(" here")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("foo()"))
        }
    }

    @Test func linkRendersWithText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.link(children: [.text("Click")], destination: "https://example.com")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("Click"))
        }
    }

    @Test func imageWithAltTextRendersAltInBrackets() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Photo", source: "img.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("[Photo]"))
        }
    }

    @Test func imageWithEmptyAltTextFallsBackToGenericPlaceholder() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "", source: "img.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            #expect(String(attr.characters).contains("[image]"))
        } else {
            Issue.record("Expected .text fallback segment")
        }
    }

    @Test func strikethroughRendersText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.strikethrough([.text("deleted")])])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("deleted"))
        }
    }

    @Test func softBreakRendersAsNewline() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("Line 1"), .softBreak, .text("Line 2")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("\n"))
        }
    }

    @Test func taskListRendersWithCheckboxCharacters() {
        let blocks: [MarkdownBlock] = [
            .taskList([
                .init(checked: false, content: [.paragraph([.text("Todo")])]),
                .init(checked: true, content: [.paragraph([.text("Done")])]),
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("\u{25CB}"))
            #expect(text.contains("\u{25C9}"))
            #expect(text.contains("Todo"))
            #expect(text.contains("Done"))
        } else {
            Issue.record("Expected .text segment for task list")
        }
    }

    @Test func checkedTaskListItemHasStrikethrough() {
        let blocks: [MarkdownBlock] = [
            .taskList([
                .init(checked: true, content: [.paragraph([.text("Done task")])]),
            ])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        guard case .text(let attr) = segments[0] else {
            Issue.record("Expected .text segment")
            return
        }
        // Find a run that contains strikethrough
        let hasStrikethrough = attr.runs.contains { $0.strikethroughStyle == .single }
        #expect(hasStrikethrough, "Checked task item text should have strikethrough")
    }
}

// MARK: - Workspace wiki links

@Suite("Workspace wiki links")
struct WorkspaceWikiLinkRenderingTests {
    private func textSegment(from segments: [FlatSegment]) throws -> AttributedString {
        #expect(segments.count == 1)
        guard segments.count == 1, case .text(let attributed) = segments[0] else {
            Issue.record("Expected one .text segment, got \(segments)")
            throw WikiLinkTestFailure()
        }
        return attributed
    }

    private func firstLink(in attributed: AttributedString) throws -> URL {
        try #require(attributed.runs.compactMap(\.link).first)
    }

    private struct ParsedTable {
        let headers: [[MarkdownInline]]
        let rows: [[[MarkdownInline]]]
    }

    struct AtomicWikiTableCase: Sendable {
        let content: String
        let expectedCells: [String]
    }

    private func firstTable(in blocks: [MarkdownBlock]) -> ParsedTable? {
        for block in blocks {
            switch block {
            case .table(let headers, let rows):
                return ParsedTable(headers: headers, rows: rows)
            case .blockQuote(let children):
                if let table = firstTable(in: children) { return table }
            case .unorderedList(let items), .orderedList(_, let items):
                for item in items {
                    if let table = firstTable(in: item) { return table }
                }
            case .taskList(let items):
                for item in items {
                    if let table = firstTable(in: item.content) { return table }
                }
            case .heading, .paragraph, .codeBlock, .thematicBreak, .htmlBlock:
                continue
            }
        }
        return nil
    }

    private func firstCodeBlock(in blocks: [MarkdownBlock]) -> (language: String?, code: String)? {
        for block in blocks {
            switch block {
            case .codeBlock(let language, let code):
                return (language, code)
            case .blockQuote(let children):
                if let code = firstCodeBlock(in: children) { return code }
            case .unorderedList(let items), .orderedList(_, let items):
                for item in items {
                    if let code = firstCodeBlock(in: item) { return code }
                }
            case .taskList(let items):
                for item in items {
                    if let code = firstCodeBlock(in: item.content) { return code }
                }
            case .heading, .paragraph, .table, .thematicBreak, .htmlBlock:
                continue
            }
        }
        return nil
    }

    @Test func givenBareWikiLinkWhenWorkspaceContextExistsThenItRendersAsUnresolvedResourceReference() throws {
        let blocks = parseCommonMark("See [[oppi-jZhDRKeV]] next")
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-source"
        )
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "See oppi-jZhDRKeV next")
        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == "oppi-jZhDRKeV")
        #expect(parsed.sourceServerID == "server-1")
        #expect(parsed.workspaceID == "workspace-1")
        #expect(parsed.sourceSessionID == "session-source")
        #expect(parsed.fileCandidatePath == "oppi-jZhDRKeV.md")
    }

    @Test func givenLabeledWikiLinkThenVisibleTextUsesLabelAndTargetUsesPath() throws {
        let blocks = parseCommonMark("Read [[notes/sessions/oppi-jZhDRKeV|session note]].")
        let segments = FlatSegment.build(from: blocks, themeID: .dark, workspaceID: "workspace-1")
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "Read session note.")
        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == "notes/sessions/oppi-jZhDRKeV")
        #expect(parsed.fileCandidatePath == "notes/sessions/oppi-jZhDRKeV.md")
    }

    @Test func givenMarkdownExtensionInTargetThenPathIsPreserved() throws {
        let blocks = parseCommonMark("Open [[notes/daily/2026-06-06.md]]")
        let segments = FlatSegment.build(from: blocks, themeID: .dark, workspaceID: "workspace-1")
        let attributed = try textSegment(from: segments)

        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == "notes/daily/2026-06-06.md")
        #expect(parsed.fileCandidatePath == "notes/daily/2026-06-06.md")
    }

    @Test func givenExplicitRelativeWikiLinkThenItResolvesAgainstSourceDirectory() throws {
        let blocks = parseCommonMark("See [[./topic|topic note]]")
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            workspaceID: "workspace-1",
            sourceDirectory: "notes/sessions"
        )
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "See topic note")
        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == "./topic")
        #expect(parsed.fileCandidatePath == "notes/sessions/topic.md")
    }

    @Test func givenIgnoredInternalReportWikiLinkThenCandidatePathRemainsUnchanged() throws {
        let path = ".internal/reports/apple-wikilink-rendering-contract-2026-06-06.md"
        let blocks = parseCommonMark("Open [[\(path)]]")
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            workspaceID: "workspace-1"
        )
        let attributed = try textSegment(from: segments)

        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == path)
        #expect(parsed.fileCandidatePath == path)
    }

    @Test func givenWorkspaceContextMissingThenWikiLinkRemainsATappableGenericResourceReference() throws {
        let blocks = parseCommonMark("See [[RV97TbYj|that session]]")
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            serverID: "server-1",
            sessionID: "session-source"
        )
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "See that session")
        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == "RV97TbYj")
        #expect(parsed.sourceServerID == "server-1")
        #expect(parsed.sourceSessionID == "session-source")
    }

    @Test(arguments: [
        ("[[Sources/App.swift#L12]]", 12, 12),
        ("[[Sources/App.swift#L12-L18|focused code]]", 12, 18),
        ("[[notes.md#L3-L4|another anchor]]", 3, 4),
    ])
    func givenGitHubLineAnchorThenFileCandidateDropsFragment(
        source: String,
        expectedStart: Int,
        expectedEnd: Int
    ) throws {
        let segments = FlatSegment.build(
            from: parseCommonMark("Open \(source)"),
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-source"
        )
        let attributed = try textSegment(from: segments)
        let url = try firstLink(in: attributed)
        let parsed = try #require(ResourceReferenceURL.parse(url))

        #expect(parsed.fileCandidatePath == (source.contains("notes") ? "notes.md" : "Sources/App.swift"))
        #expect(parsed.lineAnchor?.range == expectedStart...expectedEnd)
    }

    @Test(arguments: [
        "[[Sources/App.swift#L0]]",
        "[[Sources/App.swift#L12-L11]]",
        "[[Sources/App.swift#L12-L]]",
        "[[Sources/App.swift#L12-Lx]]",
        "[[Sources/App.swift#l12]]",
        "[[Sources/App.swift#Heading]]",
    ])
    func malformedOrHeadingAnchorRemainsLiteral(source: String) throws {
        let segments = FlatSegment.build(
            from: parseCommonMark("Open \(source)"),
            themeID: .dark,
            workspaceID: "workspace-1"
        )
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "Open \(source)")
        #expect(attributed.runs.compactMap(\.link).isEmpty)
    }

    @Test func givenAbsoluteHostWikiLinkThenItStoresAHostFileCandidate() throws {
        let blocks = parseCommonMark("Open [[/tmp/oppi-debug.log]]")
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-source"
        )
        let attributed = try textSegment(from: segments)
        let parsed = try #require(ResourceReferenceURL.parse(try firstLink(in: attributed)))

        #expect(parsed.target == "/tmp/oppi-debug.log")
        #expect(parsed.kind == .hostFile)
        #expect(parsed.fileCandidatePath == "/tmp/oppi-debug.log")
        #expect(parsed.sourceServerID == "server-1")
    }

    @Test func givenHomeAndFileURLWikiLinksThenTheyBecomeHostFileCandidates() throws {
        let cases: [(source: String, expected: String)] = [
            ("[[~/workspace/kypu/README.md]]", "~/workspace/kypu/README.md"),
            ("[[file:///tmp/foo.md]]", "/tmp/foo.md"),
        ]

        for item in cases {
            let attributed = try textSegment(from: FlatSegment.build(
                from: parseCommonMark("Open \(item.source)"),
                themeID: .dark,
                serverID: "server-1",
                workspaceID: "workspace-1"
            ))
            let parsed = try #require(ResourceReferenceURL.parse(try firstLink(in: attributed)))
            #expect(parsed.kind == .hostFile)
            #expect(parsed.fileCandidatePath == item.expected)
        }
    }

    @Test func givenAbsoluteHostWikiLinkWithLineAnchorThenFileCandidateDropsFragment() throws {
        let attributed = try textSegment(from: FlatSegment.build(
            from: parseCommonMark("Open [[/Users/chenda/workspace/kypu/src/main.go#L12-L18]]"),
            themeID: .dark,
            workspaceID: "workspace-1"
        ))
        let parsed = try #require(ResourceReferenceURL.parse(try firstLink(in: attributed)))

        #expect(parsed.kind == .hostFile)
        #expect(parsed.fileCandidatePath == "/Users/chenda/workspace/kypu/src/main.go")
        #expect(parsed.lineAnchor?.range == 12...18)
    }

    @Test(arguments: [
        "[[/tmp/foo.md?leak=1]]",
        "[[~other/secrets.md]]",
        "[[file://hostname/tmp/foo.md]]",
        "[[file:/tmp/foo.md]]",
        "[[/tmp/foo.md#Heading]]",
    ])
    func givenUnsupportedHostWikiLinkThenItRemainsLiteral(source: String) throws {
        let attributed = try textSegment(from: FlatSegment.build(
            from: parseCommonMark("Open \(source)"),
            themeID: .dark,
            workspaceID: "workspace-1"
        ))

        #expect(String(attributed.characters) == "Open \(source)")
        #expect(attributed.runs.compactMap(\.link).isEmpty)
    }

    @Test func givenRelativeWikiLinkThenItStaysAWorkspaceFileCandidate() throws {
        let attributed = try textSegment(from: FlatSegment.build(
            from: parseCommonMark("See [[server/src/file-serving-policy.ts]]"),
            themeID: .dark,
            workspaceID: "workspace-1"
        ))
        let parsed = try #require(ResourceReferenceURL.parse(try firstLink(in: attributed)))

        #expect(parsed.kind == .workspaceFile)
        #expect(parsed.fileCandidatePath == "server/src/file-serving-policy.ts")
    }

    @Test func givenRelativeWikiLinkInsideHostMarkdownThenItStaysAHostFileCandidate() throws {
        let cases: [(source: String, directory: String, expected: String)] = [
            ("[[./topic]]", "/tmp", "/tmp/topic.md"),
            ("[[../topic]]", "/tmp/notes", "/tmp/topic.md"),
        ]

        for item in cases {
            let attributed = try textSegment(from: FlatSegment.build(
                from: parseCommonMark("Open \(item.source)"),
                themeID: .dark,
                serverID: "server-1",
                workspaceID: "workspace-1",
                sourceDirectory: item.directory
            ))
            let parsed = try #require(ResourceReferenceURL.parse(try firstLink(in: attributed)))
            #expect(parsed.kind == .hostFile, "\(item.source)")
            #expect(parsed.fileCandidatePath == item.expected, "\(item.source)")
            #expect(parsed.target == String(item.source.dropFirst(2).dropLast(2)))
        }
    }

    @Test(arguments: [
        "#L0",
        "#L4-L3",
        "#L4-L",
        "#L4-Lx",
        "#l12",
        "#Heading",
    ])
    func lineAnchorParserFailsClosed(fragment: String) {
        #expect(SourceLineAnchor.parse(fragment) == nil)
    }

    @Test(arguments: [
        ("#L1", 1, 1),
        ("#L2-L5", 2, 5),
        ("#L7-L9", 7, 9),
    ])
    func lineAnchorParserAcceptsOneBasedInclusiveRanges(
        fragment: String,
        expectedStart: Int,
        expectedEnd: Int
    ) throws {
        let anchor = try #require(SourceLineAnchor.parse(fragment))
        #expect(anchor.range == expectedStart...expectedEnd)
    }

    @Test(arguments: [
        ("", 0),
        ("one", 1),
        ("one\n", 2),
        ("one\n\n", 3),
        ("one\r", 2),
        ("one\r\ntwo\r", 3),
    ])
    func sourceLineMetricsCountsEmptyAndTrailingLogicalLines(source: String, expectedCount: Int) {
        #expect(SourceLineMetrics.count(source) == expectedCount)
    }

    @Test func lineAnchorResolutionReportsMissingLinesBeforeAndAfterExcerpt() throws {
        let anchor = try #require(SourceLineAnchor(startLine: 1, endLine: 100))
        let resolution = anchor.resolution(fileLineCount: 3, firstFileLine: 40)

        #expect(resolution.existingRange == 40...42)
        #expect(resolution.message?.contains("starts before line 40") == true)
        #expect(resolution.message?.contains("continues past line 42") == true)
    }

    @Test(arguments: [
        ("[[notes.md#L2-L9|label]]", "notes.md", 2, 5, true),
        ("[[notes.md#L10]]", "notes.md", 0, 0, false),
    ])
    func lineAnchorResolutionClipsAtFileEnd(
        source: String,
        path: String,
        expectedStart: Int,
        expectedEnd: Int,
        hasExistingRange: Bool
    ) throws {
        let segments = FlatSegment.build(
            from: parseCommonMark(source),
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1"
        )
        let attributed = try textSegment(from: segments)
        let parsed = try #require(ResourceReferenceURL.parse(try firstLink(in: attributed)))
        let anchor = try #require(parsed.lineAnchor)
        let resolution = anchor.resolution(fileLineCount: 5)

        #expect(parsed.fileCandidatePath == path)
        #expect((resolution.existingRange != nil) == hasExistingRange)
        if hasExistingRange {
            #expect(resolution.existingRange?.lowerBound == expectedStart)
            #expect(resolution.existingRange?.upperBound == expectedEnd)
        }
        #expect(resolution.message != nil)
    }

    @Test(arguments: [
        "| Value |\n| :---: |\n| ``[[note|label]]`` |",
        "> | Value |\n> | ---: |\n> | ``[[note|label]]`` |",
        "- | Value |\n  | :--- |\n  | ``[[note|label]]`` |",
    ])
    func inlineCodeWikiLinkInGFMTableKeepsOneCellAndLiteralPipe(source: String) throws {
        let table = try #require(firstTable(in: parseCommonMark(source)))
        #expect(table.headers.count == 1)
        #expect(table.rows.count == 1)
        #expect(table.rows[0].count == 1)
        guard case .code(let code) = try #require(table.rows[0][0].first) else {
            Issue.record("Expected one inline-code cell")
            return
        }
        #expect(code == "[[note|label]]")
    }

    @Test(arguments: [
        AtomicWikiTableCase(
            content: "[[outer [[inner|inner]]|outer]]",
            expectedCells: ["[[outer [[inner", "inner]]", "outer]]", "x"]
        ),
        AtomicWikiTableCase(
            content: #"[[target|label\]]|tail]]"#,
            expectedCells: ["[[target", "label]]", "tail]]", "x"]
        ),
        AtomicWikiTableCase(
            content: #"[[target|label]\]tail]]"#,
            expectedCells: ["[[target", "label]]tail]]", "x", ""]
        ),
        AtomicWikiTableCase(
            content: "[[target|one|two]]",
            expectedCells: ["[[target", "one", "two]]", "x"]
        ),
        AtomicWikiTableCase(
            content: "[[|label]]",
            expectedCells: ["[[", "label]]", "x", ""]
        ),
        AtomicWikiTableCase(
            content: "[[target|]]",
            expectedCells: ["[[target", "]]", "x", ""]
        ),
        AtomicWikiTableCase(
            content: "[[notes#Heading|label]]",
            expectedCells: ["[[notes#Heading", "label]]", "x", ""]
        ),
        AtomicWikiTableCase(
            content: "[[target|label",
            expectedCells: ["[[target", "label", "x", ""]
        ),
    ])
    func unsupportedWikiCandidatesRemainAtomicInGFMTable(testCase: AtomicWikiTableCase) throws {
        let source = "| A | B | C | D |\n| --- | --- | --- | --- |\n| \(testCase.content) | x |"
        #expect(MarkdownWikiLinkRewriter.parserInput(source).source == source)

        let table = try #require(firstTable(in: parseCommonMark(source)))
        #expect(table.rows.count == 1)
        #expect(table.rows[0].map { plainText(from: $0) } == testCase.expectedCells)
    }

    @Test func validEscapedWikiSeparatorKeepsGFMTableCellAndRewritesLink() throws {
        let source = #"""
        | Value | Extra |
        | --- | --- |
        | [[note\|label]] | x |
        """#
        #expect(MarkdownWikiLinkRewriter.parserInput(source).source == source)

        let table = try #require(firstTable(in: parseCommonMark(source)))
        #expect(table.rows[0].map { plainText(from: $0) } == ["[[note|label]]", "x"])

        let segments = FlatSegment.build(
            from: [.table(headers: table.headers, rows: table.rows)],
            themeID: .dark,
            workspaceID: "workspace-1"
        )
        guard case .table(_, let rows) = try #require(segments.first),
              case .link(let children, _) = try #require(rows[0][0].first) else {
            Issue.record("Expected escaped separator to produce a wiki link")
            return
        }
        #expect(plainText(from: children) == "label")
    }

    @Test func validWikiProtectionHasBoundedParserInputAmplification() {
        let minimumLabeledReference = "[[a|b]]"
        let source = String(repeating: minimumLabeledReference, count: 20_000)
        let parserInput = MarkdownWikiLinkRewriter.parserInput(source)

        // A three-byte token replaces one byte, so the worst valid reference
        // expands from seven to nine bytes: at most 9/7 overall.
        #expect(parserInput.source.utf8.count * 7 <= source.utf8.count * 9)
        #expect(parserInput.restoration.restore(parserInput.source) == source)
        #expect(MarkdownWikiLinkRewriter.parserInput(source).source == parserInput.source)
    }

    @Test func parserBoundaryTokenSelectionIsBoundedAndFailsClosed() {
        let candidates = (0...8).map { "z\($0)z" }
        let firstEightCollisions = candidates.prefix(8).joined()

        #expect(MarkdownWikiLinkRewriter.selectParserBoundaryToken(
            absentFrom: firstEightCollisions,
            candidates: candidates
        ) == nil)
        #expect(MarkdownWikiLinkRewriter.selectParserBoundaryToken(
            absentFrom: candidates[0],
            candidates: candidates
        ) == candidates[1])

        let productionCollisions = (0...7).map { "q\($0)q" }.joined()
        let source = "\(productionCollisions) | [[a|b]] |"
        #expect(MarkdownWikiLinkRewriter.parserInput(source).source == source)
    }

    @Test(arguments: [
        ("> ~~~text[[meta|label]]\n> | [[note|label]] |\n> ~~~", "text[[meta|label]]"),
        ("- ```text\n  | [[note|label]] |\n  ```", "text"),
    ])
    func containerFencedCodePreservesExactWikiLinkSource(
        source: String,
        expectedLanguage: String
    ) throws {
        let codeBlock = try #require(firstCodeBlock(in: parseCommonMark(source)))
        #expect(codeBlock.language == expectedLanguage)
        #expect(codeBlock.code == "| [[note|label]] |")
    }

    @Test func parserBoundaryRoundTripsPrivateUseAndTokenLikeText() throws {
        let literal = "\u{E002} \u{E100} \u{F8FF} OPPIWIKIPIPEPROTECTION OPPIWIKIPIPEPROTECTIONX"
        let source = """
        \(literal) [[note|label]]

        `\(literal) [[note|label]]`

        ```text
        \(literal) [[note|label]]
        ```
        """

        let blocks = parseCommonMark(source)
        guard case .paragraph(let prose) = try #require(blocks.first) else {
            Issue.record("Expected prose paragraph")
            return
        }
        #expect(plainText(from: prose) == "\(literal) [[note|label]]")

        guard case .paragraph(let codeParagraph) = try #require(blocks.dropFirst().first),
              case .code(let inlineCode) = try #require(codeParagraph.first) else {
            Issue.record("Expected inline-code paragraph")
            return
        }
        #expect(inlineCode == "\(literal) [[note|label]]")

        let codeBlock = try #require(firstCodeBlock(in: blocks))
        #expect(codeBlock.language == "text")
        #expect(codeBlock.code == "\(literal) [[note|label]]")

        let indentedCode = try #require(firstCodeBlock(in: parseCommonMark(
            "    \(literal) [[note|label]]"
        )))
        #expect(indentedCode.language == nil)
        #expect(indentedCode.code == "\(literal) [[note|label]]")
    }

    @Test func parserBoundaryRoundTripsHTMLLiterals() throws {
        let literal = "\u{E002} \u{E100} OPPIWIKIPIPEPROTECTION"
        let inlineOpen = #"<span data-note="[[note|label]]" data-extra="|" data-literal="\#(literal)">"#
        let blockOpen = #"<div data-note="[[note|label]]" data-extra="|" data-literal="\#(literal)">"#
        let source = "\(inlineOpen)body</span>\n\n\(blockOpen)\nbody\n</div>"

        let blocks = parseCommonMark(source)
        guard case .paragraph(let inlines) = try #require(blocks.first),
              case .html(let parsedInlineOpen) = try #require(inlines.first) else {
            Issue.record("Expected inline HTML")
            return
        }
        #expect(parsedInlineOpen == inlineOpen)

        guard case .htmlBlock(let html) = try #require(blocks.dropFirst().first) else {
            Issue.record("Expected HTML block")
            return
        }
        #expect(html == "\(blockOpen)\nbody\n</div>\n")
    }

    @Test func parserBoundaryRoundTripsLinkAndImageFields() throws {
        let literal = "\u{E002}-OPPIWIKIPIPEPROTECTION"
        let linkDestination = "https://example.com/\(literal)/[[note|label]]"
        let imageDestination = "https://example.com/\(literal)/[[image|label]].png"
        let source = "[link \(literal) [[link|label]]](\(linkDestination)) | "
            + "![image \(literal) [[alt|label]]](\(imageDestination))"

        let blocks = parseCommonMark(source)
        guard case .paragraph(let inlines) = try #require(blocks.first),
              case .link(let linkChildren, let parsedLinkDestination) = try #require(inlines.first),
              case .image(let imageAlt, let parsedImageDestination) = try #require(inlines.dropFirst(2).first) else {
            Issue.record("Expected link and image")
            return
        }
        #expect(plainText(from: linkChildren) == "link \(literal) [[link|label]]")
        #expect(parsedLinkDestination == linkDestination)
        #expect(imageAlt == "image \(literal) [[alt|label]]")
        #expect(parsedImageDestination == imageDestination)
    }

    @Test func unmatchedBacktickRunDoesNotHideWikiSyntax() throws {
        let source = "| Value |\n| --- |\n| `[[note|label]]`` |"
        let table = try #require(firstTable(in: parseCommonMark(source)))
        #expect(table.rows.count == 1)
        #expect(table.rows[0].count == 1)
        #expect(plainText(from: table.rows[0][0]).contains("[[note|label]]"))
    }

    @Test(arguments: [
        "`start\n| [[note|label]] |\nend`",
        "``start\n` shorter run\n| [[note|label]] |\nend``",
    ])
    func multilineCodeSpanKeepsWikiPipeLiteral(source: String) throws {
        guard case .paragraph(let inlines) = try #require(parseCommonMark(source).first),
              case .code(let code) = try #require(inlines.first) else {
            Issue.record("Expected multiline inline code")
            return
        }
        #expect(code.contains("[[note|label]]"))
    }

    @Test func unmatchedMultilineBacktickRunDoesNotHideWikiSyntax() throws {
        let source = "`start\n| [[note|label]] |"
        guard case .paragraph(let inlines) = try #require(parseCommonMark(source).first) else {
            Issue.record("Expected literal paragraph")
            return
        }
        #expect(plainText(from: inlines).contains("[[note|label]]"))
    }

    @Test(arguments: [
        "````md\n| Value |\n| --- |\n```\n| [[note|label]] |\n````",
        "```md\n~~~\n| [[note|label]] |\n```",
    ])
    func mismatchedFenceTypeOrShorterRunDoesNotExposeWikiSyntax(source: String) throws {
        let codeBlock = try #require(firstCodeBlock(in: parseCommonMark(source)))
        #expect(codeBlock.code.contains("[[note|label]]"))
        #expect(!codeBlock.code.contains("\\|"))
    }

    @Test func sameTypeLongerFenceClosesBeforeFollowingWikiLink() throws {
        let source = "```md\ncontent\n````\n| [[note|label]] |"
        let blocks = parseCommonMark(source)
        let codeBlock = try #require(firstCodeBlock(in: blocks))
        #expect(codeBlock.code == "content")
        guard case .paragraph(let inlines) = try #require(blocks.last) else {
            Issue.record("Expected paragraph after closed fence")
            return
        }
        #expect(plainText(from: inlines) == "| [[note|label]] |")
    }

    @Test func givenUnsupportedHeadingSuffixThenRawWikiSyntaxIsPreserved() throws {
        let blocks = parseCommonMark("See [[notes/daily/2026-06-06#Heading|today heading]]")
        let segments = FlatSegment.build(from: blocks, themeID: .dark, workspaceID: "workspace-1")
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "See [[notes/daily/2026-06-06#Heading|today heading]]")
        #expect(attributed.runs.compactMap(\.link).isEmpty)
    }

    @Test func givenWikiSyntaxInsideInlineCodeThenItIsNotRewritten() throws {
        let blocks = parseCommonMark("Use `[[note]]` literally")
        let segments = FlatSegment.build(from: blocks, themeID: .dark, workspaceID: "workspace-1")
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "Use [[note]] literally")
        #expect(attributed.runs.compactMap(\.link).isEmpty)
    }

    @Test func givenLabeledWikiSyntaxInsideInlineCodeThenPipeRemainsLiteral() throws {
        let blocks = parseCommonMark("Use `[[note|label]]` literally")
        let segments = FlatSegment.build(from: blocks, themeID: .dark, workspaceID: "workspace-1")
        let attributed = try textSegment(from: segments)

        #expect(String(attributed.characters) == "Use [[note|label]] literally")
        #expect(attributed.runs.compactMap(\.link).isEmpty)
    }
}

private struct WikiLinkTestFailure: Error {}

@Suite("Resource reference resolution")
struct ResourceReferenceResolutionTests {
    private let reference = ResourceReference(
        target: "RV97TbYj",
        sourceServerID: "server-source",
        workspaceID: "workspace-1",
        sourceSessionID: "session-source",
        fileCandidatePath: "RV97TbYj.md"
    )

    @Test func URLCarriesUnresolvedTargetAndSourceScopeUntilTap() throws {
        let url = try #require(ResourceReferenceURL.make(reference))
        let parsed = try #require(ResourceReferenceURL.parse(url))

        #expect(parsed == reference)
        #expect(parsed.target == "RV97TbYj")
        #expect(parsed.fileCandidatePath == "RV97TbYj.md")
    }

    @Test func currentSessionIdentityRejectsCrossServerCatalogMatchBeforeLookup() {
        let selfReference = ResourceReference(
            target: "session-source",
            sourceServerID: "server-source",
            workspaceID: "workspace-1",
            sourceSessionID: "session-source",
            fileCandidatePath: "session-source.md"
        )
        let sameIDOnAnotherServer = ResourceReferenceMatch.session(.init(
            serverID: "server-other",
            sessionID: "session-source",
            workspaceID: "workspace-2",
            displayName: "Other session",
            workspaceName: "Elsewhere",
            serverName: "Other Mac"
        ))

        #expect(ResourceReferenceSelfLinkPolicy.isCurrentSession(selfReference))
        #expect(ResourceReferenceResolver.resolve(
            selfReference,
            matches: [sameIDOnAnotherServer]
        ) == .resolved(sameIDOnAnotherServer))
    }

    @Test func exactlyOneSessionMatchResolvesToThatSession() {
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(reference, matches: [session]) == .resolved(session))
    }

    @Test func anchoredReferenceIgnoresSessionMatchesAndResolvesOnlyFiles() throws {
        let anchoredReference = ResourceReference(
            target: "RV97TbYj#L12",
            sourceServerID: "server-source",
            workspaceID: "workspace-1",
            sourceSessionID: "session-source",
            fileCandidatePath: "RV97TbYj.md",
            lineAnchor: try #require(SourceLineAnchor.parse("#L12"))
        )
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-source",
            sessionID: "RV97TbYj#L12",
            workspaceID: "workspace-1",
            displayName: "Should not open",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))
        let file = ResourceReferenceMatch.workspaceFile(.init(
            serverID: "server-source",
            workspaceID: "workspace-1",
            worktreeID: nil,
            path: "RV97TbYj.md",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(anchoredReference, matches: [session]) == .unresolved(anchoredReference.target))
        #expect(ResourceReferenceResolver.resolve(anchoredReference, matches: [session, file]) == .resolved(file))
    }

    @Test func exactlyOneFileMatchResolvesToThatFile() {
        let file = ResourceReferenceMatch.workspaceFile(.init(
            serverID: "server-source",
            workspaceID: "workspace-1",
            worktreeID: "worktree-1",
            path: "RV97TbYj.md",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(reference, matches: [file]) == .resolved(file))
    }

    @Test func sessionAndFileCollisionIsAmbiguousInsteadOfGuessing() {
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))
        let file = ResourceReferenceMatch.workspaceFile(.init(
            serverID: "server-source",
            workspaceID: "workspace-1",
            worktreeID: nil,
            path: "RV97TbYj.md",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(reference, matches: [file, session]) == .ambiguous([session, file]))
    }

    @Test func sameSessionIDOnMultipleServersIsAmbiguous() {
        let serverA = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "First",
            workspaceName: "Oppi",
            serverName: "Laptop"
        ))
        let serverB = ResourceReferenceMatch.session(.init(
            serverID: "server-b",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-2",
            displayName: "Second",
            workspaceName: "Notes",
            serverName: "Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(reference, matches: [serverB, serverA]) == .ambiguous([serverA, serverB]))
    }

    @Test func duplicateCandidateDoesNotCreateFalseAmbiguity() {
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(reference, matches: [session, session]) == .resolved(session))
    }

    @Test func nonmatchingCandidatesAreIgnored() {
        let otherSession = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "different-session",
            workspaceID: "workspace-1",
            displayName: "Other",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))
        let otherFile = ResourceReferenceMatch.workspaceFile(.init(
            serverID: "server-source",
            workspaceID: "workspace-1",
            worktreeID: nil,
            path: "different.md",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(ResourceReferenceResolver.resolve(
            reference,
            matches: [otherSession, otherFile]
        ) == .unresolved("RV97TbYj"))
    }

    @Test func noMatchReportsTheOriginalTargetPredictably() {
        #expect(ResourceReferenceResolver.resolve(reference, matches: []) == .unresolved("RV97TbYj"))
    }

    @Test func candidateCollectorCombinesSessionAndFileLookupBeforeResolving() {
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac"
        ))
        let file = ResourceReferenceMatch.workspaceFile(.init(
            serverID: "server-source",
            workspaceID: "workspace-1",
            worktreeID: "worktree-1",
            path: "RV97TbYj.md",
            workspaceName: "Oppi",
            serverName: "Mac"
        ))

        #expect(ResourceReferenceCandidateCollector.resolve(
            reference,
            sessionMatches: [session],
            fileLookup: .complete([file])
        ) == .resolution(.ambiguous([session, file])))
        #expect(ResourceReferenceCandidateCollector.resolve(
            reference,
            sessionMatches: [session],
            fileLookup: .unavailable
        ) == .unavailable)
    }

    @Test func hostFileLookupDoesNotUseWorkspaceContents() {
        let hostReference = ResourceReference(
            target: "~/secret",
            sourceServerID: "server-1",
            workspaceID: "workspace-1",
            sourceSessionID: "session-source",
            fileCandidatePath: "~/secret",
            kind: .hostFile
        )
        let hostFile = ResourceReferenceMatch.hostFile(.init(
            serverID: "server-1",
            path: "/Users/me/secret",
            serverName: "Mac"
        ))

        #expect(ResourceReferenceFileLookupPolicy.kind(for: hostReference) == .hostFile)
        #expect(ResourceReferenceCandidateCollector.resolve(
            hostReference,
            sessionMatches: [],
            fileLookup: .complete([hostFile])
        ) == .resolution(.resolved(hostFile)))
        #expect(ResourceReferenceCandidateCollector.resolve(
            hostReference,
            sessionMatches: [],
            fileLookup: .authorizationFailed
        ) == .authorizationFailed)
    }

    @Test func hostFileTapScopeDoesNotRequireWorkspaceIdentity() {
        let hostReference = ResourceReference(
            target: "/tmp/oppi-debug.log",
            sourceServerID: "server-1",
            workspaceID: nil,
            sourceSessionID: "session-source",
            fileCandidatePath: "/tmp/oppi-debug.log",
            kind: .hostFile
        )
        let workspaceReference = ResourceReference(
            target: "notes.md",
            sourceServerID: "server-1",
            workspaceID: "workspace-1",
            sourceSessionID: "session-source",
            fileCandidatePath: "notes.md"
        )

        #expect(ResourceReferenceTapScope.matches(
            hostReference,
            serverID: "server-1",
            workspaceID: nil
        ))
        #expect(ResourceReferenceTapScope.matches(
            hostReference,
            serverID: nil,
            workspaceID: nil
        ))
        #expect(!ResourceReferenceTapScope.matches(
            hostReference,
            serverID: "server-other",
            workspaceID: nil
        ))
        #expect(!ResourceReferenceTapScope.matches(
            workspaceReference,
            serverID: "server-1",
            workspaceID: nil
        ))
    }

    @Test func sameNamedServersProduceDistinctStableChoiceAndAccessibilityLabels() {
        let serverA = ResourceReferenceMatch.session(.init(
            serverID: "server-a-12345678",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))
        let serverB = ResourceReferenceMatch.session(.init(
            serverID: "server-b-87654321",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(serverA.choiceLabel != serverB.choiceLabel)
        #expect(serverA.accessibilityLabel != serverB.accessibilityLabel)
        #expect(serverA.choiceLabel.contains("server-a"))
        #expect(serverB.choiceLabel.contains("server-b"))
    }

    @Test func nativeChoiceLabelsIdentifyResourceWorkspaceAndServer() {
        let session = ResourceReferenceMatch.session(.init(
            serverID: "server-a",
            sessionID: "RV97TbYj",
            workspaceID: "workspace-1",
            displayName: "Fix wiki links",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))
        let file = ResourceReferenceMatch.workspaceFile(.init(
            serverID: "server-source",
            workspaceID: "workspace-1",
            worktreeID: nil,
            path: "RV97TbYj.md",
            workspaceName: "Oppi",
            serverName: "Mac Studio"
        ))

        #expect(session.choiceLabel == "Session: Fix wiki links — Oppi on Mac Studio [server-a]")
        #expect(file.choiceLabel == "File: RV97TbYj.md — Oppi on Mac Studio [server-s]")
        #expect(session.accessibilityLabel == session.choiceLabel)
        #expect(file.accessibilityLabel == file.choiceLabel)
    }
}

// MARK: - MarkdownSegmentCache

@Suite("MarkdownSegmentCache")
struct MarkdownSegmentCacheTests {

    @Test func getMissReturnsNil() {
        let cache = MarkdownSegmentCache()
        let result = cache.get("never-cached-content")
        #expect(result == nil)
    }

    @Test func setAndGetRoundTrip() {
        let cache = MarkdownSegmentCache()
        let segments: [FlatSegment] = [.thematicBreak]
        cache.set("test-content", segments: segments)
        let retrieved = cache.get("test-content")
        #expect(retrieved != nil)
        #expect(retrieved?.count == 1)
    }

    @Test func cacheKeyDiffersByTheme() {
        let cache = MarkdownSegmentCache()
        cache.set("content", themeID: .dark, segments: [.thematicBreak])
        let result = cache.get("content", themeID: .light)
        #expect(result == nil, "Different theme should produce a cache miss")
    }

    @Test func cacheKeyDiffersByResourceReferenceServerScope() {
        let cache = MarkdownSegmentCache()
        cache.set(
            "[[RV97TbYj]]",
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1",
            segments: [.thematicBreak]
        )

        let result = cache.get(
            "[[RV97TbYj]]",
            themeID: .dark,
            serverID: "server-2",
            workspaceID: "workspace-1"
        )

        #expect(result == nil, "Markdown segment cache must not reuse resource links across servers")
    }

    @Test func cacheKeyDiffersByImageResolutionContext() {
        let cache = MarkdownSegmentCache()
        cache.set(
            "![image](/tmp/chart.png)",
            themeID: .dark,
            workspaceID: "workspace-1",
            sessionID: nil,
            serverBaseURL: URL(string: "https://example.com/api")!,
            sourceDirectory: nil,
            segments: [.thematicBreak]
        )

        let result = cache.get(
            "![image](/tmp/chart.png)",
            themeID: .dark,
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: URL(string: "https://example.com/api")!,
            sourceDirectory: nil
        )

        #expect(result == nil, "Markdown segment cache must not reuse image segments across different session resolution contexts")
    }

    @Test func clearAllRemovesEverything() {
        let cache = MarkdownSegmentCache()
        cache.set("a", segments: [.thematicBreak])
        cache.set("b", segments: [.thematicBreak])

        cache.clearAll()

        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == nil)
        let snapshot = cache.snapshot()
        #expect(snapshot.entries == 0)
        #expect(snapshot.totalSourceBytes == 0)
    }

    @Test func snapshotReflectsEntryCount() {
        let cache = MarkdownSegmentCache()
        #expect(cache.snapshot().entries == 0)

        cache.set("x", segments: [])
        #expect(cache.snapshot().entries == 1)

        cache.set("y", segments: [])
        #expect(cache.snapshot().entries == 2)
    }

    @Test func snapshotTracksSourceBytes() {
        let cache = MarkdownSegmentCache()
        let content = "Hello, world!" // 13 bytes UTF-8
        cache.set(content, segments: [])
        #expect(cache.snapshot().totalSourceBytes == content.utf8.count)
    }

    @Test func shouldCacheReturnsFalseForLargeContent() {
        let cache = MarkdownSegmentCache()
        let largeContent = String(repeating: "x", count: 20_000) // > 16KB threshold
        #expect(!cache.shouldCache(largeContent))
    }

    @Test func shouldCacheReturnsTrueForSmallContent() {
        let cache = MarkdownSegmentCache()
        #expect(cache.shouldCache("small"))
    }

    @Test func overwritingEntryUpdatesSourceBytes() {
        let cache = MarkdownSegmentCache()
        cache.set("short", segments: [])
        let before = cache.snapshot().totalSourceBytes

        // Overwrite with same key but content doesn't change key identity...
        // Actually the key is based on content hash, so same content = same key
        cache.set("short", segments: [.thematicBreak])
        let after = cache.snapshot().totalSourceBytes

        // Same content, same key — bytes should remain the same
        #expect(before == after)
    }
}

@MainActor
@Suite("Markdown document rendering")
struct MarkdownDocumentRenderingTests {
    @Test func documentPresentationDoesNotFallbackToRawSourceForLargeMarkdown() async throws {
        let content = [
            "# Heading",
            "",
            "**Bold intro** with `inline code`.",
            "",
            String(repeating: "Body paragraph with enough text to exercise large markdown rendering.\n\n", count: 320),
        ].joined(separator: "\n")
        #expect(content.count > 20_000)

        let controller = UIHostingController(
            rootView: FileContentView(
                content: content,
                filePath: "Notes.md",
                presentation: .document
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let rendered = await waitForTimelineCondition(timeoutMs: 1_000) {
            await MainActor.run {
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let renderedText = timelineAllTextViews(in: controller.view)
                    .map { timelineRenderedText(of: $0) }
                    .joined(separator: "\n")
                return renderedText.contains("Heading")
                    && renderedText.contains("Bold intro")
                    && renderedText.contains("inline code")
                    && !renderedText.contains("# Heading")
                    && !renderedText.contains("**Bold intro**")
                    && !renderedText.contains("`inline code`")
            }
        }

        #expect(rendered)
    }
}

// MARK: - FlatSegment image resolution

@Suite("FlatSegment image URL resolution")
struct FlatSegmentImageResolutionTests {
    private let baseURL = URL(string: "https://server.example.com")! // swiftlint:disable:this force_unwrapping
    private let workspaceID = "ws-abc123"

    // MARK: - Image-only paragraph promotion

    @Test func imageOnlyParagraphWithWorkspaceContextProducesImageSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "charts/mockup.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "Chart")
            #expect(url.absoluteString.contains("/workspaces/ws-abc123/raw/charts/mockup.png"))
            #expect(url.absoluteString.hasPrefix("https://server.example.com"))
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func imageOnlyParagraphWithoutWorkspaceContextFallsBackToAltText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "charts/mockup.png")])
        ]
        // No workspaceID or serverBaseURL — should fall back to alt text in brackets
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("[Chart]"))
        } else {
            Issue.record("Expected .text fallback segment")
        }
    }

    @Test func imageOnlyParagraphWithoutWorkspaceContextUsesGenericImageFallbackWhenAltIsEmpty() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "   ", source: "charts/mockup.png")])
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .text(let attr) = segments[0] {
            let text = String(attr.characters)
            #expect(text.contains("[image]"))
        } else {
            Issue.record("Expected .text fallback segment")
        }
    }

    @Test func paragraphWithTextAndImagePromotesResolvableImage() {
        let blocks: [MarkdownBlock] = [
            .paragraph([
                .text("See this: "),
                .image(alt: "Chart", source: "chart.png"),
            ])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        #expect(segments.count == 2)
        if case .text(let text) = segments[0] {
            #expect(String(text.characters).contains("See this:"))
        } else {
            Issue.record("Expected text before mixed paragraph image")
        }
        if case .image(let alt, let url) = segments[1] {
            #expect(alt == "Chart")
            #expect(url.absoluteString.contains("/raw/chart.png"))
        } else {
            Issue.record("Expected resolvable mixed paragraph image to render")
        }
    }

    @Test(arguments: ["png", "jpg", "jpeg", "gif", "webp"])
    func readSupportedImageLinkInMixedParagraphProducesImageSegment(ext: String) {
        let markdown = "Before ![Red green](fixtures/red-green.\(ext)) after"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )

        #expect(segments.count == 3)
        if case .text(let text) = segments[0] {
            #expect(String(text.characters).contains("Before"))
        } else {
            Issue.record("Expected text before inline image")
        }
        if case .image(let alt, let url) = segments[1] {
            #expect(alt == "Red green")
            #expect(url.absoluteString.contains("/raw/fixtures/red-green.\(ext)"))
        } else {
            Issue.record("Expected read-supported markdown image to become an image segment")
        }
        if case .text(let text) = segments[2] {
            #expect(String(text.characters).contains("after"))
        } else {
            Issue.record("Expected text after inline image")
        }
    }

    @Test func absoluteHTTPSURLImageIsPromotedToImageSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Remote", source: "https://example.com/image.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "Remote")
            #expect(url.absoluteString == "https://example.com/image.png")
        } else {
            Issue.record("Expected .image segment for https URL, got \(segments[0])")
        }
    }

    @Test func absoluteHTTPURLImageIsPromotedToImageSegment() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "HTTP", source: "http://cdn.example.com/photo.jpg")])
        ]
        // No workspace context needed for absolute URLs
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "HTTP")
            #expect(url.absoluteString == "http://cdn.example.com/photo.jpg")
        } else {
            Issue.record("Expected .image segment for http URL, got \(segments[0])")
        }
    }

    @Test func dataURIImageSourceIsNotPromoted() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Inline", source: "data:image/png;base64,abc123")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        if case .image = segments[0] {
            Issue.record("data: URI should not be promoted to workspace .image segment")
        }
    }

    @Test func imageURLContainsWorkspaceIDAndFilePath() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "output/figure1.jpg")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: "my-workspace",
            serverBaseURL: URL(string: "https://pi.local:8080")! // swiftlint:disable:this force_unwrapping
        )
        if case .image(_, let url) = segments[0] {
            let abs = url.absoluteString
            #expect(abs.contains("/workspaces/my-workspace/raw/output/figure1.jpg"))
            #expect(abs.hasPrefix("https://pi.local:8080"))
        } else {
            Issue.record("Expected .image segment")
        }
    }

    @Test func absolutePathWithoutSessionContextFallsBackToAltText() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "/absolute/path/image.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        if case .text = segments[0] {
            // Without session context, absolute filesystem paths cannot be resolved safely.
        } else {
            Issue.record("Expected fallback to text without session context")
        }
    }

    @Test func imageAndTextParagraphsAreSeparatedCorrectly() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.text("Before the chart.")]),
            .paragraph([.image(alt: "Chart", source: "chart.png")]),
            .paragraph([.text("After the chart.")]),
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        // Expect: text (merged before+after gets interrupted by .image)
        // Segments: .text("Before..."), .image("Chart"), .text("After...")
        #expect(segments.count == 3)
        if case .text = segments[0] {} else { Issue.record("Expected text before image") }
        if case .image(let alt, _) = segments[1] {
            #expect(alt == "Chart")
        } else {
            Issue.record("Expected .image segment in middle")
        }
        if case .text = segments[2] {} else { Issue.record("Expected text after image") }
    }

    @Test func emptyAltImageInImageOnlyParagraphWithWorkspaceContext() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "", source: "chart.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL
        )
        // Empty alt: promoted to .image with empty alt and a generic placeholder on load failure.
        if case .image(let alt, _) = segments[0] {
            #expect(alt.isEmpty)
        } else {
            // Also acceptable: empty paragraph filtered out entirely
            #expect(segments.isEmpty || segments.count == 1)
        }
    }

    // MARK: - Source directory resolution

    @Test func relativeImagePathIsResolvedAgainstSourceDirectory() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Chart", source: "images/chart.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            sourceDirectory: "docs"
        )
        #expect(segments.count == 1)
        if case .image(_, let url) = segments[0] {
            // Should resolve to docs/images/chart.png, not images/chart.png
            #expect(url.absoluteString.contains("/raw/docs/images/chart.png"),
                    "Expected docs/images/chart.png, got \(url.absoluteString)")
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func absolutePathWithSessionContextDoesNotResolveImage() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "/absolute/image.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            sessionID: "sess-123",
            serverBaseURL: baseURL,
            sourceDirectory: "docs"
        )
        #expect(segments.allSatisfy { segment in
            if case .image = segment { return false }
            return true
        })
    }

    @Test func fileURLWithSessionContextDoesNotResolveImage() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Local", source: "file:///Users/example/workspace/oppi/downloads/local.jpeg")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            sessionID: "sess-123",
            serverBaseURL: baseURL
        )
        #expect(segments.allSatisfy { segment in
            if case .image = segment { return false }
            return true
        })
    }

    @Test func httpsURLIgnoresSourceDirectory() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Remote", source: "https://example.com/pic.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            sourceDirectory: "docs"
        )
        if case .image(_, let url) = segments[0] {
            #expect(url.absoluteString == "https://example.com/pic.png",
                    "HTTPS URLs should pass through unchanged")
        }
    }

    @Test func nilSourceDirectoryLeavesPathUnchanged() {
        let blocks: [MarkdownBlock] = [
            .paragraph([.image(alt: "Fig", source: "images/fig.png")])
        ]
        let segments = FlatSegment.build(
            from: blocks,
            workspaceID: workspaceID,
            serverBaseURL: baseURL,
            sourceDirectory: nil
        )
        if case .image(_, let url) = segments[0] {
            #expect(url.absoluteString.contains("/raw/images/fig.png"))
            #expect(!url.absoluteString.contains("docs"))
        }
    }
}

// MARK: - Session file full-screen content

@Suite("Session file full-screen content")
struct SessionFileFullScreenContentBuilderTests {
    @Test func outsideWorkspaceMarkdownDoesNotExposeAbsoluteFileFetcher() throws {
        let serverBaseURL = try #require(URL(string: "https://server.example.com"))
        let content = SessionFileFullScreenContentBuilder.content(
            text: "![Generated chart](/tmp/chart.png)",
            filePath: "/tmp/session-report.md",
            workspaceID: "workspace-1",
            serverBaseURL: serverBaseURL,
            workspaceHostMount: "/Users/example/workspace/oppi",
            fetchSessionFileData: { _ in Data([1]) },
            sessionID: "session-1"
        )

        guard case .markdown(_, let filePath, let workspaceContext) = content else {
            Issue.record("Expected markdown full-screen content")
            return
        }

        #expect(filePath == "/tmp/session-report.md")
        let context = try #require(workspaceContext)
        #expect(context.workspaceID == "workspace-1")
        #expect(context.sessionID == "session-1")
        #expect(context.fetchSessionFile == nil)
    }

    @Test func hostFileMarkdownKeepsAbsoluteDisplayPath() throws {
        let serverBaseURL = try #require(URL(string: "https://server.example.com"))
        let content = SessionFileFullScreenContentBuilder.content(
            text: "# Host note",
            filePath: "/tmp/session-report.md",
            workspaceID: "workspace-1",
            serverBaseURL: serverBaseURL,
            workspaceHostMount: "/tmp",
            fetchSessionFileData: { _ in Data([1]) },
            sessionID: "session-1"
        )

        guard case .markdown(_, let filePath, _) = content else {
            Issue.record("Expected markdown full-screen content")
            return
        }
        #expect(filePath == "/tmp/session-report.md")
    }
}

// MARK: - Table cell inline content (links in table cells)

@Suite("Table cell inline content")
struct TableCellInlineContentTests {

    /// Regression test: markdown links inside table cells should preserve
    /// their destination URL through the parse pipeline so they can be
    /// rendered as clickable links.
    @Test func parsedTableCellPreservesLinkURL() {
        let md = """
        | Title | Link |
        | --- | --- |
        | Article | [Click here](https://example.com) |
        """
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)

        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected .table block, got \(blocks[0])")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Title", "Link"])
        #expect(rows.count == 1)

        // The second cell should contain a .link inline with the destination URL.
        let linkCell = rows[0][1]
        let hasLink = linkCell.contains { inline in
            if case .link(_, let dest) = inline {
                return dest == "https://example.com"
            }
            return false
        }
        #expect(hasLink, "Table cell should preserve link with destination URL")
        #expect(plainText(from: linkCell) == "Click here")
    }

    @Test func parsedTableCellPreservesMultipleLinks() {
        let md = """
        | Source | Read? |
        | --- | --- |
        | [Article A](https://a.com) | [Full](https://a.com/full) |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = blocks[0] else {
            Issue.record("Expected .table block")
            return
        }
        let cell0HasLink = rows[0][0].contains {
            if case .link(_, let d) = $0 { return d == "https://a.com" }
            return false
        }
        let cell1HasLink = rows[0][1].contains {
            if case .link(_, let d) = $0 { return d == "https://a.com/full" }
            return false
        }
        #expect(cell0HasLink, "First cell should preserve link URL")
        #expect(cell1HasLink, "Second cell should preserve link URL")
    }

    @Test func parsedTablePlainTextCellsUnchanged() {
        let md = """
        | Name | Value |
        | --- | --- |
        | foo | bar |
        """
        let blocks = parseCommonMark(md)
        guard case .table(let headers, let rows) = blocks[0] else {
            Issue.record("Expected .table block")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Name", "Value"])
        #expect(rows[0].map { plainText(from: $0) } == ["foo", "bar"])
    }

    @Test func parsedTableCellWithBoldAndLink() {
        let md = """
        | Col |
        | --- |
        | **bold** and [link](https://x.com) |
        """
        let blocks = parseCommonMark(md)
        guard case .table(_, let rows) = blocks[0] else {
            Issue.record("Expected .table block")
            return
        }
        let cell = rows[0][0]
        let hasStrong = cell.contains { if case .strong = $0 { return true } else { return false } }
        let hasLink = cell.contains { if case .link = $0 { return true } else { return false } }
        #expect(hasStrong, "Table cell should preserve bold formatting")
        #expect(hasLink, "Table cell should preserve link")
    }

    @Test func flatSegmentTablePassesThroughInlines() {
        let blocks: [MarkdownBlock] = [
            .table(
                headers: [[.text("Title")], [.text("Link")]],
                rows: [
                    [[.text("Art")], [.link(children: [.text("Click")], destination: "https://example.com")]],
                ]
            )
        ]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        guard case .table(_, let rows) = segments[0] else {
            Issue.record("Expected .table segment")
            return
        }
        let hasLink = rows[0][1].contains { inline in
            if case .link(_, let dest) = inline { return dest == "https://example.com" }
            return false
        }
        #expect(hasLink, "FlatSegment.table should preserve link inlines")
    }

    @Test func codeSpanClosingAfterBackslashKeepsTableStructureAndRewritesFollowingWikiLink() throws {
        let markdown = """
        | Code | Reference |
        | --- | --- |
        | ``literal \\`` [[RV97TbYj|open target]] `` |
        """

        let blocks = parseCommonMark(markdown)
        guard case .table(let headers, let rows) = try #require(blocks.first) else {
            Issue.record("Expected a table block")
            return
        }
        #expect(headers.count == 2)
        #expect(rows.count == 1)
        #expect(rows[0].count == 2)

        // The preprocessor feeds cmark-gfm, while wiki-link rewrite consumes
        // its CommonMark inline result. Model that result directly to prove
        // the wiki text after the closed code span remains a tappable link.
        let segments = FlatSegment.build(
            from: [.table(
                headers: [[.text("Code")], [.text("Reference")]],
                rows: [[
                    [.code(#"literal \"#)],
                    [.text(" "), .text("[[RV97TbYj|open target]]")],
                ]]
            )],
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sessionID: "session-source"
        )
        guard case .table(_, let renderedRows) = try #require(segments.first) else {
            Issue.record("Expected a table segment")
            return
        }
        guard case .link(_, let destination) = try #require(renderedRows[0][1].last),
              let url = try #require(destination.flatMap(URL.init(string:))),
              let reference = try #require(ResourceReferenceURL.parse(url)) else {
            Issue.record("Expected a tappable resource reference")
            return
        }
        #expect(reference.target == "RV97TbYj")
    }

    @Test func flatSegmentTableRewritesWikiLinksWithWorkspaceContext() throws {
        let md = """
        | Title | Link |
        | --- | --- |
        | Session | [[notes/sessions/oppi-jZhDRKeV|session note]] |
        """
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark, workspaceID: "workspace-1")

        #expect(segments.count == 1)
        guard case .table(_, let rows) = segments[0] else {
            Issue.record("Expected .table segment")
            return
        }
        let linkInline = try #require(rows[0][1].first)
        guard case .link(let children, let destination) = linkInline else {
            Issue.record("Expected wiki link to be rewritten in table cell, got \(linkInline)")
            return
        }
        #expect(plainText(from: children) == "session note")
        let url = try #require(destination.flatMap(URL.init(string:)))
        let parsed = try #require(ResourceReferenceURL.parse(url))
        #expect(parsed.target == "notes/sessions/oppi-jZhDRKeV")
        #expect(parsed.workspaceID == "workspace-1")
        #expect(parsed.fileCandidatePath == "notes/sessions/oppi-jZhDRKeV.md")
    }
}

// MARK: - End-to-end online image parsing

@Suite("Online image end-to-end")
struct OnlineImageEndToEndTests {

    @Test func httpsImageURLParsedFromRawMarkdown() {
        let md = "![GitHub avatar](https://avatars.githubusercontent.com/u/1?v=4)"
        let blocks = parseCommonMark(md)
        #expect(blocks.count == 1)
        if case .paragraph(let inlines) = blocks[0] {
            #expect(inlines.count == 1)
            if case .image(let alt, let source) = inlines[0] {
                #expect(alt == "GitHub avatar")
                #expect(source == "https://avatars.githubusercontent.com/u/1?v=4")
            } else {
                Issue.record("Expected .image inline, got \(inlines[0])")
            }
        } else {
            Issue.record("Expected .paragraph, got \(blocks[0])")
        }
    }

    @Test func httpsImageURLProducesImageSegment() {
        let md = "![GitHub avatar](https://avatars.githubusercontent.com/u/1?v=4)"
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "GitHub avatar")
            #expect(url.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func httpsImageWithWorkspaceContextStillWorks() {
        let md = "![test](https://example.com/photo.jpg)"
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(
            from: blocks,
            themeID: .dark,
            workspaceID: "ws-123",
            serverBaseURL: URL(string: "https://server.local")!
        )
        #expect(segments.count == 1)
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "test")
            #expect(url.absoluteString == "https://example.com/photo.jpg")
        } else {
            Issue.record("Expected .image segment, got \(segments[0])")
        }
    }

    @Test func multipleImagesInMarkdown() {
        let md = """
        # Title

        ![img1](https://example.com/a.png)

        Some text

        ![img2](https://example.com/b.png)
        """
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        let imageSegments = segments.filter {
            if case .image = $0 { return true } else { return false }
        }
        #expect(imageSegments.count == 2, "Expected 2 image segments, got \(imageSegments.count). All segments: \(segments)")
    }
}

@Suite("Online image without workspace context")
struct OnlineImageNoWorkspaceTests {

    @Test func httpsImageWorksWithoutWorkspaceContext() {
        // This is exactly what MarkdownFileView does — no workspaceID, no serverBaseURL
        let md = "![GitHub avatar](https://avatars.githubusercontent.com/u/1?v=4)"
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        // Must produce .image, not .text with [GitHub avatar]
        #expect(segments.count == 1, "Expected 1 segment, got \(segments.count)")
        if case .image(let alt, let url) = segments[0] {
            #expect(alt == "GitHub avatar")
            #expect(url.scheme == "https")
        } else {
            Issue.record("Expected .image segment without workspace context, got \(segments[0])")
        }
    }

    @Test func fullMarkdownFileContent() {
        // Simulate the exact test file content
        let md = """
        ## Online Images

        ### GitHub avatar

        ![GitHub user 1](https://avatars.githubusercontent.com/u/1?v=4)

        ### Wikipedia image

        ![Wikipedia globe](https://upload.wikimedia.org/wikipedia/commons/thumb/8/80/Wikipedia-logo-v2.svg/200px-Wikipedia-logo-v2.svg.png)
        """
        let blocks = parseCommonMark(md)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        let imageSegments = segments.filter {
            if case .image = $0 { return true } else { return false }
        }
        #expect(imageSegments.count == 2, "Expected 2 image segments in full markdown. All segments: \(segments.map { "\($0)" }.joined(separator: ", "))")
    }
}

// MARK: - Assistant markdown inline image rendering

@Suite("Assistant markdown inline image rendering")
@MainActor
struct AssistantMarkdownInlineImageRenderingTests {

    @Test(arguments: ["png", "jpg", "jpeg", "gif", "webp"])
    func mixedParagraphReadSupportedImageRendersNativeImageView(ext: String) async throws {
        let imageData = try makeReadSupportedTestImageData(ext: ext)
        let markdownView = AssistantMarkdownContentView()
        markdownView.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        markdownView.fetchWorkspaceFile = { workspaceID, path in
            #expect(workspaceID == "workspace-1")
            #expect(path == "fixtures/red-green.\(ext)")
            return imageData
        }

        let serverBaseURL = try #require(URL(string: "https://server.example.com/api"))
        markdownView.apply(configuration: .make(
            content: "Before ![Red green](fixtures/red-green.\(ext)) after",
            isStreaming: false,
            themeID: .dark,
            workspaceID: "workspace-1",
            serverBaseURL: serverBaseURL
        ))
        markdownView.layoutIfNeeded()

        let imageHost = try #require(timelineFirstView(ofType: NativeMarkdownImageView.self, in: markdownView))
        let decoded = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            markdownView.layoutIfNeeded()
            return timelineAllImageViews(in: imageHost).contains { !$0.isHidden && $0.image != nil }
        }

        #expect(decoded, "Mixed paragraph .\(ext) markdown images should render as native image views")

        let renderedText = timelineAllTextViews(in: markdownView)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: " ")
        #expect(renderedText.contains("Before"))
        #expect(renderedText.contains("after"))
        #expect(!renderedText.contains("[Red green]"))
    }

    @Test func mixedParagraphFileURLFallsBackWithoutFetching() throws {
        let markdownView = AssistantMarkdownContentView()
        markdownView.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        markdownView.fetchSessionFile = { _, _, _ in
            Issue.record("Absolute markdown images must not use the session raw-file fetcher")
            return Data()
        }

        let serverBaseURL = try #require(URL(string: "https://server.example.com/api"))
        markdownView.apply(configuration: .make(
            content: "Before ![Red green](file:///Users/example/workspace/oppi/downloads/red-green.jpeg) after",
            isStreaming: false,
            themeID: .dark,
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: serverBaseURL
        ))
        markdownView.layoutIfNeeded()

        #expect(timelineFirstView(ofType: NativeMarkdownImageView.self, in: markdownView) == nil)
        let renderedText = timelineAllTextViews(in: markdownView)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: " ")
        #expect(renderedText.contains("Before"))
        #expect(renderedText.contains("[Red green]"))
        #expect(renderedText.contains("after"))
    }

    private func makeReadSupportedTestImageData(ext: String) throws -> Data {
        switch ext {
        case "png":
            return try #require(makeRedGreenTestImage().pngData())
        case "jpg", "jpeg":
            return try #require(makeRedGreenTestImage().jpegData(compressionQuality: 0.9))
        case "gif":
            return try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="))
        case "webp":
            return try #require(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
        default:
            Issue.record("Unsupported test image extension: \(ext)")
            return Data()
        }
    }

    private func makeRedGreenTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            UIColor.green.setFill()
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }
    }
}

// MARK: - Remote markdown image policy

@Suite("Remote markdown image policy")
struct RemoteMarkdownImagePolicyTests {

    @Test func allowsPublicHTTPSHosts() throws {
        let url = try #require(URL(string: "https://images.example.com/photo.png"))
        #expect(RemoteMarkdownImagePolicy.decision(for: url) == .loadableRemote)
    }

    @Test func blocksPlainHTTPHosts() throws {
        let url = try #require(URL(string: "http://images.example.com/photo.png"))
        #expect(RemoteMarkdownImagePolicy.decision(for: url) == .blockedRemote)
    }

    @Test(arguments: [
        "https://localhost/photo.png",
        "https://router.local/photo.png",
        "https://192.168.1.1/photo.png",
        "https://10.0.0.2/photo.png",
        "https://172.16.0.9/photo.png",
        "https://[::1]/photo.png",
        "https://[fe80::1]/photo.png",
        "https://[fc00::1]/photo.png",
    ])
    func blocksLocalNetworkTargets(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        #expect(RemoteMarkdownImagePolicy.decision(for: url) == .blockedRemote)
    }

    @Test func resolvedDecisionBlocksHostnamesThatResolveToLoopback() async throws {
        let url = try #require(URL(string: "https://avatar.example.com/photo.png"))

        #expect(RemoteMarkdownImagePolicy.decision(for: url) == .loadableRemote)

        let resolved = await RemoteMarkdownImagePolicy.resolvedDecision(for: url) { _ in
            ["127.0.0.1"]
        }

        #expect(resolved == .blockedRemote)
    }

    @Test func resolvedDecisionAllowsPublicResolvedAddresses() async throws {
        let url = try #require(URL(string: "https://avatar.example.com/photo.png"))

        let resolved = await RemoteMarkdownImagePolicy.resolvedDecision(for: url) { _ in
            ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]
        }

        #expect(resolved == .loadableRemote)
    }

    @Test func resolvedDecisionFailsClosedWhenResolutionErrors() async throws {
        enum StubError: Error { case failed }

        let url = try #require(URL(string: "https://avatar.example.com/photo.png"))
        let resolved = await RemoteMarkdownImagePolicy.resolvedDecision(for: url) { _ in
            throw StubError.failed
        }

        #expect(resolved == .blockedRemote)
    }
}

// MARK: - NativeMarkdownImageView loading

@Suite("NativeMarkdownImageView online loading")
@MainActor
struct NativeMarkdownImageViewTests {

    @Test func remoteHTTPSImageRequiresTapBeforeLoading() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 160)
        view.layoutIfNeeded()

        let imageData = try #require(Self.makeRedGreenImage().pngData())
        var fetchCount = 0
        view.fetchRemoteImage = { url in
            fetchCount += 1
            #expect(url.absoluteString == "https://example.com/image.png")
            return imageData
        }

        let url = try #require(URL(string: "https://example.com/image.png"))
        view.apply(url: url, alt: "Test", fetchWorkspaceFile: nil, fetchSessionFile: nil)

        #expect(fetchCount == 0, "Remote markdown images should not auto-fetch before user action")
        let loadButton = try #require(timelineAllViews(in: view).compactMap { $0 as? UIButton }.first)
        #expect(!loadButton.isHidden)
        loadButton.sendActions(for: .touchUpInside)

        let loaded = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            timelineAllImageViews(in: view).contains { !$0.isHidden && $0.image != nil }
        }
        #expect(loaded, "NativeMarkdownImageView should load and display the remote image after explicit tap")
        #expect(fetchCount == 1)
    }

    @Test func blockedRemoteURLShowsBlockedPlaceholderWithoutFetching() throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 160)
        view.layoutIfNeeded()
        view.fetchRemoteImage = { _ in
            Issue.record("Blocked remote URLs must not fetch")
            return Data()
        }

        let url = try #require(URL(string: "http://192.168.1.1/router.png"))
        view.apply(url: url, alt: "Router", fetchWorkspaceFile: nil, fetchSessionFile: nil)

        let labels = timelineAllViews(in: view).compactMap { $0 as? UILabel }
        #expect(labels.contains { $0.text?.contains("remote image blocked") == true && !$0.isHidden })
    }

    @Test func showsLoadingPlaceholderHeight() {
        let view = NativeMarkdownImageView()
        // Force layout
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        view.layoutIfNeeded()

        let url = URL(string: "https://example.com/test.png")!
        view.apply(url: url, alt: "Loading test", fetchWorkspaceFile: nil, fetchSessionFile: nil)

        // The view should reserve a medium inline-prose placeholder while loading.
        let expectedHeight = ImageViewportSizing.policy(for: .inlineProse, screenHeight: UIScreen.main.bounds.height).placeholderHeight
        let heightConstraints = view.constraints.filter { $0.firstAttribute == .height }
        let hasPlaceholderHeight = heightConstraints.contains { $0.constant == expectedHeight }
        #expect(hasPlaceholderHeight, "Should have inline-prose loading placeholder height. Constraints: \(heightConstraints.map { "\($0.constant)" })")
    }

    @Test func svgLoadedStateInstallsTapOverlayForFullscreen() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutIfNeeded()

        let svg = """
        <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"300\" height=\"180\">
          <rect width=\"300\" height=\"180\" fill=\"#111827\"/>
        </svg>
        """
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-1",
            filePath: "chart.svg"
        ))
        view.apply(
            url: url,
            alt: "Chart",
            fetchWorkspaceFile: { _, _ in Data(svg.utf8) },
            fetchSessionFile: nil
        )

        let hasTapOverlay = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            view.layoutIfNeeded()
            return timelineAllViews(in: view).contains { $0.accessibilityIdentifier == "markdown-image.svg.tap-overlay" }
        }

        #expect(hasTapOverlay, "SVG markdown images need an explicit tap target for fullscreen")
    }

    @Test func unsupportedURLWithEmptyAltShowsGenericPlaceholder() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        view.layoutIfNeeded()

        view.apply(
            url: URL(fileURLWithPath: "/tmp/not-an-inline-image"),
            alt: "",
            fetchWorkspaceFile: nil,
            fetchSessionFile: nil
        )

        var showedPlaceholder = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            let visibleLabels = view.subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden }
            if visibleLabels.contains(where: { $0.text == "[image]" }) {
                showedPlaceholder = true
                break
            }
        }

        #expect(showedPlaceholder, "Broken markdown image should show a generic placeholder instead of collapsing")
        #expect(!view.isHidden)
    }

    @Test func fullScreenMarkdownBodyDoesNotFetchSessionAbsolutePaths() {
        let body = NativeFullScreenMarkdownBody(
            content: "![Generated chart](/tmp/chart.png)",
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "workspace-1",
            sessionID: "session-1",
            serverBaseURL: URL(string: "https://example.com/api")!,
            fetchWorkspaceFile: nil,
            fetchSessionFile: { _, _, _ in
                Issue.record("Absolute markdown images must not use the session raw-file fetcher")
                return Data()
            }
        )

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        #expect(timelineFirstView(ofType: NativeMarkdownImageView.self, in: body) == nil)
    }

    private static func makeRedGreenImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            UIColor.green.setFill()
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }
    }
}

// MARK: - NativeLatexBlockView tests

@Suite("NativeLatexBlockView", .serialized)
@MainActor
struct NativeLatexBlockViewTests {
    // The total fraction box includes numerator/denominator stacking; compare
    // the largest contiguous ink band so undersized glyphs cannot pass by box height alone.
    private func largestVisibleBandHeight(of image: UIImage) -> CGFloat? {
        guard let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0 else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var largestBand = 0
        var currentBand = 0
        for y in 0..<height {
            let rowHasInk = (0..<width).contains { x in
                pixels[(y * width + x) * 4 + 3] > 16
            }
            if rowHasInk {
                currentBand += 1
                largestBand = max(largestBand, currentBand)
            } else {
                currentBand = 0
            }
        }
        return CGFloat(largestBand) / max(image.scale, 1)
    }

    private func visibleFormulaScrollView(in root: UIView) -> HorizontalPanPassthroughScrollView? {
        if let scrollView = root as? HorizontalPanPassthroughScrollView, !scrollView.isHidden {
            return scrollView
        }
        for child in root.subviews where !child.isHidden {
            if let found = visibleFormulaScrollView(in: child) {
                return found
            }
        }
        return nil
    }

    private let wideDeviceFormula = #"""
    \begin{aligned}
    \mathbf H &= \mathbf X^\top\mathbf W\mathbf X+\lambda\mathbf I,\\
    \Delta\theta &= -\mathbf H^{-1}\nabla_\theta\mathcal L,\\
    \begin{bmatrix}x_{t+1}\\v_{t+1}\end{bmatrix}
    &=
    \begin{bmatrix}1&\Delta t\\0&1\end{bmatrix}
    \begin{bmatrix}x_t\\v_t\end{bmatrix}
    +
    \begin{bmatrix}\frac12\Delta t^2\\\Delta t\end{bmatrix}a_t.
    \end{aligned}
    """#

    /// Characterization: natural-width geometry creates horizontal overflow;
    /// gesture ownership is proven separately through the nested recognizer test.
    @Test func wideTimelineFormulaCreatesReachableHorizontalOverflowWithoutVerticalDrift() throws {
        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.layoutIfNeeded()

        view.applyAsFormulaSync(code: wideDeviceFormula, palette: ThemeID.dark.palette)
        view.layoutIfNeeded()

        let scrollView = try #require(visibleFormulaScrollView(in: view))
        #expect(scrollView.contentSize.width > scrollView.bounds.width + 1)
        let maximumOffset = scrollView.contentSize.width - scrollView.bounds.width
        scrollView.setContentOffset(CGPoint(x: maximumOffset, y: 0), animated: false)
        view.layoutIfNeeded()
        #expect(scrollView.contentOffset.x > 0)
        #expect(abs(scrollView.contentOffset.y) < 0.5)
        #expect(HorizontalPanPassthroughScrollView.shouldBeginHorizontalPan(with: CGPoint(x: -240, y: 4)))
        #expect(!HorizontalPanPassthroughScrollView.shouldBeginHorizontalPan(with: CGPoint(x: 4, y: -240)))
    }

    @Test func nestedTimelineGestureRecognizerHandsVerticalDragToOuterTimeline() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let outer = UICollectionView(
            frame: window.bounds,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        window.addSubview(outer)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 16, y: 100, width: 320, height: 240)
        outer.addSubview(view)
        view.applyAsFormulaSync(code: wideDeviceFormula, palette: ThemeID.dark.palette)
        outer.layoutIfNeeded()
        view.layoutIfNeeded()

        let inner = try #require(visibleFormulaScrollView(in: view))
        #expect(inner.contentSize.width > inner.bounds.width)
        #expect(outer.panGestureRecognizer.isEnabled)

        inner.panVelocityOverrideForTesting = CGPoint(x: 6, y: -240)
        #expect(!inner.gestureRecognizerShouldBegin(inner.panGestureRecognizer))
        #expect(outer.panGestureRecognizer.isEnabled)

        inner.panVelocityOverrideForTesting = CGPoint(x: -240, y: 6)
        #expect(inner.gestureRecognizerShouldBegin(inner.panGestureRecognizer))
    }

    @Test func wideTimelineFormulaKeepsEffectiveDisplayedGlyphsReadable() throws {
        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.layoutIfNeeded()

        view.applyAsFormulaSync(code: wideDeviceFormula, palette: ThemeID.dark.palette)
        view.layoutIfNeeded()

        let scrollView = try #require(visibleFormulaScrollView(in: view))
        let imageView = try #require(timelineAllImageViews(in: scrollView).first { $0.image != nil })
        let image = try #require(imageView.image)
        let sourceBand = try #require(largestVisibleBandHeight(of: image))
        let presentedScale = min(
            imageView.bounds.width / image.size.width,
            imageView.bounds.height / image.size.height
        )
        let effectiveBand = sourceBand * presentedScale

        #expect(presentedScale >= 0.99, "Wide formulas must pan at natural scale, not aspect-fit shrink")
        #expect(effectiveBand >= AppFont.messageBody.xHeight * 0.9)
    }

    @Test func formulaOpenActionHasLocalAccessibilityMetadataAndHitHeight() {
        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        view.layoutIfNeeded()
        view.applyAsFormulaSync(code: #"\frac{1}{2} + x"#, palette: ThemeID.dark.palette)
        view.layoutIfNeeded()

        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityTraits.contains(.button))
        #expect(view.accessibilityLabel?.contains("Math") == true)
        #expect(view.accessibilityLabel?.contains("1/2") == true)
        #expect(view.accessibilityLabel?.contains(#"\frac"#) == false)
        #expect(view.accessibilityHint?.localizedCaseInsensitiveContains("full screen") == true)
        #expect(view.bounds.height >= 44)
    }

    /// Characterization: full-screen constraints expose both horizontal ends.
    @Test func fullScreenFormulaCreatesReachableHorizontalOverflowToBothEnds() throws {
        let body = NativeFullScreenRenderedDocumentBody(
            content: .latex(wideDeviceFormula),
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let scrollView = try #require(timelineFirstView(ofType: UIScrollView.self, in: body))
        #expect(scrollView.contentSize.width > scrollView.bounds.width + 1)
        let maximumOffset = scrollView.contentSize.width - scrollView.bounds.width
        scrollView.setContentOffset(CGPoint(x: maximumOffset, y: 0), animated: false)
        host.layoutIfNeeded()
        #expect(scrollView.contentOffset.x > 0)
        #expect(abs(scrollView.contentOffset.y) < 0.5)
        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [scrollView]
        ))
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [scrollView]
        ))

        scrollView.setContentOffset(.zero, animated: false)
        #expect(abs(scrollView.contentOffset.x) < 0.5)
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [scrollView]
        ))
    }

    @Test func fullScreenFormulaExposesLocalizedAccessibilityAndForcesOnlyMathLTR() throws {
        let body = NativeFullScreenRenderedDocumentBody(
            content: .latex(#"\frac{1}{2} + x"#),
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        body.semanticContentAttribute = .forceRightToLeft
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let formula = try #require(timelineFirstView(ofType: GraphicalRendererUIView.self, in: body))
        #expect(formula.isAccessibilityElement)
        #expect(formula.accessibilityTraits.contains(.image))
        #expect(formula.accessibilityLabel?.localizedCaseInsensitiveContains("math") == true)
        #expect(formula.accessibilityLabel?.contains("1/2") == true)
        #expect(formula.semanticContentAttribute == .forceLeftToRight)
        #expect(body.semanticContentAttribute == .forceRightToLeft)
    }

    @Test func compositeFractionAccessibilityPreservesGrouping() {
        let source = #"\frac{a+b}{c+d}"#
        let label = FlatSegment.formulaAccessibilityLabel(for: source)

        #expect(label.contains("(a + b)/(c + d)"), "Composite operands must remain grouped: \(label)")
        #expect(!label.contains("a + b/c + d"))
    }

    @Test func compositeScriptAccessibilityPreservesGrouping() {
        let superscriptLabel = FlatSegment.formulaAccessibilityLabel(for: "x^{a+b}")
        let subscriptLabel = FlatSegment.formulaAccessibilityLabel(for: "x_{i+j}")
        let combined = FlatSegment.formulaAccessibilityLabel(for: "x_{i+j}^{a+b}")

        #expect(superscriptLabel.contains("x^(a + b)"), "Composite superscript must stay grouped: \(superscriptLabel)")
        #expect(subscriptLabel.contains("x_(i + j)"), "Composite subscript must stay grouped: \(subscriptLabel)")
        #expect(combined.contains("x_(i + j)^(a + b)"), "Combined scripts must stay grouped: \(combined)")
    }

    @Test func operatorLimitAccessibilityPreservesGrouping() {
        let label = FlatSegment.formulaAccessibilityLabel(for: #"\sum_{i=1}^{n+1}"#)

        #expect(label.contains("∑_(i = 1)^(n + 1)"), "Operator limits must stay grouped: \(label)")
    }

    @Test func accentAccessibilityFallsBackToExactTeXInsteadOfDroppingMeaning() {
        for source in [#"\hat{x}"#, #"\vec{v}"#, #"\overline{AB}"#] {
            let label = FlatSegment.formulaAccessibilityLabel(for: source)
            #expect(label.localizedCaseInsensitiveContains("source"))
            #expect(label.contains(source), "Accent source must be preserved exactly: \(label)")
        }
    }

    @Test func malformedFullScreenLatexBodyShowsExactSourceWithoutPartialRaster() throws {
        let source = "\\frac{a}\n\\unsupported{x}"
        let body = NativeFullScreenRenderedDocumentBody(
            content: .latex(source),
            themeID: .dark,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        #expect(timelineFirstView(ofType: GraphicalRendererUIView.self, in: body) == nil)
        let visibleSource = timelineAllTextViews(in: body)
            .filter { timelineViewIsVisible($0) }
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(visibleSource == source)
    }

    @Test func malformedLatexFileBodyShowsExactSourceWithoutPartialRaster() throws {
        let source = "\\left x\\right)\n\\unsupported{x}"
        let controller = UIHostingController(rootView: LaTeXFileView(
            content: source,
            filePath: "broken.tex",
            presentation: .document
        ))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        #expect(timelineFirstView(ofType: GraphicalRendererUIView.self, in: controller.view) == nil)
        let visibleSource = timelineAllTextViews(in: controller.view)
            .filter { timelineViewIsVisible($0) }
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(visibleSource.contains(source))
    }

    @Test func malformedCompletedFormulaFallsBackToExactSourceInsteadOfRaster() throws {
        let malformedSources = [
            #"\frac{a}"#,
            #"\begin{matrix}1&2"#,
            #"\left(x"#,
            #"\unsupported{x}"#,
        ]

        for source in malformedSources {
            let delimited = "$$\n\(source)\n$$"
            let segments = FlatSegment.build(from: parseCommonMark(delimited), themeID: .dark)
            #expect(!segments.contains { if case .latexBlock = $0 { return true }; return false })
            let visible = segments.compactMap { segment -> String? in
                guard case .text(let attributed) = segment else { return nil }
                return String(attributed.characters)
            }.joined(separator: "\n")
            #expect(visible == delimited)
        }
    }

    @Test func hostileWideFormulaDeterministicallyFallsBackBeforeRasterAllocation() throws {
        #expect(!DocumentRenderPipeline.naturalRasterBudget.permits(
            pointSize: CGSize(width: 2_049, height: 40),
            scale: 2
        ))
        #expect(!DocumentRenderPipeline.naturalRasterBudget.permits(
            pointSize: CGSize(width: 2_048, height: 2_048),
            scale: 2
        ))
        let source = String(repeating: "x", count: 600)
        let directRender = DocumentRenderPipeline.renderLatexGraphicalImage(
            text: source,
            config: RenderConfiguration(
                fontSize: UIFont.preferredFont(forTextStyle: .title1).pointSize,
                maxWidth: 320,
                theme: ThemeID.dark.palette.renderTheme,
                displayMode: .document
            )
        )
        #expect(directRender == nil, "Hostile natural-width raster should be rejected before allocation")

        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        view.layoutIfNeeded()
        view.applyAsFormulaSync(code: source, palette: ThemeID.dark.palette)
        view.layoutIfNeeded()

        let visibleFormulaImage = timelineAllImageViews(in: view).first {
            timelineViewIsVisible($0) && $0.isUserInteractionEnabled && $0.image != nil
        }
        #expect(visibleFormulaImage == nil)
        let codeText = timelineAllTextViews(in: view)
            .filter { timelineViewIsVisible($0) }
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(codeText.contains(source))
    }

    @Test func exportRasterBudgetRejectsOversizedDocumentBeforeDrawing() {
        var didDraw = false
        let image = DocumentRenderPipeline.renderGraphicalToImage(
            size: CGSize(width: 100_000, height: 100_000),
            draw: { _, _ in didDraw = true },
            backgroundColor: .white
        )

        #expect(!didDraw)
        #expect(image.size == CGSize(width: 200, height: 100))
        #expect(DocumentRenderPipeline.exportRasterBudget.permits(
            pointSize: image.size,
            scale: image.scale
        ))
    }

    @Test func maximumValidFormulaExportFallsBackWithinRasterBudget() {
        let source = String(repeating: "x", count: TeXMathLimits.maxTokenCount)
        let layout = DocumentRenderPipeline.layoutLatexExpressions(
            text: source,
            config: RenderConfiguration(
                fontSize: 18,
                maxWidth: 320,
                theme: ThemeID.dark.palette.renderTheme,
                displayMode: .document
            )
        )
        #expect(layout.isRenderable)

        let image = DocumentRenderPipeline.renderLatexExpressionsToImage(
            layout: layout,
            backgroundColor: .white
        )
        #expect(image.size != CGSize(width: 200, height: 100))
        #expect(DocumentRenderPipeline.exportRasterBudget.permits(
            pointSize: image.size,
            scale: image.scale
        ))
    }

    @Test func maximumSourceFallbackExportStaysWithinRasterBudget() {
        let source = String(repeating: "?", count: TeXMathLimits.maxSourceUTF8Bytes)
        let layout = DocumentRenderPipeline.layoutLatexExpressions(
            text: source,
            config: RenderConfiguration(
                fontSize: 18,
                maxWidth: 320,
                theme: ThemeID.dark.palette.renderTheme,
                displayMode: .document
            )
        )
        #expect(layout.exactSourceFallback == source)

        let image = DocumentRenderPipeline.renderLatexExpressionsToImage(
            layout: layout,
            backgroundColor: .white
        )
        #expect(image.size != CGSize(width: 200, height: 100))
        #expect(DocumentRenderPipeline.exportRasterBudget.permits(
            pointSize: image.size,
            scale: image.scale
        ))
    }

    @Test func formulaRerendersWhenContentSizeCategoryChanges() async throws {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = NativeLatexBlockView()
        view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: controller.view.topAnchor),
        ])
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        view.applyAsFormulaSync(code: #"\frac{1}{2}"#, palette: ThemeID.dark.palette)
        view.layoutIfNeeded()
        let initialHeight = try #require(timelineAllImageViews(in: view).first {
            timelineViewIsVisible($0) && $0.isUserInteractionEnabled && $0.image != nil
        }?.image?.size.height)

        let previousTraits = view.traitCollection
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.view.layoutIfNeeded()
        #expect(view.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        // Reapplying the same source proves content-size category participates
        // in render identity; the trait callback uses this same path in production.
        view.applyAsFormula(code: #"\frac{1}{2}"#, palette: ThemeID.dark.palette)
        view.traitCollectionDidChange(previousTraits)
        let rerendered = await waitForTimelineCondition(timeoutMs: 1_800) { @MainActor in
            controller.view.layoutIfNeeded()
            return (timelineAllImageViews(in: view).first {
                timelineViewIsVisible($0) && $0.isUserInteractionEnabled && $0.image != nil
            }?.image?.size.height ?? 0) > initialHeight + 4
        }

        #expect(rerendered)
    }

    /// Characterization: this containment already passed before the display
    /// repair; it guards the existing inline attachment geometry only.
    @Test func reportedInlineSubscriptStaysInsideItsProductionWidthLineFragment() throws {
        let markdown = #"Inline \(\nabla\!\cdot\!\mathbf E=\rho/\varepsilon_0\) after."#
        let segments = FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark)
        guard case .text(let attributed) = try #require(segments.first) else {
            Issue.record("Expected inline attributed text")
            return
        }

        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 288, height: 200))
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.attributedText = NSAttributedString(attributed)
        textView.layoutManager.ensureLayout(for: textView.textContainer)

        let storage = textView.textStorage
        let attachmentIndex = try #require((0..<storage.length).first { index in
            storage.attribute(.attachment, at: index, effectiveRange: nil) is NSTextAttachment
        })
        let attachmentRange = NSRange(location: attachmentIndex, length: 1)
        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: attachmentRange,
            actualCharacterRange: nil
        )
        let attachmentRect = textView.layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textView.textContainer
        )
        let lineFragment = textView.layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )

        #expect(lineFragment.insetBy(dx: -0.5, dy: -0.5).contains(attachmentRect))
        #expect(attachmentRect.maxX <= textView.textContainer.size.width + 0.5)
        #expect(attachmentRect.height >= AppFont.messageBody.xHeight)
    }

    @Test func displayedFractionUsesReadableDynamicBodyTypography() throws {
        let view = NativeLatexBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        view.layoutIfNeeded()

        view.applyAsFormulaSync(
            code: #"\frac{1}{2} + \frac{1}{3} = \frac{5}{6}"#,
            palette: ThemeID.dark.palette
        )
        view.layoutIfNeeded()

        let imageView = try #require(
            timelineAllImageViews(in: view).first {
                !$0.isHidden && $0.image != nil && $0.isUserInteractionEnabled
            }
        )
        let image = try #require(imageView.image)
        let largestVisibleBand = try #require(largestVisibleBandHeight(of: image))
        #expect(
            largestVisibleBand > AppFont.messageBody.pointSize,
            "Displayed glyphs should exceed the message body scale; band=\(largestVisibleBand), body=\(AppFont.messageBody.pointSize)"
        )
    }
}

// MARK: - NativeMermaidBlockView tests

@Suite("NativeMermaidBlockView")
@MainActor
struct NativeMermaidBlockViewTests {

    private func makeDiagramView() -> NativeMermaidBlockView {
        let view = NativeMermaidBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        return view
    }

    /// Find the diagram image view: a visible UIImageView with a tap gesture
    /// and user interaction enabled. Skips button images and other incidental
    /// image views in the hierarchy.
    private func firstTappableImageView(in root: UIView) -> UIImageView? {
        for sub in root.subviews {
            if let iv = sub as? UIImageView,
               !iv.isHidden,
               iv.isUserInteractionEnabled,
               iv.image != nil,
               (iv.gestureRecognizers ?? []).contains(where: { $0 is UITapGestureRecognizer }) {
                return iv
            }
            if let found = firstTappableImageView(in: sub) {
                return found
            }
        }
        return nil
    }

    /// Tap on diagram image view must work inside a real collection view
    /// hierarchy with a dismiss-keyboard gesture — same setup as on device.
    @Test func tapWorksInCollectionViewHierarchy() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))

        let layout = UICollectionViewFlowLayout()
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        let collectionView = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Same dismiss-keyboard tap as ChatTimelineCollectionView
        let dismissTap = UITapGestureRecognizer()
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        window.addSubview(collectionView)

        let cell = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        let stack = UIStackView()
        stack.axis = .vertical
        stack.frame = cell.bounds
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.addSubview(stack)

        let mermaidView = NativeMermaidBlockView()
        stack.addArrangedSubview(mermaidView)
        collectionView.addSubview(cell)

        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let palette = ThemeRuntimeState.currentPalette()
        mermaidView.applyAsDiagram(code: "graph TD\n    A-->B", palette: palette)

        // Wait for async render
        var imageView: UIImageView?
        for _ in 0..<500 {
            window.layoutIfNeeded()
            if let iv = firstTappableImageView(in: mermaidView) {
                imageView = iv
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        guard let imageView else {
            Issue.record("Diagram never rendered")
            return
        }

        // 1. Image view must be directly tappable (no scroll view wrapper)
        #expect(!(imageView.superview is UIScrollView),
                "Image view must NOT be inside a UIScrollView")

        // 2. Image view must have a tap gesture
        let taps = (imageView.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }
        #expect(!taps.isEmpty, "Image view must own a tap gesture")

        // 3. Image view must be the hit-test target
        let center = imageView.convert(
            CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY),
            to: window
        )
        let hitView = window.hitTest(center, with: nil)
        #expect(hitView === imageView,
                "hitTest must return imageView, got \(type(of: hitView as Any))")

        // 4. isUserInteractionEnabled all the way up
        var v: UIView? = imageView
        while let current = v, current !== window {
            #expect(current.isUserInteractionEnabled,
                    "\(type(of: current)) blocks interaction")
            v = current.superview
        }

        window.resignKey()
    }

    @Test func mermaidExportRendersNonBlankImage() async {
        // Verify the FileShareService export path produces a real image
        let code = "graph TD\n    A[Start] --> B[End]"
        let content = FileShareService.ShareableContent.mermaid(code)
        let item = await FileShareService.render(content, as: .image)
        if case .image(let image) = item {
            #expect(image.size.width >= 50, "Export image too narrow: \(image.size.width)")
            #expect(image.size.height >= 50, "Export image too short: \(image.size.height)")
            #expect(!FileShareService.isBlankImage(image), "Export image is blank")
        } else {
            Issue.record("Expected .image from mermaid export, got \(item)")
        }
    }

    /// When markdown containing a mermaid code block is exported as an image,
    /// the mermaid diagram must render with actual content — not appear as a
    /// blank box. We verify by comparing pixel diversity in the diagram area
    /// against the standalone mermaid export (which is known to work).
    @Test func markdownExportRendersMermaidDiagramNotBlankBox() async {
        let code = "graph TD\n    A[Start] --> B[End]"

        // 1. Standalone mermaid export (known working)
        let standalone = await FileShareService.render(.mermaid(code), as: .image)
        guard case .image(let standaloneImg) = standalone else {
            Issue.record("Standalone mermaid export failed")
            return
        }

        // 2. Markdown export containing the same mermaid
        let markdown = "```mermaid\n\(code)\n```"
        let mdExport = await FileShareService.render(.markdown(markdown), as: .image)
        guard case .image(let mdImg) = mdExport else {
            Issue.record("Markdown export failed")
            return
        }

        // 3. The standalone image has diagram content (colored pixels).
        //    Count distinct colors in the center region of each image.
        let standaloneColors = sampleDistinctColors(in: standaloneImg)
        let mdColors = sampleDistinctColors(in: mdImg)

        // The standalone diagram has many distinct colors (node fills, borders,
        // text, background). The markdown export should too — if it rendered
        // only a blank box, it would have very few colors (just background +
        // box border).
        #expect(standaloneColors >= 5,
                "Standalone mermaid should have varied colors, got \(standaloneColors)")
        #expect(mdColors >= 5,
                "Markdown mermaid export only has \(mdColors) distinct colors — diagram likely didn't render (blank box)")
    }

    /// Sample the center 50% of an image and count distinct colors.
    private func sampleDistinctColors(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let w = cgImage.width, h = cgImage.height
        guard w > 4, h > 4 else { return 0 }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * w
        var pixelData = [UInt8](repeating: 0, count: w * h * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Sample center 50% region
        let x0 = w / 4, x1 = 3 * w / 4
        let y0 = h / 4, y1 = 3 * h / 4
        var colors = Set<UInt32>()
        // Sample every 4th pixel for speed
        for y in stride(from: y0, to: y1, by: 4) {
            for x in stride(from: x0, to: x1, by: 4) {
                let offset = (y * w + x) * bytesPerPixel
                // Quantize to 6-bit per channel to ignore anti-aliasing noise
                let r = UInt32(pixelData[offset] >> 2)
                let g = UInt32(pixelData[offset + 1] >> 2)
                let b = UInt32(pixelData[offset + 2] >> 2)
                colors.insert((r << 16) | (g << 8) | b)
            }
        }
        return colors.count
    }
}
