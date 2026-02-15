import SwiftUI
import UIKit

// MARK: - Permission Resolved

struct PermissionTimelineRowConfiguration: UIContentConfiguration {
    let outcome: PermissionOutcome
    let tool: String
    let summary: String
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        PermissionTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class PermissionTimelineRowContentView: UIView, UIContentView {
    private struct Style {
        let icon: String
        let label: String
        let color: UIColor
    }

    private let containerView = UIView()
    private let stackView = UIStackView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()

    private var currentConfiguration: PermissionTimelineRowConfiguration

    init(configuration: PermissionTimelineRowConfiguration) {
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
            guard let config = newValue as? PermissionTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 8

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summaryLabel.numberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingTail

        addSubview(containerView)
        containerView.addSubview(stackView)
        stackView.addArrangedSubview(iconImageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(summaryLabel)

        addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 6),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -6),

            iconImageView.widthAnchor.constraint(equalToConstant: 13),
            iconImageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    private func apply(configuration: PermissionTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        let style = Self.style(for: configuration.outcome, palette: palette)

        iconImageView.image = UIImage(systemName: style.icon)
        iconImageView.tintColor = style.color

        titleLabel.text = "\(style.label): \(configuration.tool)"
        titleLabel.textColor = style.color

        summaryLabel.text = Self.truncatedSummary(configuration.summary)
        summaryLabel.textColor = UIColor(palette.fgDim)

        containerView.backgroundColor = style.color.withAlphaComponent(0.08)
    }

    private static func style(for outcome: PermissionOutcome, palette: ThemePalette) -> Style {
        switch outcome {
        case .allowed:
            return Style(icon: "checkmark.shield.fill", label: "Allowed", color: UIColor(palette.green))
        case .denied:
            return Style(icon: "xmark.shield.fill", label: "Denied", color: UIColor(palette.red))
        case .expired:
            return Style(icon: "clock.badge.xmark", label: "Expired", color: UIColor(palette.comment))
        case .cancelled:
            return Style(icon: "xmark.circle", label: "Cancelled", color: UIColor(palette.red))
        }
    }

    private static func truncatedSummary(_ summary: String) -> String {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 60 { return cleaned }
        return String(cleaned.prefix(59)) + "…"
    }
}

extension PermissionTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let value = "\(currentConfiguration.tool): \(currentConfiguration.summary)"
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: [
                UIAction(title: "Copy Command", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = value
                },
            ])
        }
    }
}

// MARK: - System Event

struct SystemTimelineRowConfiguration: UIContentConfiguration {
    let message: String
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        SystemTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class SystemTimelineRowContentView: UIView, UIContentView {
    private let stackView = UIStackView()
    private let iconImageView = UIImageView()
    private let messageLabel = UILabel()

    private var currentConfiguration: SystemTimelineRowConfiguration

    init(configuration: SystemTimelineRowConfiguration) {
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
            guard let config = newValue as? SystemTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(systemName: "info.circle")
        iconImageView.contentMode = .scaleAspectFit

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .caption1)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        addSubview(stackView)
        stackView.addArrangedSubview(iconImageView)
        stackView.addArrangedSubview(messageLabel)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),

            iconImageView.widthAnchor.constraint(equalToConstant: 13),
            iconImageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    private func apply(configuration: SystemTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconImageView.tintColor = UIColor(palette.comment)
        messageLabel.textColor = UIColor(palette.comment)
        messageLabel.text = configuration.message
    }
}

// MARK: - Compaction Event

struct CompactionTimelineRowConfiguration: UIContentConfiguration {
    let presentation: ChatTimelineCollectionView.Coordinator.CompactionPresentation
    let isExpanded: Bool
    let themeID: ThemeID

    var canExpand: Bool { presentation.canExpand }

    func makeContentView() -> any UIView & UIContentView {
        CompactionTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class CompactionTimelineRowContentView: UIView, UIContentView {
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
    private let chevronImageView = UIImageView()
    private let detailContainerView = UIView()
    private let detailLabel = UILabel()
    private let detailMarkdownView = AssistantMarkdownContentView()

    private var currentConfiguration: CompactionTimelineRowConfiguration

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
        containerView.layer.cornerRadius = 10

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
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.numberOfLines = 1

        tokensLabel.translatesAutoresizingMaskIntoConstraints = false
        tokensLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tokensLabel.numberOfLines = 1
        tokensLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailContainerView.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        headerStackView.addArrangedSubview(chevronImageView)

        addInteraction(UIContextMenuInteraction(delegate: self))

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
            chevronImageView.widthAnchor.constraint(equalToConstant: 10),
            chevronImageView.heightAnchor.constraint(equalToConstant: 10),

            detailLabel.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: detailContainerView.topAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: detailContainerView.bottomAnchor),

            detailMarkdownView.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor),
            detailMarkdownView.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor),
            detailMarkdownView.topAnchor.constraint(equalTo: detailContainerView.topAnchor),
            detailMarkdownView.bottomAnchor.constraint(equalTo: detailContainerView.bottomAnchor),
        ])
    }

    private func apply(configuration: CompactionTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        let style = Self.style(for: configuration.presentation.phase, palette: palette)

        iconImageView.image = UIImage(systemName: style.icon)
        iconImageView.tintColor = style.color

        titleLabel.text = style.title
        titleLabel.textColor = style.color

        containerView.backgroundColor = style.color.withAlphaComponent(style.backgroundAlpha)

        if let tokensBefore = configuration.presentation.tokensBefore,
           tokensBefore > 0 {
            tokensLabel.isHidden = false
            tokensLabel.text = "\(Self.formatTokenCount(tokensBefore)) tokens"
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

            if showMarkdown {
                detailMarkdownView.apply(
                    configuration: .init(
                        content: trimmedDetail,
                        isStreaming: false,
                        themeID: configuration.themeID
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

        let canExpand = configuration.canExpand && hasDetail
        chevronImageView.isHidden = !canExpand
        if canExpand {
            chevronImageView.tintColor = UIColor(palette.comment)
            chevronImageView.image = UIImage(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
        }
    }

    private static func style(
        for phase: ChatTimelineCollectionView.Coordinator.CompactionPresentation.Phase,
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

    private static func formatTokenCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func copyValue() -> String? {
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
}

extension CompactionTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let value = copyValue() else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: [
                UIAction(title: "Copy Compaction", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = value
                },
            ])
        }
    }
}

// MARK: - Error

struct ErrorTimelineRowConfiguration: UIContentConfiguration {
    let message: String
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        ErrorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ErrorTimelineRowContentView: UIView, UIContentView {
    private let containerView = UIView()
    private let stackView = UIStackView()
    private let iconImageView = UIImageView()
    private let messageLabel = UILabel()

    private var currentConfiguration: ErrorTimelineRowConfiguration

    init(configuration: ErrorTimelineRowConfiguration) {
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
            guard let config = newValue as? ErrorTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 12

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .top
        stackView.spacing = 8

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        iconImageView.contentMode = .scaleAspectFit

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.numberOfLines = 0

        addSubview(containerView)
        containerView.addSubview(stackView)
        stackView.addArrangedSubview(iconImageView)
        stackView.addArrangedSubview(messageLabel)

        addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func apply(configuration: ErrorTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        let red = UIColor(palette.red)

        iconImageView.tintColor = red
        messageLabel.textColor = UIColor(palette.fg)
        messageLabel.text = configuration.message

        containerView.backgroundColor = red.withAlphaComponent(0.18)
    }
}

extension ErrorTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let message = currentConfiguration.message
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: [
                UIAction(title: "Copy Error", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = message
                },
            ])
        }
    }
}
