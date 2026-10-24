import UIKit

/// What manual entry accepts: everything `oppi pair` prints.
enum ManualPairingEntry {
    /// A pasted pairing link (`oppi://connect…`), a QR payload, or the whole
    /// `oppi pair --json` output, whose `inviteURL` is the link.
    static func credentials(fromPasted text: String) -> ServerCredentials? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let credentials = ServerCredentials.decodeInviteURLString(trimmed)
            ?? ServerCredentials.decodeInvitePayload(trimmed) {
            return credentials
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = object["inviteURL"] as? String else { return nil }
        return ServerCredentials.decodeInviteURLString(link)
    }
}

/// Pairs from what `oppi pair` printed, pasted into one field. The pairing
/// link carries the server's signed identity and its certificate pin.
/// Presented in a navigation sheet; Connect hands the credentials back.
@MainActor
final class ManualEntryViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case link }
    private enum Item: Hashable { case link, invalidLink }

    private let root: AppRootEnvironment
    private let deviceModel: String
    private let onConnect: (ManualEntryViewController, ServerCredentials) -> Void
    private var linkText = ""

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var lastThemeID: ThemeID?

    init(
        root: AppRootEnvironment,
        deviceModel: String,
        onConnect: @escaping (ManualEntryViewController, ServerCredentials) -> Void
    ) {
        self.root = root
        self.deviceModel = deviceModel
        self.onConnect = onConnect
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = .supplementary
        list.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list)
        )
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Connect Manually")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.finish(self)
            }
        )
        let connect = UIBarButtonItem(
            title: String(localized: "Connect"),
            primaryAction: UIAction { [weak self] _ in self?.connect() }
        )
        connect.style = .prominent
        connect.accessibilityIdentifier = "onboarding.manual.connect"
        navigationItem.rightBarButtonItem = connect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var credentials: ServerCredentials? {
        ManualPairingEntry.credentials(fromPasted: linkText)
    }

    private var linkIsInvalid: Bool {
        !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && credentials == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        applySnapshot()
        updateConnectItem()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme changes.
        let themeID = root.themeStore.activeThemeID
        guard lastThemeID != themeID else { return }
        lastThemeID = themeID
        SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        if var snapshot = dataSource?.snapshot() {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource?.apply(snapshot, animatingDifferences: false)
        }
    }

    private func installDataSource() {
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
            self?.configureLinkField(cell)
        }
        let notice = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "This is not an Oppi pairing link.")
            content.textProperties.color = UIColor(root.themeStore.activeThemeID.palette.red)
            content.textProperties.font = .scaled(.footnote)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "onboarding.manual.invalidLink"
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { cell, _, _ in
            var content = UIListContentConfiguration.header()
            content.text = String(localized: "Pairing Link")
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .link:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            case .invalidLink:
                collectionView.dequeueConfiguredReusableCell(using: notice, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private var footerText: String {
        String(localized: "Run oppi pair on your computer and paste what it prints: the oppi://connect link, or the whole output of oppi pair --json. A link works once and expires after 90 seconds unless you set --ttl.\n\nAway from the computer’s network, this \(deviceModel) reaches it only through Tailscale or a public HTTPS address.")
    }

    private func configureLinkField(_ cell: SSHTerminalTextFieldCell) {
        let palette = root.themeStore.activeThemeID.palette
        cell.configure(
            text: linkText,
            placeholder: "oppi://connect?…",
            identifier: "onboarding.manual.link",
            keyboard: .URL,
            textColor: UIColor(palette.fg),
            returnKey: .go,
            onReturn: { [weak self] in self?.connect() }
        ) { [weak self] in
            self?.linkText = $0
            self?.inputChanged()
        }
        cell.textField.accessibilityLabel = String(localized: "Pairing Link")
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.link])
        snapshot.appendItems(linkIsInvalid ? [.link, .invalidLink] : [.link], toSection: .link)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    /// Typing never reconfigures the field, so it keeps focus and selection.
    private func inputChanged() {
        if dataSource?.snapshot().itemIdentifiers.contains(.invalidLink) != linkIsInvalid {
            applySnapshot()
        }
        updateConnectItem()
    }

    private func updateConnectItem() {
        navigationItem.rightBarButtonItem?.isEnabled = credentials != nil
    }

    private func connect() {
        guard let credentials else { return }
        view.endEditing(true)
        onConnect(self, credentials)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }
}
