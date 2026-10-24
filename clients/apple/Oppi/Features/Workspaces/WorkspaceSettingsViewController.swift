import UIKit

/// Workspace Settings root: a summary of the workspace that opens Details, one
/// index row per focused page, Show Changes in Chat, Lock Workspace, Edit with
/// Oppi, and Delete Workspace.
///
/// Toggles and pickers apply as soon as they change. Only the Details page,
/// the Instructions editor, and the Network Access hosts editor are drafts
/// with their own Save. Data for every page comes from one
/// `WorkspaceSettingsModel`, so pushed pages never refetch. Each pushed page
/// starts from the app root (the active server), so it gets this screen's
/// server scope explicitly.
///
/// The screen is its own lock gate and server switch: while the workspace is
/// locked it shows the lock cover and nothing of the workspace; unlocked, it
/// makes the workspace's server the active one ("Connecting…") and then shows
/// the list. Rows are real buttons, so a tap, a VoiceOver activation, and
/// `app.buttons[id]` all run the row's own action.
@MainActor
final class WorkspaceSettingsViewController: UIViewController, UICollectionViewDelegate {
    let root: AppRootEnvironment
    private let serverId: String
    private let workspace: Workspace
    private let model: WorkspaceSettingsModel
    private let locks = ScopedLockService.shared

    /// Closes this screen after Delete Workspace or Edit with Oppi when it was
    /// pushed onto another screen. As a shell route it leaves through the
    /// `AppNavigation` change that follows instead.
    var onLeave: (() -> Void)?
    /// The split detail root's Done: returns the column to the workspace's
    /// sessions. Nil elsewhere.
    var onDone: (() -> Void)? {
        didSet { setNeedsUpdateProperties() }
    }
    var showsSidebarToggle = false {
        didSet { setNeedsUpdateProperties() }
    }

    /// The workspace's server once it is ready.
    private var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var connectTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var isOnScreen = false
    /// Set on each appearance and by a lock; the unlocked screen spends it on
    /// one server switch.
    private var needsConnect: Bool
    private var shown: Shown?
    private var lockCover: ScopedLockCoverViewController?
    private weak var editSheet: UIViewController?
    private var sidebarToggle: UIBarButtonItem?
    private var doneItem: UIBarButtonItem?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()
    /// Bumped when a toggle's write ends, so its switch is redrawn from the
    /// stored value even where that value did not change (a cancelled unlock,
    /// a failed write).
    private var toggleRevision = 0

    private enum Shown: Equatable { case locked, connecting, list }

    private enum Section: Hashable {
        case summary, pages, trust, git, lock, oppi, error, delete
    }

    private enum Item: Hashable {
        case summary
        case instructions, skills, extensions, mcpServers, dictionary, networkAccess
        case projectTrust
        case gitStatus
        case lock
        case editWithOppi
        case error
        case delete
    }

    /// `serverId`: the workspace's server, made the active one before the
    /// list shows.
    init(serverId: String, workspace: Workspace, root: AppRootEnvironment) {
        self.serverId = serverId
        self.workspace = workspace
        self.root = root
        model = WorkspaceSettingsModel(seed: workspace)
        needsConnect = true
        collectionView = Self.makeCollectionView()
        super.init(nibName: nil, bundle: nil)
        setUp()
    }

