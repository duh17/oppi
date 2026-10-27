import UIKit

/// A Skill's files as an expandable tree (route `.serverSkillBrowser`): folders
/// open in place and a file opens in `ServerSkillFileViewController` through
/// `AppNavigation`. The Skill's page loaded the detail just before opening
/// this, so the tree usually shows at once; otherwise the screen asks the server.
///
/// The route makes the Skill's server the active one on every appearance
/// ("Connecting…" until it is ready).
@MainActor
final class ServerSkillBrowserViewController: UIViewController, UICollectionViewDelegate {
    let target: ServerSkillBrowserNavTarget

    private enum Shown: Equatable {
        case connecting
        case loading
        case empty
        case unavailable(String)
        case tree
    }

    private let root: AppRootEnvironment
    /// The route makes the Skill's server the active one on every appearance.
    private let switchesServer: Bool
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    private var nodes: [String: ServerSkillFileTreeNode] = [:]
    /// The file list the tree was built from, so a redraw keeps open folders.
    private var builtFiles: [String]?
    private var builtTree: [ServerSkillFileTreeNode] = []
    private var needsRebuild = false
    private var appliedThemeID: ThemeID?
    private var footerText = ""

    /// The Skill's server once it is ready.
    private var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var fetchedDetail: ServerSkillDetail? {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var connectTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var isOnScreen = false

    /// `connection`: the Skill's server when the caller already has it ready;
    /// nil makes it the active server first.
    init(target: ServerSkillBrowserNavTarget, root: AppRootEnvironment, connection: ServerConnection? = nil) {
        self.target = target
        self.root = root
        self.connection = connection
        switchesServer = connection == nil
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = String(localized: "Skill Files")
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
        loadTask?.cancel()
    }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    /// The Skill's page loaded this detail just before opening the list.
    private func detail(in connection: ServerConnection) -> ServerSkillDetail? {
        fetchedDetail ?? connection.serverResourceStore.skillDetail(id: target.resourceId, serverId: target.serverId)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "skills.files.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // The server switch and the load run on every appearance, as the
        // hosted screen's tasks did.
        if switchesServer {
            connect()
        } else {
            loadIfNeeded()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        connectTask?.cancel()
        connectTask = nil
        loadTask?.cancel()
        loadTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        guard let connection else {
            title = String(localized: "Skill Files")
            show(.connecting)
            return
        }
        if let detail = detail(in: connection) {
            title = detail.summary.name
            let tree = fileTree(for: detail.files)
            if tree.isEmpty {
                show(.empty)
                return
            }
            footerText = detail.summary.editable
                ? "Open a file to select text, stage comments, and revise it in an Oppi session."
                : "Files are read-only and come from \(detail.summary.provenance.label)."
            show(.tree)
            applyTree(tree)
        } else {
            title = String(localized: "Skill Files")
            show(error.map(Shown.unavailable) ?? .loading)
        }
    }

    // MARK: - Content

    private func show(_ next: Shown) {
        collectionView.isHidden = next != .tree
        // Rebuilt on every pass, so a theme change recolors these states.
        var configuration: UIContentUnavailableConfiguration?
        switch next {
        case .tree:
            break
        case .connecting:
            configuration = ControlScreenList.loading(String(localized: "Connecting…"))
        case .loading:
            configuration = ControlScreenList.loading(String(localized: "Loading skill files…"))
        case .empty:
            configuration = ControlScreenList.unavailable(
                "No Skill Files",
                systemImage: "folder",
                description: "This skill did not expose any browsable files.",
                palette: palette
            )
        case .unavailable(let reason):
            var unavailable = ControlScreenList.unavailable(
                "Files Unavailable",
                systemImage: "exclamationmark.triangle.fill",
                description: reason,
                palette: palette
            )
            var retry = UIButton.Configuration.borderedProminent()
            retry.title = String(localized: "Retry")
            unavailable.button = retry
            unavailable.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
            configuration = unavailable
        }
        configuration?.background.backgroundColor = root.themeStore.backgroundColor
        contentUnavailableConfiguration = configuration
    }

    // MARK: - Tree

    /// The tree for `files`, built once per file list.
    private func fileTree(for files: [String]) -> [ServerSkillFileTreeNode] {
        if builtFiles != files {
            builtFiles = files
            builtTree = ServerSkillFileTree.build(paths: files)
            needsRebuild = true
        }
        return builtTree
    }

    private func applyTree(_ tree: [ServerSkillFileTreeNode]) {
        guard let dataSource else { return }
        if needsRebuild {
            needsRebuild = false
            nodes = [:]
            var section = NSDiffableDataSourceSectionSnapshot<String>()
            func append(_ children: [ServerSkillFileTreeNode], to parent: String?) {
                section.append(children.map(\.id), to: parent)
                for child in children {
                    nodes[child.id] = child
                    if !child.children.isEmpty { append(child.children, to: child.id) }
                }
            }
            append(tree, to: nil)
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            dataSource.apply(snapshot, animatingDifferences: false)
            dataSource.apply(section, to: 0, animatingDifferences: false)
        }
        // Rows read the theme in `configure`; a theme change redraws them.
        let themeID = root.themeStore.activeThemeID
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func configure(_ cell: SidebarListCell, id: String) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        guard let node = nodes[id] else { return }
        var content = UIListContentConfiguration.cell()
        content.text = node.name
        content.textProperties.color = UIColor(palette.fg)
        content.imageProperties.tintColor = UIColor(palette.fg)
        switch node.kind {
        case .directory:
            let isOpen = dataSource?.snapshot(for: 0).isExpanded(id) ?? false
            ControlScreenList.buttonRow(
                cell,
                identifier: "skills.dir.\(node.path)",
                label: node.name,
                value: isOpen ? "Expanded" : "Collapsed"
            ) { [weak self] in
                self?.toggle(id)
            }
            content.image = UIImage(systemName: "folder")
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .cell))]
        case .file:
            ControlScreenList.buttonRow(
                cell,
                identifier: "skills.file.\(node.path)",
                label: "Open \(node.path)"
            ) { [weak self] in
                self?.open(path: node.path)
            }
            content.image = UIImage(systemName: Self.fileIcon(for: node.path))
            cell.contentConfiguration = content
        }
    }

    private func toggle(_ id: String) {
        guard let dataSource else { return }
        var section = dataSource.snapshot(for: 0)
        if section.isExpanded(id) {
            section.collapse([id])
        } else {
            section.expand([id])
        }
        dataSource.apply(section, to: 0, animatingDifferences: true)
        // The row's Expanded / Collapsed value follows.
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func fileIcon(for path: String) -> String {
        if path.hasSuffix(".md") { return "doc.text" }
        if path.hasSuffix(".json") || path.hasSuffix(".yml") || path.hasSuffix(".yaml") {
            return "curlybraces"
        }
        if path.hasSuffix(".sh") { return "terminal" }
        if path.hasSuffix(".swift") || path.hasSuffix(".ts") || path.hasSuffix(".js") || path.hasSuffix(".py") {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc"
    }

    private func open(path: String) {
        root.navigation.openServerSkillFile(ServerSkillFileNavTarget(
            serverId: target.serverId,
            resourceId: target.resourceId,
            path: path
        ))
    }

    // MARK: - Data

    private func connect() {
        connectTask?.cancel()
        let coordinator = root.coordinator
        let serverId = target.serverId
        connectTask = Task { [weak self] in
            guard await coordinator.switchToServerReady(serverId), !Task.isCancelled, let self else { return }
            connection = coordinator.connection(for: serverId)
            loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        guard isOnScreen, let connection, detail(in: connection) == nil else { return }
        load()
    }

    private func load() {
        guard let connection else { return }
        loadTask?.cancel()
        let target = target
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let apiClient = connection.apiClient else {
                error = "Not connected"
                return
            }
            error = nil
            do {
                let response = try await apiClient.getServerSkill(id: target.resourceId)
                guard !Task.isCancelled else { return }
                connection.serverResourceStore.rememberSkillDetail(response, serverId: target.serverId)
                fetchedDetail = response
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
