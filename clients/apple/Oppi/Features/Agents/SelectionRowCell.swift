import UIKit

/// A row that picks or unpicks one thing in a settings list: a title, optional
/// lines under it, and a mark that says whether it is chosen. The whole row is
/// one button, so a tap, a VoiceOver activation, and `app.buttons[id]` all run
/// the row's action. Like the kit's index and menu rows, its own labels paint
/// the row and the overlay `SettingsRowButton` is its one accessible element;
/// a chosen row carries the selected trait and says so in its value.
///
/// Used by the Agent editor's selection pages (tools, Skills, Extensions,
/// workspaces) and the schedule time zone list.
final class SelectionRowCell: UICollectionViewListCell {
    /// Where the row's mark sits.
    enum Mark {
        /// A circle at the leading edge, filled with a check when chosen: for
        /// a set of things any number of which can be chosen.
        case circle
        /// A check at the trailing edge, shown only when chosen: for one
        /// choice out of a list.
        case trailingCheck
    }

    private let button = SettingsRowButton(type: .system)
    private let leadingMark = UIImageView()
    private let trailingMark = UIImageView(image: UIImage(systemName: "checkmark"))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let textStack = UIStackView()
    private var textAfterMark: NSLayoutConstraint?
    private var textAtMargin: NSLayoutConstraint?
    private var textBeforeCheck: NSLayoutConstraint?
    private var textAtTrailingMargin: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        for label in [titleLabel, subtitleLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            textStack.addArrangedSubview(label)
        }
        textStack.axis = .vertical
        textStack.spacing = 3
        // A symbol with a text style follows Dynamic Type on its own.
        leadingMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        leadingMark.setContentHuggingPriority(.required, for: .horizontal)
        leadingMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        trailingMark.setContentHuggingPriority(.required, for: .horizontal)
        trailingMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [leadingMark, textStack, trailingMark, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own, as in `SettingsIndexRowCell`.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        let afterMark = textStack.leadingAnchor.constraint(equalTo: leadingMark.trailingAnchor, constant: 12)
        let atMargin = textStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        let beforeCheck = textStack.trailingAnchor.constraint(equalTo: trailingMark.leadingAnchor, constant: -8)
        let atTrailing = textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor)
        textAfterMark = afterMark
        textAtMargin = atMargin
        textBeforeCheck = beforeCheck
        textAtTrailingMargin = atTrailing
        NSLayoutConstraint.activate([
            afterMark,
            leadingMark.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            leadingMark.topAnchor.constraint(equalTo: textStack.topAnchor),
            trailingMark.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            trailingMark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            atTrailing,
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
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

    /// - Parameters:
    ///   - subtitle: a line under the title in the value color (a tool's
    ///     description, a workspace's runtime).
    ///   - subtitleIsWarning: draws `subtitle` in the warning color.
    ///   - status: a line in the warning color under the rest (a load error, "Unavailable").
    ///   - isEnabled: a row that is not chosen and cannot be, which reads dimmed.
    ///   - value: what VoiceOver says after the title; the chosen state and any status.
    ///   - hint: the description VoiceOver reads after the value.
    func configure(
        title: String,
        subtitle: String? = nil,
        subtitleIsWarning: Bool = false,
        status: String? = nil,
        mark: Mark = .circle,
        isChosen: Bool,
        isEnabled: Bool = true,
        value: String? = nil,
        hint: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        titleLabel.text = title
        titleLabel.textColor = style.title
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = subtitleIsWarning ? style.warning : style.value
        subtitleLabel.isHidden = subtitle?.isEmpty != false
        statusLabel.text = status
        statusLabel.textColor = style.warning
        statusLabel.isHidden = status == nil
        switch mark {
        case .circle:
            leadingMark.isHidden = false
            leadingMark.image = UIImage(systemName: isChosen ? "checkmark.circle.fill" : "circle")
            leadingMark.tintColor = isChosen ? style.accent : style.value
            trailingMark.isHidden = true
            textAtMargin?.isActive = false
            textBeforeCheck?.isActive = false
            textAfterMark?.isActive = true
            textAtTrailingMargin?.isActive = true
        case .trailingCheck:
            leadingMark.isHidden = true
            trailingMark.isHidden = !isChosen
            trailingMark.tintColor = style.accent
            textAfterMark?.isActive = false
            textAtTrailingMargin?.isActive = false
            textAtMargin?.isActive = true
            textBeforeCheck?.isActive = true
        }
        contentView.alpha = isEnabled ? 1 : 0.4
        button.isEnabled = isEnabled
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = value
        button.accessibilityHint = hint?.isEmpty == false ? hint : nil
        var traits: UIAccessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        if isChosen { traits.insert(.selected) }
        button.accessibilityTraits = traits
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        button.accessibilityHint = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        statusLabel.text = nil
        isHighlighted = false
    }
}
