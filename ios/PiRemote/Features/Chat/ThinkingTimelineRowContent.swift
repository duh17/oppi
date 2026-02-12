import SwiftUI
import UIKit

/// Native UIKit thinking row.
///
/// Supports both collapsed and expanded states with label text,
/// expansion affordance, and capped expanded viewport.
struct ThinkingTimelineRowConfiguration: UIContentConfiguration {
    let isDone: Bool
    let isExpanded: Bool
    let previewText: String
    let fullText: String?
    let themeID: ThemeID

    var fullTextTrimmed: String {
        (fullText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isPreviewOnly: Bool {
        fullTextTrimmed.isEmpty
    }

    var displayText: String {
        isPreviewOnly ? previewText : fullTextTrimmed
    }

    func makeContentView() -> any UIView & UIContentView {
        ThinkingTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ThinkingTimelineRowContentView: UIView, UIContentView {
    private static let expandedViewportMaxHeight: CGFloat = 200
    private static let expandedContainerHorizontalPadding: CGFloat = 8
    private static let expandedContainerVerticalPadding: CGFloat = 8

    private let containerStack = UIStackView()
    private let headerStack = UIStackView()

    private let statusHostView = UIView()
    private let statusImageView = UIImageView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let spacerView = UIView()
    private let chevronImageView = UIImageView()

    private let expandedContainerView = UIView()
    private let expandedScrollView = UIScrollView()
    private let expandedTextView = UITextView()
    private var expandedContainerHeight: NSLayoutConstraint?

    private var currentConfiguration: ThinkingTimelineRowConfiguration

    private var shouldShowThoughtContent: Bool {
        currentConfiguration.isDone
            && !currentConfiguration.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(configuration: ThinkingTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? ThinkingTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateExpandedViewportHeightIfNeeded(preferredWidth: bounds.width)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let targetWidth = targetSize.width.isFinite ? targetSize.width : bounds.width
        updateExpandedViewportHeightIfNeeded(preferredWidth: targetWidth)

        let fitted = super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )

        let width = fitted.width.isFinite && fitted.width > 0 ? fitted.width : max(1, targetWidth)
        let height = fitted.height.isFinite && fitted.height > 0 ? min(fitted.height, 10_000) : 44
        return CGSize(width: width, height: height)
    }

    private func setupViews() {
        backgroundColor = .clear

        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.axis = .vertical
        containerStack.alignment = .fill
        containerStack.spacing = 4

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 6

        statusHostView.translatesAutoresizingMaskIntoConstraints = false

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.image = UIImage(systemName: "brain")
        statusImageView.contentMode = .scaleAspectFit

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.hidesWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.numberOfLines = 1

        spacerView.translatesAutoresizingMaskIntoConstraints = false

        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        chevronImageView.contentMode = .scaleAspectFit

        expandedContainerView.translatesAutoresizingMaskIntoConstraints = false
        expandedContainerView.layer.cornerRadius = 8
        expandedContainerView.layer.borderWidth = 1
        expandedContainerView.clipsToBounds = true

        expandedScrollView.translatesAutoresizingMaskIntoConstraints = false
        expandedScrollView.alwaysBounceVertical = false
        expandedScrollView.showsVerticalScrollIndicator = true

        expandedTextView.translatesAutoresizingMaskIntoConstraints = false
        expandedTextView.isEditable = false
        expandedTextView.isSelectable = true
        expandedTextView.isScrollEnabled = false
        expandedTextView.backgroundColor = .clear
        expandedTextView.textContainerInset = .zero
        expandedTextView.textContainer.lineFragmentPadding = 0
        expandedTextView.font = .preferredFont(forTextStyle: .callout)
        expandedTextView.adjustsFontForContentSizeCategory = true

        addSubview(containerStack)

        containerStack.addArrangedSubview(headerStack)
        containerStack.addArrangedSubview(expandedContainerView)

        headerStack.addArrangedSubview(statusHostView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(spacerView)
        headerStack.addArrangedSubview(chevronImageView)

        statusHostView.addSubview(statusImageView)
        statusHostView.addSubview(statusSpinner)

        expandedContainerView.addSubview(expandedScrollView)
        expandedScrollView.addSubview(expandedTextView)

        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        expandedContainerHeight = expandedContainerView.heightAnchor.constraint(equalToConstant: 0)
        expandedContainerHeight?.isActive = true

        NSLayoutConstraint.activate([
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusHostView.widthAnchor.constraint(equalToConstant: 14),
            statusHostView.heightAnchor.constraint(equalToConstant: 14),

            statusImageView.leadingAnchor.constraint(equalTo: statusHostView.leadingAnchor),
            statusImageView.trailingAnchor.constraint(equalTo: statusHostView.trailingAnchor),
            statusImageView.topAnchor.constraint(equalTo: statusHostView.topAnchor),
            statusImageView.bottomAnchor.constraint(equalTo: statusHostView.bottomAnchor),

            statusSpinner.centerXAnchor.constraint(equalTo: statusHostView.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: statusHostView.centerYAnchor),

            chevronImageView.widthAnchor.constraint(equalToConstant: 10),
            chevronImageView.heightAnchor.constraint(equalToConstant: 10),

            expandedScrollView.leadingAnchor.constraint(
                equalTo: expandedContainerView.leadingAnchor,
                constant: Self.expandedContainerHorizontalPadding
            ),
            expandedScrollView.trailingAnchor.constraint(
                equalTo: expandedContainerView.trailingAnchor,
                constant: -Self.expandedContainerHorizontalPadding
            ),
            expandedScrollView.topAnchor.constraint(
                equalTo: expandedContainerView.topAnchor,
                constant: Self.expandedContainerVerticalPadding
            ),
            expandedScrollView.bottomAnchor.constraint(
                equalTo: expandedContainerView.bottomAnchor,
                constant: -Self.expandedContainerVerticalPadding
            ),

            expandedTextView.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor),
            expandedTextView.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor),
            expandedTextView.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor),
            expandedTextView.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor),
            expandedTextView.widthAnchor.constraint(equalTo: expandedScrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func apply(configuration: ThinkingTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        statusImageView.tintColor = UIColor(palette.purple)
        statusSpinner.color = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.comment)
        chevronImageView.tintColor = UIColor(palette.comment)
        expandedTextView.tintColor = UIColor(palette.blue)
        expandedTextView.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        if configuration.isDone {
            // Completed thoughts should read like content, not a collapsible section.
            headerStack.isHidden = true
            statusSpinner.stopAnimating()
            statusSpinner.isHidden = true
            chevronImageView.isHidden = true
            chevronImageView.image = nil

            let previewOnly = configuration.isPreviewOnly
            expandedContainerView.isHidden = !shouldShowThoughtContent
            expandedContainerView.backgroundColor = UIColor(
                (previewOnly ? palette.bgDark : palette.bgHighlight)
                    .opacity(previewOnly ? 0.70 : 0.90)
            )
            expandedContainerView.layer.borderColor = UIColor(
                (previewOnly ? palette.comment : palette.purple)
                    .opacity(previewOnly ? 0.18 : 0.24)
            ).cgColor

            if shouldShowThoughtContent {
                applyExpandedTextStyle(
                    text: configuration.displayText,
                    palette: palette,
                    isPreviewOnly: previewOnly
                )
                updateExpandedViewportHeightIfNeeded(preferredWidth: bounds.width)
            } else {
                expandedTextView.attributedText = nil
                expandedTextView.text = nil
                expandedContainerHeight?.constant = 0
                expandedScrollView.contentOffset = .zero
                expandedScrollView.alwaysBounceVertical = false
            }
            return
        }

        headerStack.isHidden = false
        titleLabel.text = "Thinking…"
        statusImageView.isHidden = true
        statusSpinner.isHidden = false
        statusSpinner.startAnimating()
        chevronImageView.isHidden = true
        chevronImageView.image = nil

        expandedContainerView.isHidden = true
        expandedTextView.attributedText = nil
        expandedTextView.text = nil
        expandedContainerHeight?.constant = 0
        expandedScrollView.contentOffset = .zero
        expandedScrollView.alwaysBounceVertical = false
    }

    private func applyExpandedTextStyle(text: String, palette: ThemePalette, isPreviewOnly: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping

        let baseFont = UIFont.preferredFont(forTextStyle: .callout)
        let baseColor = UIColor((isPreviewOnly ? palette.comment : palette.fg).opacity(isPreviewOnly ? 0.88 : 0.94))

        let rendered: NSMutableAttributedString
        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        if let markdown = try? AttributedString(markdown: text, options: markdownOptions) {
            rendered = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
        } else {
            rendered = NSMutableAttributedString(string: text)
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        if fullRange.length > 0 {
            rendered.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
            rendered.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
            rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if value == nil {
                    rendered.addAttribute(.font, value: baseFont, range: range)
                }
            }
        }

        expandedTextView.attributedText = rendered
    }

    private func updateExpandedViewportHeightIfNeeded(preferredWidth: CGFloat? = nil) {
        guard shouldShowThoughtContent else {
            expandedContainerHeight?.constant = 0
            return
        }

        let resolvedWidth = max(0, preferredWidth ?? bounds.width)
        let availableWidth = max(
            1,
            resolvedWidth - (Self.expandedContainerHorizontalPadding * 2)
        )

        guard availableWidth > 1 else { return }

        let measured = expandedTextView.sizeThatFits(
            CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let measuredTextHeight = max(20, ceil(measured.height))
        let viewportHeight = min(Self.expandedViewportMaxHeight, measuredTextHeight)

        expandedContainerHeight?.constant = viewportHeight + (Self.expandedContainerVerticalPadding * 2)
        expandedScrollView.alwaysBounceVertical = measuredTextHeight > viewportHeight
    }
}
