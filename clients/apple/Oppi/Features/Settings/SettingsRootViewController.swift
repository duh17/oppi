import UIKit

/// App Settings root: paired servers, then one row per focused section page.
///
/// Every control lives on a section page (`Settings*Page`); this screen only
/// shows each page's current value so the index reads at a glance. Rows are
/// real buttons, so a tap, a VoiceOver activation, and `app.buttons[id]` all run
/// the row's own push. The index reads its summaries in `updateProperties()`,
/// which Observation re-runs when a store it read changes, and again whenever
/// this screen comes back from a page that wrote a preference.
@MainActor
final class SettingsRootViewController: UIViewController, UICollectionViewDelegate {
    private let root: AppRootEnvironment

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var navigation: AppNavigation { root.navigation }
    private var serverStore: ServerStore { root.coordinator.serverStore }

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()
    private var cacheSizeText = ""

    private enum Section: Hashable { case servers, pages }

    private enum Item: Hashable {
        case server(String)
        case addServer
        case general, appearance, text, editor, chat, sessions, voice, tailscale
        case sshTerminal, privacy, experiments, storage
    }

    /// The rows of the pages section, in the order Settings shows them.
    private static let pages: [Item] = [
        .general, .appearance, .text, .editor, .chat, .sessions,
        .voice, .tailscale, .sshTerminal, .privacy, .experiments, .storage,
    ]

