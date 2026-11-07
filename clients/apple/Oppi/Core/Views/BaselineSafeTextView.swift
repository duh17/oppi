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
final class BaselineSafeTextView: UITextView, ReviewCommentSourceLineRangeResolving {
    var reviewCommentSourceLineRangeResolver: ((NSRange) -> ClosedRange<Int>?)?

    /// Owns what the task controls in the text do (a reader that can save its
    /// file sets it). Without one the text has no tappable control and no
    /// control for VoiceOver.
    weak var taskControlHandler: (any ReaderTaskControlHandling)? {
        didSet { if taskControlHandler !== oldValue { taskAccessibilityCache = nil } }
    }
    var taskAttachmentScan: TaskAttachmentScan?
    var taskAccessibilityCache: TaskAccessibilityCache?
    lazy var taskTouchTarget = ReaderTaskTouchTarget()

    override var attributedText: NSAttributedString? {
        didSet { invalidateTaskControls() }
    }

    /// A control gets the touch ahead of the text view's own gestures.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let located = taskControl(at: point) {
            aimTaskTouchTarget(at: located)
            return taskTouchTarget
        }
        return super.hitTest(point, with: event)
    }

    func reviewCommentSourceLineRange(for range: NSRange) -> ClosedRange<Int>? {
        reviewCommentSourceLineRangeResolver?(range)
    }

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

    }

    /// Non-scrollable cells (paragraph markdown, table clip/wrap) still install a
    /// pan recognizer. Reject that pan so the outer timeline owns vertical drags,
    /// matching user-row `VerticalPanPassthroughTextView`.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, !isScrollEnabled {
            return false
        }

        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    // MARK: - Accessibility

    /// Text with badges or checkboxes speaks through lines of its own (UIKit's
    /// leave the attachments out), so it is a container, not one element.
    override var isAccessibilityElement: Bool {
        get { usesSpokenLines ? false : super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityElements: [Any]? {
        get { usesSpokenLines ? spokenElements() : super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }

    /// UIKit drops attachments (badges, inline formulas) from a text view's
    /// spoken text. Speak each attachment's own label where it sits instead.
    override var accessibilityLabel: String? {
        get {
            guard let text = attributedText, text.length > 0,
                  text.containsAttachments(in: NSRange(location: 0, length: text.length)) else {
                return super.accessibilityLabel
            }
            var pieces: [String] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                let piece = (value as? NSTextAttachment).map { $0.accessibilityLabel ?? "" }
                    ?? (text.string as NSString).substring(with: range)
                let trimmed = piece
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            }
            return pieces.joined(separator: ", ")
        }
        set { super.accessibilityLabel = newValue }
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
