import SwiftUI
import UIKit

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
/// - Pinch-out, double-tap, or single-tap opens full screen.
struct ThinkingTimelineRowConfiguration: UIContentConfiguration {
    let isDone: Bool
    let previewText: String
    let fullText: String?
    let themeID: ThemeID

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
    static let maxBubbleHeight: CGFloat = 200
    private static let bubblePadding: CGFloat = 10
    private static let brainIndent: CGFloat = 14 + 6 // icon width + spacing
    /// Fraction of the bubble height where the fade begins (bottom 30%).
    private static let fadeStartFraction: Float = 0.7
    private static let fullScreenOverflowThreshold: CGFloat = 2

    // Header (streaming state)
    private let headerStack = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()

    // Bubble
    private let bubbleView = UIView()
    private let brainIcon = UIImageView()
    private let scrollView = UIScrollView()
    private let textLabel = UILabel()
    private let fadeMask = CAGradientLayer()
    private let expandFloatingButton = UIButton(type: .system)
    private var bubbleHeightConstraint: NSLayoutConstraint?
    private var textLeadingConstraint: NSLayoutConstraint?
    private var pinchDidTriggerFullScreen = false

    /// True when the text exceeds the bubble cap.
    private(set) var contentIsTruncated = false
    /// Whether the fade mask is currently applied.
    private var fadeApplied = false

    private var currentConfiguration: ThinkingTimelineRowConfiguration
    private let fullScreenThinkingStream: ThinkingTraceStream

    private lazy var bubbleDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBubbleDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var bubbleSingleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBubbleSingleTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = false
        recognizer.require(toFail: bubbleDoubleTapGesture)
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
        performAutoScrollIfNeeded()
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear

        // --- Header (streaming) ---
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 6

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.hidesWhenStopped = false
        statusSpinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.numberOfLines = 1
        titleLabel.text = "Thinking…"

        headerStack.addArrangedSubview(statusSpinner)
        headerStack.addArrangedSubview(titleLabel)

        // --- Bubble ---
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.cornerRadius = 10
        bubbleView.clipsToBounds = true
        bubbleView.addGestureRecognizer(bubbleDoubleTapGesture)
        bubbleView.addGestureRecognizer(bubbleSingleTapGesture)
        bubbleView.addGestureRecognizer(bubblePinchGesture)
        bubbleView.addInteraction(UIContextMenuInteraction(delegate: self))

        // Inner scroll view is for layout/content-size bookkeeping only.
        // Keep it non-interactive so timeline stays the sole vertical owner.
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
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.adjustsFontForContentSizeCategory = true

        ToolTimelineRowViewStyler.styleExpandFloatingButton(expandFloatingButton)
        expandFloatingButton.accessibilityIdentifier = "thinking.expand-full-screen"
        expandFloatingButton.addTarget(self, action: #selector(handleExpandFloatingButtonTap), for: .touchUpInside)

        // Fade mask — applied to bubbleView.layer.mask when done + truncated.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        fadeMask.locations = [0, NSNumber(value: Self.fadeStartFraction), 1]

        // Scroll view fills bubble; brain icon floats on top (done state only).
        bubbleView.addSubview(scrollView)
        scrollView.addSubview(textLabel)
        bubbleView.addSubview(brainIcon)

        // --- Container ---
        let stack = UIStackView(arrangedSubviews: [headerStack, bubbleView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        addSubview(stack)
        addSubview(expandFloatingButton)

        let bubbleHeight = bubbleView.heightAnchor.constraint(equalToConstant: 0)
        bubbleHeightConstraint = bubbleHeight

        // Text leading offset changes between done (after brain icon) and streaming (flush).
        let textLeading = textLabel.leadingAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.leadingAnchor,
            constant: Self.bubblePadding + Self.brainIndent
        )
        textLeadingConstraint = textLeading

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

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

            expandFloatingButton.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -8),
            expandFloatingButton.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
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
        statusSpinner.color = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.comment)

        let text = configuration.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        fullScreenThinkingStream.update(text: text, isDone: configuration.isDone)

