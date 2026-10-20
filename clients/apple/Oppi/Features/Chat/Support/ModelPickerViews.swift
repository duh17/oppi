import UIKit

/// A model row: name and full id on the left, context window and a checkmark
/// on the right, and a trailing star when the presenter can save a default.
/// The row and the star are the cell's two accessibility elements; tapping
/// the row selects through the list's `didSelectItemAt`, VoiceOver
/// activation runs the same owner action.
final class ModelPickerCell: UICollectionViewListCell {
    struct Star {
        let isDefault: Bool
        let isEnabled: Bool
    }

    private let row = SessionOutlineRowElement()
    private let nameLabel = UILabel()
    private let currentBadge = SessionOutlineBadgeLabel()
    private let idLabel = UILabel()
    private let contextLabel = UILabel()
    private let checkmark = UIImageView()
    private let starButton = UIButton(type: .system)
    private var onStar: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        currentBadge.text = "current"
        idLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.contentMode = .center
        checkmark.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, currentBadge])
        nameRow.spacing = 6
        nameRow.alignment = .center
        let names = UIStackView(arrangedSubviews: [nameRow, idLabel])
        names.axis = .vertical
        names.alignment = .leading
        names.spacing = 3
        // The context column is right-aligned: the spacer takes the slack.
        let slack = UIView()
        slack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = UIStackView(arrangedSubviews: [slack, contextLabel, checkmark])
        trailing.spacing = 8
        trailing.alignment = .center
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        let info = UIStackView(arrangedSubviews: [names, trailing])
        info.spacing = 10
        info.alignment = .center
        info.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(info)

        starButton.translatesAutoresizingMaskIntoConstraints = false
        starButton.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .primaryActionTriggered)
        let content = UIStackView(arrangedSubviews: [row, starButton])
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            info.topAnchor.constraint(equalTo: row.topAnchor, constant: 19.5),
            info.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -19.5),
            info.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            starButton.widthAnchor.constraint(equalToConstant: 44),
            starButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        model: ModelInfo,
        id: String,
        isCurrent: Bool,
        star: Star?,
        palette: ThemePalette,
        onSelect: @escaping () -> Void,
        onStar: @escaping () -> Void
    ) {
        nameLabel.text = model.name
        nameLabel.font = SessionOutlineStyle.font(.subheadline, bold: isCurrent)
        nameLabel.textColor = UIColor(isCurrent ? palette.blue : palette.fg)
        currentBadge.isHidden = !isCurrent
        currentBadge.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
        currentBadge.textColor = UIColor(palette.blue)
        currentBadge.backgroundColor = UIColor(palette.blue.opacity(0.14))
        idLabel.text = id
        idLabel.font = SessionOutlineStyle.font(.caption1, monospaced: true)
        idLabel.textColor = UIColor(palette.comment)
        contextLabel.isHidden = model.contextWindow <= 0
        contextLabel.text = SessionFormatting.tokenCount(model.contextWindow)
        contextLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        contextLabel.textColor = UIColor(palette.fgDim)
        checkmark.isHidden = !isCurrent
        checkmark.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        )
        checkmark.tintColor = UIColor(palette.blue)

        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = isCurrent ? UIColor(palette.blue.opacity(0.12)) : UIColor(palette.bg)
        backgroundConfiguration = background

        row.onActivate = onSelect
        row.accessibilityIdentifier = "model.picker.row.\(id)"
        row.accessibilityLabel = model.name
        row.accessibilityValue = [id, model.contextWindow > 0 ? SessionFormatting.tokenCount(model.contextWindow) : nil]
            .compactMap { $0 }.joined(separator: ", ")
        row.accessibilityTraits = isCurrent ? [.button, .selected] : .button

        starButton.isHidden = star == nil
        if let star {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(
                systemName: star.isDefault ? "star.fill" : "star",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .default)
                    .applying(UIImage.SymbolConfiguration(weight: .semibold))
            )
            config.baseForegroundColor = UIColor(star.isDefault ? palette.orange : palette.comment)
            starButton.configuration = config
            starButton.isEnabled = star.isEnabled
            self.onStar = onStar
            starButton.accessibilityLabel = star.isDefault ? "Default model" : "Set as default"
            starButton.accessibilityTraits = star.isDefault ? [.button, .selected] : .button
            starButton.accessibilityIdentifier = "model.picker.star.\(id)"
        }
        accessibilityElements = star == nil ? [row] : [row, starButton]
    }
}