    init(root: AppRootEnvironment) {
        self.root = root
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = String(localized: "Settings")
        // App Settings is the root of its pages, so it keeps the large title
        // the shell used to give it. `applyTitleDisplayMode` drops it where the
        // system puts the bar on a vertical edge.
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "settings.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (self: Self, _) in
                self.setNeedsUpdateProperties()
            }
        }
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A page writes straight to preferences, so the summary it feeds is
        // re-read on the way back. The cache size is measured here too: Clear
        // Local Cache on the Storage page writes nothing this screen observes.
        refreshCacheSize()
        applyTitleDisplayMode()
        setNeedsUpdateProperties()
    }

    /// Measures the local cache again and redraws only when it moved.
    private func refreshCacheSize() {
        Task { [weak self] in
            let size = await SettingsStoragePage.formattedCacheSize()
            guard let self, cacheSizeText != size else { return }
            cacheSizeText = size
            setNeedsUpdateProperties()
        }
    }

    /// Same rule as `HostedScreenController.applyTitleDisplayMode`: a large
    /// title shows nothing where the system puts the bar on a vertical edge,
    /// so the title stays inline there. `SystemVerticalBar` reads the trait the
    /// chat's rail items use, and a trait change re-runs this pass.
    private func applyTitleDisplayMode() {
        let large = !SystemVerticalBar.traitIsActive(traitCollection)
        // The bar's own flag, not the item's mode, is what makes a large title
        // draw; it has to be set on the first pass too, where the mode already
        // matches the one `init` set.
        if large { navigationController?.navigationBar.prefersLargeTitles = true }
        let mode: UINavigationItem.LargeTitleDisplayMode = large ? .always : .never
        guard navigationItem.largeTitleDisplayMode != mode else { return }
        navigationItem.largeTitleDisplayMode = mode
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Read every value so any change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        _ = navigation.sessionThreadsEnabled
        _ = (AppPreferences.Voice.engineMode, FontPreferences.codeFont)
        applyTitleDisplayMode()
        applySnapshot()
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.servers])
        snapshot.appendItems(serverStore.servers.map { .server($0.id) } + [.addServer], toSection: .servers)
        snapshot.appendSections([.pages])
        snapshot.appendItems(Self.pages, toSection: .pages)
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        // The theme is in the key: a light/dark or theme change repaints every
        // row, which otherwise keeps the colors it was configured with.
        let themeID = ThemeRuntimeState.currentThemeID()
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
    }

    /// The values a row is drawn from.
    private func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .server(let id):
            guard let server = serverStore.servers.first(where: { $0.id == id }) else {
                return AnyHashable(["missing", id])
            }
            let state = serverBadge(server)
            let tint = state.uiColor(ComposerThemeColors(palette: ThemeRuntimeState.currentPalette()))
            return AnyHashable([
                AnyHashable(server.name),
                AnyHashable(server.resolvedBadgeIcon.symbolName),
                AnyHashable(state.title),
                AnyHashable(tint),
                AnyHashable(lockWord(ScopedLockService.shared.badge(.server(id)))),
            ])
        case .addServer, .general, .sessions, .chat, .privacy, .sshTerminal:
            return AnyHashable(0)
        case .appearance:
            return AnyHashable(themeSummary)
        case .text:
            return AnyHashable(FontPreferences.codeFont.displayName)
        case .editor:
            return AnyHashable(CodeEditorPreferences.shared.keybindings.label)
        case .voice:
            return AnyHashable(AppPreferences.Voice.engineMode.label)
        case .tailscale:
            return AnyHashable(tailscaleSummary)
        case .experiments:
            return AnyHashable(experimentsSummary)
        case .storage:
            return AnyHashable(cacheSizeText)
        }
    }

    private func installDataSource() {
        let row = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            let palette = ThemeRuntimeState.currentPalette()
            cell.configure(
                title: title(of: item),
                systemImage: systemImage(of: item),
                value: value(of: item),
                showsDisclosure: item != .addServer,
                // An action row, not a destination: it reads in the accent
                // color the Add Server button always had.
                titleColor: item == .addServer ? UIColor(palette.blue) : UIColor(palette.fg),
                identifier: accessibilityIdentifier(of: item)
            ) { [weak self] in self?.open(item) }
        }
        let server = UICollectionView.CellRegistration<SettingsServerRowCell, Item> { [weak self] cell, _, item in
            guard let self, case .server(let id) = item,
                  let paired = serverStore.servers.first(where: { $0.id == id }) else { return }
            cell.configure(
                name: paired.name,
                state: serverBadge(paired),
                icon: paired.resolvedBadgeIcon,
                lock: ScopedLockService.shared.badge(.server(paired.id)),
                identifier: "settings.server.\(paired.id)"
            ) { [weak self] in self?.openServerSettings(paired) }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .servers
                ? String(localized: "Servers")
                : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .server:
                collectionView.dequeueConfiguredReusableCell(using: server, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    // MARK: - Rows

    private func serverBadge(_ server: PairedServer) -> ServerBadgeConnectionState {
        HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
    }

    /// The lock state a server row draws, as the value it is compared by.
    private func lockWord(_ state: ScopedLockState) -> String {
        switch state {
        case .none: ""
        case .locked: String(localized: "Locked")
        case .unlocked: String(localized: "Unlocked")
        }
    }

    private func title(of item: Item) -> String {
        switch item {
        case .server: ""
        case .addServer: String(localized: "Add Server")
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .text: String(localized: "Text")
        case .editor: String(localized: "Editor")
        case .chat: String(localized: "Chat")
        case .sessions: String(localized: "Sessions")
        case .voice: String(localized: "Voice & Dictation")
        case .tailscale: String(localized: "Tailscale")
        case .sshTerminal: String(localized: "SSH Hosts")
        case .privacy: String(localized: "Privacy & Security")
        case .experiments: String(localized: "Experiments")
        case .storage: String(localized: "Storage & About")
        }
    }

    private func systemImage(of item: Item) -> String {
        switch item {
        case .server: "desktopcomputer"
        case .addServer: "plus"
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .text: "textformat.size"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .chat: "bubble.left.and.text.bubble.right"
        case .sessions: "rectangle.stack"
        case .voice: "mic"
        case .tailscale: "network"
        case .sshTerminal: "terminal"
        case .privacy: "hand.raised"
        case .experiments: "flask"
        case .storage: "internaldrive"
        }
    }

    private func value(of item: Item) -> String? {
        switch item {
        case .appearance: themeSummary
        case .text: FontPreferences.codeFont.displayName
        case .editor: CodeEditorPreferences.shared.keybindings.label
        case .voice: AppPreferences.Voice.engineMode.label
        case .tailscale: tailscaleSummary
        case .experiments: experimentsSummary
        case .storage: cacheSizeText
        default: nil
        }
    }

    private func accessibilityIdentifier(of item: Item) -> String {
        switch item {
        case .server: "settings.server"
        case .addServer: "settings.addServer"
        case .general: "settings.row.general"
        case .appearance: "settings.row.appearance"
        case .text: "settings.row.text"
        case .editor: "settings.row.editor"
        case .chat: "settings.row.chat"
        case .sessions: "settings.row.sessions"
        case .voice: "settings.row.voice"
        case .tailscale: "settings.tailscale"
        case .sshTerminal: "settings.sshTerminal"
        case .privacy: "settings.row.privacy"
        case .experiments: "settings.row.experiments"
        case .storage: "settings.row.storage"
        }
    }

    // MARK: - Summaries

    private var themeSummary: String {
        switch root.themeStore.mode {
        case .manual: root.themeStore.manualThemeID.displayName
        case .system: ThemeMode.system.displayName
        }
    }

    private var tailscaleSummary: String {
        TailnetSettingsViewController.statusLabel(TailnetNodeController.shared.state)
    }

    private var experimentsSummary: String {
        let count = SettingsExperimentsViewController.enabledCount(
            sessionThreadsEnabled: navigation.sessionThreadsEnabled
        )
        return "\(count) on"
    }

    // MARK: - Actions

    /// A row's own push. The SwiftUI pages are named inside a closure, so this
    /// UIKit file adds no SwiftUI import while they still go through the router.
    private func open(_ item: Item) {
        let navigator = ScreenNavigator.forUIKitScreen(self, root: root)
        switch item {
        case .addServer:
            presentAddServer()
        case .general:
            navigator.push { SettingsGeneralPage() }
        case .appearance:
            navigator.push { SettingsAppearancePage() }
        case .text:
            navigator.push { SettingsTextPage() }
        case .editor:
            navigator.push(SettingsEditorViewController())
        case .chat:
            navigator.push(SettingsChatViewController())
        case .sessions:
            navigator.push { SettingsSessionsPage() }
        case .voice:
            navigator.push { SettingsVoicePage() }
        case .tailscale:
            navigator.push(TailnetSettingsViewController(coordinator: coordinator))
        case .sshTerminal:
            navigator.push(SSHTerminalHostListViewController())
        case .privacy:
            navigator.push { SettingsPrivacyPage() }
        case .experiments:
            navigator.push(SettingsExperimentsViewController(navigation: navigation))
        case .storage:
            navigator.push { SettingsStoragePage() }
        case .server:
            break
        }
    }

    /// Server Settings follows the app's active host, so opening another paired
    /// server's settings first makes it the active one, as the host switcher
    /// does. A locked server asks first; cancel stays in Settings.
    private func openServerSettings(_ server: PairedServer) {
        let coordinator = coordinator
        let navigation = navigation
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

    private func presentAddServer() {
        Router.present(
            HostFactory.screen(root: root, bars: ScreenBars()) { OnboardingView(mode: .addServer) },
            presentation: .sheet,
            from: self
        )
    }

    /// Rows push themselves; selecting one runs the same owner action as its
    /// button, so the two can never diverge.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        if case .server(let id) = item, let server = serverStore.servers.first(where: { $0.id == id }) {
            openServerSettings(server)
        } else {
            open(item)
        }
    }
}

