import UIKit

/// UITextView subclass that prevents `_firstBaselineOffsetFromTop` crashes.
///
/// UIKit internally calls `_firstBaselineOffsetFromTop` on UITextView during
/// collection view self-sizing layout. This private method asserts that Auto
/// Layout is active. During view hierarchy rebuilds (e.g. `AssistantMarkdown
/// ContentView.rebuild()`), text views are temporarily removed from their
/// superview, causing the internal AL state check to fail and throw
/// `NSInternalInconsistencyException`.
///
/// Fix: Override the private method to return a safe default (font ascent)
/// when called in an unsafe state, preventing the assertion.
///
/// Sentry: APPLE-IOS-G (23 events, fatal crash in ChatTimelineCollectionView)
final class BaselineSafeTextView: UITextView {

    // MARK: - Baseline safety

    /// Override UIKit's private baseline query to prevent the assertion
    /// that fires when the text view is between superview attachment.
    @objc func _firstBaselineOffsetFromTop() -> CGFloat {
        // When the view is properly in the hierarchy with AL, delegate
        // to the font's ascender for a reasonable baseline.
        let fontAscent = font?.ascender ?? UIFont.preferredFont(forTextStyle: .body).ascender
        return textContainerInset.top + fontAscent
    }

    @objc func _lastBaselineOffsetFromBottom() -> CGFloat {
        let fontDescender = font?.descender ?? UIFont.preferredFont(forTextStyle: .body).descender
        return textContainerInset.bottom - fontDescender
    }
}
