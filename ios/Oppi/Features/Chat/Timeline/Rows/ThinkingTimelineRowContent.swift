import SwiftUI
import UIKit

enum ThinkingRowHeightPolicy {
    static let defaultMaxBubbleHeight: CGFloat = 200
}

/// Native UIKit thinking row.
///
/// Single-vertical-owner policy:
/// - Inner bubble never owns vertical scrolling.
/// - Timeline collection view remains the only vertical scroll surface.
/// - Streaming overflow auto-follows tail programmatically for deterministic
///   readability while preserving outer follow semantics.
///
/// Long-form/full-screen policy:
/// - No floating expand icon in thinking bubbles.
/// - Context menu exposes "Open Full Screen" and "Copy" when overflowed.
/// - Double-tap or pinch-out opens full screen.
/// - Inline text selection only activates when π actions are enabled and the
///   bubble does not have a full-screen overflow affordance.
struct ThinkingTimelineRowConfiguration: UIContentConfiguration {
    let isDone: Bool
    let previewText: String
    let fullText: String?
    let themeID: ThemeID
    let maxBubbleHeight: CGFloat
    var selectedTextPiRouter: SelectedTextPiActionRouter? = nil
    var selectedTextSourceContext: SelectedTextSourceContext? = nil

    init(
        isDone: Bool,
        previewText: String,
        fullText: String?,
        themeID: ThemeID,
        maxBubbleHeight: CGFloat = ThinkingRowHeightPolicy.defaultMaxBubbleHeight,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSourceContext: SelectedTextSourceContext? = nil
    ) {
        self.isDone = isDone
        self.previewText = previewText
        self.fullText = fullText
        self.themeID = themeID
        self.maxBubbleHeight = maxBubbleHeight
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSourceContext = selectedTextSourceContext
    }

