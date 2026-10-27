import UIKit

/// The selected-server row of a server-global catalog list (Extensions): the
/// server's badge in its connection state's tint, its name, and the state word
/// under it. One paired server is passive; with several, the whole row is one
/// button that opens the switcher menu (`menu`), which the owner builds each
/// time it opens so it lists current states. The button is the row's only
/// accessibility element.
final class ServerCatalogServerRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let badge = SettingsServerBadgeView()
    private let nameLabel = UILabel()
    private let stateLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [badge, nameLabel, stateLabel, chevron, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        nameLabel.font = .scaled(.body, .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .scaled(.caption1)
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.numberOfLines = 0
        chevron.image = .scaledSymbol("chevron.up.chevron.down", style: .caption1, weight: .semibold)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        // The labels paint the row; the button above them is its one accessible element.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            stateLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            stateLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            chevron.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `menu` is nil for a single paired server: the row only reports it.
    func configure(
        server: PairedServer,
        state: ServerBadgeConnectionState,
        palette: ThemePalette,
        menu: UIMenu?
    ) {
        badge.apply(icon: server.resolvedBadgeIcon, tint: state.uiColor(ComposerThemeColors(palette: palette)))
        nameLabel.text = server.name
        nameLabel.textColor = UIColor(palette.fg)
        stateLabel.text = state.title
        stateLabel.textColor = UIColor(palette.comment)
        chevron.tintColor = UIColor(palette.comment)
        chevron.isHidden = menu == nil
        button.accessibilityLabel = "Current server: \(server.name)"
        button.accessibilityValue = state.title
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
            button.isUserInteractionEnabled = true
            button.accessibilityTraits = .button
            button.accessibilityIdentifier = "serverCatalog.server.menu"
        } else {
            button.menu = nil
            button.showsMenuAsPrimaryAction = false
            button.isUserInteractionEnabled = false
            button.accessibilityTraits = .staticText
            button.accessibilityIdentifier = "serverCatalog.server.passive"
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.menu = nil
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        nameLabel.text = nil
        stateLabel.text = nil
        isHighlighted = false
    }
}

/// A catalog list's loading, empty, and failed states, drawn in the list on
/// the page's own surface (a `ContentUnavailableView` in a list row). A
/// failed state may carry a Retry button.
final class ServerCatalogStateCell: UICollectionViewListCell {
    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var retryAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        titleLabel.font = .scaled(.title3, .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        detailLabel.font = .scaled(.subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        for view in [spinner, imageView, titleLabel, detailLabel, retryButton] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(16, after: detailLabel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
        backgroundConfiguration = .clear()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A spinner with its caption.
    func configureLoading(_ text: String, palette: ThemePalette) {
        reset()
        spinner.isHidden = false
        spinner.startAnimating()
        spinner.color = UIColor(palette.comment)
        titleLabel.font = .scaled(.body)
        titleLabel.text = text
        titleLabel.textColor = UIColor(palette.comment)
        accessibilityLabel = text
    }

    func configureMessage(
        systemImage: String,
        title: String,
        detail: String,
        palette: ThemePalette,
        retry: (identifier: String, action: () -> Void)? = nil
    ) {
        reset()
        imageView.isHidden = false
        imageView.image = UIImage(systemName: systemImage)
        imageView.tintColor = UIColor(palette.comment)
        titleLabel.font = .scaled(.title3, .semibold)
        titleLabel.text = title
        titleLabel.textColor = UIColor(palette.fg)
        detailLabel.isHidden = false
        detailLabel.text = detail
        detailLabel.textColor = UIColor(palette.comment)
        accessibilityLabel = "\(title), \(detail)"
        if let retry {
            var configuration = UIButton.Configuration.borderedProminent()
            configuration.title = "Retry"
            retryButton.configuration = configuration
            retryButton.isHidden = false
            retryButton.accessibilityIdentifier = retry.identifier
            let action = UIAction { _ in retry.action() }
            retryAction = action
            retryButton.addAction(action, for: .touchUpInside)
            // The message reads, then the button is its own element.
            accessibilityElements = [titleLabel, detailLabel, retryButton]
            isAccessibilityElement = false
        }
    }

    private func reset() {
        spinner.stopAnimating()
        spinner.isHidden = true
        imageView.isHidden = true
        detailLabel.isHidden = true
        retryButton.isHidden = true
        if let retryAction { retryButton.removeAction(retryAction, for: .touchUpInside) }
        retryAction = nil
        retryButton.accessibilityIdentifier = nil
        accessibilityElements = nil
        isAccessibilityElement = true
        accessibilityLabel = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reset()
    }
}
