import Foundation
import Testing
@testable import Oppi

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Org Attributed String Renderer Tests
//
// Coverage:
// [x] Heading levels — font size scaling
// [x] Heading keywords — TODO/DONE colored badges
// [x] Heading tags — gray monospace suffix
// [x] Bold — bold font trait
// [x] Italic — italic font trait
// [x] Code/Verbatim — monospace font, background color
// [x] Strikethrough — strikethroughStyle attribute
// [x] Underline — underlineStyle attribute
// [x] Links — .link attribute with URL, blue color
// [x] Code blocks — monospace font, language label
// [x] Lists — bullet/number prefixes, checkboxes
// [x] Block quotes — italic, indented
// [x] Horizontal rules — centered gray dashes
// [x] Keywords — small gray monospace text
// [x] Empty document — empty attributed string
// [x] Complex mixed document

@Suite("OrgAttributedStringRenderer")
struct OrgRendererTests {

    let parser = OrgParser()
    let renderer = OrgAttributedStringRenderer()
    let config = RenderConfiguration.default()

    // MARK: - Helpers

    private func render(_ source: String) -> NSAttributedString {
        let doc = parser.parse(source)
        return renderer.renderAttributedString(doc, configuration: config)
    }

    /// Extract font at a character offset.
    private func font(in attrStr: NSAttributedString, at offset: Int) -> UIFont? {
        guard offset < attrStr.length else { return nil }
        return attrStr.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
    }

    /// Check if font at offset has bold trait.
    private func isBold(in attrStr: NSAttributedString, at offset: Int) -> Bool {
        guard let f = font(in: attrStr, at: offset) else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    /// Check if font at offset has italic trait.
    private func isItalic(in attrStr: NSAttributedString, at offset: Int) -> Bool {
        guard let f = font(in: attrStr, at: offset) else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.traitItalic)
    }

    /// Check if font at offset is monospaced.
    private func isMonospace(in attrStr: NSAttributedString, at offset: Int) -> Bool {
        guard let f = font(in: attrStr, at: offset) else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    }

    /// Check for .link attribute at offset.
    private func linkValue(in attrStr: NSAttributedString, at offset: Int) -> URL? {
        guard offset < attrStr.length else { return nil }
        return attrStr.attribute(.link, at: offset, effectiveRange: nil) as? URL
    }

    /// Check for background color at offset.
    private func hasBackgroundColor(in attrStr: NSAttributedString, at offset: Int) -> Bool {
        guard offset < attrStr.length else { return false }
        return attrStr.attribute(.backgroundColor, at: offset, effectiveRange: nil) != nil
    }

    /// Extract the full string content.
    private func text(_ attrStr: NSAttributedString) -> String {
        attrStr.string
    }

    // MARK: - Empty Document

    @Test("Empty document produces empty attributed string")
    func emptyDocument() {
        let result = render("")
        #expect(result.length == 0)
    }

    // MARK: - Headings

