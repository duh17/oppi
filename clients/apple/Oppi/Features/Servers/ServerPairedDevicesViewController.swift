import UIKit

/// Devices paired with this server, with Revoke for every device but this one.
///
/// The page is pinned to the server and `ServerSettingsModel` it was made with
/// (Server Settings pushes it and tracks it, so a server switch closes it), so a
/// Revoke can only reach a device of that server. Revoke asks first (an action
/// sheet naming the device), then App Lock, then the model sends the DELETE for
/// the device the person chose, never for whichever row is shown by then. A row
/// offers Revoke as a swipe and as a visible button with the same owner; this
/// device's row offers none.
@MainActor
final class ServerPairedDevicesViewController: ListScreenController<ServerPairedDevicesViewController.Section, ServerPairedDevicesViewController.Item> {
    enum Section: Hashable, Sendable { case devices }

    enum Item: Hashable, Sendable {
        case loading, empty
        case device(String)
        case error, failed
    }

    let server: PairedServer
    let model: ServerSettingsModel
    private let root: AppRootEnvironment

    init(model: ServerSettingsModel, server: PairedServer, root: AppRootEnvironment) {
        self.model = model
        self.server = server
        self.root = root
        super.init(
            title: String(localized: "Paired Devices"),
            listIdentifier: "server.pairedDevices.list",
            scope: .server(server.name),
            headers: true,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    private var state: ServerDetailPairedDevicesState {
        let current = coordinator.serverStore.server(for: server.id) ?? server
        return model.pairedDevicesState(currentDeviceId: current.deviceCredential?.deviceId)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task {
                await self?.model.reloadPairedDevices()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
    }

    // MARK: - Sections

    override func sections() -> [ListSection<Section, Item>] {
        var items: [Item] = []
        switch state {
        case .loading:
            items = [.loading]
        case .loaded(let rows, let error):
            items = rows.isEmpty ? [.empty] : rows.map { .device($0.id) }
            if error != nil { items.append(.error) }
        case .failed:
            items = [.failed]
        }
        return [ListSection(
            .devices,
            footer: String(localized: "Every paired device can see this list. Revoking disconnects that device immediately."),
            items: items
        )]
    }

    private func row(_ id: String) -> PairedDeviceRoster.Row? {
        guard case .loaded(let rows, _) = state else { return nil }
        return rows.first { $0.id == id }
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .loading, .empty:
            return AnyHashable(0)
        case .device(let id):
            guard let row = row(id) else { return AnyHashable(0) }
            return AnyHashable([row.title, row.caption, String(row.isThisDevice), String(row.canRevoke), String(model.isRevokingDevice)])
        case .error:
            if case .loaded(_, let error?) = state { return AnyHashable(error) }
            return AnyHashable("")
        case .failed:
            if case .failed(let message) = state { return AnyHashable(message) }
            return AnyHashable("")
        }
    }

    // MARK: - Cells

    private lazy var deviceRow = UICollectionView.CellRegistration<ServerPairedDeviceCell, Item> { [weak self] cell, _, item in
        guard let self, case .device(let id) = item, let row = row(id) else { return }
        cell.configure(row, isRevoking: model.isRevokingDevice) { [weak self, weak cell] in
            self?.confirmRevoke(row, from: cell)
        }
    }

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .loading:
            cell.configure(.loading(String(localized: "Loading devices…")), identifier: "server.pairedDevices.loading")
        case .empty:
            cell.configure(.message(String(localized: "No paired devices")), identifier: "server.pairedDevices.empty")
        case .error:
            guard case .loaded(_, let error?) = state else { return }
            let model = self.model
            cell.configure(
                .failure(
                    title: String(localized: "Couldn't Load Devices"),
                    reason: error,
                    retry: { [model] in Task { await model.reloadPairedDevices() } }
                ),
                identifier: "server.pairedDevices.error"
            )
        case .failed:
            guard case .failed(let message) = state else { return }
            let model = self.model
            cell.configure(
                .failure(title: String(localized: "Couldn't Load Devices"), reason: message) { [model] in
                    Task { await model.reloadPairedDevices() }
                },
                identifier: "server.pairedDevices.error"
            )
        case .device:
            break
        }
    }

    override func prepareRegistrations() {
        _ = (deviceRow, stateRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .device: collectionView.dequeueConfiguredReusableCell(using: deviceRow, for: indexPath, item: item)
        case .loading, .empty, .error, .failed: collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        }
    }

    // MARK: - Revoke

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .device(let id) = item, let row = row(id), row.canRevoke, !model.isRevokingDevice else { return nil }
        let revoke = UIContextualAction(style: .destructive, title: String(localized: "Revoke")) { [weak self] _, _, done in
            guard let self else { return done(false) }
            // The sheet asks; nothing is revoked until it is confirmed.
            confirmRevoke(row, from: indexPath(for: item).flatMap { collectionView.cellForItem(at: $0) })
            done(false)
        }
        revoke.accessibilityLabel = String(localized: "Revoke \(row.title)")
        let configuration = UISwipeActionsConfiguration(actions: [revoke])
        // A destructive action never runs on a full swipe: it only asks.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    /// What asks before a device loses access.
    static func revocation(for row: PairedDeviceRoster.Row) -> Confirmation {
        Confirmation(
            title: row.title.isEmpty ? String(localized: "Revoke this device?") : String(localized: "Revoke \(row.title)?"),
            message: String(localized: "\(row.title.isEmpty ? String(localized: "That device") : row.title) will lose access immediately. Pair it again to restore access."),
            actionTitle: String(localized: "Revoke")
        )
    }

