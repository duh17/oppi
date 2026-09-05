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
/// Returns `NSAttributedString` directly (no `AttributedString` round-trip).
/// Source is preserved by `SyntaxHighlighter`; this wrapper only captures the
/// theme identity used to paint.
enum FullScreenCodeHighlighter {

    /// Highlight source code. The returned string's `.string` equals `text`.
    /// Token color is bounded by `SyntaxHighlighter.maxLines`; the tail keeps
    /// the explicit base (variable) color.
    static func buildHighlightedText(
        _ text: String,
        language: SyntaxLanguage,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> NSAttributedString {
        SyntaxHighlighter.highlight(text, language: language, themeID: themeID)
    }
}
