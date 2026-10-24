import UIKit

/// Set Up a Computer: signs in to a Mac or Linux computer's sshd (macOS Remote
/// Login, or Linux sshd) with a password, through the embedded Tailscale node
/// for a tailnet name and the current network otherwise, and runs one
/// read-only check. When Oppi already answers there, Pair mints an invite
/// over SSH. Otherwise Install & Start runs the bundled `install.sh` on the
/// same kind of connection, shows its steps live, checks again, and pairs
/// without another tap. Only the SSH host key is saved; the password is not.
///
/// Leaving the screen cancels whatever is running, which closes the SSH
/// connection. While Install & Start runs, the back button and sheet swipe
/// are held so a stray gesture does not stop it; Cancel is explicit.
final class SSHPreflightViewController: UIViewController, UICollectionViewDelegate {
    private enum Phase {
        case idle
        case checking(SSHSetupAddress)
        case failed(SSHPreflightFailure, SSHSetupAddress)
        case finished(SSHPreflightReport, SSHSetupAddress)
    }

    /// Install & Start, from the tap to the paired machine.
    private enum Install {
        case none
        /// The installer runs, then the machine is checked again and an
        /// invite minted on the same connection (`completion` is set by then).
        case running(SSHInstallProgress)
        /// Enrolling the minted invite.
        case pairing(SSHInstallProgress)
        /// Finished; the result rows and footer say what happened.
        case completed(SSHInstallProgress)
        case failed(SSHInstallProgress, SSHPreflightFailure)
        /// Cancelled by the person.
        case stopped(SSHInstallProgress)

        var progress: SSHInstallProgress? {
            switch self {
            case .none: nil
            case .running(let progress), .pairing(let progress), .completed(let progress),
                 .failed(let progress, _), .stopped(let progress): progress
            }
        }

        var isActive: Bool {
            switch self {
            case .running, .pairing: true
            default: false
            }
        }
    }

    private enum Section: Hashable { case machine, signIn, action, result, failure, forget, next }

    private enum Item: Hashable {
        case machine, manualHost, username, password
        case checkButton, checking
        case failureMessage, fingerprint(String), trustKey, forgetKey
        case signedInAs, result(String)
        case installStep(SSHInstallStep), installStatus, installCancel, installError, installRetry
        case pair, pairing, install
    }

    private static let manualSelection = "\u{0}manual"

    private let coordinator: ConnectionCoordinator
    private let onPaired: (() -> Void)?
    private var tailnet: TailnetNodeController { .shared }

