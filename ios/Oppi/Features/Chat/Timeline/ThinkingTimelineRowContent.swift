import SwiftUI
import UIKit

/// Native UIKit thinking row — simple and reliable.
///
/// Done state: brain icon + text in a rounded bubble, capped at ~200pt.
/// Height snaps to line boundaries so the last visible line is never clipped.
/// When truncated, a bottom fade mask hints at more content; tap opens full-screen.
///
/// Streaming state: spinner + "Thinking…" header + optional live preview.
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
    /// Fraction of the bubble height where the fade begins (bottom 30%).
    private static let fadeStartFraction: Float = 0.7

    // Header (streaming state)
    private let headerStack = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()

    // Bubble (done state — brain icon + text)
    private let bubbleView = UIView()
    private let brainIcon = UIImageView()
    private let textLabel = UILabel()
    private let fadeMask = CAGradientLayer()
    private var bubbleHeightConstraint: NSLayoutConstraint?
    private var textTopConstraint: NSLayoutConstraint?
    private var textBottomConstraint: NSLayoutConstraint?

    /// True when the text exceeds the bubble cap and is clipped.
    private(set) var contentIsTruncated = false
    /// Whether the fade mask is currently applied.
    private var fadeApplied = false

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
        // Force a fixed size so the spinner doesn't push layout around.
        statusSpinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.numberOfLines = 1
        titleLabel.text = "Thinking…"

        headerStack.addArrangedSubview(statusSpinner)
        headerStack.addArrangedSubview(titleLabel)

        // --- Bubble (done + streaming preview) ---
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.layer.cornerRadius = 10
        bubbleView.clipsToBounds = true

        brainIcon.translatesAutoresizingMaskIntoConstraints = false
        brainIcon.image = UIImage(systemName: "sparkle")
        brainIcon.contentMode = .scaleAspectFit

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .preferredFont(forTextStyle: .callout)
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.adjustsFontForContentSizeCategory = true

        // Fade mask — applied to bubbleView.layer.mask when truncated.
        // Fades from opaque → transparent at the bottom.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        fadeMask.locations = [0, NSNumber(value: Self.fadeStartFraction), 1]

        bubbleView.addSubview(brainIcon)
        bubbleView.addSubview(textLabel)

        // --- Container ---
        let stack = UIStackView(arrangedSubviews: [headerStack, bubbleView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        addSubview(stack)

        let bubbleHeight = bubbleView.heightAnchor.constraint(equalToConstant: 0)
        bubbleHeightConstraint = bubbleHeight

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            brainIcon.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: Self.bubblePadding),
            brainIcon.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: Self.bubblePadding),
            brainIcon.widthAnchor.constraint(equalToConstant: 14),
            brainIcon.heightAnchor.constraint(equalToConstant: 14),

            textLabel.leadingAnchor.constraint(equalTo: brainIcon.trailingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -Self.bubblePadding),

            bubbleHeight,
        ])

        // Text vertical anchoring — top for done (read from start),
        // bottom for streaming (tail-follow latest text).
        let top = textLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: Self.bubblePadding)
        let bottom = textLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -Self.bubblePadding)
        top.isActive = true
        bottom.isActive = false
        textTopConstraint = top
        textBottomConstraint = bottom
    }

    // MARK: - Apply

    private func apply(configuration: ThinkingTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        brainIcon.tintColor = UIColor(palette.purple).withAlphaComponent(0.7)
        statusSpinner.color = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.comment)

        let text = configuration.displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        if configuration.isDone {
            // Done: hide header, show bubble with brain + text.
            headerStack.isHidden = true
            statusSpinner.stopAnimating()

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
            updateBubbleHeight(forWidth: bounds.width)
        } else {
            // Streaming: show header spinner, show bubble with preview if available.
            headerStack.isHidden = false
            statusSpinner.startAnimating()
            brainIcon.isHidden = true

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
            return
        }

        // Available width for text: total - brain icon (14) - spacing (6) - padding (10 * 2)
        let textWidth = max(1, width - 14 - 6 - Self.bubblePadding * 2)
        let textSize = textLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let intrinsic = ceil(textSize.height) + Self.bubblePadding * 2

        if intrinsic <= Self.maxBubbleHeight {
            // Fits — show everything, no truncation.
            contentIsTruncated = false
            bubbleHeightConstraint?.constant = intrinsic
            removeFadeMask()
        } else {
            // Overflows — snap to complete lines so the last visible line isn't clipped.
            contentIsTruncated = true
            let lineHeight = ceil(textLabel.font.lineHeight)
            let maxTextHeight = Self.maxBubbleHeight - Self.bubblePadding * 2
            let visibleLines = floor(maxTextHeight / lineHeight)
            let snappedHeight = visibleLines * lineHeight + Self.bubblePadding * 2
            bubbleHeightConstraint?.constant = snappedHeight

            // Apply fade mask for done state (not streaming — streaming tail-follows).
            if currentConfiguration.isDone {
                applyFadeMask()
            } else {
                removeFadeMask()
            }
        }

        // Streaming tail-follow: anchor text to bottom so latest text is visible.
        let tailFollow = !currentConfiguration.isDone && contentIsTruncated
        textTopConstraint?.isActive = !tailFollow
        textBottomConstraint?.isActive = tailFollow
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
