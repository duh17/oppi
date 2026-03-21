import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Oppi

/// Tests that FlatSegment.build produces UIKit attributes (UIColor/UIFont)
/// so normalizedAttributedText can find them, and that the streaming ->
/// finished transition preserves colors.
@Suite("Stream finish formatting preservation")
@MainActor
struct StreamFinishFormattingTests {

    let darkPalette = ThemeID.dark.palette

    // MARK: - FlatSegment.build produces UIKit attributes

    @Test func paragraphUsesUIKitForegroundColor() {
        let blocks: [MarkdownBlock] = [.paragraph([.text("hello")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        guard case .text(let attributed) = segments[0] else {
            Issue.record("Expected .text segment"); return
        }
        let ns = NSAttributedString(attributed)
        var found = false
        ns.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if value is UIColor { found = true }
        }
        #expect(found, "Paragraph should use UIKit foregroundColor key")
    }

    @Test func headingUsesUIKitFont() {
        let blocks: [MarkdownBlock] = [.heading(level: 1, inlines: [.text("Title")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        guard case .text(let attributed) = segments[0] else {
            Issue.record("Expected .text segment"); return
        }
        let ns = NSAttributedString(attributed)
        var foundUIFont = false
        var isBold = false
        ns.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if let font = value as? UIFont {
                foundUIFont = true
                isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
            }
        }
        #expect(foundUIFont, "Heading should use UIKit font key")
        #expect(isBold, "H1 should be bold")
    }

    @Test func inlineCodeUsesUIKitColorAndFont() {
        let blocks: [MarkdownBlock] = [.paragraph([.text("Use "), .code("foo()"), .text(" here")])]
        let segments = FlatSegment.build(from: blocks, themeID: .dark)
        guard case .text(let attributed) = segments[0] else {
            Issue.record("Expected .text segment"); return
        }
        let ns = NSAttributedString(attributed)
        let codeRange = (ns.string as NSString).range(of: "foo()")
        #expect(codeRange.location != NSNotFound)

        let color = ns.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? UIColor
        let font = ns.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont

        #expect(color != nil, "Inline code should have UIColor")
        #expect(font != nil, "Inline code should have UIFont")
        if let font {
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), "Code font should be monospaced")
        }
    }

    // MARK: - Applier: streaming -> finished preserves formatting

    @Test func applierPreservesColorsAfterStreamFinish() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: NoOpTextViewDelegate()
        )

        let markdown = "Use `foo()` for results"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        // Stream then finish
        applier.apply(segments: segments, config: .init(content: markdown, isStreaming: true, themeID: .dark))
        applier.apply(segments: segments, config: .init(content: markdown, isStreaming: false, themeID: .dark))

        guard let attrText = findTextViews(in: stackView).first?.attributedText else {
            Issue.record("No attributed text after finish"); return
        }

        let baseFG = UIColor(darkPalette.fg)
        let codeRange = (attrText.string as NSString).range(of: "foo()")
        guard codeRange.location != NSNotFound else {
            Issue.record("foo() not found in rendered text"); return
        }

        let codeColor = attrText.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? UIColor
        #expect(codeColor != nil, "Code should have UIColor after stream finish")
        if let codeColor {
            #expect(!colorsMatch(codeColor, baseFG), "Code should keep distinct color after stream finish")
        }
    }

    // MARK: - Helpers

    private func colorsMatch(_ a: UIColor, _ b: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) < 0.02 && abs(g1 - g2) < 0.02 && abs(b1 - b2) < 0.02
    }

    private func findTextViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        for subview in view.subviews {
            if let tv = subview as? UITextView { result.append(tv) }
            result.append(contentsOf: findTextViews(in: subview))
        }
        return result
    }
}

private final class NoOpTextViewDelegate: NSObject, UITextViewDelegate {}
