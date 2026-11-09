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

    private weak var observedTextStorage: NSTextStorage?

    /// Ends the scan and accessibility cache when the text changes. Every
    /// change (`attributedText`, `text`, an edit of `textStorage`) ends in the
    /// storage's `didProcessEditing`, so one observer covers them all. It is
    /// taken up with the first scan, on the storage the text view has by then,
    /// because there is nothing to end before one. `attributedText` must stay
    /// UITextView's own getter: UIKit's accessibility reads it from a worker
    /// thread, where an override that wraps it is main-actor checked and traps.
    func observeTextEdits() {
        guard observedTextStorage !== textStorage else { return }
        invalidateTaskControls()
        if let previous = observedTextStorage {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextStorage.didProcessEditingNotification,
                object: previous
            )
        }
        observedTextStorage = textStorage
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidProcessEditing),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    @objc private func textStorageDidProcessEditing() {
        invalidateTaskControls()
    }

    /// A control gets the touch ahead of the text view's own gestures.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let located = taskControl(at: point) {
            aimTaskTouchTarget(at: located)
            return taskTouchTarget
        }
        return super.hitTest(point, with: event)
    }

    /// Text Copy puts on the pasteboard for the selection, when the drawn glyphs
    /// are not what the selection means (a table's padding and separators). Nil
    /// from the closure, or no closure, copies the selected glyphs as usual.
    var copyTextProvider: ((_ text: NSAttributedString, _ selection: NSRange) -> String?)?

    override func copy(_ sender: Any?) {
        if let text = copyTextProvider?(attributedText, selectedRange) {
            UIPasteboard.general.string = text
            return
        }
        super.copy(sender)
    }

    func reviewCommentSourceLineRange(for range: NSRange) -> ClosedRange<Int>? {
        reviewCommentSourceLineRangeResolver?(range)
    }

    /// Scrolling is on only so the view has no intrinsic size (its owner sizes
    /// it); it never scrolls, and keeps its text at the top like a view with
    /// scrolling off.
    var isScrollingOnlyForSizing = false

    private var holdsTextAtTop: Bool { !isScrollEnabled || isScrollingOnlyForSizing }

    override func layoutSubviews() {
        super.layoutSubviews()

        if holdsTextAtTop {
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
        layoutFindMark()
    }

    // MARK: - Find mark

    /// A reader's current find match in this text, marked behind its words.
    struct FindMark: Equatable {
        var range: NSRange
        var color: UIColor
    }

    /// Set by the owner from its find state whenever it configures or lays out
    /// the text. The mark is placed again on every layout of this view, so new
    /// text or a new width moves it with the words.
    var findMark: FindMark? {
        didSet { if findMark != oldValue { setNeedsLayout() } }
    }
    /// No stored list: `init(usingTextLayoutManager:)` skips Swift's property
    /// initializers, so only properties whose zero value is valid are safe here.
    private final class FindMarkView: UIView {}

    /// One view per line the match spans, behind the text. The first stands
    /// for the match: its words, for VoiceOver and for tests.
    private func layoutFindMark() {
        var rects: [CGRect] = []
        if let mark = findMark, NSMaxRange(mark.range) <= textStorage.length,
           let start = position(from: beginningOfDocument, offset: mark.range.location),
           let end = position(from: start, offset: mark.range.length),
           let range = textRange(from: start, to: end) {
            // At large text sizes the match's lines may not be laid out yet, and unlaid lines have no rects.
            if let layout = textLayoutManager, let content = layout.textContentManager,
               let from = content.location(content.documentRange.location, offsetBy: mark.range.location),
               let to = content.location(from, offsetBy: mark.range.length),
               let laidOut = NSTextRange(location: from, end: to) {
                layout.ensureLayout(for: laidOut)
            }
            rects = selectionRects(for: range).map(\.rect).filter { $0.width > 0 && $0.height > 0 }
        }
        var views = subviews.compactMap { $0 as? FindMarkView }
        while views.count > rects.count { views.removeLast().removeFromSuperview() }
        while views.count < rects.count {
            let view = FindMarkView()
            view.layer.cornerRadius = 3
            view.isUserInteractionEnabled = false
            insertSubview(view, at: views.count)
            views.append(view)
        }
        guard let mark = findMark, let first = views.first else { return }
        for (view, rect) in zip(views, rects) {
            view.frame = rect.insetBy(dx: -1, dy: 0)
            view.backgroundColor = mark.color
        }
        first.isAccessibilityElement = true
        first.accessibilityIdentifier = "fileViewer.find.currentMatch"
        first.accessibilityLabel = (textStorage.string as NSString).substring(with: mark.range)
    }

    /// Non-scrollable cells (paragraph markdown, table clip/wrap) still install a
    /// pan recognizer. Reject that pan so the outer timeline owns vertical drags,
    /// matching user-row `VerticalPanPassthroughTextView`.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, holdsTextAtTop {
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