/// A settings index row: a theme-blue symbol, a Title Case title, an optional
/// current-value summary, and the system disclosure chevron. The whole row is
/// one button, so a tap, a VoiceOver activation, and `app.buttons[id]` all run
/// the row's push.
final class SettingsIndexRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [iconView, titleLabel, valueLabel, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityTraits = .button
        // The labels paint the row; the button above them is its one accessible
        // element, so the row reads as a single control.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // A grouped list's separator starts where the row's title does.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        systemImage: String,
        value: String?,
        showsDisclosure: Bool,
        titleColor: UIColor,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        iconView.image = UIImage(systemName: systemImage)
        iconView.tintColor = UIColor(palette.blue)
        titleLabel.text = title
        titleLabel.textColor = titleColor
        valueLabel.text = value
        valueLabel.textColor = UIColor(palette.comment)
        valueLabel.isHidden = value == nil
        accessories = showsDisclosure ? [.disclosureIndicator()] : []
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = value
        if let tapAction { button.removeAction(tapAction, for: .touchUpInside) }
        let tap = UIAction { _ in action() }
        tapAction = tap
        button.addAction(tap, for: .touchUpInside)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        iconView.image = nil
        titleLabel.text = nil
        valueLabel.text = nil
        isHighlighted = false
    }
}

