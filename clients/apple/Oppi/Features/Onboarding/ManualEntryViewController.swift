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
final class ManualEntryViewController: ListScreenController<ManualEntryViewController.Section, ManualEntryViewController.Item> {
    enum Section: Hashable, Sendable { case link }
    enum Item: Hashable, Sendable { case link, invalidLink }

    private let deviceModel: String
    private let onConnect: (ManualEntryViewController, ServerCredentials) -> Void
    private var linkText = ""
    private var connectItem: UIBarButtonItem?

    init(
        deviceModel: String,
        onConnect: @escaping (ManualEntryViewController, ServerCredentials) -> Void
    ) {
        self.deviceModel = deviceModel
        self.onConnect = onConnect
        super.init(
            title: String(localized: "Connect Manually"),
            listIdentifier: "onboarding.manual.list",
            headers: true,
            footers: true,
            dismissesKeyboardOnDrag: true
        )
    }

    /// Only a signed code can pair (`InviteBootstrapService` refuses the rest),
    /// so an unsigned one is flagged here instead of after Connect.
    private var credentials: ServerCredentials? {
        ManualPairingEntry.credentials(fromPasted: linkText)
            .flatMap { $0.normalizedServerFingerprint == nil ? nil : $0 }
    }

    /// Why the pasted text cannot pair, or nil while it is empty or usable.
    private var linkProblem: String? {
        guard !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, credentials == nil else {
            return nil
        }
        return ManualPairingEntry.credentials(fromPasted: linkText) == nil
            ? String(localized: "This is not an Oppi pairing link.")
            : OnboardingPairingFailure.message(for: .unsigned)
    }

    private var linkIsInvalid: Bool { linkProblem != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        connectItem = connect
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(
                .link,
                header: String(localized: "Pairing Link"),
                footer: footerText,
                items: linkIsInvalid ? [.link, .invalidLink] : [.link]
            ),
        ]
    }

    /// The field is keyed by what it draws — nothing — so a pass that adds the
    /// notice, rewrites it, or repaints the theme leaves the field alone: it
    /// keeps focus, text, and selection. The notice is keyed by its words, so it
    /// rewrites while it stays (not a link, then unsigned).
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .link: AnyHashable(0)
        case .invalidLink: AnyHashable(linkProblem)
        }
    }

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
        self?.configureLinkField(cell)
    }

    override func prepareRegistrations() {
        _ = fieldRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .link: collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .invalidLink: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .link:
            break
        case .invalidLink:
            var content = content(.plain)
            content.text = linkProblem
            content.textProperties.color = ThemeRuntimeState.currentThemeID().palette.ui.red
            content.textProperties.font = .scaled(.footnote)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "onboarding.manual.invalidLink"
        }
    }

    override func updateProperties() {
        super.updateProperties()
        connectItem?.isEnabled = credentials != nil
    }

    private var footerText: String {
        String(localized: "Run oppi pair on your computer and paste what it prints: the oppi://connect link, or the whole output of oppi pair --json. A link works once and expires after 90 seconds unless you set --ttl.\n\nAway from the computer’s network, this \(deviceModel) reaches it only through Tailscale or a public HTTPS address.")
    }

    private func configureLinkField(_ cell: SSHTerminalTextFieldCell) {
        cell.configure(
            text: linkText,
            placeholder: "oppi://connect?…",
            identifier: "onboarding.manual.link",
            keyboard: .URL,
            textColor: SettingsStyle.current.title,
            returnKey: .go,
            onReturn: { [weak self] in self?.connect() }
        ) { [weak self] in
            self?.linkText = $0
            self?.setNeedsUpdateProperties()
        }
        cell.textField.accessibilityLabel = String(localized: "Pairing Link")
    }

    private func connect() {
        guard let credentials else { return }
        view.endEditing(true)
        onConnect(self, credentials)
    }
}
