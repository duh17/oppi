import UIKit

/// The Emoji or Genmoji chooser: the current custom choice drawn at the left
/// with what it is, or the prompt. The whole row is one button that opens the
/// keyboard on the picker's hidden glyph input.
final class IconPickerChooserCell: UICollectionViewListCell {
    enum Preview {
        case none
        case choice(IconChoice)
        case genmoji(UIImage?)
        case importedImage(Data)
    }

    private let button = SettingsRowButton(type: .system)
    /// The preview is one of the two places an animated image plays.
    private let iconView = IconChoiceUIView(size: 28, frameSize: 36, animatesImage: true)
    private let imageView = UIImageView()
    private let promptView = UIImageView(image: UIImage(systemName: "face.smiling"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let leading = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [iconView, imageView, promptView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            ])
        }
        imageView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28),
        ])
        // The icon slot is 36 pt at every text size, so the prompt's symbol does not scale out of it.
        promptView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22)
        leading.setContentHuggingPriority(.required, for: .horizontal)
        leading.setContentCompressionResistancePriority(.required, for: .horizontal)
        leading.widthAnchor.constraint(equalToConstant: 36).isActive = true
        leading.heightAnchor.constraint(equalToConstant: 36).isActive = true

        titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        for label in [titleLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [leading, text, chevron])
        row.spacing = 12
        row.alignment = .center
        for view in [row, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        button.accessibilityTraits = .button
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

    func configure(
        choice: IconPickerCustomChoice?,
        preview: Preview,
        purpose: IconChoiceUIView.Content.Purpose,
        assetCache: IconAssetCache?,
        isEnabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        iconView.isHidden = true
        imageView.isHidden = true
        promptView.isHidden = true
        switch preview {
        case .none:
            // A hidden icon view would keep playing an image it showed before.
            iconView.clear()
            promptView.isHidden = false
            promptView.tintColor = style.accent
        case .choice(let value):
            iconView.isHidden = false
            iconView.apply(
                .choice(value, purpose: purpose, sandbox: false),
                assetCache: assetCache
            )
        case .genmoji(let image):
            iconView.clear()
            imageView.isHidden = false
            imageView.image = image
        case .importedImage(let data):
            iconView.isHidden = false
            iconView.apply(.importedImage(data))
        }
        titleLabel.text = "Choose Emoji or Genmoji"
        titleLabel.textColor = style.title
        detailLabel.text = choice?.accessibilityDescription
        detailLabel.textColor = style.value
        detailLabel.isHidden = choice == nil
        chevron.tintColor = style.value
        contentView.alpha = isEnabled ? 1 : 0.4
        button.isEnabled = isEnabled
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = "Choose Emoji or Genmoji"
        button.accessibilityValue = choice?.accessibilityDescription ?? "No custom choice selected"
        button.accessibilityHint = "Opens the current keyboard"
        button.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        imageView.image = nil
        isHighlighted = false
    }
}
