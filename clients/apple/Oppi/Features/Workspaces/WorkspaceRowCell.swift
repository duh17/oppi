import UIKit

/// A workspace as a settings row: its icon (with the sandbox mark), name and
/// lock badge, an optional description, its folder, and an optional line naming
/// the server. The whole row is one button, so a tap, a VoiceOver activation,
/// and `app.buttons[id]` all run its action. Workspace Settings shows it as the
/// summary that opens Details; the server's workspace list shows one per
/// workspace.
///
/// The labels paint the row; the button above them is its one accessible
/// element, so the row reads as a single control. The text lines stack, so at
/// large text sizes each wraps and the row grows; the icon keeps its size.
final class WorkspaceRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let icon = IconChoiceUIView(size: 24, frameSize: 36)
    private let nameLabel = UILabel()
    private let lockLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let folderLabel = UILabel()
    private let serverLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, lockLabel])
        nameRow.spacing = 5
        nameRow.alignment = .center
        let text = UIStackView(arrangedSubviews: [nameRow, descriptionLabel, folderLabel, serverLabel])
        text.axis = .vertical
        text.spacing = 2
        for view in [icon, text, button] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        accessories = [.disclosureIndicator()]
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 0
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lockLabel.setContentHuggingPriority(.required, for: .horizontal)
        lockLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        descriptionLabel.font = .preferredFont(forTextStyle: .footnote)
        descriptionLabel.numberOfLines = 0
        // A folder path has no spaces to wrap at, so it wraps by character: at a
        // large text size it takes more lines instead of being cut off.
        folderLabel.font = .preferredFont(forTextStyle: .footnote)
        folderLabel.numberOfLines = 0
        folderLabel.lineBreakMode = .byCharWrapping
        serverLabel.font = .preferredFont(forTextStyle: .footnote)
        serverLabel.numberOfLines = 0
        for label in [nameLabel, descriptionLabel, folderLabel, serverLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // The separator starts where the name does, past the icon.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: text.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameters:
    ///   - description: shown under the name; `nil` leaves the line out.
    ///   - server: the server's name, under the folder; `nil` leaves it out.
    ///   - customActions: what a swipe does, for VoiceOver's actions rotor.
    func configure(
        workspace: Workspace,
        description: String? = nil,
        folder: String,
        server: String? = nil,
        lock: ScopedLockState,
        colors: ComposerThemeColors,
        assetCache: IconAssetCache?,
        identifier: String,
        customActions: [UIAccessibilityCustomAction] = [],
        action: @escaping () -> Void
    ) {
        icon.apply(
            .choice(workspace.icon, purpose: .workspace, sandbox: workspace.runtime == .sandbox),
            colors: colors,
            assetCache: assetCache
        )
        nameLabel.text = workspace.name
        nameLabel.textColor = colors.fg
        descriptionLabel.text = description
        descriptionLabel.isHidden = description == nil
        descriptionLabel.textColor = colors.comment
        folderLabel.text = folder
        folderLabel.textColor = colors.comment
        serverLabel.text = server
        serverLabel.isHidden = server == nil
        serverLabel.textColor = colors.comment
        SessionRowText.setLockBadge(lock, on: lockLabel, color: colors.comment, key: workspace.id)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = workspace.name
        button.accessibilityValue = ([description, folder, server, lock.accessibilityWord] as [String?])
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        button.accessibilityCustomActions = customActions
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        button.accessibilityCustomActions = nil
        nameLabel.text = nil
        descriptionLabel.text = nil
        folderLabel.text = nil
        serverLabel.text = nil
        lockLabel.attributedText = nil
        isHighlighted = false
    }
}

extension ScopedLockState {
    /// The state as a row's accessibility value; empty without a lock.
    var accessibilityWord: String {
        switch self {
        case .none: ""
        case .locked: String(localized: "Locked")
        case .unlocked: String(localized: "Unlocked")
        }
    }
}