    #if DEBUG
    /// Screenshot harness entry: a fixture model on a ready connection, with
    /// no server switch.
    init(workspace: Workspace, model: WorkspaceSettingsModel, connection: ServerConnection, root: AppRootEnvironment) {
        serverId = connection.currentServerId ?? ""
        self.workspace = workspace
        self.root = root
        self.model = model
        self.connection = connection
        needsConnect = false
        collectionView = Self.makeCollectionView()
        super.init(nibName: nil, bundle: nil)
        setUp()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private static func makeCollectionView() -> UICollectionView {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        return UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    private func setUp() {
        traitOverrides.appRootEnvironment = root
        title = String(localized: "Workspace Settings")
        navigationItem.largeTitleDisplayMode = .never
    }

    private var current: Workspace { model.workspace }

    private var lockTarget: ScopedLockTarget {
        .workspace(serverId: serverId, workspaceId: workspace.id)
    }

    private var lockScope: ScopedLockScope? {
        guard let connection else { return nil }
        return (connection.currentServerId ?? connection.workspaceStore.activeServerId)
            .map { .workspace(serverId: $0, workspaceId: workspace.id) }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "workspace.edit.list"
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
        navigationController?.setToolbarHidden(true, animated: animated)
        // The lock footer names the App Lock method, which Privacy changes.
        setNeedsUpdateProperties()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        needsConnect = connection == nil || needsConnect
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        connectTask?.cancel()
        connectTask = nil
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        if locks.isLocked(lockTarget) {
            needsConnect = true
            show(.locked)
        } else {
            if needsConnect, isOnScreen {
                needsConnect = false
                connect()
            }
            if connection == nil {
                show(.connecting)
            } else {
                show(.list)
                applySnapshot()
            }
        }
        updateBar()
    }

    /// Makes the workspace's server the active one, then binds the model to
    /// it and loads the Pi resources (a repeat load is a no-op). A shown list
    /// stays while the switch runs again.
    private func connect() {
        connectTask?.cancel()
        let coordinator = root.coordinator
        let serverId = serverId
        connectTask = Task { [weak self] in
            guard await coordinator.switchToServerReady(serverId), !Task.isCancelled,
                  let ready = coordinator.connection(for: serverId), let self else { return }
            connection = ready
            attachModel(to: ready)
        }
    }

    private func attachModel(to connection: ServerConnection) {
        model.attach(connection: connection, workspace: workspace)
        loadTask?.cancel()
        let model = model
        loadTask = Task { await model.loadPiResourcesIfNeeded() }
    }

    // MARK: - Content

    private func show(_ next: Shown) {
        guard shown != next else { return }
        shown = next
        collectionView.isHidden = next != .list
        if next != .locked, let lockCover {
            lockCover.willMove(toParent: nil)
            lockCover.view.removeFromSuperview()
            lockCover.removeFromParent()
            self.lockCover = nil
        }
        switch next {
        case .locked:
            connectTask?.cancel()
            connectTask = nil
            let cover = ScopedLockCoverViewController(target: lockTarget, title: workspace.name)
            addChild(cover)
            cover.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cover.view)
            NSLayoutConstraint.activate([
                cover.view.topAnchor.constraint(equalTo: view.topAnchor),
                cover.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                cover.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                cover.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            cover.didMove(toParent: self)
            lockCover = cover
            contentUnavailableConfiguration = nil
        case .connecting:
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = String(localized: "Connecting…")
            loading.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = loading
        case .list:
            contentUnavailableConfiguration = nil
        }
    }

    private func updateBar() {
        var leading: [UIBarButtonItem] = []
        if showsSidebarToggle {
            let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
            sidebarToggle = toggle
            WorkspaceSplitSidebarToggle.sync(toggle, root: root)
            leading.append(toggle)
        }
        if let onDone {
            let item = doneItem ?? UIBarButtonItem(systemItem: .done)
            item.title = String(localized: "Done")
            item.primaryAction = UIAction(title: String(localized: "Done")) { _ in onDone() }
            item.accessibilityIdentifier = "workspace.edit.done"
            doneItem = item
            leading.append(item)
        }
        ControlScreenList.setBarItems(trailing: [], leading: leading, on: navigationItem)
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary])
        snapshot.appendItems([.summary], toSection: .summary)
        var pages: [Item] = [.instructions, .skills, .extensions, .mcpServers, .dictionary]
        if model.isSandbox { pages.append(.networkAccess) }
        snapshot.appendSections([.pages])
        snapshot.appendItems(pages, toSection: .pages)
        if model.projectTrust != nil {
            snapshot.appendSections([.trust])
            snapshot.appendItems([.projectTrust], toSection: .trust)
        }
        snapshot.appendSections([.git])
        snapshot.appendItems([.gitStatus], toSection: .git)
        if lockScope != nil {
            snapshot.appendSections([.lock])
            snapshot.appendItems([.lock], toSection: .lock)
        }
        if connection?.apiClient != nil {
            snapshot.appendSections([.oppi])
            snapshot.appendItems([.editWithOppi], toSection: .oppi)
        }
        if model.error != nil {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error], toSection: .error)
        }
        snapshot.appendSections([.delete])
        snapshot.appendItems([.delete], toSection: .delete)

