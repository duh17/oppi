import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Oppi

// MARK: - Stream Finish Formatting Preservation

/// Tests that assistant message formatting (colors, fonts) survives the
/// streaming -> finished transition.
///
/// Root cause (commit 2027eae): the jank autoresearch added a streaming/
/// non-streaming branch in updateInPlace. During streaming, direct
/// `NSAttributedString(AttributedString)` was used (colors work). After
/// streaming, `normalizedAttributedText` ran, which checked
/// `NSAttributedString.Key.foregroundColor` ("NSColor") — but SwiftUI
/// `AttributedString` stores colors under "SwiftUI.ForegroundColor".
/// The `as? UIColor` cast always failed, replacing all colors with baseColor.
///
/// Fix: always use direct `NSAttributedString(AttributedString)` conversion.
/// FlatSegment.build already applies correct theme attributes.
@Suite("Stream finish formatting preservation")
@MainActor
struct StreamFinishFormattingTests {

    let darkPalette = ThemeID.dark.palette

    // MARK: - Root cause: SwiftUI Color key != NSAttributedString.Key.foregroundColor

    @Test func swiftUIForegroundColorUsedDifferentKeyThanUIKit() {
        // This test documents the root cause: SwiftUI AttributedString stores
        // foregroundColor under "SwiftUI.ForegroundColor", not "NSColor".
        var attr = AttributedString("hello")
        attr.foregroundColor = darkPalette.cyan

        let ns = NSAttributedString(attr)
        var foundNSColorKey = false
        var foundSwiftUIColorKey = false

        ns.enumerateAttributes(
            in: NSRange(location: 0, length: ns.length)
        ) { attributes, _, _ in
            for (key, _) in attributes {
                if key == .foregroundColor {
                    foundNSColorKey = true
                }
                if key.rawValue == "SwiftUI.ForegroundColor" {
                    foundSwiftUIColorKey = true
                }
            }
        }

        // SwiftUI uses its own key, NOT UIKit's .foregroundColor
        #expect(!foundNSColorKey, "SwiftUI Color should NOT be stored under NSColor key")
        #expect(foundSwiftUIColorKey, "SwiftUI Color should be stored under SwiftUI.ForegroundColor key")
    }

    // MARK: - Applier: streaming -> finished preserves formatting

