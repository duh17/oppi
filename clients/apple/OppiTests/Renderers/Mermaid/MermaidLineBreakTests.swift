import CoreText
import Foundation
import Testing
import UIKit
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/diagrams/common/common.ts
//   lineBreakRegex = /<br\s*\/?>/gi
//   getRows() — splits on <br> tags and \n
//
// SPEC: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/diagrams/sequence/sequenceDiagram.spec.js
//   'should handle different line breaks' test — verifies <br>, <br/>, <br />, <br \t/>
//
// COVERAGE:
// [x] normalizeBrTags: <br> variants (no slash, slash, space+slash, tab+slash)
// [x] normalizeBrTags: case insensitivity (<BR>, <Br>, <BR/>)
// [x] normalizeBrTags: multiple tags in one string
// [x] normalizeBrTags: no false positives (plain text, partial matches)
// [x] Flowchart node labels with <br> → multi-line
// [x] Flowchart edge labels with <br> → multi-line
// [x] Sequence participant labels with <br> → multi-line
// [x] Sequence message text with <br> → multi-line
// [x] Mindmap node labels with <br> → multi-line
// [x] Gantt task names with <br> → multi-line
// [x] measureText: single-line vs multi-line height

@Suite("Mermaid Line Break Handling")
struct MermaidLineBreakTests {
    let parser = MermaidParser()

    // MARK: - normalizeBrTags

    @Test func brNoSlash() {
        #expect(MermaidTextUtils.normalizeBrTags("hello<br>world") == "hello\nworld")
    }

    @Test func brWithSlash() {
        #expect(MermaidTextUtils.normalizeBrTags("hello<br/>world") == "hello\nworld")
    }

    @Test func brWithSpaceSlash() {
        #expect(MermaidTextUtils.normalizeBrTags("hello<br />world") == "hello\nworld")
    }

    @Test func brWithTabSlash() {
        // Matches Mermaid spec: <br \t/>
        #expect(MermaidTextUtils.normalizeBrTags("hello<br\t/>world") == "hello\nworld")
    }

    @Test func brCaseInsensitive() {
        #expect(MermaidTextUtils.normalizeBrTags("a<BR>b") == "a\nb")
        #expect(MermaidTextUtils.normalizeBrTags("a<Br/>b") == "a\nb")
        #expect(MermaidTextUtils.normalizeBrTags("a<BR />b") == "a\nb")
    }

    @Test func multipleBrTags() {
        #expect(MermaidTextUtils.normalizeBrTags("a<br>b<br/>c<br />d") == "a\nb\nc\nd")
    }

    @Test func noFalsePositives() {
        // Plain text without br tags should pass through unchanged.
        #expect(MermaidTextUtils.normalizeBrTags("hello world") == "hello world")
        #expect(MermaidTextUtils.normalizeBrTags("a < br > b") == "a < br > b")
        #expect(MermaidTextUtils.normalizeBrTags("break") == "break")
        #expect(MermaidTextUtils.normalizeBrTags("") == "")
    }

    // MARK: - Flowchart: node labels with <br>

