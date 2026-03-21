import UIKit

enum AttributedStringNormalizer {
    /// Fill in missing `.font` attributes with `fallback`.
    ///
    /// Markdown-parsed `NSAttributedString` can leave runs without a font
    /// attribute (e.g. plain-text spans between styled runs). UITextView
    /// falls back to its own font property for those runs, but that default
    /// may differ from the intended design. This helper ensures every run
    /// has an explicit font.
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