    @Test func applierPreservesInlineCodeColorAfterStreamFinish() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        let delegate = NoOpTextViewDelegate()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: delegate
        )

        let markdown = "Use `foo()` for results"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        // Step 1: Apply as streaming
        let streamingConfig = AssistantMarkdownContentView.Configuration(
            content: markdown,
            isStreaming: true,
            themeID: .dark
        )
        applier.apply(segments: segments, config: streamingConfig)

        let streamingTextView = findTextViews(in: stackView).first
        #expect(streamingTextView != nil, "Should have a text view after streaming apply")
        let streamingColors = extractColorMap(from: streamingTextView?.attributedText)

        // Step 2: Apply same content as finished (non-streaming)
        let finishedConfig = AssistantMarkdownContentView.Configuration(
            content: markdown,
            isStreaming: false,
            themeID: .dark
        )
        applier.apply(segments: segments, config: finishedConfig)

        let finishedTextView = findTextViews(in: stackView).first
        let finishedColors = extractColorMap(from: finishedTextView?.attributedText)

        // The "foo()" portion should have the SAME color in both states.
        // Before the fix, finished would strip it to base fg.
        let streamingCodeColor = streamingColors["foo()"]
        let finishedCodeColor = finishedColors["foo()"]

        #expect(streamingCodeColor != nil, "Streaming should have color for 'foo()'")
        #expect(finishedCodeColor != nil, "Finished should have color for 'foo()'")

        // Both should have a non-base color (cyan for inline code)
        if let sc = streamingCodeColor, let fc = finishedCodeColor {
            #expect(
                colorKeysMatch(sc, fc),
                "Code color should match: streaming=\(sc) finished=\(fc)"
            )
        }
    }

    @Test func applierPreservesMultipleInlineColorsAfterStreamFinish() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        let delegate = NoOpTextViewDelegate()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: delegate
        )

        let markdown = "See `code` and [link](https://example.com) here"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        // Stream then finish
        let streamingConfig = AssistantMarkdownContentView.Configuration(
            content: markdown, isStreaming: true, themeID: .dark
        )
        applier.apply(segments: segments, config: streamingConfig)

        let finishedConfig = AssistantMarkdownContentView.Configuration(
            content: markdown, isStreaming: false, themeID: .dark
        )
        applier.apply(segments: segments, config: finishedConfig)

        // Check the finished text has distinct colors for code vs link vs body
        let textView = findTextViews(in: stackView).first
        guard let attrText = textView?.attributedText else {
            Issue.record("No attributed text after finish")
            return
        }

        let colorMap = extractColorMap(from: attrText)
        let seeColor = colorMap["See "]
        let codeColor = colorMap["code"]
        let linkColor = colorMap["link"]

        // Code and link should have different colors from body text
        if let sc = seeColor, let cc = codeColor {
            #expect(!colorKeysMatch(sc, cc), "Code should differ from body text")
        }
        if let sc = seeColor, let lc = linkColor {
            #expect(!colorKeysMatch(sc, lc), "Link should differ from body text")
        }
    }

    @Test func rebuildAlsoPreservesColors() {
        // Test the rebuild path (structural change) also preserves colors.
        let stackView = UIStackView()
        stackView.axis = .vertical
        let delegate = NoOpTextViewDelegate()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stackView,
            textViewDelegate: delegate
        )

        let markdown = "Use `foo()` for results"
        let blocks = parseCommonMark(markdown)
        let segments = FlatSegment.build(from: blocks, themeID: .dark)

        // Apply directly as non-streaming (triggers rebuild since no prior state)
        let config = AssistantMarkdownContentView.Configuration(
            content: markdown, isStreaming: false, themeID: .dark
        )
        applier.apply(segments: segments, config: config)

        let textView = findTextViews(in: stackView).first
        guard let attrText = textView?.attributedText else {
            Issue.record("No attributed text after rebuild")
            return
        }

        let colorMap = extractColorMap(from: attrText)
        let bodyColor = colorMap["Use "]
        let codeColor = colorMap["foo()"]

        #expect(bodyColor != nil, "Body text should have color")
        #expect(codeColor != nil, "Code text should have color")

        if let bc = bodyColor, let cc = codeColor {
            #expect(!colorKeysMatch(bc, cc), "Code should have different color than body after rebuild")
        }
    }

    // MARK: - Helpers

    /// Extract a map of substring -> attribute key for foreground colors.
    /// Uses the SwiftUI.ForegroundColor key since that's what AttributedString stores.
    private func extractColorMap(from attrStr: NSAttributedString?) -> [String: String] {
        guard let attrStr else { return [:] }
        var map: [String: String] = [:]
        let swiftUIKey = NSAttributedString.Key(rawValue: "SwiftUI.ForegroundColor")

        attrStr.enumerateAttribute(
            swiftUIKey,
            in: NSRange(location: 0, length: attrStr.length)
        ) { value, range, _ in
            if let value {
                let substring = (attrStr.string as NSString).substring(with: range)
                map[substring] = "\(value)"
            }
        }
        return map
    }

    private func colorKeysMatch(_ a: String, _ b: String) -> Bool {
        a == b
    }

    private func findTextViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        for subview in view.subviews {
            if let tv = subview as? UITextView {
                result.append(tv)
            }
            result.append(contentsOf: findTextViews(in: subview))
        }
        return result
    }
}

// MARK: - NoOp Delegate

private final class NoOpTextViewDelegate: NSObject, UITextViewDelegate {}
