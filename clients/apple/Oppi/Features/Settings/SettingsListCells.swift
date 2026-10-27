import UIKit

/// A settings index row: an optional theme-blue symbol, a Title Case title,
/// an optional current-value summary, and the system disclosure chevron. The
/// whole row is one button, so a tap, a VoiceOver activation, and
/// `app.buttons[id]` all run the row's push. Without a symbol the title starts
/// at the row's margin.
final class SettingsIndexRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private var tapAction: UIAction?
    private var titleAfterIcon: NSLayoutConstraint?
    private var titleAtMargin: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [iconView, titleLabel, valueLabel, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityTraits = .button
        // The labels paint the row; the button above them is its one accessible
        // element, so the row reads as a single control.
        accessibilityElements = [button]
        // One of the two title starts is active, by whether the row has a symbol.
        let afterIcon = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12)
        titleAfterIcon = afterIcon
        titleAtMargin = titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            afterIcon,
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // A grouped list's separator starts where the row's title does.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        systemImage: String?,
        value: String?,
        showsDisclosure: Bool,
        titleColor: UIColor,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        iconView.isHidden = systemImage == nil
        titleAfterIcon?.isActive = systemImage != nil
        titleAtMargin?.isActive = systemImage == nil
        iconView.tintColor = UIColor(palette.blue)
        titleLabel.text = title
        titleLabel.textColor = titleColor
        valueLabel.text = value
        valueLabel.textColor = UIColor(palette.comment)
        valueLabel.isHidden = value == nil
        accessories = showsDisclosure ? [.disclosureIndicator()] : []
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = value
        if let tapAction { button.removeAction(tapAction, for: .touchUpInside) }
        let tap = UIAction { _ in action() }
        tapAction = tap
        button.addAction(tap, for: .touchUpInside)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        iconView.image = nil
        titleLabel.text = nil
        valueLabel.text = nil
        isHighlighted = false
    }
}

/// A row's overlay button. It is transparent over the row's labels, so the
/// cell's own highlight never fires; this hands the press to the cell, which
/// paints the pressed fill.
final class SettingsRowButton: UIButton {
    var onHighlight: ((Bool) -> Void)?

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            onHighlight?(isHighlighted)
        }
    }
}

/// A choice row: the title and the current choice (in the accent color, with
/// the up/down mark a pop-up button shows), and the whole row one button whose
/// menu lists the choices with a checkmark on the current one. Like
/// `SettingsIndexRowCell`, the labels paint the row and the button is its one
/// accessible element, so a tap, a VoiceOver activation, and `app.buttons[id]`
/// all open the menu. At accessibility text sizes the choice stacks under the
/// title instead of sharing its line. The title uses the system label color,
/// as the title of a plain `valueCell` row on the same page does.
final class SettingsMenuRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [titleLabel, valueLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        titleLabel.textColor = .label
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A symbol with a text style follows Dynamic Type on its own.
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let value = UIStackView(arrangedSubviews: [valueLabel, chevron])
        value.spacing = 4
        value.alignment = .center
        value.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(value)
        stack.spacing = 8
        for view in [stack, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own, as in `SettingsIndexRowCell`.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        button.showsMenuAsPrimaryAction = true
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        arrangeForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrangeForTextSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func arrangeForTextSize() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        stack.axis = stacked ? .vertical : .horizontal
        stack.alignment = stacked ? .leading : .center
    }

    func configure(
        title: String,
        identifier: String,
        options: [(title: String, selected: Bool, action: () -> Void)]
    ) {
        let tint = UIColor(ThemeRuntimeState.currentPalette().blue)
        let current = options.first(where: \.selected)?.title
        titleLabel.text = title
        valueLabel.text = current
        valueLabel.textColor = tint
        chevron.tintColor = tint
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = current
        button.menu = UIMenu(children: options.map { option in
            UIAction(title: option.title, state: option.selected ? .on : .off) { _ in option.action() }
        })
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.menu = nil
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        titleLabel.text = nil
        valueLabel.text = nil
        isHighlighted = false
    }
}
