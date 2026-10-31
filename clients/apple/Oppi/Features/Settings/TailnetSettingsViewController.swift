import UIKit

/// Connect Oppi's embedded Tailscale node, list online tailnet machines, and
/// open Set Up a Computer for one that is not running Oppi yet.
///
/// Each online machine that can host Oppi is probed for Oppi's `/health`
/// while the screen is visible. A visit starts the probes over, so a result
/// never outlives the visit that produced it; there is no polling timer.
final class TailnetSettingsViewController: ListScreenController<TailnetSettingsViewController.Section, TailnetSettingsViewController.Item> {
    enum Section: Hashable, Sendable { case status, peers, setup, disconnect }

    enum Item: Hashable, Sendable {
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

    init(coordinator: ConnectionCoordinator, onPaired: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.onPaired = onPaired
        self.onClose = onClose
        // The node is this device's own, so everything on the page is saved here.
        super.init(
            title: String(localized: "Tailscale"),
            listIdentifier: "tailnet.list",
            scope: .device,
            headers: true,
            footers: true
        )
        navigationItem.largeTitleDisplayMode = .never
    }

    #if DEBUG
    convenience init(coordinator: ConnectionCoordinator, previewProbes: [String: TailnetPeerProbe]) {
        self.init(coordinator: coordinator)
        self.previewProbes = previewProbes
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        if onClose != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel,
                primaryAction: UIAction { [weak self] _ in self?.onClose?() }
            )
        }
    }

    // MARK: - Load

    /// The node's state, each time the page shows and on pull to refresh: it
    /// can have started, signed in, or failed while the page was away. The
    /// probes start from what arrives (`startProbesIfNeeded()`).
    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func load() async throws {
        await tailnet.refresh()
        guard !Task.isCancelled else { return }
        reprobe()
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

    override func updateProperties() {
        // Read the node and the paired servers here so a change redraws.
        _ = (tailnet.state, tailnet.snapshot, coordinator.serverStore.servers)
        startProbesIfNeeded()
        super.updateProperties()
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

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        let state = tailnet.state
        var statusItems: [Item] = [.status]
        if state == .running, tailnet.snapshot?.selfDNSName != nil { statusItems.append(.thisDevice) }
        switch state {
        case .off: statusItems.append(.connect)
        case .starting: statusItems.append(.starting)
        case .needsLogin(let url): statusItems.append(url == nil ? .waitingForLink : .signIn)
        case .needsMachineAuth, .running: break
        case .failed: statusItems.append(.tryAgain)
        }
        var sections: [ListSection<Section, Item>] = [ListSection(.status, header: String(localized: "Tailscale"), footer: footer(.status), items: statusItems)]
        if state == .running {
            let peers = visiblePeers
            var items: [Item] = []
            for peer in peers {
                items.append(.peer(peer.id))
                if pairingPeerID == peer.id, pairingWaitExpiresAt != nil { items.append(.pairingWait(peer.id)) }
            }
            sections.append(ListSection(
                .peers,
                header: String(localized: "Online Machines"),
                footer: footer(.peers),
                items: peers.isEmpty ? [.noPeers] : items
            ))
        }
        sections.append(ListSection(.setup, footer: footer(.setup), items: [.setUpMachine]))
        if state != .off {
            sections.append(ListSection(.disconnect, items: [.disconnect]))
        }
        return sections
    }

    /// Everything a row paints or captures, so a row redraws in place when a
    /// probe, a pairing, or the node changes it, and VoiceOver keeps its focus.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .status:
            return AnyHashable(Self.statusLabel(tailnet.state))
        case .thisDevice:
            return AnyHashable(tailnet.snapshot?.selfDNSName ?? "")
        case .peer(let id):
            guard let peer = visiblePeers.first(where: { $0.id == id }) else { return AnyHashable("missing") }
            return AnyHashable([
                AnyHashable(peer.displayName),
                AnyHashable(peer.dnsName),
                AnyHashable(peer.os),
                AnyHashable(peer.tailscaleIPs),
                AnyHashable(String(describing: status(of: peer))),
                AnyHashable(pairingPeerID),
                AnyHashable(pairingWaitExpiresAt == nil),
                AnyHashable(tailnet.state == .running),
            ])
        case .pairingWait:
            return AnyHashable(pairingWaitExpiresAt)
        case .connect, .starting, .signIn, .waitingForLink, .tryAgain, .noPeers, .setUpMachine, .disconnect:
            return AnyHashable(0)
        }
    }

    private var palette: ThemePalette { ThemeRuntimeState.currentPalette() }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        self?.configureAction(cell, item: item)
    }

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { cell, _, item in
        switch item {
        case .starting:
            cell.configure(.loading(String(localized: "Starting\u{2026}")))
        case .waitingForLink:
            cell.configure(.loading(String(localized: "Waiting for sign-in link\u{2026}")))
        default:
            cell.configure(.message(String(localized: "No other machines are online.")))
        }
    }

    private lazy var setupRowCell = UICollectionView.CellRegistration<SetupRowCell, Item> { [weak self] cell, _, item in
        guard let self, let model = setupRow(item) else { return }
        cell.configure(model)
    }

    private lazy var waitRow = UICollectionView.CellRegistration<PairingWaitRowCell, Item> { [weak self] cell, _, _ in
        guard let self, let expiresAt = pairingWaitExpiresAt else { return }
        cell.configure(
            expiresAt: expiresAt, colors: ComposerThemeColors(palette: palette)
        ) { [weak self] in self?.cancelPairing() }
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Set Up a Mac or Linux Computer"),
            image: .symbol("laptopcomputer.and.arrow.down"),
            value: nil,
            identifier: "tailnet.checkMachine"
        ) { [weak self] in self?.openSetup(peer: nil) }
    }

    override func prepareRegistrations() {
        _ = (actionRow, stateRow, setupRowCell, waitRow, indexRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .status, .thisDevice:
            super.dequeue(item, at: indexPath)
        case .connect, .signIn, .tryAgain, .disconnect:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .starting, .waitingForLink, .noPeers:
            collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .pairingWait:
            collectionView.dequeueConfiguredReusableCell(using: waitRow, for: indexPath, item: item)
        case .setUpMachine:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .peer:
            collectionView.dequeueConfiguredReusableCell(using: setupRowCell, for: indexPath, item: item)
        }
    }

    override func decorate(header content: inout UIListContentConfiguration, section: Section) {
        guard section == .status else { return }
        content.image = UIImage(named: "tailscale")
        content.imageProperties.maximumSize = CGSize(width: 16, height: 16)
        content.imageProperties.tintColor = .secondaryLabel
    }

    override func decorate(footer content: inout UIListContentConfiguration, section: Section) {
        if section == .status, case .failed = tailnet.state {
            content.textProperties.color = SettingsStyle.current.destructive
        }
    }

    /// The node's status and this device's name: read-only facts.
    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = content(.info)
        switch item {
        case .status:
            content.text = String(localized: "Status")
            content.secondaryText = Self.statusLabel(tailnet.state)
            cell.accessibilityIdentifier = "tailnet.status"
        case .thisDevice:
            content.text = String(localized: "This Device")
            content.secondaryText = tailnet.snapshot?.selfDNSName
        default:
            break
        }
        cell.contentConfiguration = content
    }

    /// Machine names and this device's name can be copied, as their text was
    /// selectable before.
    override func copyText(of item: Item) -> String? {
        switch item {
        case .thisDevice: tailnet.snapshot?.selfDNSName
        case .peer(let id):
            visiblePeers.first { $0.id == id }.map { $0.dnsName.isEmpty ? $0.tailscaleIPs.first ?? "" : $0.dnsName }
        default: nil
        }
    }

    private func configureAction(_ cell: SettingsActionRowCell, item: Item) {
        switch item {
        case .connect:
            cell.configure(title: String(localized: "Connect to Tailscale"), identifier: "tailnet.connect") { [weak self] in
                self?.tailnet.connect()
            }
        case .signIn:
            cell.configure(
                title: String(localized: "Sign In to Tailscale"), systemImage: "person.badge.key", identifier: "tailnet.signIn"
            ) { [weak self] in
                guard let self, case .needsLogin(let url?) = tailnet.state else { return }
                InAppBrowserPresenter.present(url: url)
            }
        case .tryAgain:
            cell.configure(title: String(localized: "Retry"), identifier: "tailnet.tryAgain") { [weak self] in
                guard let self else { return }
                Task { await self.tailnet.restart() }
            }
        case .disconnect:
            cell.configure(
                title: String(localized: "Disconnect"),
                tint: .destructive,
                identifier: "tailnet.disconnect",
                confirmation: .init(
                    title: String(localized: "Disconnect from Tailscale?"),
                    message: String(localized: "Paired *.ts.net servers stop connecting until you connect again."),
                    actionTitle: String(localized: "Disconnect")
                )
            ) { [weak self] in
                guard let self else { return }
                Task { await self.tailnet.disconnect() }
            }
        default:
            break
        }
    }

    private func setupRow(_ item: Item) -> SetupRow? {
        guard case .peer(let id) = item, let peer = visiblePeers.first(where: { $0.id == id }) else { return nil }
        return peerRow(peer)
    }

    private func peerRow(_ peer: TailnetPeer) -> SetupRow {
        let fg = palette.ui.fg
        let comment = palette.ui.comment
        let address = SetupRow.Line(text: peer.dnsName.isEmpty ? peer.tailscaleIPs.first ?? "" : peer.dnsName, color: comment)
        var row = SetupRow(title: peer.displayName, titleColor: fg, lines: [address])
        switch status(of: peer) {
        case .paired:
            row.trailing = .badge(String(localized: "Paired"), symbol: "checkmark.circle.fill", color: palette.ui.green)
            row.accessibilityLabel = "\(peer.displayName), \(String(localized: "Paired"))"
            // In a sheet (Add Server → Set Up a Computer) the row only says the computer is paired:
            // opening that server's settings would switch the active server behind the sheets and
            // route Server Settings under them, away from the flow the person is in.
            if onClose == nil {
                row.rowAction = ("tailnet.paired.\(peer.id)", { [weak self] in self?.openServerSettings(for: peer) })
            }
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
                    color: palette.ui.blue,
                    enabled: pairingPeerID == nil && tailnet.state == .running
                ) { [weak self] in self?.startPairing(with: peer) }
            }
        case .needsCertificate:
            row.lines.append(.init(text: String(localized: "Oppi needs Tailscale HTTPS"), color: palette.ui.orange, symbol: "lock.trianglebadge.exclamationmark"))
            row.lines.append(.init(text: peer.setupCheckTitle, color: palette.ui.blue, font: .preferredFont(forTextStyle: .footnote).withWeight(.medium)))
            row.rowAction = ("tailnet.check.\(peer.id)", { [weak self] in self?.openSetup(peer: peer) })
        case .notReachable:
            row.lines.append(.init(text: String(localized: "Oppi isn\u{2019}t running here"), color: comment, symbol: "exclamationmark.circle"))
            row.lines.append(.init(text: peer.setupCheckTitle, color: palette.ui.blue, font: .preferredFont(forTextStyle: .footnote).withWeight(.medium)))
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
            return String(localized: "Signs in to your computer over SSH and checks what Oppi needs. If Oppi isn\u{2019}t there yet, Install & Start sets it up and pairs this \(UIDevice.current.model). Works with any computer this \(UIDevice.current.model) can reach, on Tailscale or not.")
        case .disconnect:
            return nil
        }
    }

    // MARK: - Actions

    private func openSetup(peer: TailnetPeer?) {
        Router.push(SSHPreflightViewController(coordinator: coordinator, initialPeer: peer, onPaired: onPaired), from: self)
    }

    /// The peer's own server, not the one that happens to be active: Server Settings follows
    /// the active server, so this makes the peer's server active first (a locked one asks), as
    /// App Settings' server rows do, then opens Server Settings for it.
    func openServerSettings(for peer: TailnetPeer) {
        guard let server = coordinator.serverStore.servers.first(where: { peer.hasHost($0.host) }),
              let root = AppRootEnvironment.near(self) else { return }
        let coordinator = coordinator
        let navigation = root.navigation
        let perform: @MainActor () -> Void = {
            if coordinator.activeServerId != server.id {
                guard coordinator.restoreActiveServer(server.id) else { return }
                Task { await coordinator.prepareSelectedServerShell(for: server) }
            }
            navigation.openServerDetails(ServerDetailsNavTarget(serverId: server.id))
        }
        if ScopedLockService.shared.gate(.server(server.id), onUnlock: perform) {
            perform()
        }
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
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
