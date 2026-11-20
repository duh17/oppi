import UIKit

/// The icon picker's Animation row, shown while the icon is a symbol:
/// the symbol on its tile playing the chosen effect (the preview is one of the
/// two places an icon animates), "Animation" with the effect's name, and a
/// menu of None and each `IconSymbolEffect`. The whole row is the one button
/// that opens the menu.
final class IconPickerSymbolEffectCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let preview = IconChoiceUIView(frameSize: 36, animates: true)
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = String(localized: "Animation")
        titleLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.font = .preferredFont(forTextStyle: .body)
        for label in [titleLabel, valueLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [preview, titleLabel, valueLabel, chevron])
        row.spacing = 12
        row.setCustomSpacing(6, after: valueLabel)
        row.alignment = .center
        for view in [row, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.showsMenuAsPrimaryAction = true
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        // The labels paint the row; the button above them is its one accessible element.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `symbol` is the chosen symbol and `effect` its effect; `ownPage` names
    /// where else it plays (`IconPickerPurpose.ownPage`); `choose` gets the
    /// person's pick (nil for None).
    func configure(
        symbol: String,
        effect: IconSymbolEffect?,
        ownPage: String,
        assetCache: IconAssetCache?,
        isEnabled: Bool,
        identifier: String,
        choose: @escaping (IconSymbolEffect?) -> Void
    ) {
        let style = SettingsStyle.current
        preview.apply(.choice(.symbol(symbol, effect: effect), purpose: .agent, sandbox: false), assetCache: assetCache)
        let value = effect?.title ?? String(localized: "None")
        titleLabel.textColor = style.title
        valueLabel.text = value
        valueLabel.textColor = style.value
        chevron.tintColor = style.value
        contentView.alpha = isEnabled ? 1 : 0.4
        let options = [nil] + IconSymbolEffect.allCases.map(Optional.some)
        button.menu = UIMenu(options: .singleSelection, children: options.map { option in
            UIAction(
                title: option?.title ?? String(localized: "None"),
                identifier: UIAction.Identifier("\(identifier).\(option?.rawValue ?? "none")"),
                state: option == effect ? .on : .off
            ) { _ in choose(option) }
        })
        button.isEnabled = isEnabled
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = String(localized: "Animation")
        button.accessibilityValue = value
        button.accessibilityHint = String(localized: "Chooses how the symbol animates on \(ownPage)")
        button.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.menu = nil
        button.accessibilityIdentifier = nil
        isHighlighted = false
    }
}