        let shown = Set(dataSource.snapshot().itemIdentifiers)
        // The theme is in the key: a light/dark or theme change repaints every
        // row, which otherwise keeps the colors it was configured with.
        let themeID = ThemeRuntimeState.currentThemeID()
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
        refreshFooters()
    }

    /// Every value a row is drawn from, read here so any change re-runs this
    /// pass and reconfigures only the rows it touches.
    private func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .summary:
            return AnyHashable([
                AnyHashable(current.name),
                AnyHashable(current.icon),
                AnyHashable(current.runtime),
                AnyHashable(folderSummary),
                AnyHashable(lockWord),
            ])
        case .instructions: return AnyHashable(model.instructionsSummary)
        case .skills: return AnyHashable(model.skillsSummary)
        case .extensions: return AnyHashable(model.extensionsSummary)
        case .mcpServers: return AnyHashable(model.mcpSummary)
        case .dictionary: return AnyHashable(0)
        case .networkAccess: return AnyHashable(model.networkAccessSummary)
        case .projectTrust: return AnyHashable(model.projectTrust?.title)
        case .gitStatus:
            return AnyHashable([
                AnyHashable(model.gitStatusEnabled),
                AnyHashable(model.isSavingGitStatus || model.isDeleting),
                AnyHashable(toggleRevision),
            ])
        case .lock:
            return AnyHashable([
                AnyHashable(lockScope.map(locks.isFlagged) ?? false),
                AnyHashable(locks.isAuthenticating),
                AnyHashable(toggleRevision),
            ])
        case .editWithOppi: return AnyHashable(0)
        case .error: return AnyHashable(model.error)
        case .delete: return AnyHashable([model.isDeleting, !model.isWriteQueueIdle])
        }
    }

    private var folderSummary: String {
        if let folder = model.savedFolder { return folder }
        return model.isSandbox ? String(localized: "Sandbox") : String(localized: "No folder")
    }

    private var lockWord: String { locks.badge(lockTarget).accessibilityWord }

    // MARK: - Data source

    private func installDataSource() {
        let summary = UICollectionView.CellRegistration<WorkspaceSettingsSummaryCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            let palette = ThemeRuntimeState.currentPalette()
            cell.configure(
                workspace: current,
                folder: folderSummary,
                lock: locks.badge(lockTarget),
                colors: ComposerThemeColors(palette: palette),
                assetCache: connection?.iconAssetCache,
                identifier: "workspace.edit.details"
            ) { [weak self] in self?.perform(.summary) }
        }
        let index = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            let palette = ThemeRuntimeState.currentPalette()
            let row = indexRow(item)
            cell.configure(
                title: row.title,
                systemImage: row.systemImage,
                value: row.value,
                showsDisclosure: true,
                titleColor: UIColor(palette.fg),
                identifier: row.identifier
            ) { [weak self] in self?.perform(item) }
        }
        let toggle = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureToggle(cell, item: item)
        }
        let info = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureInfo(cell, item: item)
        }
        let action = UICollectionView.CellRegistration<SSHTerminalActionCell, Item> { [weak self] cell, _, item in
            self?.configureAction(cell, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            self?.configureFooter(view, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .summary:
                collectionView.dequeueConfiguredReusableCell(using: summary, for: indexPath, item: item)
            case .instructions, .skills, .extensions, .mcpServers, .dictionary, .networkAccess:
                collectionView.dequeueConfiguredReusableCell(using: index, for: indexPath, item: item)
            case .gitStatus, .lock:
                collectionView.dequeueConfiguredReusableCell(using: toggle, for: indexPath, item: item)
            case .projectTrust, .error:
                collectionView.dequeueConfiguredReusableCell(using: info, for: indexPath, item: item)
            case .editWithOppi, .delete:
                collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func indexRow(_ item: Item) -> (title: String, systemImage: String, value: String?, identifier: String) {
        switch item {
        case .instructions:
            (String(localized: "Instructions"), "doc.text", model.instructionsSummary, "workspace.edit.instructions")
        case .skills:
            (String(localized: "Skills"), "sparkles", model.skillsSummary, "workspace.edit.skills")
        case .extensions:
            (String(localized: "Extensions"), "puzzlepiece.extension", model.extensionsSummary, "workspace.edit.extensions")
        case .mcpServers:
            (String(localized: "MCP Servers"), "network", model.mcpSummary, "workspace.edit.mcpServers")
        case .dictionary:
            (String(localized: "Dictionary"), "text.book.closed", nil, "workspace.edit.dictionary")
        default:
            (String(localized: "Network Access"), "lock.shield", model.networkAccessSummary, "workspace.edit.networkAccess")
        }
    }

    private func configureToggle(_ cell: UICollectionViewListCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        var content = UIListContentConfiguration.cell()
        content.textProperties.color = UIColor(palette.fg)
        cell.accessories = []
        switch item {
        case .gitStatus:
            content.text = String(localized: "Show Changes in Chat")
            cell.accessories = [.settingsToggle(
                model.gitStatusEnabled,
                identifier: "workspace.edit.gitStatus",
                isEnabled: !(model.isSavingGitStatus || model.isDeleting),
                label: content.text
            ) { [weak self] isOn in
                guard let self else { return }
                let model = model
                Task { [weak self] in
                    await model.setGitStatusEnabled(isOn)
                    self?.redrawToggles()
                }
            }]
        case .lock:
            guard let scope = lockScope else { return }
            content.text = String(localized: "Lock Workspace")
            cell.accessories = [.settingsToggle(
                locks.isFlagged(scope),
                identifier: "workspace.edit.lock",
                isEnabled: !locks.isAuthenticating,
                label: content.text
            ) { [weak self] isOn in
                guard let self else { return }
                // Turning the lock on never asks and keeps this screen open
                // for now; turning it off asks for device authentication and
                // stays on after a cancel.
                if isOn {
                    locks.lock(scope, unlockedForNow: true)
                    redrawToggles()
                } else {
                    let locks = locks
                    Task { [weak self] in
                        _ = await locks.removeLock(scope)
                        self?.redrawToggles()
                    }
                }
            }]
        default:
            break
        }
        cell.contentConfiguration = content
    }

    private func redrawToggles() {
        toggleRevision += 1
        setNeedsUpdateProperties()
    }

    /// Project Trust and the inline error: read-only rows.
    private func configureInfo(_ cell: UICollectionViewListCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        cell.accessories = []
        cell.isAccessibilityElement = true
        switch item {
        case .projectTrust:
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Project Trust")
            content.secondaryText = model.projectTrust?.title
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "workspace.edit.projectTrust"
            cell.accessibilityLabel = content.text
            cell.accessibilityValue = content.secondaryText
        default:
            var content = UIListContentConfiguration.cell()
            content.text = model.error
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.red)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "workspace.edit.error"
            cell.accessibilityLabel = model.error
            cell.accessibilityValue = nil
        }
    }

    private func configureAction(_ cell: SSHTerminalActionCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        switch item {
        case .editWithOppi:
            cell.configure(
                title: String(localized: "Edit with Oppi"),
                identifier: "workspace.edit.editWithOppi",
                color: UIColor(palette.blue),
                subtitle: String(localized: "Describe a change and Oppi makes it."),
                subtitleColor: UIColor(palette.comment),
                image: "text.bubble"
            ) { [weak self] in self?.perform(.editWithOppi) }
        default:
            cell.configure(
                title: String(localized: "Delete Workspace"),
                identifier: "workspace.edit.delete",
                color: UIColor(palette.red),
                // A queued write could otherwise land after the delete.
                enabled: !model.isDeleting && model.isWriteQueueIdle,
                image: "trash"
            ) { [weak self] in self?.perform(.delete) }
        }
    }

    // MARK: - Footers

    private func footerText(_ section: Section) -> String? {
        switch section {
        case .trust:
            model.projectTrust?.explanation
        case .git:
            String(localized: "Shows branch, changed files, and line stats above the chat.")
        case .lock:
            ScopedLockToggle.footer(for: "this workspace and its sessions")
        case .summary, .pages, .oppi, .error, .delete:
            nil
        }
    }

    private func configureFooter(_ view: UICollectionViewListCell, at indexPath: IndexPath) {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = dataSource?.sectionIdentifier(for: indexPath.section).flatMap(footerText)
        content.textProperties.numberOfLines = 0
        view.contentConfiguration = content
    }

    /// Footers are not rows, so a reconfigure does not reach them: redraw the
    /// ones on screen from the model's current values.
    private func refreshFooters() {
        let kind = UICollectionView.elementKindSectionFooter
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            if let footer = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell {
                configureFooter(footer, at: indexPath)
            }
        }
    }

    // MARK: - Actions

    /// A row's own action. Selecting a row runs the same one as its button, so
    /// the two can never diverge.
    private func perform(_ item: Item) {
        switch item {
        case .summary, .instructions, .skills, .extensions, .mcpServers, .dictionary, .networkAccess:
            push(item)
        case .editWithOppi:
            presentEditWithOppi()
        case .delete:
            confirmDelete()
        case .projectTrust, .gitStatus, .lock, .error:
            break
        }
    }

    /// Pushes the page for `item`. Each page is a SwiftUI leaf that starts from
    /// the app root, so this screen's server, API client, and navigation go on
    /// it explicitly. The SwiftUI pages are named inside closures, so this
    /// UIKit file adds no SwiftUI import.
    private func push(_ item: Item) {
        guard let connection else { return }
        let navigator = ScreenNavigator.forUIKitScreen(self, root: root)
        let model = model
        let workspaceId = workspace.id
        let apiClient = connection.apiClient
        let navigation = root.navigation
        switch item {
        case .summary:
            navigator.push {
                WorkspaceDetailsPage(model: model)
                    .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
            }
        case .instructions:
            navigator.push {
                WorkspaceInstructionsPage(model: model)
                    .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
            }
        case .skills:
            navigator.push {
                WorkspaceSkillsPage(model: model)
                    .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
            }
        case .extensions:
            navigator.push {
                WorkspaceExtensionsPage(model: model)
                    .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
            }
        case .mcpServers:
            // A host workspace manages its own `.pi/mcp.json`; a sandbox picks
            // from the global servers.
            navigator.push {
                if model.isSandbox {
                    WorkspaceSandboxMcpPage(model: model)
                        .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
                } else {
                    McpServersView(scopeId: workspaceId)
                        .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
                }
            }
        case .dictionary:
            navigator.push {
                DictationDictionaryView(workspaceId: workspaceId)
                    .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
            }
        case .networkAccess:
            navigator.push {
                WorkspaceNetworkAccessPage(model: model)
                    .presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
            }
        case .projectTrust, .gitStatus, .lock, .editWithOppi, .error, .delete:
            break
        }
    }

    /// The guided composer: describe the change, then Send creates one session
    /// on this screen's server and opens it.
    private func presentEditWithOppi() {
        guard let connection, editSheet == nil else { return }
        let sheet = GuidedControlSessionViewController(
            configuration: GuidedControlComposerConfiguration(
                domain: .workspaces,
                intent: .revise,
                targetId: workspace.id,
                targetName: current.name,
                allowsEmptyRequest: true,
                placeholder: "Describe how this workspace should change…"
            ),
            root: root,
            connection: { connection },
            onSessionPrepared: { [weak self] target in self?.openEditSession(target) }
        )
        editSheet = sheet
        Router.present(sheet, presentation: .sheet.inNavigation(), from: self)
    }

    /// Closes the sheet, leaves Workspace Settings the way Delete does, and
    /// opens the prepared session.
    private func openEditSession(_ target: WorkspaceSessionNavTarget) {
        if let editSheet { Router.finish(editSheet) }
        onLeave?()
        let navigation = root.navigation
        Task { @MainActor in
            await Task.yield()
            navigation.openWorkspaceSession(target)
        }
    }

    private func confirmDelete() {
        let sheet = UIAlertController(
            title: String(localized: "Delete Workspace?"),
            message: WorkspaceDeleteConfirmationPolicy.deleteMessage(for: current),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Delete Workspace"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { await self.deleteWorkspace() }
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController,
           let row = dataSource?.indexPath(for: .delete).flatMap(collectionView.cellForItem(at:)) {
            popover.sourceView = row
            popover.sourceRect = row.bounds
        }
        Router.topPresenter(from: self).present(sheet, animated: true)
    }

    private func deleteWorkspace() async {
        guard let connection else { return }
        let name = current.name
        guard await AppLockService.shared.authorizeProtectedAction(
            reason: String(localized: "Delete \(name)")
        ) else { return }
        guard let deleted = await model.deleteWorkspace() else { return }
        ScopedLockService.shared.forgetWorkspace(
            serverId: deleted.serverId,
            workspaceId: deleted.workspaceId,
            sessionIds: connection.sessionStore.listProjectionSessions(workspaceId: deleted.workspaceId).map(\.id)
        )
        onLeave?()
        root.navigation.leaveDeletedWorkspace(serverId: deleted.serverId, workspaceId: deleted.workspaceId)
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource?.itemIdentifier(for: indexPath) {
        case .gitStatus, .lock, .projectTrust, .error, nil: false
        default: true
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        perform(item)
    }
}

/// The workspace's summary row: its icon, name and lock badge, and folder.
/// The whole row is one button, so a tap, a VoiceOver activation, and
/// `app.buttons[id]` all open Details.
final class WorkspaceSettingsSummaryCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let icon = IconChoiceUIView(size: 24, frameSize: 36)
    private let nameLabel = UILabel()
    private let lockLabel = UILabel()
    private let folderLabel = UILabel()
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [icon, nameLabel, lockLabel, folderLabel, button] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        accessories = [.disclosureIndicator()]
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lockLabel.setContentHuggingPriority(.required, for: .horizontal)
        lockLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        folderLabel.font = .preferredFont(forTextStyle: .footnote)
        folderLabel.adjustsFontForContentSizeCategory = true
        folderLabel.numberOfLines = 1
        folderLabel.lineBreakMode = .byTruncatingMiddle
        button.accessibilityTraits = .button
        // The labels paint the row; the button above them is its one accessible
        // element, so the row reads as a single control.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            lockLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            lockLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            lockLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            folderLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            folderLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            folderLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            folderLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // The separator starts where the name does, past the icon.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        workspace: Workspace,
        folder: String,
        lock: ScopedLockState,
        colors: ComposerThemeColors,
        assetCache: IconAssetCache?,
        identifier: String,
        action: @escaping () -> Void
    ) {
        icon.apply(
            .choice(workspace.icon, purpose: .workspace, sandbox: workspace.runtime == .sandbox),
            colors: colors,
            assetCache: assetCache
        )
        nameLabel.text = workspace.name
        nameLabel.textColor = colors.fg
        folderLabel.text = folder
        folderLabel.textColor = colors.comment
        SessionRowText.setLockBadge(lock, on: lockLabel, color: colors.comment)
        let lockWord = lock.accessibilityWord
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = workspace.name
        button.accessibilityValue = lockWord.isEmpty ? folder : "\(folder), \(lockWord)"
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
        folderLabel.text = nil
        lockLabel.attributedText = nil
        isHighlighted = false
    }
}

private extension ScopedLockState {
    /// The state as the row's accessibility value; empty without a lock.
    var accessibilityWord: String {
        switch self {
        case .none: ""
        case .locked: String(localized: "Locked")
        case .unlocked: String(localized: "Unlocked")
        }
    }
}
