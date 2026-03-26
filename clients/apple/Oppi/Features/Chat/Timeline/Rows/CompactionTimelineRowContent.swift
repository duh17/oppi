import SwiftUI
import UIKit

struct CompactionTimelineRowConfiguration: UIContentConfiguration {
    let presentation: ChatTimelineCollectionHost.Controller.CompactionPresentation
    let isExpanded: Bool
    let onToggleExpand: (() -> Void)?

    init(
        presentation: ChatTimelineCollectionHost.Controller.CompactionPresentation,
        isExpanded: Bool,
        onToggleExpand: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.isExpanded = isExpanded
        self.onToggleExpand = onToggleExpand
    }

    var canExpand: Bool { presentation.canExpand }

    func makeContentView() -> any UIView & UIContentView {
        CompactionTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class CompactionTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    private struct Style {
        let icon: String
        let title: String
        let color: UIColor
        let backgroundAlpha: CGFloat
    }

    private let containerView = UIView()
    private let stackView = UIStackView()
    private let headerStackView = UIStackView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let tokensLabel = UILabel()
    private let expandButton = UIButton(type: .system)
    private let detailContainerView = UIView()
    private let detailLabel = UILabel()
    private let detailMarkdownView = AssistantMarkdownContentView()
    private var detailLabelBottom: NSLayoutConstraint?
    private var detailMarkdownBottom: NSLayoutConstraint?

    private var currentConfiguration: CompactionTimelineRowConfiguration
    private var interactionHandlers: TimelineRowInteractionHandlers?

    init(configuration: CompactionTimelineRowConfiguration) {
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
            guard let config = newValue as? CompactionTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = TimelineBubbleStyle.bubbleCornerRadius

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 6

        headerStackView.translatesAutoresizingMaskIntoConstraints = false
        headerStackView.axis = .horizontal
        headerStackView.alignment = .center
        headerStackView.spacing = 6

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppFont.monoMediumSemibold
        titleLabel.numberOfLines = 1

        tokensLabel.translatesAutoresizingMaskIntoConstraints = false
        tokensLabel.font = AppFont.mono
        tokensLabel.numberOfLines = 1
        tokensLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.contentHorizontalAlignment = .center
        expandButton.contentVerticalAlignment = .center
        expandButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        expandButton.setContentHuggingPriority(.required, for: .horizontal)
        expandButton.tintColor = UIColor(ThemeRuntimeState.currentPalette().comment)
        expandButton.accessibilityIdentifier = "compaction.expand-toggle"
        expandButton.addTarget(self, action: #selector(handleExpandButtonTap), for: .touchUpInside)

        detailContainerView.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = AppFont.monoMedium
        detailLabel.numberOfLines = 0
        detailLabel.lineBreakMode = .byTruncatingTail

        detailMarkdownView.translatesAutoresizingMaskIntoConstraints = false
        detailMarkdownView.isHidden = true

        addSubview(containerView)
        containerView.addSubview(stackView)
        stackView.addArrangedSubview(headerStackView)
        stackView.addArrangedSubview(detailContainerView)

        detailContainerView.addSubview(detailLabel)
        detailContainerView.addSubview(detailMarkdownView)

        headerStackView.addArrangedSubview(iconImageView)
        headerStackView.addArrangedSubview(titleLabel)
        headerStackView.addArrangedSubview(UIView())
        headerStackView.addArrangedSubview(tokensLabel)
        headerStackView.addArrangedSubview(expandButton)

        interactionHandlers = TimelineRowInteractionInstaller.install(
            on: containerView,
            provider: self
        )
        // Exclude expand button from double-tap gesture.
        interactionHandlers?.gesture.delegate = self

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),

            iconImageView.widthAnchor.constraint(equalToConstant: 14),
            iconImageView.heightAnchor.constraint(equalToConstant: 14),
            expandButton.widthAnchor.constraint(equalToConstant: 28),
            expandButton.heightAnchor.constraint(equalToConstant: 28),

            detailLabel.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: detailContainerView.topAnchor),

            detailMarkdownView.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor),
            detailMarkdownView.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor),
            detailMarkdownView.topAnchor.constraint(equalTo: detailContainerView.topAnchor),
        ])

        // Bottom constraints stored separately — only the visible view drives container height.
        let labelBottom = detailLabel.bottomAnchor.constraint(equalTo: detailContainerView.bottomAnchor)
        let mdBottom = detailMarkdownView.bottomAnchor.constraint(equalTo: detailContainerView.bottomAnchor)
        labelBottom.isActive = true
        mdBottom.isActive = false
        detailLabelBottom = labelBottom
        detailMarkdownBottom = mdBottom
    }

    private func apply(configuration: CompactionTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        let style = Self.style(for: configuration.presentation.phase, palette: palette)

        iconImageView.image = UIImage(systemName: style.icon)
        iconImageView.tintColor = style.color

        titleLabel.text = style.title
        titleLabel.textColor = style.color

        containerView.backgroundColor = style.color.withAlphaComponent(style.backgroundAlpha)

        if let tokensBefore = configuration.presentation.tokensBefore,
           tokensBefore > 0 {
            tokensLabel.isHidden = false
            tokensLabel.text = "\(SessionFormatting.tokenCountDecimal(tokensBefore)) tokens"
            tokensLabel.textColor = UIColor(palette.comment)
        } else {
            tokensLabel.isHidden = true
            tokensLabel.text = nil
        }

        let trimmedDetail = configuration.presentation.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hasDetail: Bool
        if let trimmedDetail, !trimmedDetail.isEmpty {
            hasDetail = true
            detailContainerView.isHidden = false

            let canExpand = configuration.canExpand
            let showMarkdown = canExpand && configuration.isExpanded

            detailLabel.isHidden = showMarkdown
            detailMarkdownView.isHidden = !showMarkdown

            // Only the visible view's bottom constraint drives container height.
            detailLabelBottom?.isActive = !showMarkdown
            detailMarkdownBottom?.isActive = showMarkdown

            if showMarkdown {
                detailMarkdownView.apply(
                    configuration: .init(
                        content: trimmedDetail,
                        isStreaming: false,
                        themeID: ThemeRuntimeState.currentThemeID()
                    )
                )
            } else {
                detailLabel.text = trimmedDetail
                detailLabel.textColor = UIColor(palette.fgDim)
                detailLabel.numberOfLines = canExpand ? 1 : 0
            }
        } else {
            hasDetail = false
            detailContainerView.isHidden = true
            detailLabel.isHidden = true
            detailLabel.text = nil
            detailMarkdownView.isHidden = true
            detailLabel.numberOfLines = 0
        }

        let canExpand = configuration.canExpand
            && hasDetail
            && configuration.onToggleExpand != nil
        expandButton.isHidden = !canExpand
        expandButton.isEnabled = canExpand

        if canExpand {
            expandButton.tintColor = UIColor(palette.comment)
            expandButton.setImage(
                UIImage(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down"),
                for: .normal
            )
            expandButton.accessibilityLabel = configuration.isExpanded
                ? "Collapse compaction summary"
                : "Expand compaction summary"
        } else {
            expandButton.setImage(nil, for: .normal)
            expandButton.accessibilityLabel = nil
        }
    }

    private static func style(
        for phase: ChatTimelineCollectionHost.Controller.CompactionPresentation.Phase,
        palette: ThemePalette
    ) -> Style {
        switch phase {
        case .inProgress:
            return Style(
                icon: "arrow.triangle.2.circlepath",
                title: "Compacting context...",
                color: UIColor(palette.blue),
                backgroundAlpha: 0.12
            )

        case .completed:
            return Style(
                icon: "tray.full",
                title: "Context compacted",
                color: UIColor(palette.comment),
                backgroundAlpha: 0.18
            )

        case .retrying:
            return Style(
                icon: "arrow.clockwise.circle",
                title: "Compacted — retrying",
                color: UIColor(palette.orange),
                backgroundAlpha: 0.14
            )

        case .cancelled:
            return Style(
                icon: "xmark.circle",
                title: "Compaction cancelled",
                color: UIColor(palette.red),
                backgroundAlpha: 0.16
            )
        }
    }

    // MARK: - TimelineRowInteractionProvider

    var copyableText: String? {
        let title = titleLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = currentConfiguration.presentation.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if detail.isEmpty {
            return title.isEmpty ? nil : title
        }

        if title.isEmpty {
            return detail
        }

        return "\(title): \(detail)"
    }

    var interactionFeedbackView: UIView { containerView }

    @objc private func handleExpandButtonTap() {
        currentConfiguration.onToggleExpand?()
    }
}

extension CompactionTimelineRowContentView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current: UIView? = touch.view
        while let view = current {
            if view === expandButton {
                return false
            }
            current = view.superview
        }
        return true
    }
}
