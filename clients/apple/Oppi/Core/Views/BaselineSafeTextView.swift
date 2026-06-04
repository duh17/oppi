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
final class BaselineSafeTextView: UITextView {

    override func layoutSubviews() {
        super.layoutSubviews()

        if !isScrollEnabled {
            let desiredOffset = CGPoint(
                x: -adjustedContentInset.left,
                y: -adjustedContentInset.top
            )

            if abs(contentOffset.x - desiredOffset.x) > 0.5
                || abs(contentOffset.y - desiredOffset.y) > 0.5 {
                // UITextView can retain an internal scroll position across attributed
                // text updates even when scrolling is disabled. Streaming assistant
                // markdown reuses these text views in place, so clamp them back to the
                // visual top on each layout pass.
                contentOffset = desiredOffset
            }
        }

        ReviewCommentInlineAnnotationRenderer.repositionBubbleButtons(in: self)
    }

    // MARK: - Baseline safety

    // periphery:ignore - @objc override of UIKit private baseline query; prevents assertion during detach
    /// Override UIKit's private baseline query to prevent the assertion
    /// that fires when the text view is between superview attachment.
    @objc func _firstBaselineOffsetFromTop() -> CGFloat {
        // When the view is properly in the hierarchy with AL, delegate
        // to the font's ascender for a reasonable baseline.
        let fontAscent = font?.ascender ?? UIFont.preferredFont(forTextStyle: .body).ascender
        return textContainerInset.top + fontAscent
    }

    // periphery:ignore - @objc override of UIKit private baseline query; prevents assertion during detach
    @objc func _lastBaselineOffsetFromBottom() -> CGFloat {
        let fontDescender = font?.descender ?? UIFont.preferredFont(forTextStyle: .body).descender
        return textContainerInset.bottom - fontDescender
    }
}