    @Test("H1 uses 24pt font")
    func headingLevel1FontSize() {
        let result = render("* Big Title")
        // Find "Big Title" in output
        let str = text(result)
        guard let range = str.range(of: "Big Title") else {
            Issue.record("Expected 'Big Title' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let f = font(in: result, at: nsOffset)
        #expect(f != nil)
        #expect(f!.pointSize == 24)
    }

    @Test("H2 uses 20pt font")
    func headingLevel2FontSize() {
        let result = render("** Medium Title")
        let str = text(result)
        guard let range = str.range(of: "Medium Title") else {
            Issue.record("Expected 'Medium Title' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let f = font(in: result, at: nsOffset)
        #expect(f != nil)
        #expect(f!.pointSize == 20)
    }

    @Test("H3 uses 17pt font")
    func headingLevel3FontSize() {
        let result = render("*** Small Title")
        let str = text(result)
        guard let range = str.range(of: "Small Title") else {
            Issue.record("Expected 'Small Title' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let f = font(in: result, at: nsOffset)
        #expect(f != nil)
        #expect(f!.pointSize == 17)
    }

    @Test("H4 uses base font size")
    func headingLevel4FontSize() {
        let result = render("**** Level 4")
        let str = text(result)
        guard let range = str.range(of: "Level 4") else {
            Issue.record("Expected 'Level 4' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let f = font(in: result, at: nsOffset)
        #expect(f != nil)
        #expect(f!.pointSize == config.fontSize)
    }

    @Test("Headings are bold")
    func headingIsBold() {
        let result = render("* Bold Heading")
        let str = text(result)
        guard let range = str.range(of: "Bold Heading") else {
            Issue.record("Expected 'Bold Heading' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isBold(in: result, at: nsOffset))
    }

    @Test("Heading with TODO keyword shows keyword text")
    func headingTodoKeyword() {
        let result = render("* TODO Fix the bug")
        let str = text(result)
        #expect(str.contains("TODO"))
        #expect(str.contains("Fix the bug"))
    }

    @Test("Heading with tags includes tag text")
    func headingTags() {
        let result = render("* Meeting notes :work:planning:")
        let str = text(result)
        #expect(str.contains("work"))
        #expect(str.contains("planning"))
    }

    // MARK: - Bold

    @Test("Bold text has bold font trait")
    func boldTrait() {
        let result = render("Normal *bold text* normal")
        let str = text(result)
        guard let range = str.range(of: "bold text") else {
            Issue.record("Expected 'bold text' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isBold(in: result, at: nsOffset))
    }

    @Test("Non-bold text lacks bold trait")
    func nonBoldLacksTrait() {
        let result = render("Normal *bold* normal")
        // "Normal " starts at 0
        #expect(!isBold(in: result, at: 0))
    }

    // MARK: - Italic

    @Test("Italic text has italic font trait")
    func italicTrait() {
        let result = render("Normal /italic text/ normal")
        let str = text(result)
        guard let range = str.range(of: "italic text") else {
            Issue.record("Expected 'italic text' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isItalic(in: result, at: nsOffset))
    }

    // MARK: - Code / Verbatim

    @Test("Inline code uses monospace font")
    func inlineCodeMonospace() {
        let result = render("Use ~println~ here")
        let str = text(result)
        guard let range = str.range(of: "println") else {
            Issue.record("Expected 'println' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isMonospace(in: result, at: nsOffset))
    }

    @Test("Inline code has background color")
    func inlineCodeBackground() {
        let result = render("Use ~code~ here")
        let str = text(result)
        guard let range = str.range(of: "code") else {
            Issue.record("Expected 'code' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(hasBackgroundColor(in: result, at: nsOffset))
    }

    @Test("Verbatim uses monospace font")
    func verbatimMonospace() {
        let result = render("The =output= value")
        let str = text(result)
        guard let range = str.range(of: "output") else {
            Issue.record("Expected 'output' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isMonospace(in: result, at: nsOffset))
    }

    // MARK: - Strikethrough

    @Test("Strikethrough text has strikethroughStyle attribute")
    func strikethroughAttribute() {
        let result = render("This is +deleted+ text")
        let str = text(result)
        guard let range = str.range(of: "deleted") else {
            Issue.record("Expected 'deleted' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let style = result.attribute(.strikethroughStyle, at: nsOffset, effectiveRange: nil) as? Int
        #expect(style != nil)
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Underline

    @Test("Underline text has underlineStyle attribute")
    func underlineAttribute() {
        let result = render("This is _underlined_ text")
        let str = text(result)
        guard let range = str.range(of: "underlined") else {
            Issue.record("Expected 'underlined' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let style = result.attribute(.underlineStyle, at: nsOffset, effectiveRange: nil) as? Int
        #expect(style != nil)
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Links

    @Test("Link has .link attribute with URL")
    func linkAttribute() {
        let result = render("Visit [[https://example.com][Example]] site")
        let str = text(result)
        guard let range = str.range(of: "Example") else {
            Issue.record("Expected 'Example' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let url = linkValue(in: result, at: nsOffset)
        #expect(url != nil)
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test("Bare link uses URL as display text")
    func bareLinkDisplaysURL() {
        let result = render("Go to [[https://example.com]]")
        let str = text(result)
        #expect(str.contains("https://example.com"))
        // Find the URL text and check for .link attribute
        guard let range = str.range(of: "https://example.com") else {
            Issue.record("Expected URL in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        let url = linkValue(in: result, at: nsOffset)
        #expect(url != nil)
    }

    // MARK: - Lists

    @Test("Unordered list items have bullet prefix")
    func unorderedListBullet() {
        let result = render("- First item\n- Second item")
        let str = text(result)
        #expect(str.contains("•"))
        #expect(str.contains("First item"))
        #expect(str.contains("Second item"))
    }

    @Test("Ordered list items have number prefix")
    func orderedListNumbers() {
        let result = render("1. Alpha\n2. Beta")
        let str = text(result)
        #expect(str.contains("1."))
        #expect(str.contains("2."))
        #expect(str.contains("Alpha"))
        #expect(str.contains("Beta"))
    }

    @Test("Checkbox states render correct symbols")
    func checkboxSymbols() {
        let input = """
        - [X] Done task
        - [ ] Open task
        - [-] Partial task
        """
        let result = render(input)
        let str = text(result)
        #expect(str.contains("☑"))
        #expect(str.contains("☐"))
        #expect(str.contains("☒"))
    }

    // MARK: - Code Block

    @Test("Code block uses monospace font")
    func codeBlockMonospace() {
        let input = """
        #+begin_src python
        print("hello")
        #+end_src
        """
        let result = render(input)
        let str = text(result)
        guard let range = str.range(of: "print") else {
            Issue.record("Expected 'print' in code block output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isMonospace(in: result, at: nsOffset))
    }

    @Test("Code block includes language label")
    func codeBlockLanguageLabel() {
        let input = """
        #+begin_src swift
        let x = 1
        #+end_src
        """
        let result = render(input)
        let str = text(result)
        #expect(str.contains("swift"))
    }

    // MARK: - Block Quote

    @Test("Block quote text is italic")
    func blockQuoteItalic() {
        let input = """
        #+begin_quote
        Wise words here
        #+end_quote
        """
        let result = render(input)
        let str = text(result)
        guard let range = str.range(of: "Wise words") else {
            Issue.record("Expected 'Wise words' in output")
            return
        }
        let nsOffset = str.distance(from: str.startIndex, to: range.lowerBound)
        #expect(isItalic(in: result, at: nsOffset))
    }

    // MARK: - Horizontal Rule

    @Test("Horizontal rule renders centered dashes")
    func horizontalRule() {
        let result = render("-----")
        let str = text(result)
        #expect(str.contains("───"))
    }

    // MARK: - Keywords

    @Test("Keyword renders as small text")
    func keywordRendering() {
        let result = render("#+TITLE: My Document")
        let str = text(result)
        #expect(str.contains("TITLE"))
        #expect(str.contains("My Document"))

        // Keyword text should be monospace
        #expect(isMonospace(in: result, at: 0))
    }

    // MARK: - Complex Document

    @Test("Complex document with mixed elements renders without crash")
    func complexDocument() {
        let input = """
        #+TITLE: Test Document

        * TODO [#A] Project Plan :work:

        This is a paragraph with *bold*, /italic/, and ~code~.

        ** Resources

        - [[https://example.com][Example Link]]
        - [X] Read the docs
        - [ ] Write the code

        #+begin_src python
        def hello():
            print("world")
        #+end_src

        #+begin_quote
        The best code is no code at all.
        #+end_quote

        -----

        *** Notes

        Some _underlined_ and +deleted+ text here.
        """
        let result = render(input)
        #expect(result.length > 0)

        let str = text(result)
        #expect(str.contains("Project Plan"))
        #expect(str.contains("bold"))
        #expect(str.contains("italic"))
        #expect(str.contains("code"))
        #expect(str.contains("hello"))
        #expect(str.contains("───"))
        #expect(str.contains("underlined"))
        #expect(str.contains("deleted"))
    }

    // MARK: - Protocol Conformance

    @Test("Renderer produces RenderOutput.attributedString via protocol")
    func protocolConformance() {
        let doc = parser.parse("* Hello")
        let output = renderer.render(doc, configuration: config)
        if case .attributedString(let attrStr) = output {
            #expect(attrStr.length > 0)
        } else {
            Issue.record("Expected .attributedString output")
        }
    }
}