/// A row's overlay button. It is transparent over the row's labels, so the
/// cell's own highlight never fires; this hands the press to the cell, which
/// paints the pressed fill.
final class SettingsRowButton: UIButton {
    var onHighlight: ((Bool) -> Void)?

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            onHighlight?(isHighlighted)
        }
    }
}

/// A paired server row: its badge in the connection state's tint, the server's
/// name, its lock badge, and the state word under it, like the SwiftUI row the
/// host switcher drew.
final class SettingsServerRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let badge = SettingsServerBadgeView()
    private let nameLabel = UILabel()
    private let lockView = UIImageView()
    private let stateLabel = UILabel()
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [badge, nameLabel, lockView, stateLabel, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        // A server row pushes Server Settings, so it carries the same
        // disclosure chevron as every other row that pushes.
        accessories = [.disclosureIndicator()]
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lockView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
        lockView.contentMode = .scaleAspectFit
        lockView.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.font = .preferredFont(forTextStyle: .footnote)
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.numberOfLines = 0
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            lockView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            lockView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            lockView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            stateLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            stateLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // The separator starts where the server's name does, past its badge.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        name: String,
        state: ServerBadgeConnectionState,
        icon: ServerBadgeIcon,
        lock: ScopedLockState,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        // The state's own color, in UIKit (`ServerBadgeConnectionState.uiColor`).
        badge.apply(icon: icon, tint: state.uiColor(ComposerThemeColors(palette: palette)))
        nameLabel.text = name
        nameLabel.textColor = UIColor(palette.fg)
        stateLabel.text = state.title
        stateLabel.textColor = UIColor(palette.comment)
        switch lock {
        case .none:
            lockView.image = nil
            button.accessibilityValue = state.title
        case .locked:
            lockView.image = UIImage(systemName: "lock.fill")
            lockView.tintColor = UIColor(palette.comment)
            button.accessibilityValue = "\(state.title), \(String(localized: "Locked"))"
        case .unlocked:
            lockView.image = UIImage(systemName: "lock.open.fill")
            lockView.tintColor = UIColor(palette.comment)
            button.accessibilityValue = "\(state.title), \(String(localized: "Unlocked"))"
        }
        lockView.isAccessibilityElement = false
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = name
        if let tapAction { button.removeAction(tapAction, for: .touchUpInside) }
        let tap = UIAction { _ in action() }
        tapAction = tap
        button.addAction(tap, for: .touchUpInside)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        nameLabel.text = nil
        stateLabel.text = nil
        lockView.image = nil
        isHighlighted = false
    }
}

/// A server's mark on a tinted circle: the UIKit form of `RuntimeBadge`.
final class SettingsServerBadgeView: UIView {
    private let symbol = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.55),
            symbol.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55),
        ])
        layer.masksToBounds = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(icon: ServerBadgeIcon, tint: UIColor) {
        let name = UIImage(systemName: icon.symbolName) != nil ? icon.symbolName : "desktopcomputer"
        symbol.image = UIImage(systemName: name)
        symbol.tintColor = tint
        backgroundColor = tint.withAlphaComponent(0.16)
        layer.borderColor = tint.withAlphaComponent(0.5).cgColor
        layer.borderWidth = 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}
