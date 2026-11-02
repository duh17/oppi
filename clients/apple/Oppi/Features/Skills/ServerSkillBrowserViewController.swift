import UIKit

/// A Skill's files as an expandable tree (route `.serverSkillBrowser`): folders
/// open in place and a file opens in `ServerSkillFileViewController` through
/// `AppNavigation`. The Skill's page loaded the detail just before opening
/// this, so the tree usually shows at once; otherwise (or on a Retry, a pull, a
/// return) the page asks the server.
///
/// A page on `ListScreenController`: the tree is flattened into the kit's rows
/// from the page's own open set, so an opened folder is a row insert under its
/// own row, indented, with a chevron — not an outline snapshot. The kit owns the
/// list, its pin, its theme, the load, and the whole-screen states.
///
/// The route makes the Skill's server the active one on every appearance
/// ("Connecting…" until it is ready).
@MainActor
final class ServerSkillBrowserViewController: ListScreenController<
    ServerSkillBrowserViewController.Section,
    ServerSkillBrowserViewController.Item
> {
    enum Section: Hashable, Sendable { case files }

    /// One row of the flattened tree. Its identity is the node's, so opening or
    /// closing a folder changes which rows the list has, never who they are: an
    /// open folder's own row stays where it was.
    struct Item: Hashable, Sendable {
        let nodeId: String
    }

    /// What a row draws: the node, how deep it sits, and whether its children
    /// are out.
    private struct Row {
        let node: ServerSkillFileTreeNode
        let depth: Int
        let isOpen: Bool
    }

    let target: ServerSkillBrowserNavTarget

    private let root: AppRootEnvironment
    /// The route makes the Skill's server the active one on every appearance.
    private let switchesServer: Bool
    /// The folders the person opened, by node id, as they left them: a reload
    /// replaces the files, not this.
    private var expanded: Set<String> = []
    /// The rows of the last pass, by node id, for the cells to draw from.
    private var rows: [String: Row] = [:]

    /// The Skill's server once it is ready.
    private var connection: ServerConnection?
    /// The detail the last request returned.
    private var fetchedDetail: ServerSkillDetail?

    /// `connection`: the Skill's server when the caller already has it ready;
    /// nil makes it the active server first.
    init(target: ServerSkillBrowserNavTarget, root: AppRootEnvironment, connection: ServerConnection? = nil) {
        self.target = target
        self.root = root
        self.connection = connection
        switchesServer = connection == nil
        super.init(title: String(localized: "Skill Files"), listIdentifier: "skills.files.list", footers: true)
        traitOverrides.appRootEnvironment = root
        // The page titles itself with the Skill's name once it has it.
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    /// The Skill's page loaded this detail just before opening the list.
    private func detail(in connection: ServerConnection) -> ServerSkillDetail? {
        fetchedDetail ?? connection.serverResourceStore.skillDetail(id: target.resourceId, serverId: target.serverId)
    }

    /// What the rows show now: nil until the Skill's server has the detail.
    private var shownDetail: ServerSkillDetail? {
        connection.flatMap(detail(in:))
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // A folder and a file act through their own button: the list selects
        // nothing.
        collectionView.allowsSelection = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func updateProperties() {
        title = shownDetail?.summary.name ?? String(localized: "Skill Files")
        super.updateProperties()
    }

    // MARK: - Load

    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func loadSubject() -> AnyHashable? { AnyHashable(target) }

    /// Another Skill or another server is another tree, closed.
    override func subjectDidChange() {
        fetchedDetail = nil
        expanded = []
    }

    /// Makes the Skill's server the active one (when the route does), then asks
    /// it for the detail — which it already has when the Skill's page just
    /// loaded it, unless something asked for a fresh read.
    override func load() async throws {
        // A Retry, a pull, or a return to the page re-reads; appearing again
        // shows what the store has.
        let forced = loadTrigger == .ask
        clearLoadFailure()
        if switchesServer {
            guard await root.coordinator.switchToServerReady(target.serverId), !Task.isCancelled else { return }
            connection = root.coordinator.connection(for: target.serverId)
        }
        guard let connection else { throw LoadFailure(String(localized: "Server offline")) }
        if !forced, detail(in: connection) != nil { return }
        guard let apiClient = connection.apiClient else { throw LoadFailure(String(localized: "Not connected")) }
        let fetched = try await apiClient.getServerSkill(id: target.resourceId)
        guard !Task.isCancelled else { return }
        // The Skill's own page and file reader read the same copy.
        connection.serverResourceStore.rememberSkillDetail(fetched, serverId: target.serverId)
        fetchedDetail = fetched
    }

    override func loadingCaption() -> String? { String(localized: "Loading skill files…") }

    override func failureTitle() -> String? { String(localized: "Files Unavailable") }

    override func emptyState() -> LoadState? {
        .empty(
            title: String(localized: "No Skill Files"),
            systemImage: "folder",
            message: String(localized: "This skill did not expose any browsable files.")
        )
    }

    /// The route's server first: until it is ready there is nothing to list.
    override func wholeScreenState() -> LoadState? {
        guard connection != nil else { return .connecting }
        return super.wholeScreenState()
    }

    // MARK: - Rows

    /// Every row is a button of the kit's theme card.
    override var rowStyle: ListRowStyle { .card }

    override func sections() -> [ListSection<Section, Item>] {
        guard let detail = shownDetail else {
            rows = [:]
            return []
        }
        let tree = ServerSkillFileTree.build(paths: detail.files)
        let flattened = flatten(tree)
        rows = Dictionary(uniqueKeysWithValues: flattened.map { ($0.node.id, $0) })
        guard !flattened.isEmpty else { return [] }
        return [ListSection(
            .files,
            footer: detail.summary.editable
                ? String(localized: "Open a file to select text, stage comments, and revise it in an Oppi session.")
                : String(localized: "Files are read-only and come from \(detail.summary.provenance.label)."),
            items: flattened.map { Item(nodeId: $0.node.id) }
        )]
    }

    /// The tree in list order: a folder's children follow it, one level in,
    /// while it is open.
    private func flatten(_ nodes: [ServerSkillFileTreeNode], depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            let row = [Row(node: node, depth: depth, isOpen: expanded.contains(node.id))]
            guard node.kind == .directory, expanded.contains(node.id) else { return row }
            return row + flatten(node.children, depth: depth + 1)
        }
    }

    /// A folder's row draws what it draws — its open state — so opening or
    /// closing it reconfigures that row and no other.
    override func inputs(of item: Item) -> AnyHashable {
        AnyHashable([AnyHashable(item.nodeId), AnyHashable(expanded.contains(item.nodeId))])
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        guard let row = rows[item.nodeId] else { return }
        let palette = palette
        var content = content(.plain)
        content.text = row.node.name
        content.imageProperties.tintColor = palette.ui.fg
        // A child sits one level in from its folder, as a tree draws it.
        content.directionalLayoutMargins.leading += CGFloat(row.depth) * Self.indent
        switch row.node.kind {
        case .directory:
            ListScreen.buttonRow(
                cell,
                identifier: "skills.dir.\(row.node.path)",
                label: row.node.name,
                value: row.isOpen ? "Expanded" : "Collapsed"
            ) { [weak self] in
                self?.toggle(row.node.id)
            }
            content.image = UIImage(systemName: "folder")
            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(
                customView: Self.chevron(isOpen: row.isOpen, palette: palette),
                placement: .trailing()
            ))]
        case .file:
            ListScreen.buttonRow(
                cell,
                identifier: "skills.file.\(row.node.path)",
                label: "Open \(row.node.path)"
            ) { [weak self] in
                self?.open(path: row.node.path)
            }
            content.image = UIImage(systemName: Self.fileIcon(for: row.node.path))
            cell.contentConfiguration = content
        }
    }

    /// How far a level of the tree indents its rows.
    private static let indent: CGFloat = 18

    /// The folder's own state: a chevron that points at its children while they
    /// are shown. The row's button owns the tap, so this only draws.
    private static func chevron(isOpen: Bool, palette: ThemePalette) -> UIImageView {
        let chevron = UIImageView(image: UIImage(systemName: isOpen ? "chevron.down" : "chevron.right"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        chevron.tintColor = palette.ui.comment
        chevron.isAccessibilityElement = false
        return chevron
    }

    private func toggle(_ nodeId: String) {
        if expanded.contains(nodeId) {
            expanded.remove(nodeId)
        } else {
            expanded.insert(nodeId)
        }
        setNeedsUpdateProperties()
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
}
