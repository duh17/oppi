import SwiftUI
import UIKit

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

