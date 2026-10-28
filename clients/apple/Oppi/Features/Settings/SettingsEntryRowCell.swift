import UIKit

/// An entry in a list the person edits: an optional accent symbol, a title, and
/// a caption under it (the entry's text, or why it is excluded). The whole row
/// is one button that opens the entry's editor, with no chevron because the
/// editor is a sheet or a field on the same page. Like `SettingsIndexRowCell`,
/// the labels paint the row and the button above them is its one accessible
/// element, so a tap, a VoiceOver activation, and `app.buttons[id]` all run the
/// row's action. The page adds delete or reorder accessories itself.
final class SettingsEntryRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let iconView = UIImageView()
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private var stackAfterIcon: NSLayoutConstraint?
    private var stackAtMargin: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(captionLabel)
        for view in [iconView, textStack, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.numberOfLines = 0
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        let afterIcon = textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12)
        stackAfterIcon = afterIcon
        stackAtMargin = textStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            afterIcon,
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameters:
    ///   - caption: the line under the title; `isWarning` draws it in the
    ///     warning color (an entry that will not be used).
    func configure(
        title: String,
        caption: String?,
        isWarning: Bool = false,
        systemImage: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        titleLabel.text = title
        titleLabel.textColor = style.title
        captionLabel.text = caption
        captionLabel.textColor = isWarning ? style.warning : style.value
        captionLabel.isHidden = caption == nil
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        iconView.isHidden = systemImage == nil
        iconView.tintColor = style.accent
        stackAfterIcon?.isActive = systemImage != nil
        stackAtMargin?.isActive = systemImage == nil
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = caption
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        iconView.image = nil
        titleLabel.text = nil
        captionLabel.text = nil
        accessories = []
        isHighlighted = false
    }
}
