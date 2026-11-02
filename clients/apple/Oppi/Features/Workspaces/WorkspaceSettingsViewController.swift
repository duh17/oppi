import UIKit

/// Workspace Settings root: a summary of the workspace that opens Details, one
/// index row per focused page, Show Changes in Chat, Lock Workspace, and
/// Delete Workspace, with the compact Oppi bar at the bottom to describe a
/// change.
///
/// Toggles and pickers apply as soon as they change. Only the Details page,
/// the Instructions editor, and the Network Access hosts editor are drafts
/// with their own Save. Data for every page comes from one
/// `WorkspaceSettingsModel`, so pushed pages never refetch. Each pushed page
/// starts from the app root (the active server), so it gets this screen's
/// server scope explicitly.
///
/// A `ListScreenController`: the base owns the list, its theme, each row's
/// redraw key, and the page's load, which here is the workspace's server switch
/// (a load on every appearance). The lock is part of that load's subject, so a
/// relock cancels a switch in flight.
///
/// The screen is its own lock gate and server switch: while the workspace is
/// locked it shows the lock cover and nothing of the workspace; unlocked, it
/// makes the workspace's server the active one ("Connecting…") and then shows
/// the list. The bar shows with the list and never while the lock cover does.
/// Rows are real buttons, so a tap, a VoiceOver activation, and
/// `app.buttons[id]` all run the row's own action.
@MainActor
final class WorkspaceSettingsViewController: ListScreenController<
    WorkspaceSettingsViewController.Section,
    WorkspaceSettingsViewController.Item
