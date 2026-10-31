import UIKit

/// Agents: Pi (the server's global Pi configuration) and the saved Agents,
/// with the guided composer to describe a new one. A row pushes its detail,
/// which reports edits back.
///
/// A `ListScreenController`: the base owns the list, the loading and failure
/// row, and the load on appearance and pull to refresh. This page keeps its
/// rows, its composer, and the sidebar toggle.
@MainActor
final class AgentListViewController: ListScreenController<AgentListViewController.Section, AgentListViewController.Item> {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    enum Section: Hashable, Sendable {
        case agents, status
    }

    enum Item: Hashable, Sendable {
        case pi
        case saved(String)
    }

    private let root: AppRootEnvironment
    private let composer: GuidedControlComposerController
    private var sidebarToggle: UIBarButtonItem?

    private var agents: [AgentDefinitionSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    /// The server and API client the last load started with. The page reads
    /// both in `updateProperties()`, so a connection that comes up, drops, or
    /// moves to another server reloads the list without a Retry.
    private var loadedSource: LoadSource?
    /// The server `agents` came from.
    private var agentsServerId: String?

    private struct LoadSource: Equatable {
        let serverId: String?
        let client: ObjectIdentifier?
    }

    private var currentSource: LoadSource {
        LoadSource(
            serverId: root.coordinator.activeServerId,
            client: root.coordinator.activeConnection.apiClient.map(ObjectIdentifier.init)
        )
    }

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .agents,
                intent: .create,
                placeholder: "Describe a new Agent…"
            ),
            root: root
        )
        super.init(
            title: "Agents", listIdentifier: "agents.list",
            headers: true, footers: true,
            dismissesKeyboardOnDrag: true, pullsToRefresh: true
        )
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.install(in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        // The load this appearance starts is this source: marking it before the
        // base schedules the load keeps `updateProperties` from asking for it
        // again and cancelling the load it just started.
        loadedSource = currentSource
        super.viewIsAppearing(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        ListScreen.setBarItems(trailing: [], leading: sidebarItems(), on: navigationItem)
        // The connection or the server changed under the screen: load again.
        if isShowing, currentSource != loadedSource { setNeedsRefresh() }
    }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        // A diffable list traps on a repeated item; a repeated agent id shows once.
        var shown = Set<Item>()
        let items = AgentManagementPresentation.rows(savedAgents: agents).map { row in
            switch row {
            case .pi: Item.pi
            case .saved(let agent): Item.saved(agent.id)
            }
        }.filter { shown.insert($0).inserted }
        var sections: [ListSection<Section, Item>] = [ListSection(
            .agents,
            header: "Agents",
            footer: "Pi uses the server's global Pi configuration. Saved Agents add reusable instructions, resources, and session defaults.",
            items: items
        )]
        if let state = stateRow() { sections.append(ListSection(.status, items: [], state: state)) }
        return sections
    }

    /// The Agents card carries the heading; the state row's card does not, so
    /// it gets no empty header above it.
    override func showsHeader(for section: Section) -> Bool { section != .status }

    /// A load settles the list in place; its rows should not slide.
    override var animatesUpdates: Bool { false }

    /// Saved Agents are loading, or the load failed: one row under Pi and the
    /// Agents it already has, with Retry.
    private func stateRow() -> ListStateRow? {
        guard error != nil || (isLoading && agents.isEmpty) else { return nil }
        // A Retry keeps its row and turns it into the loading row.
        if !isLoading, let error {
            return ListStateRow(
                state: .failed(
                    title: error,
                    message: nil,
                    retry: RetryAction { [weak self] in self?.setNeedsRefresh() }
                ),
                identifier: "agents.state"
            )
        }
        return ListStateRow(state: .loading("Loading saved Agents…"), identifier: "agents.state")
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard case .saved(let id) = item, let agent = agents.first(where: { $0.id == id }) else { return AnyHashable(0) }
        // The row draws the age as text ("2h ago"), which changes without the
        // agent changing: the string is the input, so a pass redraws it.
        return AnyHashable([
            AnyHashable(agent.name), AnyHashable(agent.version), AnyHashable(agent.description),
            AnyHashable(agent.icon), AnyHashable(agent.updatedAt.relativeString()),
        ])
    }

    /// The page's rows: one `SidebarListCell`, a themed card, filled by
    /// `configure(_:item:)`.
    private lazy var row = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        ListScreen.background(cell, grouped: true, palette: palette, settingsCard: true)
        configure(cell, item: item)
    }

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = row
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .pi:
            ListScreen.buttonRow(cell, identifier: "agents.row.pi", label: "Pi", value: "Global Pi configuration") { [weak self] in
                self?.openPi()
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                Self.row(
                    icon: Self.tile(PiAvatarRenderer.render(size: 30, themeID: nil), size: 30, padding: 4, radius: 10, palette: palette),
                    title: "Pi",
                    badge: nil,
                    subtitle: "Global Pi configuration",
                    trailing: nil,
                    palette: palette
                )
            }
            cell.accessories = [.disclosureIndicator()]
        case .saved(let id):
            guard let agent = agents.first(where: { $0.id == id }) else { return }
            let description = agent.description.flatMap { $0.isEmpty ? nil : $0 } ?? "No description"
            ListScreen.buttonRow(
                cell,
                identifier: "agents.row.\(agent.id)",
                label: "\(agent.name), v\(agent.version)",
                value: description
            ) { [weak self] in
                self?.openAgent(agent.id)
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                let badge = ControlStatusPill()
                badge.apply(
                    text: "v\(agent.version)",
                    tone: UIColor(palette.comment),
                    emphasis: .quiet,
                    palette: palette,
                    monospacedDigit: true
                )
                let icon = UIImageView(image: AgentIconRenderer.render(value: agent.icon, size: 22))
                icon.contentMode = .center
                icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
                let updated = UILabel()
                updated.text = agent.updatedAt.relativeString()
                updated.font = UIFont.scaled(.caption2, monospacedDigits: true)
                updated.adjustsFontForContentSizeCategory = true
                updated.textColor = UIColor(palette.comment)
                updated.setContentCompressionResistancePriority(.required, for: .horizontal)
                return Self.row(
                    icon: icon,
                    title: agent.name,
                    badge: badge,
                    subtitle: description,
                    trailing: updated,
                    palette: palette
                )
            }
            cell.accessories = [.disclosureIndicator()]
        }
    }

    /// An icon, a headline (with an optional badge) over a caption, and an
    /// optional trailing view.
    private static func row(
        icon: UIView,
        title: String,
        badge: UIView?,
        subtitle: String,
        trailing: UIView?,
        palette: ThemePalette
    ) -> UIView {
        let titleLabel = ControlRowViews.label(title, style: .headline, color: UIColor(palette.fg), lines: 1)
        let titleRow = ControlRowViews.stack([titleLabel] + (badge.map { [$0] } ?? []), axis: .horizontal, spacing: 8, alignment: .center)
        let caption = ControlRowViews.label(subtitle, style: .caption1, color: UIColor(palette.comment), lines: 2)
        let text = ControlRowViews.stack([titleRow, caption], spacing: 4, alignment: .leading)
        var views: [UIView] = [icon, text, ControlRowViews.spacer()]
        if let trailing { views.append(trailing) }
        return ControlRowViews.stack(views, axis: .horizontal, spacing: 12, alignment: .center)
    }

    /// An image on a rounded highlight tile (Pi's avatar).
    static func tile(_ image: UIImage, size: CGFloat, padding: CGFloat, radius: CGFloat, palette: ThemePalette) -> UIView {
        let tile = UIView()
        tile.backgroundColor = UIColor(palette.bgHighlight)
        tile.layer.cornerRadius = radius
        tile.layer.cornerCurve = .continuous
        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size),
            imageView.topAnchor.constraint(equalTo: tile.topAnchor, constant: padding),
            imageView.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -padding),
            imageView.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: padding),
            imageView.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -padding),
        ])
        return tile
    }

    // MARK: - Actions

    private func openPi() {
        Router.push(PiAgentDetailViewController(root: root), from: self)
    }

    /// The pushed detail reports edits here; the list shows them when it is
    /// back on screen.
    private func openAgent(_ agentId: String) {
        let detail = AgentDetailViewController(root: root, agentId: agentId) { [weak self] updated in
            self?.agentUpdated(updated)
        }
        Router.push(detail, from: self)
    }

    private func agentUpdated(_ updated: StoredAgentDefinition) {
        guard let index = agents.firstIndex(where: { $0.id == updated.id }) else { return }
        agents[index] = AgentDefinitionSummary(
            id: updated.id,
            name: updated.name,
            icon: updated.definition.icon,
            description: updated.description,
            launchConstraints: updated.definition.launchConstraints,
            sessionDefaults: updated.definition.sessionDefaults,
            status: updated.status,
            version: updated.version,
            createdAt: updated.createdAt,
            updatedAt: updated.updatedAt,
            archivedAt: updated.archivedAt
        )
    }

    /// The active server's saved Agents: on every appearance, on pull to
    /// refresh, and after a Retry.
    override func refresh() async {
        loadedSource = currentSource
        await loadAgents()
    }

    private func loadAgents() async {
        // Agents of another server never stay up while this server loads.
        if agentsServerId != root.coordinator.activeServerId {
            agents = []
            agentsServerId = nil
        }
        guard let apiClient = root.coordinator.activeConnection.apiClient else {
            // A cancelled load leaves the flag to the load that replaced it.
            isLoading = false
            error = "Server offline"
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let loaded = try await apiClient.listAgents()
            guard !Task.isCancelled, isCurrent(apiClient) else { return }
            agents = loaded
            agentsServerId = root.coordinator.activeServerId
            error = nil
        } catch {
            // A cancelled load leaves the row and the list as they were.
            guard !Task.isCancelled, isCurrent(apiClient), !error.isLoadCancellation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Whether `apiClient` still serves the active server: an answer that
    /// arrives after the connection or the server changed is not this list's.
    private func isCurrent(_ apiClient: APIClient) -> Bool {
        root.coordinator.activeConnection.apiClient === apiClient
    }
}