/// A section header: "Recent", or a provider with its quota pills, model
/// count, and a collapse chevron. The provider header is one button element
/// whose tap toggles the section; the quota pills stay out of VoiceOver and
/// read in its label instead. The pills sit inline when the row has room and
/// wrap below the name otherwise.
final class ModelPickerHeaderView: UICollectionReusableView {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let pills = UIStackView()
    private let countLabel = UILabel()
    private let chevron = UIImageView()
    private let controls = UIStackView()
    private let topRow = UIStackView()
    private let column = UIStackView()
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        pills.spacing = 4
        pills.alignment = .leading
        pills.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        controls.spacing = 6
        controls.alignment = .center
        controls.addArrangedSubview(countLabel)
        controls.addArrangedSubview(chevron)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        topRow.spacing = 6
        topRow.alignment = .center
        for view in [iconView, nameLabel, controls] { topRow.addArrangedSubview(view) }
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 5
        column.addArrangedSubview(topRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 11),
            iconView.heightAnchor.constraint(equalToConstant: 11),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func tapped() {
        onToggle?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onToggle else { return false }
        onToggle()
        return true
    }

    func configure(recentWith palette: ThemePalette) {
        configureText("Recent", palette: palette)
        iconView.isHidden = true
        pills.isHidden = true
        controls.isHidden = true
        onToggle = nil
        accessibilityLabel = "Recent"
        accessibilityTraits = .header
    }

    func configure(
        provider: String,
        badges: [ProviderQuota.ProviderBadge],
        modelCount: Int,
        hasVisibleModels: Bool,
        isCollapsed: Bool,
        isSearching: Bool,
        palette: ThemePalette,
        onToggle: @escaping () -> Void
    ) {
        let name = ProviderIcon.displayName(for: provider)
        configureText(name, palette: palette)
        iconView.isHidden = false
        iconView.image = ComposerProviderIconRenderer.image(
            provider: provider,
            size: 11,
            colors: ComposerThemeColors(palette: palette)
        )
        pills.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for badge in badges {
            let pill = SessionOutlineBadgeLabel()
            pill.insets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
            let color = Self.tone(badge.tone, palette: palette)
            pill.text = badge.label
            pill.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)
            pill.textColor = color
            pill.backgroundColor = color.withAlphaComponent(0.14)
            pills.addArrangedSubview(pill)
        }
        pills.isHidden = badges.isEmpty
        pills.isAccessibilityElement = false
        controls.isHidden = isSearching
        countLabel.text = "\(modelCount)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
        countLabel.textColor = UIColor(palette.comment)
        chevron.isHidden = !hasVisibleModels
        chevron.image = UIImage(
            systemName: isCollapsed ? "chevron.right" : "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        )
        chevron.tintColor = UIColor(palette.comment)

        let toggles = !isSearching && hasVisibleModels
        self.onToggle = toggles ? onToggle : nil
        let base = toggles ? (isCollapsed ? "Expand \(name) models" : "Collapse \(name) models") : name
        let quota = badges.map(\.accessibilityLabel).joined(separator: ", ")
        accessibilityLabel = quota.isEmpty ? base : "\(base), quota \(quota)"
        accessibilityTraits = toggles ? .button : .header
        placePills(availableWidth: nil)
    }

    private func configureText(_ text: String, palette: ThemePalette) {
        nameLabel.text = text
        nameLabel.font = SessionOutlineStyle.font(.caption1, bold: true)
        nameLabel.textColor = UIColor(palette.fgDim)
    }

    private static func tone(_ tone: ProviderQuota.BadgeTone, palette: ThemePalette) -> UIColor {
        switch tone {
        case .green: UIColor(palette.green)
        case .orange: UIColor(palette.orange)
        case .red: UIColor(palette.red)
        }
    }

    /// Pills inline between the name and the controls when they fit, else on
    /// their own row (stacked vertically when even that is too narrow).
    private func placePills(availableWidth: CGFloat?) {
        guard !pills.isHidden else { return }
        let compressed = UIView.layoutFittingCompressedSize
        pills.axis = .horizontal
        let pillsWidth = pills.systemLayoutSizeFitting(compressed).width
        let fixedWidth = (iconView.isHidden ? 0 : 17)
            + nameLabel.intrinsicContentSize.width + 6
            + controls.systemLayoutSizeFitting(compressed).width + 6
        let width = availableWidth ?? (bounds.width - layoutMargins.left - layoutMargins.right)
        let inline = width <= 0 || fixedWidth + pillsWidth <= width
        if inline {
            topRow.insertArrangedSubview(pills, at: 2)
        } else {
            column.addArrangedSubview(pills)
            if pillsWidth > width { pills.axis = .vertical }
        }
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        placePills(availableWidth: attributes.size.width - layoutMargins.left - layoutMargins.right)
        return super.preferredLayoutAttributesFitting(attributes)
    }
}