> {
    enum Section: Hashable, Sendable {
        case summary, pages, trust, git, lock, error, delete
    }

    enum Item: Hashable, Sendable {
        case summary
        case instructions, skills, extensions, mcpServers, dictionary, networkAccess
        case projectTrust
        case gitStatus
        case lock
        case error
        case delete
    }

    let root: AppRootEnvironment
    private let serverId: String
    private let workspace: Workspace
    let model: WorkspaceSettingsModel
    let locks: ScopedLockService

    /// Closes this screen after Delete Workspace or a session prepared by the
    /// Oppi bar when it was pushed onto another screen. As a shell route it leaves through the
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

    /// The workspace's server once it is ready: the list has nothing to show
    /// before it.
    private var connection: ServerConnection? {
        didSet { if connection !== oldValue { setNeedsUpdateProperties() } }
    }
    /// Whether this screen makes its server the active one (not the fixture).
    private let switchesServer: Bool
    private var lockCover: ScopedLockCoverViewController?
    /// The compact Oppi bar, made once the workspace's server is ready.
    private var composer: GuidedControlComposerController?
    private weak var deleteAlert: UIAlertController?
    private var sidebarToggle: UIBarButtonItem?
    private var doneItem: UIBarButtonItem?
    /// Bumped when a toggle's write ends, so its switch is redrawn from the
    /// stored value even where that value did not change (a cancelled unlock,
    /// a failed write).
    private var toggleRevision = 0

    /// `serverId`: the workspace's server, made the active one before the
    /// list shows.
    init(serverId: String, workspace: Workspace, root: AppRootEnvironment, locks: ScopedLockService = .shared) {
        self.serverId = serverId
        self.workspace = workspace
        self.root = root
        self.locks = locks
        switchesServer = true
        model = WorkspaceSettingsModel(seed: workspace)
        super.init(
            title: String(localized: "Workspace Settings"),
            listIdentifier: "workspace.edit.list",
            footers: true
        )
        setUp()
    }

    #if DEBUG
    /// Screenshot harness entry: a fixture model on a ready connection, with
    /// no server switch.
    init(
        workspace: Workspace,
        model: WorkspaceSettingsModel,
        connection: ServerConnection,
        root: AppRootEnvironment,
        locks: ScopedLockService = .shared
    ) {
        self.workspace = workspace
        self.root = root
        self.locks = locks
        switchesServer = false
        serverId = connection.currentServerId ?? ""
        self.model = model
        self.connection = connection
        super.init(
            title: String(localized: "Workspace Settings"),
            listIdentifier: "workspace.edit.list",
            footers: true
        )
        setUp()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setUp() {
        traitOverrides.appRootEnvironment = root
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

    private var isLocked: Bool { locks.isLocked(lockTarget) }

    /// Whether the list has anything to show: the workspace's server is ready
    /// and its lock is off.
    private var showsWorkspace: Bool { !isLocked && connection != nil }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (self: Self, _) in
                self.setNeedsUpdateProperties()
            }
        }
        // A cover added before the list was pinned would sit behind it.
        showLockCover()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        // The lock footer names the App Lock method, which Privacy changes.
        setNeedsUpdateProperties()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer?.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        // Read the theme and the lock, so a change to either re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID, locks.isAuthenticating)
        collectionView.isHidden = !showsWorkspace
        showLockCover()
        updateBar()
        updateComposer()
    }

    // MARK: - Load

    /// A load each time it shows: the workspace's server is made the active one
    /// again, as the hosted screen's `.task(id:)` did.
    override var loadPolicy: LoadPolicy { switchesServer ? .eachAppearance : .none }

    /// The load is a server switch, not a read: a pull would switch again and show
    /// a spinner that does nothing.
    override var offersPullToRefresh: Bool { false }

    /// The server it switches to, and whether the workspace is locked: a relock
    /// cancels a switch in flight.
    override func loadSubject() -> AnyHashable? {
        AnyHashable([AnyHashable(serverId), AnyHashable(isLocked)])
    }

    /// Makes the workspace's server the active one, then binds the model to it
    /// and loads the Pi resources (a repeat load is a no-op). A shown list stays
    /// until the switch answers: `connection` is replaced only by its result.
    override func load() async throws {
        guard switchesServer, !isLocked else { return }
        // A switch the lock ended while it ran does not take the server either.
        guard await root.coordinator.switchToServerReady(
            serverId,
            shouldActivate: { [weak self] in !(self?.isLocked ?? true) }
        ) else { return }
        guard !Task.isCancelled, !isLocked else { return }
        guard let ready = root.coordinator.connection(for: serverId) else { return }
        connection = ready
        model.attach(connection: ready, workspace: workspace)
        await model.loadPiResourcesIfNeeded()
    }

    /// The list's own state while it has nothing to show: the server switch on
    /// its way. A locked workspace shows its cover instead.
    override func wholeScreenState() -> LoadState? {
        guard !isLocked else { return nil }
        return connection == nil ? .connecting : nil
    }

    /// The Oppi bar describes a change to this workspace on its own server.
    /// It shows with the list on a server that has an API client, and a lock
    /// holds it back: nothing of a locked workspace stays usable.
    private func updateComposer() {
        guard let connection else { return }
        let composer = composer ?? makeComposer(connection)
        composer.model.isDisabled = isLocked
        composer.model.updateTarget(id: workspace.id, name: current.name, path: nil)
        composer.setHidden(!showsWorkspace || connection.apiClient == nil)
    }

    private func makeComposer(_ connection: ServerConnection) -> GuidedControlComposerController {
        let composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .workspaces,
                intent: .revise,
                presentation: .compact,
                targetId: workspace.id,
                targetName: current.name,
                placeholder: String(localized: "Describe a change…")
            ),
            root: root,
            connection: { connection },
            onSessionPrepared: { [weak self] target in self?.openEditSession(target) }
        )
        composer.install(in: self)
        self.composer = composer
        return composer
    }

    // MARK: - Content

    /// The lock cover while the workspace is locked, and nothing of the rest:
    /// it sits over the list, which the page hides with it.
    private func showLockCover() {
        guard isLocked else {
            guard let lockCover else { return }
            lockCover.willMove(toParent: nil)
            lockCover.view.removeFromSuperview()
            lockCover.removeFromParent()
            self.lockCover = nil
            return
        }
        dismissPresentedModals()
        let cover: ScopedLockCoverViewController
        if let lockCover {
            cover = lockCover
        } else {
            cover = ScopedLockCoverViewController(target: lockTarget, title: workspace.name)
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
        }
        view.bringSubviewToFront(cover.view)
    }

    /// Nothing of a locked workspace stays on screen: the Delete confirmation,
    /// which sits above this screen's cover, goes with it.
    private func dismissPresentedModals() {
        deleteAlert?.dismiss(animated: false)
        deleteAlert = nil
    }

    private func updateBar() {
        var leading: [UIBarButtonItem] = []
        if showsSidebarToggle {
            let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
            sidebarToggle = toggle
            WorkspaceSplitSidebarToggle.sync(toggle, root: root)
            leading.append(toggle)
        }
        if showsWorkspace, let onDone {
            let item = doneItem ?? UIBarButtonItem(systemItem: .done)
            item.title = String(localized: "Done")
            item.primaryAction = UIAction(title: String(localized: "Done")) { _ in onDone() }
            item.accessibilityIdentifier = "workspace.edit.done"
            doneItem = item
            leading.append(item)
        }
        ListScreen.setBarItems(trailing: [], leading: leading, on: navigationItem)
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        // A locked workspace and one whose server is not ready show nothing: the
        // cover, or the whole screen's own state.
        guard showsWorkspace else { return [] }
        var sections = [
            ListSection<Section, Item>(.summary, items: [.summary]),
        ]
        var pages: [Item] = [.instructions, .skills, .extensions, .mcpServers, .dictionary]
        if model.isSandbox { pages.append(.networkAccess) }
        sections.append(ListSection(.pages, items: pages))
        if model.projectTrust != nil {
            sections.append(ListSection(.trust, footer: footerText(.trust), items: [.projectTrust]))
        }
        sections.append(ListSection(.git, footer: footerText(.git), items: [.gitStatus]))
        if lockScope != nil {
            sections.append(ListSection(.lock, footer: footerText(.lock), items: [.lock]))
        }
        if model.error != nil {
            sections.append(ListSection(.error, items: [.error]))
        }
        sections.append(ListSection(.delete, items: [.delete]))
        return sections
    }

    /// Every value a row is drawn from, read here so any change re-runs this
    /// pass and reconfigures only the rows it touches.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .summary:
            return AnyHashable([
                AnyHashable(current.name),
                AnyHashable(current.icon),
                AnyHashable(current.runtime),
                AnyHashable(folderSummary),
                AnyHashable(serverSummary),
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
        case .error: return AnyHashable(model.error)
        case .delete: return AnyHashable([model.isDeleting, !model.isWriteQueueIdle])
        }
    }

    private var folderSummary: String {
        if let folder = model.savedFolder { return folder }
        return model.isSandbox ? String(localized: "Sandbox") : String(localized: "No folder")
    }

    /// The row names the server the workspace is on, so a second server's
    /// workspace is not mistaken for the first's.
    private var serverSummary: String? {
        root.coordinator.serverStore.server(for: serverId).map { String(localized: "On \($0.name)") }
    }

    private var lockWord: String { locks.badge(lockTarget).accessibilityWord }

    // MARK: - Cells

    private lazy var summaryRow = UICollectionView.CellRegistration<WorkspaceRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let palette = ThemeRuntimeState.currentPalette()
        cell.configure(
            workspace: current,
            folder: folderSummary,
            server: serverSummary,
            lock: locks.badge(lockTarget),
            colors: ComposerThemeColors(palette: palette),
            assetCache: connection?.iconAssetCache,
            identifier: "workspace.edit.details"
        ) { [weak self] in self?.perform(.summary) }
    }

    private lazy var indexCell = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        let row = indexRow(item)
        cell.configure(
            title: row.title,
            image: row.systemImage.isEmpty ? nil : .symbol(row.systemImage),
            value: row.value,
            identifier: row.identifier
        ) { [weak self] in self?.perform(item) }
    }

    private lazy var switchRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        self?.configureSwitch(cell, item: item)
    }

    private lazy var infoRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        self?.configureInfo(cell, item: item)
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        self?.configureAction(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = (summaryRow, indexCell, switchRow, infoRow, actionRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .summary:
            collectionView.dequeueConfiguredReusableCell(using: summaryRow, for: indexPath, item: item)
        case .instructions, .skills, .extensions, .mcpServers, .dictionary, .networkAccess:
            collectionView.dequeueConfiguredReusableCell(using: indexCell, for: indexPath, item: item)
        case .gitStatus, .lock:
            collectionView.dequeueConfiguredReusableCell(using: switchRow, for: indexPath, item: item)
        case .projectTrust, .error:
            collectionView.dequeueConfiguredReusableCell(using: infoRow, for: indexPath, item: item)
        case .delete:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
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
            (String(localized: "Dictation Dictionary"), "text.book.closed", nil, "workspace.edit.dictionary")
        default:
            (String(localized: "Network Access"), "lock.shield", model.networkAccessSummary, "workspace.edit.networkAccess")
        }
    }

    private func configureSwitch(_ cell: UICollectionViewListCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        var content = UIListContentConfiguration.cell()
        content.textProperties.color = palette.ui.fg
        cell.accessories = []
        switch item {
        case .gitStatus:
            content.text = String(localized: "Show Changes in Chat")
            cell.accessories = [.settingsToggle(
                model.gitStatusEnabled,
                identifier: "workspace.edit.gitStatus",
                label: content.text,
                isEnabled: !(model.isSavingGitStatus || model.isDeleting),
                reusing: cell
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
                label: content.text,
                isEnabled: !locks.isAuthenticating,
                reusing: cell
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
            content.textProperties.color = palette.ui.fg
            content.secondaryTextProperties.color = palette.ui.comment
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "workspace.edit.projectTrust"
            cell.accessibilityLabel = content.text
            cell.accessibilityValue = content.secondaryText
        default:
            var content = UIListContentConfiguration.cell()
            content.text = model.error
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.red
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "workspace.edit.error"
            cell.accessibilityLabel = model.error
            cell.accessibilityValue = nil
        }
    }

    private func configureAction(_ cell: SettingsActionRowCell, item: Item) {
        cell.configure(
            title: String(localized: "Delete Workspace"),
            systemImage: "trash",
            tint: .destructive,
            identifier: "workspace.edit.delete",
            // A queued write could otherwise land after the delete.
            isEnabled: canDelete
        ) { [weak self] in self?.perform(.delete) }
    }

    // MARK: - Footers

    private func footerText(_ section: Section) -> String? {
        switch section {
        case .trust:
            model.projectTrust?.explanation
        case .git:
            String(localized: "Shows branch, changed files, and line stats above the chat.")
        case .lock:
            ScopedLockToggleRow.footer(for: "this workspace and its sessions")
        case .summary, .pages, .error, .delete:
            nil
        }
    }

    // MARK: - Selection

    /// A row's own action. Selecting a row runs the same one as its button, so
    /// the two can never diverge.
    override func isSelectable(_ item: Item) -> Bool {
        switch item {
        case .gitStatus, .lock, .projectTrust, .error: false
        case .delete: canDelete
        default: true
        }
    }

    override func select(_ item: Item) {
        perform(item)
    }

    // MARK: - Actions

    private func perform(_ item: Item) {
        switch item {
        case .summary, .instructions, .skills, .extensions, .mcpServers, .dictionary, .networkAccess:
            push(item)
        case .delete:
            confirmDelete()
        case .projectTrust, .gitStatus, .lock, .error:
            break
        }
    }

    /// Pushes the page for `item`. Every page is UIKit except Dictionary, a
    /// SwiftUI leaf that starts from the app root, so this screen's server, API
    /// client, and navigation go on it explicitly.
    private func push(_ item: Item) {
        guard let connection else { return }
        let model = model
        let workspaceId = workspace.id
        let apiClient = connection.apiClient
        let navigation = root.navigation
        switch item {
        case .summary:
            Router.push(WorkspaceDetailsViewController(settings: model, connection: connection, root: root), from: self)
        case .instructions:
            Router.push(WorkspaceInstructionsViewController(model: model, root: root), from: self)
        case .skills:
            Router.push(WorkspaceSkillsViewController(model: model, connection: connection, root: root), from: self)
        case .extensions:
            Router.push(WorkspaceExtensionsViewController(model: model, root: root), from: self)
        case .mcpServers:
            // A host workspace manages its own `.pi/mcp.json`; a sandbox picks
            // from the global servers.
            if model.isSandbox {
                Router.push(WorkspaceSandboxMcpViewController(model: model, root: root), from: self)
            } else {
                Router.push(McpServersViewController(scopeId: workspaceId, root: root), from: self)
            }
        case .dictionary:
            guard let serverId = connection.currentServerId else { return }
            Router.push(
                DictationDictionaryViewController.make(
                    root: root, serverId: serverId, workspace: (id: workspaceId, name: workspace.name)
                ),
                from: self
            )
        case .networkAccess:
            Router.push(WorkspaceNetworkAccessViewController(model: model, root: root), from: self)
        case .projectTrust, .gitStatus, .lock, .error, .delete:
            break
        }
    }

    /// Leaves Workspace Settings the way Delete does and opens the session
    /// the Oppi bar prepared. A lock that engaged while Send was in flight
    /// refuses it.
    func openEditSession(_ target: WorkspaceSessionNavTarget) {
        guard !isLocked else { return }
        onLeave?()
        let navigation = root.navigation
        Task { @MainActor in
            await Task.yield()
            navigation.openWorkspaceSession(target)
        }
    }

    /// Delete runs only on an unlocked workspace with no write queued or delete
    /// in flight (a queued write could otherwise land after the delete).
    private var canDelete: Bool {
        !isLocked && !model.isDeleting && model.isWriteQueueIdle
    }

    private func confirmDelete() {
        guard canDelete, deleteAlert == nil else { return }
        let row = indexPath(for: .delete).flatMap(collectionView.cellForItem(at:))
        deleteAlert = Confirmation.deleteWorkspace(current).present(from: self, anchor: row) { [weak self] in
            guard let self else { return }
            Task { await self.deleteWorkspace() }
        }
    }

    /// Checked again after the authorization prompt: a lock may engage while
    /// it is up.
    func deleteWorkspace() async {
        guard let connection, canDelete else { return }
        let name = current.name
        guard await AppLockService.shared.authorizeProtectedAction(
            reason: String(localized: "Delete \(name)")
        ) else { return }
        guard canDelete else { return }
        guard let deleted = await model.deleteWorkspace() else { return }
        locks.forgetWorkspace(
            serverId: deleted.serverId,
            workspaceId: deleted.workspaceId,
            sessionIds: connection.sessionStore.listProjectionSessions(workspaceId: deleted.workspaceId).map(\.id)
        )
        onLeave?()
        root.navigation.leaveDeletedWorkspace(serverId: deleted.serverId, workspaceId: deleted.workspaceId)
    }
}
