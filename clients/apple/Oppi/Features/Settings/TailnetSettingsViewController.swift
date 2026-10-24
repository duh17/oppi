import UIKit

/// Connect Oppi's embedded Tailscale node, list online tailnet machines, and
/// open Set Up a Machine for one that is not running Oppi yet.
///
/// Each online machine that can host Oppi is probed for Oppi's `/health`
/// while the screen is visible. A visit starts the probes over, so a result
/// never outlives the visit that produced it; there is no polling timer.
final class TailnetSettingsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case status, peers, setup, disconnect }

    private enum Item: Hashable {
        case status, thisDevice
        case connect, starting, signIn, waitingForLink, tryAgain
        case noPeers, peer(String), pairingWait(String)
        case setUpMachine
        case disconnect
    }

    /// Re-runs the probes when the node starts or stops, the probed machines
    /// change, or a refresh was requested.
    private struct ProbeTrigger: Equatable {
        let isRunning: Bool
        let peers: [String]
        let refresh: Int
    }

    private let coordinator: ConnectionCoordinator
    /// Called after a machine is paired and selected. Onboarding uses this to
    /// leave setup; Settings leaves the list in place.
    private let onPaired: (() -> Void)?
    /// Set when this screen is the root of a sheet: its Cancel closes it.
    private let onClose: (() -> Void)?
    private var tailnet: TailnetNodeController { .shared }

    private var pairingPeerID: String? { didSet { setNeedsUpdateProperties() } }
    private var pairingMessage: String? { didSet { setNeedsUpdateProperties() } }
    private var pairingWaitExpiresAt: Int64? { didSet { setNeedsUpdateProperties() } }
    private var pairingTask: Task<Void, Never>?
    private var pairingGeneration: UInt64 = 0
    /// Latest Oppi probe per peer id; a missing entry means none has started.
    private var probes: [String: TailnetPeerProbe] = [:] { didSet { setNeedsUpdateProperties() } }
    private var probeRefresh = 0 { didSet { setNeedsUpdateProperties() } }
    private var probeTask: Task<Void, Never>?
    private var probeTrigger: ProbeTrigger?
    private var isVisible = false
    #if DEBUG
    /// Skips live health probes so a screenshot can show a settled row.
    private var previewProbes: [String: TailnetPeerProbe]?
    #endif

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?

    init(coordinator: ConnectionCoordinator, onPaired: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.onPaired = onPaired
        self.onClose = onClose
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Tailscale")
        navigationItem.largeTitleDisplayMode = .never
    }

    #if DEBUG
    convenience init(coordinator: ConnectionCoordinator, previewProbes: [String: TailnetPeerProbe]) {
        self.init(coordinator: coordinator)
        self.previewProbes = previewProbes
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "tailnet.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UIRefreshControl else { return }
            Task {
                await self.tailnet.refresh()
                self.reprobe()
                control.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        if onClose != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel,
                primaryAction: UIAction { [weak self] _ in self?.onClose?() }
            )
        }
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tailnet.startIfEnabled()
        isVisible = true
        // A new visit probes again.
        probeTrigger = nil
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        probeTask?.cancel()
        probeTask = nil
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Read the node and the paired servers here so a change redraws.
        _ = (tailnet.state, tailnet.snapshot, coordinator.serverStore.servers)
        startProbesIfNeeded()
        applySnapshot()
    }

    // MARK: - Machines

    /// Phones and tablets cannot run an Oppi server, so they are not listed.
    private var visiblePeers: [TailnetPeer] {
        tailnet.onlinePeers.filter(\.canHostOppi)
    }

    private func status(of peer: TailnetPeer) -> TailnetPeerStatus {
        TailnetPeerStatus.derive(peer: peer, pairedHosts: coordinator.serverStore.servers.map(\.host), probe: probes[peer.id])
    }

    /// Peers whose Oppi readiness is unknown. Paired machines need no probe.
    private var probeTargets: [TailnetPeer] {
        visiblePeers.filter { status(of: $0) != .paired }
    }

    private func startProbesIfNeeded() {
        guard isVisible else { return }
        let trigger = ProbeTrigger(
            isRunning: tailnet.state == .running,
            peers: probeTargets.map { "\($0.id)|\($0.dnsName)" },
            refresh: probeRefresh
        )
        guard trigger != probeTrigger else { return }
        probeTrigger = trigger
        probeTask?.cancel()
        #if DEBUG
        if let previewProbes {
            probes = previewProbes
            return
        }
        #endif
        probeTask = Task { [weak self] in await self?.probePeers() }
    }

    /// Probes every unpaired machine for Oppi, concurrently, once the node's
    /// SOCKS route is current. Leaving the screen or a new trigger cancels
    /// it, and cancelled probes never store a result.
    private func probePeers() async {
        guard tailnet.state == .running else {
            probes = [:]
            return
        }
        let targets = probeTargets
        guard !targets.isEmpty else { return }
        for peer in targets { probes[peer.id] = .inFlight }
        do {
            try await tailnet.waitUntilCurrentGenerationProxyReady()
        } catch {
            // A cancelled run leaves `.inFlight` for the next run to replace;
            // a proxy that never came up leaves the rows unchecked.
            if !Task.isCancelled {
                for peer in targets { probes[peer.id] = nil }
            }
            return
        }
        await TailnetSameUserPairing.probeOutcomes(dnsNames: targets.map(\.dnsName)) { [weak self] dnsName, outcome in
            guard let self, !Task.isCancelled else { return }
            for peer in targets where peer.dnsName == dnsName {
                probes[peer.id] = outcome
            }
        }
    }

    private func reprobe() {
        probes = [:]
        probeRefresh += 1
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        guard let dataSource else { return }
        let state = tailnet.state
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.status])
        var statusItems: [Item] = [.status]
        if state == .running, tailnet.snapshot?.selfDNSName != nil { statusItems.append(.thisDevice) }
        switch state {
        case .off: statusItems.append(.connect)
        case .starting: statusItems.append(.starting)
        case .needsLogin(let url): statusItems.append(url == nil ? .waitingForLink : .signIn)
        case .needsMachineAuth, .running: break
        case .failed: statusItems.append(.tryAgain)
        }
        snapshot.appendItems(statusItems, toSection: .status)

        if state == .running {
            snapshot.appendSections([.peers])
            let peers = visiblePeers
            var items: [Item] = []
            for peer in peers {
                items.append(.peer(peer.id))
                if pairingPeerID == peer.id, pairingWaitExpiresAt != nil { items.append(.pairingWait(peer.id)) }
            }
            snapshot.appendItems(peers.isEmpty ? [.noPeers] : items, toSection: .peers)
        }
        snapshot.appendSections([.setup])
        snapshot.appendItems([.setUpMachine], toSection: .setup)
        if state != .off {
            snapshot.appendSections([.disconnect])
            snapshot.appendItems([.disconnect], toSection: .disconnect)
        }
        // No text fields or menus here: every section redraws whole, footers
        // included, so each pass shows current state.
        let shown = dataSource.snapshot().sectionIdentifiers
        snapshot.reloadSections(snapshot.sectionIdentifiers.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var palette: ThemePalette { ThemeRuntimeState.currentPalette() }

    private func installDataSource() {
        let value = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureValue(cell, item: item)
        }
        let action = UICollectionView.CellRegistration<SSHTerminalActionCell, Item> { [weak self] cell, _, item in
            self?.configureAction(cell, item: item)
        }
        let row = UICollectionView.CellRegistration<SetupRowCell, Item> { [weak self] cell, _, item in
            guard let self, let model = setupRow(item) else { return }
            cell.configure(model)
        }
        let wait = UICollectionView.CellRegistration<PairingWaitRowCell, Item> { [weak self] cell, _, _ in
            guard let self, let expiresAt = pairingWaitExpiresAt else { return }
            cell.configure(
                expiresAt: expiresAt, fg: UIColor(palette.fg), comment: UIColor(palette.comment)
            ) { [weak self] in self?.cancelPairing() }
        }
        let index = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                title: String(localized: "Set Up a Mac or Linux Machine"),
                systemImage: "laptopcomputer.and.arrow.down",
                value: nil,
                showsDisclosure: true,
                titleColor: UIColor(palette.fg),
                identifier: "tailnet.checkMachine"
            ) { [weak self] in self?.openSetup(peer: nil) }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .status:
                content.text = String(localized: "Tailscale")
                content.image = UIImage(named: "tailscale")
                content.imageProperties.maximumSize = CGSize(width: 16, height: 16)
                content.imageProperties.tintColor = .secondaryLabel
            case .peers:
                content.text = String(localized: "Online Machines")
            default:
                content.text = nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.textProperties.numberOfLines = 0
            if let section = dataSource?.sectionIdentifier(for: indexPath.section) {
                content.text = footer(section)
                if section == .status, case .failed = tailnet.state {
                    content.textProperties.color = UIColor(palette.red)
                }
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .status, .thisDevice:
                collectionView.dequeueConfiguredReusableCell(using: value, for: indexPath, item: item)
            case .connect, .signIn, .tryAgain, .disconnect:
                collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            case .pairingWait:
                collectionView.dequeueConfiguredReusableCell(using: wait, for: indexPath, item: item)
            case .setUpMachine:
                collectionView.dequeueConfiguredReusableCell(using: index, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configureValue(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        switch item {
        case .status:
            content.text = String(localized: "Status")
            content.secondaryText = Self.statusLabel(tailnet.state)
            cell.accessibilityIdentifier = "tailnet.status"
        case .thisDevice:
            content.text = String(localized: "This Device")
            content.secondaryText = tailnet.snapshot?.selfDNSName
            cell.accessibilityIdentifier = nil
        default:
            break
        }
        cell.contentConfiguration = content
    }

    private func configureAction(_ cell: SSHTerminalActionCell, item: Item) {
        let blue = UIColor(palette.blue)
        switch item {
        case .connect:
            cell.configure(title: String(localized: "Connect to Tailscale"), identifier: "tailnet.connect", color: blue) { [weak self] in
                self?.tailnet.connect()
            }
        case .signIn:
            cell.configure(
                title: String(localized: "Sign In to Tailscale"), identifier: "tailnet.signIn", color: blue,
                image: "person.badge.key"
            ) { [weak self] in
                guard let self, case .needsLogin(let url?) = tailnet.state else { return }
                InAppBrowserPresenter.present(url: url)
            }
        case .tryAgain:
            cell.configure(title: String(localized: "Try Again"), identifier: "tailnet.tryAgain", color: blue) { [weak self] in
                guard let self else { return }
                Task { await self.tailnet.restart() }
            }
        case .disconnect:
            cell.configure(title: String(localized: "Disconnect"), identifier: "tailnet.disconnect", color: UIColor(palette.red)) { [weak self] in
                self?.confirmDisconnect()
            }
        default:
            break
        }
    }

    private func setupRow(_ item: Item) -> SetupRow? {
        let comment = UIColor(palette.comment)
        switch item {
        case .starting:
            return SetupRow(leading: .spinner, title: String(localized: "Starting\u{2026}"), titleColor: comment)
        case .waitingForLink:
            return SetupRow(leading: .spinner, title: String(localized: "Waiting for sign-in link\u{2026}"), titleColor: comment)
        case .noPeers:
            return SetupRow(title: String(localized: "No other machines are online."), titleColor: comment)
        case .peer(let id):
            guard let peer = visiblePeers.first(where: { $0.id == id }) else { return nil }
            return peerRow(peer)
        default:
            return nil
        }
    }

    private func peerRow(_ peer: TailnetPeer) -> SetupRow {
        let fg = UIColor(palette.fg)
        let comment = UIColor(palette.comment)
        let address = SetupRow.Line(text: peer.dnsName.isEmpty ? peer.tailscaleIPs.first ?? "" : peer.dnsName, color: comment)
        var row = SetupRow(title: peer.displayName, titleColor: fg, lines: [address])
        switch status(of: peer) {
        case .paired:
            row.trailing = .badge(String(localized: "Paired"), symbol: "checkmark.circle.fill", color: UIColor(palette.green))
            row.accessibilityLabel = "\(peer.displayName), \(String(localized: "Paired"))"
            row.rowAction = ("tailnet.paired.\(peer.id)", { [weak self] in self?.openServerSettings(for: peer) })
        case .checking:
            row.trailing = .spinner
            row.accessibilityLabel = String(localized: "\(peer.displayName), checking for Oppi")
        case .ready:
            if pairingPeerID == peer.id {
                if pairingWaitExpiresAt == nil {
                    row.trailing = .spinner
                    row.lines.append(.init(text: String(localized: "Pairing\u{2026}"), color: comment))
                }
            } else {
                row.button = .init(
                    title: String(localized: "Pair with Oppi"),
                    identifier: "tailnet.pair.\(peer.id)",
                    color: UIColor(palette.blue),
                    enabled: pairingPeerID == nil && tailnet.state == .running
                ) { [weak self] in self?.startPairing(with: peer) }
            }
        case .needsCertificate:
            row.lines.append(.init(text: String(localized: "Oppi needs Tailscale HTTPS"), color: UIColor(palette.orange), symbol: "lock.trianglebadge.exclamationmark"))
            row.lines.append(.init(text: peer.setupCheckTitle, color: UIColor(palette.blue), font: .preferredFont(forTextStyle: .footnote).withWeight(.medium)))
            row.rowAction = ("tailnet.check.\(peer.id)", { [weak self] in self?.openSetup(peer: peer) })
        case .notReachable:
            row.lines.append(.init(text: String(localized: "Oppi isn\u{2019}t running here"), color: comment, symbol: "exclamationmark.circle"))
            row.lines.append(.init(text: peer.setupCheckTitle, color: UIColor(palette.blue), font: .preferredFont(forTextStyle: .footnote).withWeight(.medium)))
            row.rowAction = ("tailnet.check.\(peer.id)", { [weak self] in self?.openSetup(peer: peer) })
        case .unchecked:
            row.lines.append(.init(text: String(localized: "Not checked yet. Pull to refresh."), color: comment))
        }
        return row
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .status:
            switch tailnet.state {
            case .needsMachineAuth:
                return String(localized: "A tailnet admin must approve \(TailnetNodeController.hostName) in the Tailscale admin console.")
            case .failed(let message):
                return message
            default:
                return String(localized: "Oppi joins your tailnet as its own device without the Tailscale VPN. While it is connected, paired *.ts.net servers connect through it.")
            }
        case .peers:
            return pairingMessage
                ?? String(localized: "Pair with a Mac or Linux machine that runs Oppi and is signed into the same Tailscale account.")
        case .setup:
            return String(localized: "Signs in to your computer over SSH and checks what Oppi needs. If Oppi isn\u{2019}t there yet, Install & Start sets it up and pairs this \(UIDevice.current.model). Works with any machine this \(UIDevice.current.model) can reach, on Tailscale or not.")
        case .disconnect:
            return nil
        }
    }

    // MARK: - Actions

    private func openSetup(peer: TailnetPeer?) {
        Router.push(SSHPreflightViewController(coordinator: coordinator, initialPeer: peer, onPaired: onPaired), from: self)
    }

    private func openServerSettings(for peer: TailnetPeer) {
        guard let server = coordinator.serverStore.servers.first(where: { peer.hasHost($0.host) }),
              let root = HostFactory.root(near: self) else { return }
        ScreenNavigator.forUIKitScreen(self, root: root).push { ServerSettingsRootView(server: server) }
    }

    private func confirmDisconnect() {
        let sheet = UIAlertController(
            title: String(localized: "Disconnect from Tailscale?"),
            message: String(localized: "Paired *.ts.net servers stop connecting until you connect again."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Disconnect"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { await self.tailnet.disconnect() }
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func startPairing(with peer: TailnetPeer) {
        pairingTask?.cancel()
        pairingGeneration &+= 1
        let generation = pairingGeneration
        pairingTask = Task { [weak self] in await self?.pair(with: peer, generation: generation) }
    }

    private func cancelPairing() {
        pairingGeneration &+= 1
        pairingTask?.cancel()
        pairingTask = nil
        pairingPeerID = nil
        pairingWaitExpiresAt = nil
        pairingMessage = String(localized: "Pairing cancelled.")
    }

    private func pair(with peer: TailnetPeer, generation: UInt64) async {
        pairingMessage = nil
        pairingWaitExpiresAt = nil
        pairingPeerID = peer.id
        defer {
            if generation == pairingGeneration {
                pairingPeerID = nil
                pairingWaitExpiresAt = nil
                // A paired peer is recognised from the store; a failed attempt
                // may have changed what the machine answers.
                probes[peer.id] = nil
                probeRefresh += 1
            }
        }
        do {
            tailnet.startIfEnabled()
            try await tailnet.waitUntilCurrentGenerationProxyReady()
            let baseURL = try await TailnetSameUserPairing.firstHealthyProbeURL(dnsName: peer.dnsName) { url in
                try await TailnetSameUserPairing.health(at: url)
            }
            let inviteClient = try TailnetSameUserPairing.makeBootstrapClient(
                nodeState: tailnet.state,
                proxy: TailnetTransportRoute.proxy,
                baseURL: baseURL,
                makeClient: { APIClient(baseURL: $0, token: "") }
            )
            let invite = try await inviteClient.issueTailscalePairingInvite()
            let enrolled = try await InviteBootstrapService.enroll(
                inviteURL: invite.inviteURL,
                serverStore: coordinator.serverStore,
                coordinator: coordinator,
                onWaitingForApproval: { [weak self] expiresAt in
                    guard let self, generation == pairingGeneration else { return }
                    pairingWaitExpiresAt = expiresAt
                },
                confirmTrust: { reason in
                    await BiometricService.shared.authenticate(reason: reason)
                }
            )
            guard generation == pairingGeneration, !Task.isCancelled else { return }
            pairingMessage = String(localized: "Paired with \(enrolled.name).")
            if enrolled.selected {
                onPaired?()
            }
        } catch let failure as TailnetSameUserPairing.Failure {
            guard generation == pairingGeneration else { return }
            pairingMessage = failure.errorDescription
        } catch let error as InviteBootstrapError {
            guard generation == pairingGeneration else { return }
            pairingMessage = error.errorDescription
        } catch {
            guard generation == pairingGeneration else { return }
            pairingMessage = InviteBootstrapService.pairingFailureMessage(for: error, host: peer.displayName)
        }
    }

    static func statusLabel(_ state: TailnetNodeState) -> String {
        switch state {
        case .off: String(localized: "Off")
        case .starting: String(localized: "Starting")
        case .needsLogin: String(localized: "Sign-in required")
        case .needsMachineAuth: String(localized: "Awaiting approval")
        case .running: String(localized: "Connected")
        case .failed: String(localized: "Error")
        }
    }

    // MARK: - Selection and copy

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    /// Machine names and this device's name can be copied, as their text was
    /// selectable before.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        let text: String?
        switch item {
        case .thisDevice: text = tailnet.snapshot?.selfDNSName
        case .peer(let id):
            text = visiblePeers.first { $0.id == id }.map { $0.dnsName.isEmpty ? $0.tailscaleIPs.first ?? "" : $0.dnsName }
        default: text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
