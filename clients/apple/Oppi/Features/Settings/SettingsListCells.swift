import UIKit

/// A settings navigation row: an optional accent symbol, a Title Case title in
/// the theme's title color, an optional current-value summary, and the system
/// disclosure chevron. The whole row is one button, so a tap, a VoiceOver
/// activation, and `app.buttons[id]` all run the row's push. Without a symbol
/// the title starts at the row's margin. The value sits beside the title when
/// both fit on one line, and under it when they do not (a long summary, or a
/// large text size), so neither is squeezed.
final class SettingsIndexRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let iconView = UIImageView()
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private var stackAfterIcon: NSLayoutConstraint?
    private var stackAtMargin: NSLayoutConstraint?
    private var isSideBySide = true

    private static let iconWidth: CGFloat = 24
    private static let iconSpacing: CGFloat = 12
    /// The gap between the title and the value, beside or under it.
    private static let textSpacing: CGFloat = 8
    private static let stackedSpacing: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(valueLabel)
        for view in [iconView, textStack, button] {
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
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        arrange(sideBySide: true, force: true)
        button.accessibilityTraits = .button
        // The labels paint the row; the button above them is its one accessible
        // element, so the row reads as a single control.
        accessibilityElements = [button]
        // One of the two text starts is active, by whether the row has a symbol.
        let afterIcon = textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconSpacing)
        stackAfterIcon = afterIcon
        stackAtMargin = textStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            afterIcon,
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // A grouped list's separator starts where the row's title does.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        systemImage: String?,
        value: String?,
        valueNeedsAttention: Bool = false,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        iconView.isHidden = systemImage == nil
        stackAfterIcon?.isActive = systemImage != nil
        stackAtMargin?.isActive = systemImage == nil
        iconView.tintColor = style.accent
        titleLabel.text = title
        titleLabel.textColor = style.title
        valueLabel.text = value
        // A value that asks for something ("Needs setup") is drawn in the warning color.
        valueLabel.textColor = valueNeedsAttention ? style.warning : style.value
        valueLabel.isHidden = value == nil
        accessories = [.disclosureIndicator()]
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = value
        button.setTapAction(action)
        setNeedsLayout()
    }

    /// The value sits beside the title when both fit on one line in the text
    /// stack as laid out, and under it otherwise. The stack's width is the same
    /// either way (its leading and trailing edges are pinned), so the choice
    /// cannot flip back and forth.
    private func updateArrangement() {
        guard !valueLabel.isHidden, textStack.bounds.width > 0 else {
            arrange(sideBySide: true)
            return
        }
        func lineWidth(_ label: UILabel) -> CGFloat {
            ((label.text ?? "") as NSString).size(withAttributes: [.font: label.font as Any]).width
        }
        let needed = lineWidth(titleLabel) + Self.textSpacing + lineWidth(valueLabel)
        arrange(sideBySide: needed <= textStack.bounds.width)
    }

    private func arrange(sideBySide: Bool, force: Bool = false) {
        guard force || sideBySide != isSideBySide else { return }
        isSideBySide = sideBySide
        textStack.axis = sideBySide ? .horizontal : .vertical
        textStack.alignment = sideBySide ? .center : .leading
        textStack.spacing = sideBySide ? Self.textSpacing : Self.stackedSpacing
        valueLabel.textAlignment = sideBySide ? .right : .natural
        valueLabel.numberOfLines = sideBySide ? 1 : 0
        // A stacked value wraps, so it gives way before the title does.
        valueLabel.setContentCompressionResistancePriority(sideBySide ? .required : .defaultLow, for: .horizontal)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let before = isSideBySide
        updateArrangement()
        if before != isSideBySide { super.layoutSubviews() }
    }

    /// The row is laid out at the width it will have before its height is
    /// measured, so the choice between beside and under uses the real width.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if bounds.width != layoutAttributes.size.width {
            bounds.size.width = layoutAttributes.size.width
        }
        layoutIfNeeded()
        updateArrangement()
        layoutIfNeeded()
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
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
    private var tapAction: UIAction?

    /// The row's tap, replacing the one a reused cell had; `nil` clears it.
    func setTapAction(_ handler: (() -> Void)?) {
        if let tapAction {
            removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        guard let handler else { return }
        let action = UIAction { _ in handler() }
        tapAction = action
        addAction(action, for: .touchUpInside)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            onHighlight?(isHighlighted)
        }
    }
}

/// A choice row: the title in the theme's title color and the current choice
/// (in the accent color, with the up/down mark a pop-up button shows), and the
/// whole row one button whose menu lists the choices with a checkmark on the
/// current one. Like `SettingsIndexRowCell`, the labels paint the row and the
/// button is its one accessible element, so a tap, a VoiceOver activation, and
/// `app.buttons[id]` all open the menu. At accessibility text sizes the choice
/// stacks under the title instead of sharing its line.
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

    /// A disabled row keeps its current choice visible and cannot open its menu.
    func configure(
        title: String,
        identifier: String,
        isEnabled: Bool = true,
        options: [(title: String, selected: Bool, action: () -> Void)]
    ) {
        configure(
            title: title,
            identifier: identifier,
            isEnabled: isEnabled,
            value: options.first(where: \.selected)?.title,
            menu: UIMenu(children: options.map { option in
                UIAction(title: option.title, state: option.selected ? .on : .off) { _ in option.action() }
            })
        )
    }

    /// The same row with a menu the caller built (grouped choices) and the
    /// text the row shows for the current one.
    func configure(
        title: String,
        identifier: String,
        isEnabled: Bool = true,
        value current: String?,
        menu: UIMenu
    ) {
        let style = SettingsStyle.current
        titleLabel.text = title
        titleLabel.textColor = style.title
        valueLabel.text = current
        valueLabel.textColor = style.accent
        chevron.tintColor = style.accent
        for view in [titleLabel, valueLabel, chevron] { view.alpha = isEnabled ? 1 : 0.4 }
        button.isEnabled = isEnabled
        button.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = current
        button.menu = menu
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