    /// Best available text for display.
    var displayText: String {
        let full = (fullText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? previewText : full
    }

    func makeContentView() -> any UIView & UIContentView {
        ThinkingTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ThinkingTimelineRowContentView: UIView, UIContentView {
    private static let bubblePadding: CGFloat = 10
    private static let brainIndent: CGFloat = 14 + 6 // icon width + spacing
    /// Fraction of the bubble height where the fade begins (bottom 30%).
    private static let fadeStartFraction: Float = 0.7
    private static let fullScreenOverflowThreshold: CGFloat = 2

    // Header removed — the unified WorkingIndicator in the timeline
    // already shows the Game of Life while the agent is working.
    // Thinking rows now only show the bubble (streaming or done).

    // Bubble
    private let bubbleView = UIView()
    private let brainIcon = UIImageView()
    private let scrollView = UIScrollView()
    private let textLabel = UITextView()
    private let fadeMask = CAGradientLayer()
    private var bubbleHeightConstraint: NSLayoutConstraint?
    private var textLeadingConstraint: NSLayoutConstraint?
    private var pinchDidTriggerFullScreen = false

    /// True when the text exceeds the bubble cap.
    private(set) var contentIsTruncated = false
    /// Whether the fade mask is currently applied.
    private var fadeApplied = false
    /// Render signature to skip redundant text updates.
    private var renderSignature: Int?

    private var currentConfiguration: ThinkingTimelineRowConfiguration
    private let fullScreenThinkingStream: ThinkingTraceStream

    private lazy var bubbleDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBubbleDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var bubblePinchGesture: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleBubblePinch(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    init(configuration: ThinkingTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        let initialText = configuration.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullScreenThinkingStream = ThinkingTraceStream(
            text: initialText,
            isDone: configuration.isDone
        )
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? ThinkingTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private var isSelectedTextPiEnabled: Bool {
        currentConfiguration.selectedTextPiRouter != nil
            && currentConfiguration.selectedTextSourceContext != nil
    }

    private var currentInteractionSpec: TimelineExpandableTextInteractionSpec {
        TimelineExpandableTextInteractionSpec.build(
            hasSelectedTextContext: isSelectedTextPiEnabled,
            supportsFullScreenPreview: canShowFullScreen
        )
    }

    // MARK: - Layout

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        updateBubbleHeight(forWidth: targetSize.width)
        let fitted = super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
        let w = fitted.width.isFinite && fitted.width > 0 ? fitted.width : max(1, targetSize.width)
        let h = fitted.height.isFinite && fitted.height > 0 ? min(fitted.height, 10_000) : 44
        return CGSize(width: w, height: h)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBubbleHeight(forWidth: bounds.width)
        syncFadeMaskFrame()
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear

        // --- Bubble ---
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.cornerRadius = 10
        bubbleView.clipsToBounds = true
        bubbleView.addGestureRecognizer(bubbleDoubleTapGesture)
        bubbleView.addGestureRecognizer(bubblePinchGesture)
        bubbleView.addInteraction(UIContextMenuInteraction(delegate: self))

        // Inner scroll view is for layout/content-size bookkeeping only.
        // Keep scrolling disabled so the timeline stays the sole vertical owner.
        // Selection-enabled rows temporarily re-enable subview interaction.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.isScrollEnabled = false
        scrollView.isUserInteractionEnabled = false

        brainIcon.translatesAutoresizingMaskIntoConstraints = false
        brainIcon.image = UIImage(systemName: "sparkle")
        brainIcon.contentMode = .scaleAspectFit

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .preferredFont(forTextStyle: .callout)
        textLabel.isEditable = false
        textLabel.isScrollEnabled = false
        textLabel.isSelectable = false
        textLabel.delegate = self
        textLabel.textContainerInset = .zero
        textLabel.textContainer.lineFragmentPadding = 0
        textLabel.textContainer.lineBreakMode = .byWordWrapping
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.backgroundColor = .clear

        // Fade mask — applied to bubbleView.layer.mask when done + truncated.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        fadeMask.locations = [0, NSNumber(value: Self.fadeStartFraction), 1]

        // Scroll view fills bubble; brain icon floats on top (done state only).
        bubbleView.addSubview(scrollView)
        scrollView.addSubview(textLabel)
        bubbleView.addSubview(brainIcon)

        // --- Container (bubble is the only child now) ---
        addSubview(bubbleView)

        let bubbleHeight = bubbleView.heightAnchor.constraint(equalToConstant: 0)
        bubbleHeightConstraint = bubbleHeight

        // Text leading offset changes between done (after brain icon) and streaming (flush).
        let textLeading = textLabel.leadingAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.leadingAnchor,
            constant: Self.bubblePadding + Self.brainIndent
        )
        textLeadingConstraint = textLeading

        NSLayoutConstraint.activate([
            bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubbleView.topAnchor.constraint(equalTo: topAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),

            brainIcon.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: Self.bubblePadding),
            brainIcon.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: Self.bubblePadding),
            brainIcon.widthAnchor.constraint(equalToConstant: 14),
            brainIcon.heightAnchor.constraint(equalToConstant: 14),

            // Scroll view fills bubble.
            scrollView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bubbleView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor),

            // Content width = frame width (no horizontal scroll).
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),

            // Text label pinned to content layout guide with padding.
            textLeading,
            textLabel.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Self.bubblePadding
            ),
            textLabel.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Self.bubblePadding
            ),
            textLabel.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Self.bubblePadding
            ),

            bubbleHeight,
        ])
    }

    // MARK: - Apply

    private func apply(configuration: ThinkingTimelineRowConfiguration) {
        let wasStreaming = !currentConfiguration.isDone
        let isNowStreaming = !configuration.isDone
        currentConfiguration = configuration

        if isNowStreaming && !wasStreaming {
            scrollView.contentOffset = .zero
        }

        let palette = configuration.themeID.palette
        brainIcon.tintColor = UIColor(palette.purple).withAlphaComponent(0.7)
        let text = configuration.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        fullScreenThinkingStream.update(text: text, isDone: configuration.isDone)

        let signature = Self.textSignature(text: text, isDone: configuration.isDone)
        let needsTextUpdate = signature != renderSignature

        if configuration.isDone {
            // Done: show bubble with brain icon + text.
            textLeadingConstraint?.constant = Self.bubblePadding + Self.brainIndent

            if text.isEmpty {
                textLabel.attributedText = nil
                renderSignature = signature
                bubbleView.isHidden = true
                bubbleHeightConstraint?.constant = 0
                removeFadeMask()
                updateSelectedTextInteractionPolicy()
                return
            }

            bubbleView.isHidden = false
            brainIcon.isHidden = false
            bubbleView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.08)
            if needsTextUpdate {
                textLabel.attributedText = makeThinkingAttributedText(
                    text,
                    color: UIColor(palette.fg).withAlphaComponent(0.94)
                )
                renderSignature = signature
            }

            // Done state starts at top of clipped preview.
            scrollView.contentOffset = .zero
            updateBubbleHeight(forWidth: bounds.width)
        } else {
            // Streaming: just the preview bubble (no header — the unified
            // WorkingIndicator in the timeline already shows the GoL).
            brainIcon.isHidden = true

            // Full-width text (no brain icon indent).
            textLeadingConstraint?.constant = Self.bubblePadding

            if text.isEmpty {
                textLabel.attributedText = nil
                renderSignature = signature
                bubbleView.isHidden = true
                bubbleHeightConstraint?.constant = 0
                removeFadeMask()
            } else {
                bubbleView.isHidden = false
                bubbleView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.06)
                if needsTextUpdate {
                    // Streaming: plain text — skip expensive markdown parsing.
                    // Full markdown rendering applies once on isDone transition.
                    textLabel.attributedText = nil
                    textLabel.text = text
                    textLabel.textColor = UIColor(palette.comment).withAlphaComponent(0.88)
                    textLabel.font = .preferredFont(forTextStyle: .callout)
                    renderSignature = signature
                }
                updateBubbleHeight(forWidth: bounds.width)
                if needsTextUpdate, contentIsTruncated {
                    ToolTimelineRowUIHelpers.followTail(
                        in: scrollView,
                        contentLabel: textLabel
                    )
                }
            }
        }

        updateSelectedTextInteractionPolicy()
    }

    private func updateSelectedTextInteractionPolicy() {
        let interaction = currentInteractionSpec
        textLabel.isSelectable = interaction.inlineSelectionEnabled
        scrollView.isUserInteractionEnabled = interaction.inlineSelectionEnabled
        bubbleDoubleTapGesture.isEnabled = interaction.enablesTapActivation
        bubblePinchGesture.isEnabled = interaction.enablesPinchActivation
    }

    /// Cheap render signature to skip redundant text updates.
    private static func textSignature(text: String, isDone: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(text.count)
        hasher.combine(isDone)
        // Include prefix + suffix for content-change detection without
        // hashing the full multi-KB thinking text on every flush.
        hasher.combine(text.prefix(128))
        hasher.combine(text.suffix(128))
        return hasher.finalize()
    }

    private func makeThinkingAttributedText(_ text: String, color: UIColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        let rendered: NSMutableAttributedString
        if let markdown = try? AttributedString(markdown: text, options: options) {
            rendered = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
        } else {
            rendered = NSMutableAttributedString(string: text)
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        guard fullRange.length > 0 else { return rendered }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.lineBreakMode = .byWordWrapping

        rendered.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        rendered.addAttribute(.foregroundColor, value: color, range: fullRange)

        rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                rendered.addAttribute(
                    .font,
                    value: UIFont.preferredFont(forTextStyle: .callout),
                    range: range
                )
            }
        }

        return rendered
    }

    // MARK: - Height

    private func updateBubbleHeight(forWidth width: CGFloat) {
        guard !bubbleView.isHidden, width > 0 else {
            bubbleHeightConstraint?.constant = 0
            contentIsTruncated = false
            removeFadeMask()
            configureScrollBehavior()
            updateSelectedTextInteractionPolicy()
            return
        }

        let isDone = currentConfiguration.isDone
        let leadingOffset = isDone ? (Self.bubblePadding + Self.brainIndent) : Self.bubblePadding
        let textWidth = max(1, width - leadingOffset - Self.bubblePadding)
        let textSize = textLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let intrinsic = ceil(textSize.height) + Self.bubblePadding * 2
        let maxBubbleHeight = currentConfiguration.maxBubbleHeight

        if !isDone {
            // Streaming: fixed viewport height. Cell height never changes
            // during streaming — only contentOffset moves inside the bubble.
            // Matches the tool row fixed-viewport-during-streaming contract.
            bubbleHeightConstraint?.constant = maxBubbleHeight
            contentIsTruncated = intrinsic > maxBubbleHeight
            removeFadeMask()
        } else if intrinsic <= maxBubbleHeight {
            // Done + fits: natural height.
            contentIsTruncated = false
            bubbleHeightConstraint?.constant = intrinsic
            removeFadeMask()
        } else {
            // Done + overflow: snap to complete lines + fade mask.
            contentIsTruncated = true
            let lineHeight = ceil(textLabel.font?.lineHeight ?? 18)
            let maxTextHeight = maxBubbleHeight - Self.bubblePadding * 2
            let visibleLines = floor(maxTextHeight / lineHeight)
            let snappedHeight = visibleLines * lineHeight + Self.bubblePadding * 2
            bubbleHeightConstraint?.constant = snappedHeight
            applyFadeMask()
        }

        configureScrollBehavior()
        updateSelectedTextInteractionPolicy()
    }

    // MARK: - Scroll Behavior

    private func configureScrollBehavior() {
        // Single-vertical-owner policy: inner thinking bubble never scrolls.
        scrollView.isScrollEnabled = false
        scrollView.isUserInteractionEnabled = currentInteractionSpec.inlineSelectionEnabled
        scrollView.showsVerticalScrollIndicator = false
    }

    #if DEBUG
    /// Whether the tail of the streaming content is visible in the viewport.
    ///
    /// Pure observation — does NOT trigger layout or auto-scroll. Reads
    /// the state that `apply()` left behind. This is critical: if this
    /// property called `layoutIfNeeded()`, it would propagate up the view
    /// hierarchy, trigger `layoutSubviews()` → `performAutoScrollIfNeeded()`,
    /// and mask bugs where `apply()` fails to drive auto-scroll.
    ///
    /// Returns `true` when:
    /// - content is not truncated (everything visible), OR
    /// - the scroll offset is positive (apply drove the scroll toward tail)
    ///
    /// Returns `true` for done state (no streaming to follow).
    var isShowingTailForTesting: Bool { // periphery:ignore
        guard !currentConfiguration.isDone else { return true }
        guard contentIsTruncated, scrollView.bounds.height > 0 else { return true }
        // If content overflows, apply() must have driven the scroll.
        // A positive offset proves auto-scroll happened.
        return scrollView.contentOffset.y > 0
    }
    #endif

    // MARK: - Full Screen

    private var trimmedDisplayText: String {
        currentConfiguration.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canShowFullScreen: Bool {
        guard !trimmedDisplayText.isEmpty else { return false }
        guard !bubbleView.isHidden else { return false }

        let viewportHeight = max(0, scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom)
        guard viewportHeight > 1 else {
            return contentIsTruncated
        }

        let overflowY = scrollView.contentSize.height - viewportHeight
        return overflowY > Self.fullScreenOverflowThreshold
    }

    @objc private func handleBubbleDoubleTap() {
        showFullScreen()
    }

    @objc private func handleBubblePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard canShowFullScreen else { return }

        switch recognizer.state {
        case .began:
            pinchDidTriggerFullScreen = false

        case .changed:
            guard !pinchDidTriggerFullScreen,
                  recognizer.scale >= 1.10 else {
                return
            }

            pinchDidTriggerFullScreen = true
            showFullScreen()

        case .ended, .cancelled, .failed:
            pinchDidTriggerFullScreen = false

        default:
            break
        }
    }

    func showFullScreen() {
        guard canShowFullScreen else { return }

        let content = FullScreenCodeContent.thinking(
            content: trimmedDisplayText,
            stream: fullScreenThinkingStream
        )
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            content,
            from: self,
            selectedTextPiRouter: currentConfiguration.selectedTextPiRouter,
            selectedTextSessionId: currentConfiguration.selectedTextSourceContext?.sessionId,
            selectedTextSourceLabel: currentConfiguration.selectedTextSourceContext?.sourceLabel
        )
    }

    private func copyDisplayText() {
        guard !trimmedDisplayText.isEmpty else { return }
        TimelineCopyFeedback.copy(trimmedDisplayText, feedbackView: bubbleView)
    }

    private func contextMenu() -> UIMenu? {
        guard currentInteractionSpec.supportsFullScreenPreview else { return nil }

        return UIMenu(title: "", children: [
            UIAction(
                title: String(localized: "Open Full Screen"),
                image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
            ) { [weak self] _ in
                self?.showFullScreen()
            },
            UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.copyDisplayText()
            },
        ])
    }

    #if DEBUG
    // periphery:ignore - used by ThinkingRowContentViewTests via @testable import
    func contextMenuForTesting() -> UIMenu? {
        contextMenu()
    }
    #endif

    // MARK: - Fade Mask

    private func applyFadeMask() {
        guard !fadeApplied else {
            syncFadeMaskFrame()
            return
        }
        fadeApplied = true
        bubbleView.layer.mask = fadeMask
        syncFadeMaskFrame()
    }

    private func removeFadeMask() {
        guard fadeApplied else { return }
        fadeApplied = false
        bubbleView.layer.mask = nil
    }

    private func syncFadeMaskFrame() {
        guard fadeApplied else { return }
        let h = bubbleHeightConstraint?.constant ?? bubbleView.bounds.height
        let w = max(1, bubbleView.bounds.width > 0 ? bubbleView.bounds.width : bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = CGRect(x: 0, y: 0, width: w, height: h)
        CATransaction.commit()
    }
}

extension ThinkingTimelineRowContentView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        SelectedTextPiEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: currentConfiguration.selectedTextPiRouter,
            sourceContext: currentConfiguration.selectedTextSourceContext
        )
    }
}

extension ThinkingTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard contextMenu() != nil else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.contextMenu()
        }
    }
}
