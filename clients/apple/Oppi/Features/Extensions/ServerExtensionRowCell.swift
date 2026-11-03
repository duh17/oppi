import UIKit

/// One extension in the Extensions list: its puzzle mark (emptied and muted
/// while off), name, description, package, provenance, its badges (Plugin,
/// Pi extension, Built-in, Project), state, and first warning, with the system
/// disclosure chevron. The
/// whole row is one button (`extensions.row.<id>`), so a tap, a VoiceOver
/// activation, and `app.buttons[id]` all open its detail.
final class ServerExtensionRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let packageLabel = UILabel()
    private let provenanceLabel = UILabel()
    private let stateIcon = UIImageView()
    private let stateLabel = UILabel()
    private let badgeRow = UIStackView()
    private let warningLabel = UILabel()
    private let textStack = UIStackView()
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.font = .scaled(.body, .semibold)
        descriptionLabel.font = .scaled(.subheadline)
        packageLabel.font = .scaled(.caption1)
        provenanceLabel.font = .scaled(.caption1)
        stateLabel.font = .scaled(.caption1, .medium)
        warningLabel.font = .scaled(.caption1)
        for label in [nameLabel, descriptionLabel, packageLabel, provenanceLabel, stateLabel, warningLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        stateIcon.contentMode = .scaleAspectFit
        stateIcon.setContentHuggingPriority(.required, for: .horizontal)
        stateIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stateRow = UIStackView(arrangedSubviews: [stateIcon, stateLabel])
        stateRow.axis = .horizontal
        stateRow.alignment = .firstBaseline
        stateRow.spacing = 4
        badgeRow.axis = .horizontal
        badgeRow.alignment = .center
        badgeRow.spacing = 6

        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        for view in [nameLabel, descriptionLabel, packageLabel, provenanceLabel, badgeRow, stateRow, warningLabel] {
            textStack.addArrangedSubview(view)
        }
        for view in [iconView, textStack, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        accessories = [.disclosureIndicator()]
        button.accessibilityTraits = .button
        // The labels paint the row; the button above them is its one accessible
        // element, so the row reads as a single control.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // A grouped list's separator starts where the row's text does.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
        ])
        // The description's line limit follows the text size category (the
        // list sets `selfSizingInvalidation`, so the row re-measures).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: Self, _) in
            cell.applyDescriptionLineLimit()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(resource: ServerExtensionSummary, palette: ThemePalette, action: @escaping () -> Void) {
        let fg = palette.ui.fg
        let comment = palette.ui.comment
        let icon = ServerExtensionListPresentation.icon(for: resource)
        iconView.image = UIImage(
            systemName: icon.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
        )
        iconView.tintColor = icon == .enabled ? palette.ui.blue : comment
        nameLabel.text = resource.name
        nameLabel.textColor = fg
        descriptionLabel.text = resource.description
        descriptionLabel.isHidden = resource.description?.isEmpty ?? true
        descriptionLabel.textColor = comment
        packageLabel.text = resource.packageName
        packageLabel.isHidden = resource.packageName == nil
        packageLabel.textColor = comment
        provenanceLabel.text = resource.provenance.label
        provenanceLabel.textColor = comment

        let isIssue = resource.state == .error || resource.state == .unknown
        stateIcon.image = UIImage(
            systemName: isIssue ? "exclamationmark.triangle.fill" : (resource.state == .on ? "checkmark.circle" : "minus.circle"),
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        )
        stateIcon.tintColor = isIssue ? palette.ui.orange : comment
        stateLabel.text = ServerExtensionListPresentation.statusLabel(for: resource)
        stateLabel.textColor = isIssue ? palette.ui.orange : comment
        configureBadges(ServerExtensionListPresentation.badges(for: resource), palette: palette)
        // The first warning (a linked built-in, plugins that could not load); the detail lists all.
        warningLabel.text = resource.warnings.first
        warningLabel.isHidden = resource.warnings.isEmpty
        warningLabel.textColor = palette.ui.orange
        applyDescriptionLineLimit()

        button.accessibilityIdentifier = "extensions.row.\(resource.id)"
        button.accessibilityLabel = ServerExtensionListPresentation.accessibilityLabel(for: resource)
        if let tapAction { button.removeAction(tapAction, for: .touchUpInside) }
        let tap = UIAction { _ in action() }
        tapAction = tap
        button.addAction(tap, for: .touchUpInside)
    }

    private func configureBadges(_ badges: [ServerExtensionBadge], palette: ThemePalette) {
        badgeRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for badge in badges {
            let pill = InsetLabel(insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6), capsule: true)
            let color = switch badge.tone {
            case .kind: palette.ui.blue
            case .source: palette.ui.comment
            }
            pill.text = badge.label
            pill.font = .scaled(.caption2, .semibold)
            pill.textColor = color
            pill.backgroundColor = color.withAlphaComponent(0.14)
            badgeRow.addArrangedSubview(pill)
        }
        badgeRow.isHidden = badges.isEmpty
    }

    private func applyDescriptionLineLimit() {
        let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        descriptionLabel.numberOfLines = isAccessibilitySize ? 0 : 2
        warningLabel.numberOfLines = isAccessibilitySize ? 0 : 2
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        iconView.image = nil
        isHighlighted = false
    }
}
