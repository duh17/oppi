import SwiftUI
import UIKit

/// Native UIKit thinking row — simple and reliable.
///
/// Done state: brain icon + text in a rounded bubble, capped at ~200pt.
/// Height snaps to line boundaries so the last visible line is never clipped.
/// When truncated, a bottom fade mask hints at more content; tap opens full-screen.
///
/// Streaming state: spinner + "Thinking…" header + scrollable preview.
/// Auto-tails to the bottom like the main chat view. Scrolling up pauses
/// auto-tail; scrolling back to the bottom resumes it.
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
    private var bubbleHeightConstraint: NSLayoutConstraint?
    private var textLeadingConstraint: NSLayoutConstraint?

    /// True when the text exceeds the bubble cap.
    private(set) var contentIsTruncated = false
    /// Whether the fade mask is currently applied.
    private var fadeApplied = false
    /// Auto-tail: scroll to bottom on new content. Paused when user scrolls up.
    private var shouldAutoScroll = true

    private var currentConfiguration: ThinkingTimelineRowConfiguration

    init(configuration: ThinkingTimelineRowConfiguration) {
        self.currentConfiguration = configuration
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

        // Scroll view — enables scrolling during streaming.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = false
        scrollView.isScrollEnabled = false
        scrollView.isUserInteractionEnabled = false
        scrollView.delegate = self

        brainIcon.translatesAutoresizingMaskIntoConstraints = false
        brainIcon.image = UIImage(systemName: "sparkle")
        brainIcon.contentMode = .scaleAspectFit

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .preferredFont(forTextStyle: .callout)
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.adjustsFontForContentSizeCategory = true

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
        ])
    }

    // MARK: - Apply

    private func apply(configuration: ThinkingTimelineRowConfiguration) {
        let wasStreaming = !currentConfiguration.isDone
        let isNowStreaming = !configuration.isDone
        currentConfiguration = configuration

        // Reset auto-scroll when entering streaming state.
        if isNowStreaming && !wasStreaming {
            shouldAutoScroll = true
            scrollView.contentOffset = .zero
        }

        let palette = configuration.themeID.palette
        brainIcon.tintColor = UIColor(palette.purple).withAlphaComponent(0.7)
        statusSpinner.color = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.comment)

        let text = configuration.displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        if configuration.isDone {
            // Done: hide header, show bubble with brain icon + text.
            headerStack.isHidden = true
            statusSpinner.stopAnimating()

            // Offset text after brain icon.
            textLeadingConstraint?.constant = Self.bubblePadding + Self.brainIndent

            if text.isEmpty {
                bubbleView.isHidden = true
                bubbleHeightConstraint?.constant = 0
                removeFadeMask()
                return
            }

            bubbleView.isHidden = false
            brainIcon.isHidden = false
            bubbleView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.08)
            textLabel.textColor = UIColor(palette.fg).withAlphaComponent(0.94)
            textLabel.text = text

            // Reset scroll for done state.
            shouldAutoScroll = true
            scrollView.contentOffset = .zero

            updateBubbleHeight(forWidth: bounds.width)
        } else {
            // Streaming: header spinner + scrollable preview.
            headerStack.isHidden = false
            statusSpinner.startAnimating()
            brainIcon.isHidden = true

            // Full-width text (no brain icon indent).
            textLeadingConstraint?.constant = Self.bubblePadding

            if text.isEmpty {
                bubbleView.isHidden = true
                bubbleHeightConstraint?.constant = 0
                removeFadeMask()
            } else {
                bubbleView.isHidden = false
                bubbleView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.06)
                textLabel.textColor = UIColor(palette.comment).withAlphaComponent(0.88)
                textLabel.text = text
                updateBubbleHeight(forWidth: bounds.width)
            }
        }
    }

    // MARK: - Height

    private func updateBubbleHeight(forWidth width: CGFloat) {
        guard !bubbleView.isHidden, width > 0 else {
            bubbleHeightConstraint?.constant = 0
            contentIsTruncated = false
            removeFadeMask()
            configureScrollBehavior()
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
            // Streaming + overflow: cap at max, scrollable.
            contentIsTruncated = true
            bubbleHeightConstraint?.constant = Self.maxBubbleHeight
            removeFadeMask()
        }

        configureScrollBehavior()
    }

    // MARK: - Scroll Behavior

    private func configureScrollBehavior() {
        let scrollable = !currentConfiguration.isDone && contentIsTruncated
        scrollView.isScrollEnabled = scrollable
        scrollView.isUserInteractionEnabled = scrollable
        scrollView.showsVerticalScrollIndicator = scrollable
    }

    private func performAutoScrollIfNeeded() {
        guard shouldAutoScroll,
              !currentConfiguration.isDone,
              scrollView.isScrollEnabled,
              scrollView.bounds.height > 0 else { return }

        let bottomY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        guard bottomY > 0, scrollView.contentOffset.y < bottomY - 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.contentOffset = CGPoint(x: 0, y: bottomY)
        CATransaction.commit()
    }

    private var isAtBottom: Bool {
        let bottomEdge = scrollView.contentOffset.y + scrollView.bounds.height
        return bottomEdge >= scrollView.contentSize.height - 20
    }

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

    // MARK: - Full Screen

    func showFullScreen() {
        let text = currentConfiguration.displayText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let content = FullScreenCodeContent.markdown(content: text, filePath: nil)
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(content, from: self)
    }
}

// MARK: - UIScrollViewDelegate (auto-tail)

extension ThinkingTimelineRowContentView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only track user-initiated scrolls, not programmatic ones.
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        shouldAutoScroll = isAtBottom
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            shouldAutoScroll = isAtBottom
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        shouldAutoScroll = isAtBottom
    }
}