    @Test func flowchartNodeLabelBr() {
        let result = parser.parse("""
        flowchart TD
            A[Line one<br/>Line two]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "A" }
        #expect(node?.label == "Line one\nLine two")
    }

    @Test func flowchartNodeLabelMultipleBr() {
        let result = parser.parse("""
        flowchart LR
            B[First<br>Second<br />Third]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        let node = d.nodes.first { $0.id == "B" }
        #expect(node?.label == "First\nSecond\nThird")
    }

    @Test func flowchartAllShapesNormalize() {
        // Verify normalization works across different node shapes.
        let result = parser.parse("""
        flowchart TD
            A[rect<br/>label]
            B(round<br/>label)
            C{diamond<br/>label}
            D((circle<br/>label))
            E([stadium<br/>label])
            F[[sub<br/>label]]
            G[(cyl<br/>label)]
            H{{hex<br/>label}}
            I>asym<br/>label]
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        for node in d.nodes {
            #expect(
                node.label.contains("\n"),
                "Node \(node.id) (\(node.shape)) should have normalized <br/> to newline, got: \(node.label)"
            )
        }
    }

    // MARK: - Flowchart: edge labels with <br>

    @Test func flowchartEdgeLabelBr() {
        let result = parser.parse("""
        flowchart TD
            A -->|Line one<br/>Line two| B
        """)
        guard case .flowchart(let d) = result else {
            Issue.record("Expected flowchart")
            return
        }
        #expect(d.edges.first?.label == "Line one\nLine two")
    }

    // MARK: - Sequence: participant labels with <br>
    // Modeled after Mermaid spec test: 'should handle different line breaks'

    @Test func sequenceParticipantBrVariants() {
        let result = parser.parse("""
        sequenceDiagram
            participant A as multiline<br>text
            participant B as multiline<br/>text
            participant C as multiline<br />text
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.participants[0].label == "multiline\ntext")
        #expect(d.participants[1].label == "multiline\ntext")
        #expect(d.participants[2].label == "multiline\ntext")
    }

    // MARK: - Sequence: message text with <br>

    @Test func sequenceMessageBr() {
        let result = parser.parse("""
        sequenceDiagram
            Alice->>Bob: Hello<br/>How are you?
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages.first?.text == "Hello\nHow are you?")
    }

    @Test func sequenceMessageBrVariants() {
        let result = parser.parse("""
        sequenceDiagram
            A->>B: msg<br>one
            B->>C: msg<br/>two
            C->>A: msg<br />three
        """)
        guard case .sequence(let d) = result else {
            Issue.record("Expected sequence")
            return
        }
        #expect(d.messages[0].text == "msg\none")
        #expect(d.messages[1].text == "msg\ntwo")
        #expect(d.messages[2].text == "msg\nthree")
    }

    // MARK: - Mindmap: node labels with <br>

    @Test func mindmapNodeLabelBr() {
        let result = parser.parse("""
        mindmap
            root[Line one<br/>Line two]
        """)
        guard case .mindmap(let d) = result else {
            Issue.record("Expected mindmap")
            return
        }
        #expect(d.root.label == "Line one\nLine two")
    }

    // MARK: - Gantt: task names with <br>

    @Test func ganttTaskNameBr() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            Task one<br/>continued :2024-01-01, 3d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.sections.first?.tasks.first?.name == "Task one\ncontinued")
    }

    // MARK: - Multi-line text measurement

    @Test func measureTextMultiLineIsTaller() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let singleLine = MermaidTextUtils.measureText("Hello world", font: font, fontSize: 14)
        let multiLine = MermaidTextUtils.measureText("Hello\nworld", font: font, fontSize: 14)
        #expect(multiLine.height > singleLine.height, "Multi-line text should be taller than single-line")
    }

    @Test func measureTextMultiLineWidth() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let size = MermaidTextUtils.measureText("Short\nMuch longer line here", font: font, fontSize: 14)
        let longLine = MermaidTextUtils.measureText("Much longer line here", font: font, fontSize: 14)
        // Width should match the widest line.
        #expect(abs(size.width - longLine.width) < 1.0)
    }

    // MARK: - Official markdown string labels

    @Test func inspectLabelDetectsQuotedBacktickMarkdown() {
        let markdown = MermaidTextUtils.inspectLabel("\"`**bold** and _italic_`\"")
        #expect(markdown.isMarkdown)
        #expect(markdown.text == "**bold** and _italic_")

        let shapeBackticks = MermaidTextUtils.inspectLabel("`**bold**`")
        #expect(shapeBackticks.isMarkdown)
        #expect(shapeBackticks.text == "**bold**")

        let plain = MermaidTextUtils.inspectLabel("\"text with (parens) and *stars*\"")
        #expect(!plain.isMarkdown)
        #expect(plain.text == "text with (parens) and *stars*")
    }

    @Test func inspectLabelKeepsEntitiesAndUnicode() {
        let entities = MermaidTextUtils.inspectLabel("\"quote:#quot; amp:#amp;\"")
        #expect(!entities.isMarkdown)
        #expect(entities.text == "quote:\" amp:&")

        let unicode = MermaidTextUtils.inspectLabel("\"Café — 日本語 — emoji ✅\"")
        #expect(!unicode.isMarkdown)
        #expect(unicode.text == "Café — 日本語 — emoji ✅")
    }

    @Test func attributedMarkdownGalleryLabelHasBoldAndItalicRuns() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = MermaidTextUtils.attributedLabel(
            "**bold** and _italic_",
            font: font,
            fontSize: 14,
            isMarkdown: true
        )
        #expect(attributed.string == "bold and italic")
        #expect(!attributed.string.contains("*"))
        #expect(!attributed.string.contains("_"))
        #expect(!attributed.string.contains("`"))

        let runs = MermaidTextUtils.markdownLabelRuns("**bold** and _italic_")
        #expect(runs.contains { $0.text == "bold" && $0.isBold && !$0.isItalic })
        #expect(runs.contains { $0.text == "italic" && $0.isItalic && !$0.isBold })

        var boldText: String?
        var italicText: String?
        attributed.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let uiFont = value as? UIFont else { return }
            let name = uiFont.fontName
            let fragment = (attributed.string as NSString).substring(with: range)
            if name.contains("Bold") {
                boldText = fragment
            }
            if name.contains("Oblique") || name.contains("Italic") {
                italicText = fragment
            }
        }
        #expect(boldText == "bold")
        #expect(italicText == "italic")
    }

    @Test func attributedPlainQuotedStarsStayLiteral() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let text = "text with (parens) and *stars*"
        let attributed = MermaidTextUtils.attributedLabel(
            text,
            font: font,
            fontSize: 14,
            isMarkdown: false
        )
        #expect(attributed.string == text)
        #expect(attributed.string.contains("*stars*"))
    }

    @Test func attributedMarkdownKeepsUnmatchedMarkersLiteral() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let text = "**unclosed and *also"
        let attributed = MermaidTextUtils.attributedLabel(
            text,
            font: font,
            fontSize: 14,
            isMarkdown: true
        )
        #expect(attributed.string == text)
    }

    @Test func markdownLabelMeasuresCloserToFormattedTextThanMarkers() {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let raw = "**bold** and _italic_"
        let formatted = "bold and italic"
        let markdownSize = MermaidTextUtils.measureText(raw, font: font, fontSize: 14, isMarkdown: true)
        let formattedSize = MermaidTextUtils.measureText(formatted, font: font, fontSize: 14)
        let rawSize = MermaidTextUtils.measureText(raw, font: font, fontSize: 14)
        #expect(
            abs(markdownSize.width - formattedSize.width) < abs(markdownSize.width - rawSize.width),
            "Markdown width \(markdownSize.width) should be closer to formatted \(formattedSize.width) than raw \(rawSize.width)"
        )
    }
}
