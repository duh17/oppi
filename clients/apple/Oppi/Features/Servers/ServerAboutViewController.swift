import UIKit

/// About This Server: connection and version facts, the voice backends the
/// server reports, and the update flow.
///
/// The page is pinned to the server and `ServerSettingsModel` it was made with
/// (Server Settings pushes it and tracks it, so a server switch closes it); it
/// shows what that model loaded and never refetches for another server. The page
/// scope is the server: every row is a fact about it, or an action on it.
@MainActor
final class ServerAboutViewController: ListScreenController<ServerAboutViewController.Section, ServerAboutViewController.Item> {
    enum Section: Hashable, Sendable { case status, voice, update }

    enum Item: Hashable, Sendable {
        case connection, uptime, piSDK, piTUI, oppiServer
        case voice(String)
        case updateDidNotReturn, updateProgress, updateRestartNeeded, updateError
        case minimumVersion, updateAvailable, updateButton, manualCommand, manualCopy
    }

    let server: PairedServer
    let model: ServerSettingsModel
    private let root: AppRootEnvironment
    private var copiedManualCommand = false

    init(model: ServerSettingsModel, server: PairedServer, root: AppRootEnvironment) {
        self.model = model
        self.server = server
        self.root = root
        super.init(
            title: String(localized: "About This Server"),
            listIdentifier: "server.about.list",
            scope: .server(server.name),
            headers: true,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    /// The pinned server as the pairing list has it now.
    private var current: PairedServer { coordinator.serverStore.server(for: server.id) ?? server }

    override func viewDidLoad() {
        super.viewDidLoad()
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task {
                // A pull reads the server again, so a `checking` or stale voice row can move on.
                await self?.model.load()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
    }

    // MARK: - What shows

    /// The rows of the Update section for what the server reports, in order.
    /// Nothing when there is nothing to say: the section is then hidden.
    nonisolated static func updateItems(
        update: ServerInfo.UpdateInfo?,
        belowMinimum: Bool,
        inFlight: Bool,
        didNotReturn: Bool
    ) -> [Item] {
        let installing = update?.isInstalling == true
        let restarting = update?.isRestarting == true
        let restartNeeded = update?.isRestartNeeded == true
        let shows = belowMinimum || update?.available == true || installing || restarting || restartNeeded
            || update?.isFailed == true || inFlight || didNotReturn
            || (update != nil && update?.isAppUpdatable == false)
        guard shows else { return [] }

        var items: [Item] = []
        if didNotReturn {
            items.append(.updateDidNotReturn)
        } else if let update {
            if installing || restarting || inFlight {
                items.append(.updateProgress)
            } else if restartNeeded {
                items.append(.updateRestartNeeded)
            } else if update.isFailed, let message = update.error, !message.isEmpty {
                items.append(.updateError)
            }
            let settled = !installing && !restarting && !restartNeeded && !inFlight
            if belowMinimum, settled { items.append(.minimumVersion) }
            if update.available, update.isAppUpdatable, !installing, !restarting, !restartNeeded {
                if ServerUpdatePresentation.availableTitle(update) != nil { items.append(.updateAvailable) }
                items.append(.updateButton)
            } else if !update.isAppUpdatable {
                items.append(contentsOf: [.manualCommand, .manualCopy])
            }
        } else if belowMinimum {
            items.append(contentsOf: [.minimumVersion, .manualCommand, .manualCopy])
        }
        return items
    }

    override func sections() -> [ListSection<Section, Item>] {
        var statusItems: [Item] = [.connection]
        if let info = model.info {
            statusItems.append(contentsOf: [.uptime, .piSDK])
            if let cli = info.piCliVersion, !cli.isEmpty { statusItems.append(.piTUI) }
            statusItems.append(.oppiServer)
        }
        var sections = [ListSection<Section, Item>(
            .status,
            header: String(localized: "Status"),
            footer: String(localized: "Pi SDK is the embedded Pi coding-agent package that runs Oppi sessions. Pi TUI is the pi command-line app installed on this server."),
            items: statusItems
        )]
        if let backends = model.info?.voiceBackends, !backends.isEmpty {
            sections.append(ListSection(
                .voice,
                header: String(localized: "Voice"),
                footer: String(localized: "A voice feature shows in chats only while its backend is ready."),
                items: backends.map { .voice($0.feature) }
            ))
        }
        if let info = model.info {
            let updateRows = Self.updateItems(
                update: info.update,
                belowMinimum: ServerReleaseVersion.isBelowMinimum(info.version),
                inFlight: model.updateInFlight,
                didNotReturn: model.updateDidNotReturn
            )
            if !updateRows.isEmpty {
                sections.append(ListSection(
                    .update,
                    header: String(localized: "Update"),
                    footer: ServerUpdatePresentation.footer(info.update),
                    items: updateRows
                ))
            }
        }
        return sections
    }

    private func backend(_ feature: String) -> ServerInfo.VoiceBackend? {
        model.info?.voiceBackends?.first { $0.feature == feature }
    }

    /// The command to run by hand: the server's own, else the generic install.
    private var manualCommandText: String {
        model.info?.update?.manualCommand ?? ServerUpdatePresentation.fallbackManualCommand
    }

    /// Sessions on this server that a restart would interrupt.
    private var busySessionTitles: [String] {
        guard let store = coordinator.connection(for: server.id)?.sessionStore else { return [] }
        return store.sessions(forServer: server.id)
            .filter { $0.status == .starting || $0.status.isRunning }
            .map(\.displayTitle)
    }

    override func inputs(of item: Item) -> AnyHashable {
        let info = model.info
        switch item {
        case .connection:
            return AnyHashable(ServerSettingsViewController.connectionStatusTitle(for: current, coordinator: coordinator))
        case .uptime: return AnyHashable(info?.uptimeLabel ?? "")
        case .piSDK: return AnyHashable(info?.piVersion ?? "")
        case .piTUI: return AnyHashable(info?.piCliVersion ?? "")
        case .oppiServer: return AnyHashable(info?.version ?? "")
        case .voice(let feature): return AnyHashable(String(describing: backend(feature)))
        case .updateDidNotReturn: return AnyHashable(0)
        case .manualCopy: return AnyHashable(copiedManualCommand)
        case .updateProgress:
            return AnyHashable(String(describing: info?.update))
        case .updateRestartNeeded: return AnyHashable(info?.update?.isSourceLink ?? false)
        case .updateError: return AnyHashable(info?.update?.error ?? "")
        case .minimumVersion: return AnyHashable(String(describing: info?.update))
        case .updateAvailable: return AnyHashable(info?.update.flatMap(ServerUpdatePresentation.availableTitle) ?? "")
        case .updateButton:
            return AnyHashable([
                AnyHashable(String(describing: info?.update)),
                AnyHashable(model.updateInFlight),
                AnyHashable(busySessionTitles),
            ])
        case .manualCommand: return AnyHashable(manualCommandText)
        }
    }

    // MARK: - Cells

    private lazy var voiceRow = UICollectionView.CellRegistration<ServerAboutVoiceCell, Item> { [weak self] cell, _, item in
        guard let self, case .voice(let feature) = item, let backend = backend(feature) else { return }
        cell.configure(backend, identifier: "server.about.voice.\(feature)")
    }

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        configureState(cell, item: item)
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        configureAction(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = (voiceRow, stateRow, actionRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .voice:
            collectionView.dequeueConfiguredReusableCell(using: voiceRow, for: indexPath, item: item)
        case .updateDidNotReturn, .updateProgress, .updateRestartNeeded, .updateError:
            collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .updateButton, .manualCopy:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .connection, .uptime, .piSDK, .piTUI, .oppiServer, .minimumVersion, .updateAvailable, .manualCommand:
            super.dequeue(item, at: indexPath)
        }
    }

    /// The facts: a title and its value, or a line of text.
    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        let info = model.info
        var config = content(.info)
        switch item {
        case .connection:
            config.text = String(localized: "Connection")
            config.secondaryText = ServerSettingsViewController.connectionStatusTitle(for: current, coordinator: coordinator)
            cell.accessibilityIdentifier = "server.about.connection"
        case .uptime:
            config.text = String(localized: "Uptime")
            config.secondaryText = info?.uptimeLabel
            cell.accessibilityIdentifier = "server.about.uptime"
        case .piSDK:
            config.text = String(localized: "Pi SDK")
            config.secondaryText = info?.piVersion
            cell.accessibilityIdentifier = "server.about.piSDK"
        case .piTUI:
            config.text = String(localized: "Pi TUI")
            config.secondaryText = info?.piCliVersion
            cell.accessibilityIdentifier = "server.about.piTUI"
        case .oppiServer:
            config.text = String(localized: "Oppi Server")
            config.secondaryText = info?.version
            cell.accessibilityIdentifier = "server.about.version"
        case .minimumVersion:
            config = content(.subtitle)
            config.text = ServerUpdatePresentation.minimumVersionNoticeTitle
            config.textProperties.numberOfLines = 0
            config.secondaryText = info?.update.flatMap {
                ServerUpdatePresentation.minimumVersionUnpublishedDetail(latestVersion: $0.latestVersion, isSourceLink: $0.isSourceLink)
            }
            config.secondaryTextProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "server.update.minimumVersion"
        case .updateAvailable:
            config = content(.plain)
            config.text = info?.update.flatMap(ServerUpdatePresentation.availableTitle)
            config.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "server.update.available"
        case .manualCommand:
            config = content(.plain)
            config.text = manualCommandText
            config.textProperties.font = UIFont.scaledMonospaced(.footnote)
            config.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "server.update.manualCommand"
        default:
            break
        }
        cell.contentConfiguration = config
    }

    private func configureState(_ cell: SettingsStateRowCell, item: Item) {
        let update = model.info?.update
        switch item {
        case .updateDidNotReturn:
            cell.configure(
                .failure(String(localized: "Server did not come back. Nothing was rolled back. Check the machine it runs on."), retry: nil),
                identifier: "server.update.didNotReturn"
            )
        case .updateProgress:
            let text = update.map {
                ServerUpdatePresentation.progressLabel(status: $0.status, restartMode: $0.restartMode, isSourceLink: $0.isSourceLink)
            } ?? String(localized: "Updating…")
            cell.configure(.loading(text), identifier: "server.update.progress")
        case .updateRestartNeeded:
            let installed = update?.isSourceLink == true ? String(localized: "Built") : String(localized: "Installed")
            cell.configure(
                .message(String(localized: "\(installed). Restart this Oppi server to use the new version.")),
                identifier: "server.update.restartNeeded"
            )
        case .updateError:
            cell.configure(.failure(update?.error ?? "", retry: nil), identifier: "server.update.error")
        default:
            break
        }
    }

    private func configureAction(_ cell: SettingsActionRowCell, item: Item) {
        switch item {
        case .updateButton:
            guard let update = model.info?.update else { return }
            let actionTitle = ServerUpdatePresentation.actionTitle(update)
            cell.configure(
                title: actionTitle,
                identifier: "server.update.button",
                isEnabled: !model.updateInFlight,
                confirmation: .init(
                    title: ServerUpdatePresentation.confirmationTitle(update),
                    message: ServerUpdatePresentation.confirmationMessage(busySessionTitles: busySessionTitles),
                    actionTitle: actionTitle
                )
            ) { [weak self] in
                guard let model = self?.model else { return }
                Task { await model.startServerUpdate() }
            }
        case .manualCopy:
            cell.configure(
                title: copiedManualCommand ? String(localized: "Copied") : String(localized: "Copy Command"),
                systemImage: copiedManualCommand ? "checkmark" : "doc.on.doc",
                identifier: "server.update.manualCopy"
            ) { [weak self] in
                guard let self else { return }
                UIPasteboard.general.string = manualCommandText
                copiedManualCommand = true
                setNeedsUpdateProperties()
            }
        default:
            break
        }
    }

    // MARK: - Copy

    /// Long press copies the value a row shows.
    override func copyText(of item: Item) -> String? {
        switch item {
        case .connection: ServerSettingsViewController.connectionStatusTitle(for: current, coordinator: coordinator)
        case .uptime: model.info?.uptimeLabel
        case .piSDK: model.info?.piVersion
        case .piTUI: model.info?.piCliVersion
        case .oppiServer: model.info?.version
        case .voice(let feature): backend(feature).flatMap { $0.detail ?? $0.target }
        case .manualCommand: manualCommandText
        case .minimumVersion, .updateAvailable, .updateButton, .manualCopy,
             .updateDidNotReturn, .updateProgress, .updateRestartNeeded, .updateError: nil
        }
    }
}

/// How About This Server shows a voice backend's state. Generic over features and providers:
/// the label, target, and detail come from the server as sent.
struct VoiceBackendPresentation: Equatable {
    let title: String
    let symbol: String
    /// The feature shows in chats.
    let isAvailable: Bool
    /// Configured but blocked on something the owner can fix (start the backend, sign in).
    let needsAttention: Bool

    init(_ health: ServerInfo.VoiceBackend.Health) {
        switch health {
        case .ready:
            self.init(title: String(localized: "Ready"), symbol: "checkmark.circle.fill", isAvailable: true)
        case .checking:
            self.init(title: String(localized: "Checking"), symbol: "clock")
        case .unreachable:
            self.init(title: String(localized: "Not reachable"), symbol: "exclamationmark.triangle", needsAttention: true)
        case .needsCredentials:
            self.init(title: String(localized: "Needs sign-in"), symbol: "key", needsAttention: true)
        case .notConfigured:
            self.init(title: String(localized: "Not set up"), symbol: "minus.circle")
        case .unknown:
            self.init(title: String(localized: "Not available"), symbol: "questionmark.circle")
        }
    }

    private init(title: String, symbol: String, isAvailable: Bool = false, needsAttention: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.isAvailable = isAvailable
        self.needsAttention = needsAttention
    }
}

// MARK: - Voice cell

/// One voice feature: its label, its state with a symbol, the target it uses, and
/// why it is in that state. Read-only; the lines stack, so a large text size gives
/// each its own width. One accessibility element that reads the label, then the
/// state, target, and detail.
final class ServerAboutVoiceCell: UICollectionViewListCell {
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let stateLabel = UILabel()
    private let targetLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for label in [titleLabel, stateLabel, targetLabel, detailLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(label)
        }
        titleLabel.font = .preferredFont(forTextStyle: .body)
        stateLabel.font = .preferredFont(forTextStyle: .footnote)
        targetLabel.font = UIFont.scaledMonospaced(.footnote)
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ backend: ServerInfo.VoiceBackend, identifier: String) {
        let style = SettingsStyle.current
        let palette = ThemeRuntimeState.currentPalette()
        let presentation = VoiceBackendPresentation(backend.health)
        let tint = presentation.isAvailable
            ? UIColor(palette.green)
            : presentation.needsAttention ? style.warning : style.value
        titleLabel.text = backend.label
        titleLabel.textColor = style.title
        let attachment = NSTextAttachment(image: UIImage(systemName: presentation.symbol)?.withTintColor(tint) ?? UIImage())
        let state = NSMutableAttributedString(attachment: attachment)
        state.append(NSAttributedString(string: " " + presentation.title))
        state.addAttributes([.foregroundColor: tint], range: NSRange(location: 0, length: state.length))
        stateLabel.attributedText = state
        let target = backend.target.flatMap { $0.isEmpty ? nil : $0 }
        let detail = backend.detail.flatMap { $0.isEmpty ? nil : $0 }
        targetLabel.text = target
        targetLabel.textColor = style.value
        targetLabel.isHidden = target == nil
        detailLabel.text = detail
        detailLabel.textColor = style.value
        detailLabel.isHidden = detail == nil
        accessibilityIdentifier = identifier
        accessibilityLabel = backend.label
        accessibilityValue = [presentation.title, target, detail].compactMap { $0 }.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }
}
