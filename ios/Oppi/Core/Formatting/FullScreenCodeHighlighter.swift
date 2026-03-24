import UIKit

/// Thread-safe wrapper for sending immutable `NSAttributedString` across
/// isolation boundaries without the lossy `AttributedString` round-trip.
///
/// `NSAttributedString` is immutable and thread-safe in practice, but the
/// compiler doesn't know that. This wrapper marks it `@unchecked Sendable`
/// so we can return it from `Task.detached` without converting through
/// Swift's `AttributedString` (which drops custom attributes and can
/// produce attribute runs that crash UIKit's internal `NSMutableRLEArray`).
struct SendableNSAttributedString: @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = value
    }
}

/// Pure-function highlighting pipeline for the full-screen code viewer.
///
/// Extracts the highlight + remainder-append logic from
/// `NativeFullScreenCodeBody.loadHighlighting()` into a testable static
/// method. Returns `NSAttributedString` directly (no `AttributedString`
/// round-trip).
enum FullScreenCodeHighlighter {

    /// Highlight source code, appending an unhighlighted remainder if the
    /// content exceeds `SyntaxHighlighter.maxLines`.
    ///
    /// The returned string's `.string` always equals the input `text`.
    /// All attribute ranges are guaranteed to be within `0..<length`.
    static func buildHighlightedText(
        _ text: String,
        language: SyntaxLanguage
    ) -> NSAttributedString {
        let highlighted = SyntaxHighlighter.highlight(text, language: language)
        let highlightedStr = highlighted.string

        // If highlighting covered the full text, return as-is.
        guard highlightedStr.count < text.count else {
            return highlighted
        }

        // SyntaxHighlighter truncates at maxLines. Append the unhighlighted
        // remainder so the full-screen viewer shows all content.
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let splitIndex = text.index(text.startIndex, offsetBy: highlightedStr.count)
        let remainder = String(text[splitIndex...])
        let baseAttrs: [NSAttributedString.Key: Any] = highlighted.length > 0
            ? highlighted.attributes(at: 0, effectiveRange: nil)
            : [:]
        mutable.append(NSAttributedString(string: remainder, attributes: baseAttrs))
        return NSAttributedString(attributedString: mutable)
    }
}