    private var selection: String { didSet { targetMayHaveChanged(from: oldValue, manual: manualHost) } }
    private var manualHost = "" { didSet { targetMayHaveChanged(from: selection, manual: oldValue) } }
    private var username = "" { didSet { setNeedsUpdateProperties() } }
    private var password = "" { didSet { setNeedsUpdateProperties() } }
    private var phase = Phase.idle { didSet { setNeedsUpdateProperties() } }
    private var install = Install.none { didSet { installStateChanged(from: oldValue) } }
    private var pairing = false { didSet { setNeedsUpdateProperties() } }
    /// An invite is being enrolled; `cancel()` lets it finish.
    private var enrolling = false
    private var pairMessage: String? {
        didSet {
            // The outcome of Pair or Install & Start: "Paired with …" or why not.
            if let pairMessage, pairMessage != oldValue, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: pairMessage)
            }
            setNeedsUpdateProperties()
        }
    }
    private var runID = UUID()
    private var task: Task<Void, Never>?
    private var keepAwake: SetupKeepAwake?
    private var heldNavigation: UINavigationController?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var machineRow = ChangedRows<Item>()

    /// `initialPeer` preselects a machine from the tailnet list; the picker
    /// still allows changing it.
    init(coordinator: ConnectionCoordinator, initialPeer: TailnetPeer? = nil, onPaired: (() -> Void)? = nil) {
        self.coordinator = coordinator
        self.onPaired = onPaired
        selection = initialPeer?.dialHost ?? ""
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Set Up a Computer")
        navigationItem.largeTitleDisplayMode = .never
    }

    #if DEBUG
    /// Screenshot harness: a settled check, and optionally an install in
    /// progress or stopped by a failure, without dialing SSH.
    convenience init(
        coordinator: ConnectionCoordinator,
        previewReport: SSHPreflightReport,
        host: String,
        installProgress: SSHInstallProgress? = nil,
        installFailure: SSHPreflightFailure? = nil
    ) {
        self.init(coordinator: coordinator)
        selection = host
        phase = .finished(previewReport, SSHSetupAddress(host: host))
        username = previewReport.user
        if let installProgress {
            install = installFailure.map { .failed(installProgress, $0) } ?? .running(installProgress)
        }
    }

    /// Screenshot harness: a settled failure without dialing SSH.
    convenience init(coordinator: ConnectionCoordinator, previewFailure: SSHPreflightFailure, host: String) {
        self.init(coordinator: coordinator)
        selection = host
        phase = .failed(previewFailure, SSHSetupAddress(host: host))
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
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "sshPreflight.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        tailnet.startIfEnabled()
        selectDefaultMachine()
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Popped, or its sheet closed: stop and close the connection. A Face ID
        // prompt over the screen is not leaving it.
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancel()
        }
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Read here so a change to the online machines or the node redraws.
        _ = (tailnet.state, tailnet.onlinePeers)
        applySnapshot()
    }

    // MARK: - State

    private var setupPeers: [TailnetPeer] {
        tailnet.onlinePeers.filter(\.canHostOppi)
    }

    private func address(selection: String, manual: String) -> SSHSetupAddress? {
        if selection == Self.manualSelection { return SSHSetupAddress(manual) }
        let host = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : SSHSetupAddress(host: host)
    }

    private var target: SSHSetupAddress? { address(selection: selection, manual: manualHost) }

    /// A different machine starts over: its results do not apply.
    private func targetMayHaveChanged(from oldSelection: String, manual oldManual: String) {
        if address(selection: oldSelection, manual: oldManual) != target, !isBusy {
            phase = .idle
            install = .none
            pairMessage = nil
        }
        setNeedsUpdateProperties()
    }

    private var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    private var isBusy: Bool { isChecking || pairing || install.isActive }

    private var canSignIn: Bool {
        target != nil && !username.isEmpty && !password.isEmpty
    }

    private var canCheck: Bool { !isBusy && canSignIn }

    /// "Mac", "Linux computer", or "computer", for copy about the checked computer.
    private func computerNoun(_ report: SSHPreflightReport?) -> String {
        guard let report else { return String(localized: "computer") }
        if report.isMacOS { return String(localized: "Mac") }
        if report.isLinux { return String(localized: "Linux computer") }
        return String(localized: "computer")
    }

    /// "iPhone" or "iPad": this device, in setup copy.
    private var deviceName: String { UIDevice.current.model }

    private func installStateChanged(from old: Install) {
        announceInstallChange(from: old)
        let active = install.isActive
        if active, keepAwake == nil {
            keepAwake = SetupKeepAwake()
        } else if !active, let keepAwake {
            keepAwake.end()
            self.keepAwake = nil
        }
        // Back and swipe-to-dismiss would cancel a long install; Cancel says so.
        navigationItem.hidesBackButton = active
        isModalInPresentation = active
        if active, let navigationController {
            heldNavigation = navigationController
            navigationController.isModalInPresentation = true
        } else if !active, let heldNavigation {
            heldNavigation.isModalInPresentation = false
            self.heldNavigation = nil
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Snapshot

    private var currentReport: (SSHPreflightReport, SSHSetupAddress)? {
        if case .finished(let report, let address) = phase { return (report, address) }
        return nil
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.machine])
        snapshot.appendItems(selection == Self.manualSelection ? [.machine, .manualHost] : [.machine], toSection: .machine)
        snapshot.appendSections([.signIn])
        snapshot.appendItems([.username, .password], toSection: .signIn)
        snapshot.appendSections([.action])
        snapshot.appendItems([isChecking ? .checking : .checkButton], toSection: .action)

        switch phase {
        case .idle, .checking:
            break
        case .failed(let failure, _):
            snapshot.appendSections([.failure])
            var items: [Item] = [.failureMessage]
            switch failure {
            case .unknownHostKey:
                items += [.fingerprint("Fingerprint"), .trustKey]
            case .hostKeyMismatch:
                items += [.fingerprint("Trusted"), .fingerprint("Presented")]
            default:
                break
            }
            snapshot.appendItems(items, toSection: .failure)
            if case .hostKeyMismatch = failure {
                snapshot.appendSections([.forget])
                snapshot.appendItems([.forgetKey], toSection: .forget)
            }
        case .finished(let report, _):
            snapshot.appendSections([.result])
            snapshot.appendItems([.signedInAs] + report.checks.map { .result($0.title) }, toSection: .result)
            let next = nextItems(report)
            if !next.isEmpty {
                snapshot.appendSections([.next])
                snapshot.appendItems(next, toSection: .next)
            }
        }

        // Rows already shown are reconfigured in place, never reloaded, so a
        // text field keeps its cursor and VoiceOver focus stays on its row.
        // The machine menu only when its choices change, so an open menu stays.
        let shown = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            $0 != .machine && shown.itemIdentifiers.contains($0)
        })
        let machineChanged = machineRow.changed(in: [.machine]) { _ in
            AnyHashable([AnyHashable(setupPeers.map(\.dialHost)), AnyHashable(selection), AnyHashable(isBusy), AnyHashable(appliedThemeID)])
        }
        if !machineChanged.isEmpty, shown.itemIdentifiers.contains(.machine) {
            snapshot.reconfigureItems([.machine])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        SetupListSupplementaries.refresh(collectionView) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
    }

    private func nextItems(_ report: SSHPreflightReport) -> [Item] {
        var items: [Item] = []
        if install.progress != nil {
            items += SSHInstallStep.allCases.map(Item.installStep)
        }
        switch install {
        case .running(let progress):
            if progress.completion != nil { items.append(.installStatus) }
            items.append(.installCancel)
        case .pairing:
            // No Cancel: stopping an enrollment midway could leave this device
            // enrolled on the server without the app knowing. It is short.
            items.append(.installStatus)
        case .failed, .stopped:
            items += [.installError, .installRetry]
        case .none, .completed:
            switch report.nextStep {
            case .pair: items.append(pairing ? .pairing : .pair)
            case .install: items.append(.install)
            case .unsupported: break
            }
        }
        return items
    }

    // MARK: - Cells

    private func installDataSource() {
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
            self?.configureField(cell, item: item)
        }
        let action = UICollectionView.CellRegistration<SSHTerminalActionCell, Item> { [weak self] cell, _, item in
            self?.configureAction(cell, item: item)
        }
        let row = UICollectionView.CellRegistration<SetupRowCell, Item> { [weak self] cell, _, item in
            guard let self, let model = setupRow(item) else { return }
            cell.configure(model)
        }
        let value = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureValue(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .manualHost, .username, .password:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            case .checkButton, .trustKey, .forgetKey, .pair, .install, .installCancel, .installRetry:
                collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            case .machine, .signedInAs:
                collectionView.dequeueConfiguredReusableCell(using: value, for: indexPath, item: item)
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

    private var palette: ThemePalette { ThemeRuntimeState.currentPalette() }

    private func configureSupplementary(_ view: UICollectionViewListCell, kind: String, at indexPath: IndexPath) {
        let section = dataSource?.sectionIdentifier(for: indexPath.section)
        var content: UIListContentConfiguration
        if kind == UICollectionView.elementKindSectionHeader {
            content = .header()
            content.text = section.flatMap(header)
        } else {
            content = .footer()
            content.text = section.flatMap(footer)
            content.textProperties.numberOfLines = 0
        }
        view.contentConfiguration = content
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let fg = UIColor(palette.fg)
        switch item {
        case .manualHost:
            cell.configure(
                text: manualHost, placeholder: String(localized: "Hostname or IP address"),
                identifier: "sshPreflight.host", keyboard: .URL, textColor: fg, enabled: !isBusy
            ) { [weak self] in self?.manualHost = $0 }
        case .username:
            cell.configure(
                text: username, placeholder: String(localized: "Username"),
                identifier: "sshPreflight.username", contentType: .username, textColor: fg, enabled: !isBusy,
                returnKey: .next
            ) { [weak self] in self?.username = $0 }
        case .password:
            cell.configure(
                text: password, placeholder: String(localized: "Password"),
                identifier: "sshPreflight.password", isSecure: true, contentType: .password,
                textColor: fg, enabled: !isBusy, returnKey: .go,
                onReturn: { [weak self] in self?.check() }
            ) { [weak self] in self?.password = $0 }
        default:
            break
        }
    }

    private func configureAction(_ cell: SSHTerminalActionCell, item: Item) {
        let blue = UIColor(palette.blue)
        let red = UIColor(palette.red)
        switch item {
        case .checkButton:
            cell.configure(title: String(localized: "Check"), identifier: "sshPreflight.check", color: blue, enabled: canCheck) { [weak self] in
                self?.check()
            }
        case .trustKey:
            cell.configure(title: String(localized: "Trust Key and Check"), identifier: "sshPreflight.trustKey", color: blue, enabled: canCheck) { [weak self] in
                guard let self, case .failed(.unknownHostKey(let key), let address) = phase else { return }
                check(trusting: key, address: address)
            }
        case .forgetKey:
            cell.configure(title: String(localized: "Forget Trusted Key"), identifier: "sshPreflight.forgetKey", color: red) { [weak self] in
                self?.confirmForget()
            }
        case .pair:
            cell.configure(title: String(localized: "Pair"), identifier: "sshPreflight.pair", color: blue, enabled: !isBusy && canSignIn) { [weak self] in
                guard let self, let (_, address) = currentReport else { return }
                pair(address: address)
            }
        case .install:
            cell.configure(
                title: String(localized: "Install & Start Oppi"), identifier: "sshPreflight.install", color: blue,
                enabled: !isBusy && canSignIn, image: "arrow.down.circle"
            ) { [weak self] in
                guard let self, let (_, address) = currentReport else { return }
                startInstall(address: address)
            }
        case .installCancel:
            cell.configure(title: String(localized: "Cancel Setup"), identifier: "sshPreflight.install.cancel", color: red) { [weak self] in
                self?.cancel()
            }
        case .installRetry:
            cell.configure(title: String(localized: "Try Again"), identifier: "sshPreflight.install.retry", color: blue, enabled: !isBusy && canSignIn) { [weak self] in
                guard let self, let (_, address) = currentReport else { return }
                startInstall(address: address)
            }
        default:
            break
        }
    }

    private func configureValue(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        cell.accessories = []
        switch item {
        case .machine:
            content.text = String(localized: "Computer")
            let peers = setupPeers
            var options: [(title: String, selected: Bool, action: () -> Void)] = peers.map { peer in
                (peer.displayName, selection == peer.dialHost, { [weak self] in self?.selection = peer.dialHost })
            }
            // A preselected machine that left the online list stays choosable.
            if selection != Self.manualSelection, !selection.isEmpty, !peers.contains(where: { $0.dialHost == selection }) {
                options.insert((selection, true, {}), at: 0)
            }
            options.append((String(localized: "Other\u{2026}"), selection == Self.manualSelection, { [weak self] in
                self?.selection = Self.manualSelection
            }))
            cell.accessories = [.settingsPopUpMenu(identifier: "sshPreflight.machine", isEnabled: !isBusy, options: options)]
        case .signedInAs:
            content.text = String(localized: "Signed In As")
            content.secondaryText = currentReport?.0.user
        default:
            break
        }
        cell.contentConfiguration = content
    }

    private func setupRow(_ item: Item) -> SetupRow? {
        let fg = UIColor(palette.fg)
        let comment = UIColor(palette.comment)
        let red = UIColor(palette.red)
        switch item {
        case .checking:
            return SetupRow(
                leading: .spinner, title: String(localized: "Checking\u{2026}"), titleColor: comment,
                button: .init(title: String(localized: "Cancel"), identifier: "sshPreflight.cancel", color: UIColor(palette.blue)) { [weak self] in
                    self?.cancel()
                }
            )
        case .failureMessage:
            guard case .failed(let failure, _) = phase else { return nil }
            return SetupRow(title: failure.message, titleColor: red, identifier: "sshPreflight.failure")
        case .fingerprint(let label):
            guard let key = fingerprintKey(label) else { return nil }
            return SetupRow(
                title: "\(label) (\(key.algorithm))", titleColor: comment,
                lines: [.init(text: key.fingerprint, color: fg, font: .scaledMonospaced(.footnote))]
            )
        case .result(let title):
            guard let check = currentReport?.0.checks.first(where: { $0.title == title }) else { return nil }
            let symbol: (String, UIColor, String) = switch check.status {
            case .ok: ("checkmark.circle.fill", UIColor(palette.green), String(localized: "OK"))
            case .installs: ("arrow.down.circle", UIColor(palette.blue), String(localized: "Install & Start adds it"))
            case .missing: ("xmark.circle.fill", red, String(localized: "Missing"))
            case .info: ("info.circle", comment, String(localized: "Note"))
            }
            return SetupRow(
                leading: .symbol(symbol.0, symbol.1), title: check.title, titleColor: fg,
                lines: [.init(text: check.detail, color: comment)],
                identifier: "sshPreflight.result.\(check.id)",
                accessibilityLabel: "\(check.title), \(symbol.2), \(check.detail)"
            )
        case .installStep(let step):
            return installStepRow(step)
        case .installStatus:
            let text: String
            if case .pairing = install {
                text = String(localized: "Pairing this \(deviceName)\u{2026}")
            } else {
                text = String(localized: "Checking that Oppi answers\u{2026}")
            }
            return SetupRow(leading: .spinner, title: text, titleColor: comment, identifier: "sshPreflight.install.status")
        case .installError:
            switch install {
            case .failed(_, let failure):
                var lines: [SetupRow.Line] = []
                if case .installFailed(let code, _) = failure {
                    lines.append(.init(text: String(localized: "Error code: \(code)"), color: comment, font: .scaledMonospaced(.footnote)))
                }
                return SetupRow(
                    leading: .symbol("exclamationmark.triangle.fill", red), title: failure.message, titleColor: red,
                    lines: lines, identifier: "sshPreflight.install.error"
                )
            case .stopped:
                return SetupRow(
                    leading: .symbol("stop.circle", comment),
                    title: String(localized: "Setup was stopped. Try again to finish; it picks up where it stopped."),
                    titleColor: comment, identifier: "sshPreflight.install.error"
                )
            default:
                return nil
            }
        case .pairing:
            return SetupRow(leading: .spinner, title: String(localized: "Pairing\u{2026}"), titleColor: comment, identifier: "sshPreflight.pairing")
        default:
            return nil
        }
    }

    private func fingerprintKey(_ label: String) -> SSHHostKey? {
        guard case .failed(let failure, _) = phase else { return nil }
        switch (failure, label) {
        case (.unknownHostKey(let key), "Fingerprint"): return key
        case (.hostKeyMismatch(let saved, _), "Trusted"): return saved
        case (.hostKeyMismatch(_, let presented), "Presented"): return presented
        default: return nil
        }
    }

    /// How one installer step reads: its name, symbol, detail line, and the
    /// state word VoiceOver speaks.
    private struct StepPresentation {
        let title: String
        let leading: SetupRow.Leading
        let detail: String
        let word: String
    }

    private func presentation(of step: SSHInstallStep, _ state: SSHInstallProgress.StepState) -> StepPresentation {
        let comment = UIColor(palette.comment)
        let orange = UIColor(palette.orange)
        let title: String
        let about: String
        switch step {
        case .node:
            title = String(localized: "Node.js")
            about = String(localized: "The runtime Oppi runs on.")
        case .oppi:
            title = String(localized: "Oppi")
            about = String(localized: "The Oppi server, in your home folder.")
        case .service:
            title = String(localized: "Background Service")
            about = String(localized: "Keeps Oppi running, including after a restart.")
        case .start:
            title = String(localized: "Start")
            about = String(localized: "Waits until Oppi answers.")
        }
        func or(_ text: String, _ fallback: String) -> String { text.isEmpty ? fallback : text }
        switch state {
        case .pending:
            return .init(title: title, leading: .symbol("circle", comment), detail: about, word: String(localized: "Waiting"))
        case .running(let text):
            return .init(title: title, leading: .spinner, detail: or(text, about), word: String(localized: "In progress"))
        case .finished(let text):
            return .init(title: title, leading: .symbol("checkmark.circle.fill", UIColor(palette.green)), detail: or(text, about), word: String(localized: "Done"))
        case .skipped(let text) where step == .service:
            // Linux without a systemd user manager: Oppi runs in the
            // background but will not come back after a restart. Setup goes
            // on to pairing; the installer's detail says what to change.
            return .init(
                title: title, leading: .symbol("exclamationmark.triangle.fill", orange),
                detail: or(text, String(localized: "Oppi is running, but will not start again after a restart.")),
                word: String(localized: "Needs attention")
            )
        case .skipped(let text):
            return .init(title: title, leading: .symbol("checkmark.circle", UIColor(palette.green)), detail: or(text, about), word: String(localized: "Already done"))
        case .warning(let text):
            // Done, with something to fix later; the installer's detail says
            // what. Setup goes on to pairing.
            return .init(title: title, leading: .symbol("exclamationmark.triangle.fill", orange), detail: or(text, about), word: String(localized: "Needs attention"))
        case .failed(let text):
            return .init(title: title, leading: .symbol("xmark.circle.fill", UIColor(palette.red)), detail: or(text, about), word: String(localized: "Failed"))
        }
    }

    private func installStepRow(_ step: SSHInstallStep) -> SetupRow {
        let shown = presentation(of: step, install.progress?.state(of: step) ?? .pending)
        return SetupRow(
            leading: shown.leading, title: shown.title, titleColor: UIColor(palette.fg),
            lines: [.init(text: shown.detail, color: UIColor(palette.comment))],
            identifier: "sshPreflight.install.step.\(step.rawValue)",
            accessibilityLabel: "\(shown.title), \(shown.word), \(shown.detail)"
        )
    }

    /// VoiceOver hears each step change, the finish, and a failure, since
    /// the rows change while focus may be elsewhere.
    private func announceInstallChange(from old: Install) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        var spoken: [String] = []
        if let progress = install.progress {
            for step in SSHInstallStep.allCases {
                let state = progress.state(of: step)
                guard state != .pending, state != old.progress?.state(of: step) else { continue }
                let shown = presentation(of: step, state)
                spoken.append("\(shown.title), \(shown.word)")
            }
        }
        switch install {
        case .pairing:
            if case .pairing = old {} else {
                spoken.append(String(localized: "Oppi is installed and running. Pairing this \(deviceName)."))
            }
        case .failed(_, let failure):
            spoken.append(failure.message)
        case .stopped:
            if case .stopped = old {} else { spoken.append(String(localized: "Setup stopped.")) }
        case .none, .running, .completed:
            break
        }
        guard !spoken.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: spoken.joined(separator: ". "))
    }

    private func header(_ section: Section) -> String? {
        switch section {
        case .machine: String(localized: "Computer")
        case .signIn: String(localized: "Sign In")
        case .failure:
            if case .failed(_, let address) = phase { address.label } else { nil }
        case .result: currentReport?.1.label
        case .next:
            install.progress != nil ? String(localized: "Install & Start") : nil
        case .action, .forget: nil
        }
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .machine:
            var text = String(localized: "Oppi signs in to the computer over SSH. On a Mac, turn on Remote Login in System Settings \u{2192} General \u{2192} Sharing. On Linux, start the SSH server (sshd).")
            if selection == Self.manualSelection {
                text += " " + String(localized: "Add :port to the name if SSH is not on port 22.")
            }
            return text
        case .signIn:
            return String(localized: "Use the account you sign in to that computer with. Oppi sends your password only to a computer whose SSH key you trusted, and never saves it.")
        case .action:
            guard let target,
                  SSHDial.route(host: target.host, tailnetRunning: tailnet.state == .running, whenNodeStopped: .fail) == .tailnetRequired else { return nil }
            return String(localized: "A Tailscale name needs Oppi's Tailscale connection.")
        case .failure:
            guard case .failed(.unknownHostKey(let key), _) = phase else { return nil }
            return String(localized: "On the computer, `ssh-keygen -lf /etc/ssh/ssh_host_\(Self.keyFileStem(key))_key.pub` prints the same value.")
        case .result:
            guard let report = currentReport?.0, report.nextStep == .unsupported else { return nil }
            return String(localized: "Oppi runs on macOS and Linux.")
        case .next:
            return nextFooter()
        case .forget:
            return nil
        }
    }

    private func nextFooter() -> String? {
        guard let report = currentReport?.0 else { return nil }
        let computer = computerNoun(report)
        var parts: [String] = []
        switch install {
        case .running, .pairing:
            parts.append(String(localized: "Keep Oppi open until setup finishes. This \(deviceName) stays awake meanwhile."))
        case .failed, .stopped:
            break
        case .none, .completed:
            switch report.nextStep {
            case .pair:
                parts.append(String(localized: "Oppi is running on this \(computer). Pair signs this \(deviceName) in with a one-time invite."))
            case .install:
                parts.append(String(localized: "Installs Oppi and the Node.js it runs on in your home folder on this \(computer), keeps Oppi running in the background, then pairs this \(deviceName). Downloads come from nodejs.org and npm, so it can take a few minutes. No administrator password is needed."))
            case .unsupported:
                break
            }
        }
        if let pairMessage { parts.append(pairMessage) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Actions

    private func selectDefaultMachine() {
        guard selection.isEmpty else { return }
        selection = TailnetPeer.preferredSetupPeer(among: tailnet.onlinePeers)?.dialHost ?? Self.manualSelection
    }

    /// A request for `address`, with the key the user trusted for it.
    private func request(for address: SSHSetupAddress) throws -> SSHPreflightClient.Request {
        SSHPreflightClient.Request(
            username: username, password: password,
            savedHostKey: try SSHKnownHosts().savedKey(host: address.host, port: address.port)
        )
    }

    /// A tailnet name is never dialed on the system network from here.
    private func dialSSH(_ address: SSHSetupAddress) async throws -> Int32 {
        try await SSHDial.socket(host: address.host, port: address.port, whenNodeStopped: .fail)
    }

    /// Starts `work` as the screen's one task. A newer run or Cancel makes
    /// `isCurrent` false, so a finished stale run changes nothing.
    private func start(_ work: @escaping @MainActor (_ isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> Void) {
        task?.cancel()
        let runID = UUID()
        self.runID = runID
        task = Task { [weak self] in
            await work { self?.runID == runID }
            if self?.runID == runID { self?.task = nil }
        }
    }

    private func check(trusting key: SSHHostKey? = nil, address: SSHSetupAddress? = nil) {
        guard canCheck, let address = address ?? target else { return }
        let request: SSHPreflightClient.Request
        do {
            if let key { try SSHKnownHosts().trust(key, host: address.host, port: address.port) }
            request = try self.request(for: address)
        } catch {
            phase = .failed(.handshakeFailed(error.localizedDescription), address)
            return
        }
        install = .none
        pairMessage = nil
        phase = .checking(address)
        start { [weak self] isCurrent in
            guard let self else { return }
            let outcome: Phase?
            do {
                let socket = try await dialSSH(address)
                let report = try await SSHPreflightClient.run(request, socket: socket)
                outcome = .finished(report, address)
            } catch let failure as SSHPreflightFailure {
                outcome = .failed(failure, address)
            } catch {
                outcome = nil // Cancelled.
            }
            guard isCurrent() else { return }
            phase = outcome ?? .idle
        }
    }

    /// Cancelling the task closes the SSH connection. An enrollment already
    /// sent is left to finish: stopping it midway could leave this device
    /// enrolled on the server with no saved pairing and no `onPaired`.
    private func cancel() {
        guard !enrolling else { return }
        task?.cancel()
        task = nil
        runID = UUID()
        if isChecking { phase = .idle }
        pairing = false
        switch install {
        case .running(let progress), .pairing(let progress):
            install = .stopped(progress)
        default:
            break
        }
    }

    private func pair(address: SSHSetupAddress) {
        guard !isBusy, canSignIn else { return }
        let request: SSHPreflightClient.Request
        do {
            request = try self.request(for: address)
        } catch {
            pairMessage = SSHPreflightFailure.handshakeFailed(error.localizedDescription).message
            return
        }
        pairing = true
        pairMessage = nil
        start { [weak self] isCurrent in
            guard let self else { return }
            let message: String
            var paired = false
            do {
                let socket = try await dialSSH(address)
                let invite = try await SSHPreflightClient.mintInvite(request, socket: socket)
                (message, paired) = try await enroll(invite)
            } catch let failure as SSHPreflightFailure where failure.isHostKeyFailure {
                guard isCurrent() else { return }
                pairing = false
                phase = .failed(failure, address)
                return
            } catch {
                message = Self.pairingMessage(for: error, host: address.host)
            }
            guard isCurrent() else { return }
            pairing = false
            finishPairing(message: message, paired: paired)
        }
    }

    /// Install & Start: the installer, a fresh check, and the invite on one
    /// signed-in connection, then the same enrollment as Pair.
    private func startInstall(address: SSHSetupAddress) {
        guard !isBusy, canSignIn else { return }
        let request: SSHPreflightClient.Request
        let script: Data
        do {
            script = try SSHInstallScript.bundled()
            request = try self.request(for: address)
        } catch let failure as SSHPreflightFailure {
            install = .failed(SSHInstallProgress(), failure)
            return
        } catch {
            install = .failed(SSHInstallProgress(), .handshakeFailed(error.localizedDescription))
            return
        }
        pairMessage = nil
        install = .running(SSHInstallProgress())
        start { [weak self] isCurrent in
            guard let self else { return }
            do {
                let socket = try await dialSSH(address)
                let outcome = try await SSHPreflightClient.install(request, script: script, socket: socket) { [weak self] next in
                    guard isCurrent() else { return }
                    self?.install = .running(next)
                }
                guard isCurrent() else { return }
                let progress = install.progress ?? SSHInstallProgress()
                switch outcome {
                case .notAnswering(let report):
                    phase = .finished(report, address)
                    install = .completed(progress)
                    pairMessage = String(localized: "Setup finished, but Oppi is not answering yet. Wait a moment, then check again.")
                case .ready(let report, let invite):
                    phase = .finished(report, address)
                    install = .pairing(progress)
                    let message: String
                    var paired = false
                    do {
                        (message, paired) = try await enroll(invite)
                    } catch {
                        message = Self.pairingMessage(for: error, host: address.host)
                    }
                    guard isCurrent() else { return }
                    install = .completed(progress)
                    finishPairing(message: message, paired: paired)
                }
            } catch let failure as SSHPreflightFailure {
                guard isCurrent() else { return }
                if failure.isHostKeyFailure {
                    // The key changed since the check: the same fingerprints
                    // and Trust or Forget that Check shows, not a setup error.
                    install = .none
                    phase = .failed(failure, address)
                } else {
                    install = .failed(install.progress ?? SSHInstallProgress(), failure)
                }
            } catch {
                // Cancelled: `cancel()` already showed it stopped.
            }
        }
    }

    /// Enrolls a minted invite. Returns the message to show and whether the
    /// new server is now the selected one.
    private func enroll(_ invite: TailscalePairingInvite) async throws -> (String, Bool) {
        enrolling = true
        defer { enrolling = false }
        let enrolled = try await InviteBootstrapService.enroll(
            inviteURL: invite.inviteURL,
            serverStore: coordinator.serverStore,
            coordinator: coordinator
        ) { reason in
            await BiometricService.shared.authenticate(reason: reason)
        }
        return (String(localized: "Paired with \(enrolled.name)."), enrolled.selected)
    }

    private static func pairingMessage(for error: any Error, host: String) -> String {
        switch error {
        case let failure as SSHPreflightFailure: failure.message
        case let error as InviteBootstrapError: error.errorDescription ?? "Pairing failed. Request a fresh invite and try again."
        case is CancellationError: ""
        default: InviteBootstrapService.pairingFailureMessage(for: error, host: host)
        }
    }

    private func finishPairing(message: String, paired: Bool) {
        if !message.isEmpty { pairMessage = message }
        if paired {
            password = ""
            onPaired?()
        }
    }

    private func confirmForget() {
        guard case .failed(_, let address) = phase else { return }
        let sheet = UIAlertController(
            title: String(localized: "Forget the trusted host key?"),
            message: String(localized: "Independently verify why the host key changed before forgetting it."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Forget Trusted Key"), style: .destructive) { [weak self] _ in
            do {
                try SSHKnownHosts().forget(host: address.host, port: address.port)
                self?.phase = .idle
            } catch {
                self?.phase = .failed(.handshakeFailed(error.localizedDescription), address)
            }
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    /// `ssh-ed25519` → `ed25519`, `ecdsa-sha2-nistp256` → `ecdsa`.
    private static func keyFileStem(_ key: SSHHostKey) -> String {
        let algorithm = key.algorithm.replacingOccurrences(of: "ssh-", with: "")
        return algorithm.hasPrefix("ecdsa") ? "ecdsa" : algorithm
    }

    // MARK: - Selection and copy

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    /// Fingerprints, the signed-in user, and check details can be copied, as
    /// their text was selectable before.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource?.itemIdentifier(for: indexPath),
              let text = copyText(item) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    private func copyText(_ item: Item) -> String? {
        switch item {
        case .fingerprint(let label): fingerprintKey(label)?.fingerprint
        case .signedInAs: currentReport?.0.user
        case .result(let title): currentReport?.0.checks.first { $0.title == title }?.detail
        case .failureMessage:
            if case .failed(let failure, _) = phase { failure.message } else { nil }
        case .installError:
            if case .failed(_, let failure) = install { failure.message } else { nil }
        default: nil
        }
    }
}

/// Holds the device awake while Install & Start runs and asks iOS for the
/// usual short background grace. The embedded Tailscale node and the SSH
/// connection live in this process, so a suspended app drops the install's
/// connection; the installer is idempotent and Try Again finishes it.
@MainActor
private final class SetupKeepAwake {
    private let tasks = UIApplicationBackgroundTasks(name: "oppi.setup.install")
    private var backgroundTask: UIBackgroundTaskIdentifier?

    /// The idle timer is one reason in `ScreenAwakeController`, its only
    /// writer, so ending clears this reason and leaves other owners' alone.
    init() {
        ScreenAwakeController.shared.setSetupInstallActive(true)
        backgroundTask = tasks.begin { [weak self] in self?.endBackgroundTask() }
    }

    func end() {
        ScreenAwakeController.shared.setSetupInstallActive(false)
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard let backgroundTask else { return }
        self.backgroundTask = nil
        tasks.end(backgroundTask)
    }
}
