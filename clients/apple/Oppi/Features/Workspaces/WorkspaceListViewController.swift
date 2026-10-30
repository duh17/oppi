import OSLog
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "WorkspaceList")

extension Confirmation {
    /// What Delete asks before it removes a workspace's record. The list and
    /// the workspace's settings both ask it.
    static func deleteWorkspace(_ workspace: Workspace) -> Confirmation {
        Confirmation(
            title: String(localized: "Delete Workspace?"),
            message: "This removes the Oppi workspace record for \"\(workspace.name)\". Files on disk stay. Sessions in this workspace may become unreachable.",
            actionTitle: String(localized: "Delete Workspace")
        )
    }
}

/// Workspace management list for one server, reached from Server Settings: the
/// server's workspaces, each opening its settings (behind its lock), a
/// trailing swipe that deletes after a confirmation, a New Workspace button,
/// and pull to refresh.
@MainActor
final class WorkspaceListViewController: ListScreenController<
    WorkspaceListViewController.Section,
    WorkspaceListViewController.Item
> {
    enum Section: Hashable, Sendable { case workspaces }
    enum Item: Hashable, Sendable { case workspace(String) }

    private let server: PairedServer
    private let root: AppRootEnvironment
    private let locks: ScopedLockService
    private var refreshTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var isDeleting = false {
        didSet { setNeedsUpdateProperties() }
    }
    private weak var deleteSheet: UIAlertController?

    private lazy var createItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.createWorkspace() }
        )
        item.accessibilityLabel = String(localized: "New Workspace")
        item.accessibilityIdentifier = "server.workspace.create"
        return item
    }()

    init(server: PairedServer, root: AppRootEnvironment, locks: ScopedLockService = .shared) {
        self.server = server
        self.root = root
        self.locks = locks
        super.init(
            title: String(localized: "Workspaces"),
            listIdentifier: "server.workspaceList",
            scope: .server(server.name)
        )
        traitOverrides.appRootEnvironment = root
    }

    deinit {
        refreshTask?.cancel()
        deleteTask?.cancel()
    }

    private var connection: ServerConnection? { root.coordinator.connection(for: server.id) }

    private var workspaces: [Workspace] { connection?.workspaceStore.workspaces ?? [] }

    private func lockBadge(_ workspace: Workspace) -> ScopedLockState {
        locks.badge(.workspace(serverId: server.id, workspaceId: workspace.id))
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { [weak self, weak refresh] in
                await self?.refreshCatalog(force: true)
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refreshCatalog(force: false) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        ListScreen.setBarItems(trailing: [createItem], leading: [], on: navigationItem)
        if workspaces.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .empty(
                    title: String(localized: "No Workspaces"),
                    systemImage: "square.grid.2x2",
                    message: String(localized: "Tap + to create one.")
                ),
                palette: ThemeRuntimeState.currentPalette()
            )
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func refreshCatalog(force: Bool) async {
        guard await root.coordinator.apiClientReady(for: server.id) != nil,
              let connection else { return }
        await connection.refreshWorkspaceCatalog(force: force)
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        return [ListSection(.workspaces, items: Self.unique(workspaces.map(\.id)).map(Item.workspace))]
    }

    /// A snapshot traps on a repeated item identifier, so a response that
    /// repeats an id shows its first.
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func workspace(_ item: Item) -> Workspace? {
        guard case .workspace(let id) = item else { return nil }
        return workspaces.first { $0.id == id }
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard let workspace = workspace(item) else { return AnyHashable(0) }
        return AnyHashable([
            AnyHashable(workspace),
            AnyHashable(lockBadge(workspace) == .locked),
            AnyHashable(lockBadge(workspace) == .unlocked),
            AnyHashable(isDeleting),
        ])
    }

    private lazy var workspaceRow = UICollectionView.CellRegistration<WorkspaceRowCell, Item> { [weak self] cell, _, item in
        guard let self, let workspace = workspace(item) else { return }
        let lock = lockBadge(workspace)
        let delete = UIAccessibilityCustomAction(name: String(localized: "Delete")) { [weak self] _ in
            self?.confirmDelete(workspace) ?? false
        }
        cell.configure(
            workspace: workspace,
            // A locked workspace shows its name only.
            description: lock == .locked ? nil : workspace.description,
            folder: workspace.hostMount ?? String(localized: "No folder"),
            lock: lock,
            colors: ComposerThemeColors(palette: ThemeRuntimeState.currentPalette()),
            assetCache: connection?.iconAssetCache,
            identifier: "server.workspace.\(workspace.id)",
            customActions: isDeleting ? [] : [delete]
        ) { [weak self] in self?.open(workspace) }
    }

    override func prepareRegistrations() {
        _ = workspaceRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: workspaceRow, for: indexPath, item: item)
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard !isDeleting, let workspace = workspace(item) else { return nil }
        let delete = UIContextualAction(style: .normal, title: String(localized: "Delete")) { [weak self] _, _, completion in
            completion(self?.confirmDelete(workspace) ?? false)
        }
        delete.image = UIImage(systemName: "trash")
        delete.backgroundColor = UIColor(ThemeRuntimeState.currentPalette().red)
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        // A delete asks first, so a long swipe must not run it.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    // MARK: - Actions

    /// Pushes the workspace's settings; a locked workspace asks first, and
    /// cancelling stays here. The screen makes this server the active one
    /// before it shows anything, and pops itself when it leaves.
    private func open(_ workspace: Workspace) {
        let target = ScopedLockTarget.workspace(serverId: server.id, workspaceId: workspace.id)
        if locks.gate(target, onUnlock: { [weak self] in self?.openSettings(workspace) }) {
            openSettings(workspace)
        }
    }

    private func openSettings(_ workspace: Workspace) {
        let screen = WorkspaceSettingsViewController(serverId: server.id, workspace: workspace, root: root)
        screen.onLeave = { [weak screen] in
            if let screen { Router.finish(screen) }
        }
        Router.push(screen, from: self)
    }

    private func createWorkspace() {
        Router.present(
            WorkspaceCreateViewController(root: root, server: server),
            presentation: .sheet.inNavigation(),
            from: self,
            theme: root.themeStore
        )
    }

    /// Asks before deleting; returns whether the question was shown.
    @discardableResult
    private func confirmDelete(_ workspace: Workspace) -> Bool {
        guard !isDeleting, deleteSheet == nil else { return false }
        let row = indexPath(for: .workspace(workspace.id)).flatMap(collectionView.cellForItem(at:))
        deleteSheet = Confirmation.deleteWorkspace(workspace).present(from: self, anchor: row) { [weak self] in
            self?.startDelete(workspace)
        }
        return true
    }

    private func startDelete(_ workspace: Workspace) {
        guard deleteTask == nil else { return }
        deleteTask = Task { [weak self] in
            await self?.deleteWorkspace(workspace)
            self?.deleteTask = nil
        }
    }

    func deleteWorkspace(_ workspace: Workspace) async {
        guard !isDeleting else { return }
        guard await AppLockService.shared.authorizeProtectedAction(
            reason: String(localized: "Delete \(workspace.name)")
        ) else { return }
        guard let conn = connection else { return }
        guard let api = conn.apiClient else {
            show(error: "Server is offline")
            return
        }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try await api.deleteWorkspace(id: workspace.id)
            locks.forgetWorkspace(
                serverId: server.id,
                workspaceId: workspace.id,
                sessionIds: conn.sessionStore.listProjectionSessions(workspaceId: workspace.id).map(\.id)
            )
            conn.workspaceStore.remove(id: workspace.id, serverId: server.id)
            root.navigation.leaveDeletedWorkspace(serverId: server.id, workspaceId: workspace.id)
        } catch {
            logger.error("Delete failed for \(workspace.id.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
            show(error: error.localizedDescription)
        }
    }

    private func show(error message: String) {
        errorAlerts.show(message: message)
    }
}