    /// Asks before revoking `row`, as a popover from `source` on iPad.
    func confirmRevoke(_ row: PairedDeviceRoster.Row, from source: UIView?) {
        guard row.canRevoke, !model.isRevokingDevice else { return }
        Self.revocation(for: row).present(from: self, anchor: source) { [weak self] in
            Task { await self?.revoke(row) }
        }
    }

    /// Revokes the device the person confirmed, after App Lock, on this page's server.
    func revoke(_ row: PairedDeviceRoster.Row) async {
        guard await AppLockService.shared.authorizeProtectedAction(
            reason: String(localized: "Revoke \(row.title)")
        ) else { return }
        await model.revokeDevice(row)
    }
}

// MARK: - Device cell

/// One paired device: its name and a caption (how it paired, when it enrolled), and
/// Revoke for a device that is not this one. The text is one accessibility element
/// (the name is its label, the caption its value) and Revoke is another.
final class ServerPairedDeviceCell: UICollectionViewListCell {
    private let textBlock = UIView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let revokeButton = UIButton(type: .system)
    private var revokeAction: (() -> Void)?
    private var compactConstraints: [NSLayoutConstraint] = []
    private var accessibilityConstraints: [NSLayoutConstraint] = []
    /// A row with no Revoke: the text takes the whole row.
    private var textOnlyConstraints: [NSLayoutConstraint] = []
    private var layoutKey: String?
    private var offersRevoke = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [titleLabel, captionLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            textBlock.addSubview(label)
        }
        titleLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        textBlock.translatesAutoresizingMaskIntoConstraints = false
        textBlock.isAccessibilityElement = true
        textBlock.accessibilityTraits = .staticText
        revokeButton.translatesAutoresizingMaskIntoConstraints = false
        revokeButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        revokeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        revokeButton.titleLabel?.numberOfLines = 0
        revokeButton.contentHorizontalAlignment = .trailing
        revokeButton.setContentHuggingPriority(.required, for: .horizontal)
        revokeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        revokeButton.addAction(UIAction { [weak self] _ in self?.revokeAction?() }, for: .touchUpInside)
        contentView.addSubview(textBlock)
        contentView.addSubview(revokeButton)
        accessibilityElements = [textBlock, revokeButton]

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: textBlock.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: textBlock.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: textBlock.trailingAnchor),
            captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            captionLabel.leadingAnchor.constraint(equalTo: textBlock.leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: textBlock.trailingAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: textBlock.bottomAnchor),
            textBlock.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // Beside the text on a normal size; under it at an accessibility size, where
        // the text would otherwise be squeezed into a sliver.
        compactConstraints = [
            textBlock.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textBlock.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            revokeButton.leadingAnchor.constraint(equalTo: textBlock.trailingAnchor, constant: 8),
            revokeButton.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            revokeButton.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ]
        accessibilityConstraints = [
            textBlock.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textBlock.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            revokeButton.topAnchor.constraint(equalTo: textBlock.bottomAnchor, constant: 4),
            revokeButton.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            revokeButton.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            revokeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            revokeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ]
        textOnlyConstraints = [
            textBlock.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textBlock.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            textBlock.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ]
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: Self, _) in
            cell.updateLayoutMode()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateLayoutMode() {
        let accessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let key = !offersRevoke ? "text" : accessibility ? "accessibility" : "compact"
        guard key != layoutKey else { return }
        layoutKey = key
        NSLayoutConstraint.deactivate(compactConstraints + accessibilityConstraints + textOnlyConstraints)
        NSLayoutConstraint.activate(key == "text" ? textOnlyConstraints : accessibility ? accessibilityConstraints : compactConstraints)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func configure(_ row: PairedDeviceRoster.Row, isRevoking: Bool, revoke: @escaping () -> Void) {
        let style = SettingsStyle.current
        titleLabel.text = row.title
        titleLabel.textColor = style.title
        captionLabel.text = row.caption
        captionLabel.textColor = style.value
        textBlock.accessibilityIdentifier = row.isThisDevice
            ? "server.pairedDevices.thisDevice"
            : "server.pairedDevices.row.\(row.id)"
        textBlock.accessibilityLabel = row.title
        textBlock.accessibilityValue = row.caption
        revokeButton.isHidden = !row.canRevoke
        revokeButton.setTitle(String(localized: "Revoke"), for: .normal)
        revokeButton.setTitleColor(style.destructive, for: .normal)
        revokeButton.setTitleColor(style.destructive.withAlphaComponent(0.4), for: .disabled)
        revokeButton.isEnabled = !isRevoking
        // This device has no Revoke: no control, and no identifier for one.
        revokeButton.accessibilityIdentifier = row.canRevoke ? "server.pairedDevices.revoke.\(row.id)" : nil
        revokeButton.accessibilityLabel = String(localized: "Revoke \(row.title)")
        revokeAction = revoke
        offersRevoke = row.canRevoke
        accessibilityElements = row.canRevoke ? [textBlock, revokeButton] : [textBlock]
        updateLayoutMode()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        revokeAction = nil
        textBlock.accessibilityIdentifier = nil
        textBlock.accessibilityLabel = nil
        textBlock.accessibilityValue = nil
        revokeButton.accessibilityIdentifier = nil
        revokeButton.accessibilityLabel = nil
    }
}