        if configuration.isDone {
            // Done: hide header, show bubble with brain icon + text.
            headerStack.isHidden = true
            statusSpinner.stopAnimating()

            // Offset text after brain icon.
            textLeadingConstraint?.constant = Self.bubblePadding + Self.brainIndent

            if text.isEmpty {
                textLabel.attributedText = nil
                bubbleView.isHidden = true
                bubbleHeightConstraint?.constant = 0
                removeFadeMask()
                updateFullScreenAffordances()
                return
            }

            bubbleView.isHidden = false
            brainIcon.isHidden = false
            bubbleView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.08)
            textLabel.attributedText = makeThinkingAttributedText(
                text,
                color: UIColor(palette.fg).withAlphaComponent(0.94)
            )

            // Done state starts at top of clipped preview.
            scrollView.contentOffset = .zero
            updateBubbleHeight(forWidth: bounds.width)
        } else {
            // Streaming: header spinner + preview bubble (non-interactive vertically).
            headerStack.isHidden = false
            statusSpinner.startAnimating()
            brainIcon.isHidden = true

            // Full-width text (no brain icon indent).
            textLeadingConstraint?.constant = Self.bubblePadding

            if text.isEmpty {
                textLabel.attributedText = nil
                bubbleView.isHidden = true
                bubbleHeightConstraint?.constant = 0
                removeFadeMask()
            } else {
                bubbleView.isHidden = false
                bubbleView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.06)
                textLabel.attributedText = makeThinkingAttributedText(
                    text,
                    color: UIColor(palette.comment).withAlphaComponent(0.88)
                )
                updateBubbleHeight(forWidth: bounds.width)
            }
        }

        updateFullScreenAffordances()
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
            updateFullScreenAffordances()
            return
        }

        let isDone = currentConfiguration.isDone
        let leadingOffset = isDone ? (Self.bubblePadding + Self.brainIndent) : Self.bubblePadding
        let textWidth = max(1, width - leadingOffset - Self.bubblePadding)
        let textSize = textLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let intrinsic = ceil(textSize.height) + Self.bubblePadding * 2

        if intrinsic <= Self.maxBubbleHeight {
            // Fits — show everything, no truncation.
            contentIsTruncated = false
            bubbleHeightConstraint?.constant = intrinsic
            removeFadeMask()
        } else if isDone {
            // Done + overflow: snap to complete lines + fade mask.
            contentIsTruncated = true
            let lineHeight = ceil(textLabel.font.lineHeight)
            let maxTextHeight = Self.maxBubbleHeight - Self.bubblePadding * 2
            let visibleLines = floor(maxTextHeight / lineHeight)
            let snappedHeight = visibleLines * lineHeight + Self.bubblePadding * 2
            bubbleHeightConstraint?.constant = snappedHeight
            applyFadeMask()
        } else {
            // Streaming + overflow: cap at max and auto-follow tail.
            contentIsTruncated = true
            bubbleHeightConstraint?.constant = Self.maxBubbleHeight
            removeFadeMask()
        }

        configureScrollBehavior()
        updateFullScreenAffordances()
    }

    // MARK: - Scroll Behavior

    private func configureScrollBehavior() {
        // Single-vertical-owner policy: inner thinking bubble never scrolls.
        scrollView.isScrollEnabled = false
        scrollView.isUserInteractionEnabled = false
        scrollView.showsVerticalScrollIndicator = false
    }

    private func performAutoScrollIfNeeded() {
        guard !currentConfiguration.isDone,
              contentIsTruncated,
              scrollView.bounds.height > 0 else { return }

        let bottomY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        guard bottomY > 0, scrollView.contentOffset.y < bottomY - 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.contentOffset = CGPoint(x: 0, y: bottomY)
        CATransaction.commit()
    }

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

    private func updateFullScreenAffordances() {
        // Thinking rows intentionally avoid the floating expand affordance.
        // Bubble tap/pinch and context menu remain the entry points.
        expandFloatingButton.isHidden = true
    }

    @objc private func handleExpandFloatingButtonTap() {
        showFullScreen()
    }

    @objc private func handleBubbleSingleTap() {
        showFullScreen()
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
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(content, from: self)
    }

    private func copyDisplayText() {
        guard !trimmedDisplayText.isEmpty else { return }
        TimelineCopyFeedback.copy(trimmedDisplayText, feedbackView: bubbleView)
    }

    private func contextMenu() -> UIMenu? {
        guard canShowFullScreen else { return nil }

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
