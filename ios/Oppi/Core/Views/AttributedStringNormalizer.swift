import UIKit

enum AttributedStringNormalizer {
    /// Fill in missing `.font` attributes with `fallback`.
    ///
    /// Markdown-parsed `NSAttributedString` can leave runs without a font
    /// attribute (e.g. plain-text spans between styled runs). UITextView
    /// falls back to its own font property for those runs, but that default
    /// may differ from the intended design. This helper ensures every run
    /// has an explicit font.
    ///
    /// - Important: Only detects UIKit-scoped fonts (`NSAttributedString.Key.font`).
    ///   SwiftUI-scoped fonts (set via `AttributedString.font = Font.xxx`) are stored
    ///   under a different key and will appear as `nil` here. Callers must use
    ///   `.uiKit.font` when building `AttributedString` destined for UIKit.
    static func ensureFont(
        in mutable: NSMutableAttributedString,
        fallback: UIFont
    ) {
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return }
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: fallback, range: range)
            }
        }
    }
}
