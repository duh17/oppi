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
            dismissesKeyboardOnDrag: true
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        ListScreen.setBarItems(trailing: [], leading: sidebarItems(), on: navigationItem)
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The server and the client serving it: a connection that comes up, drops,
    /// or moves to another server is another subject, so the list loads again
    /// without a Retry.
    override func loadSubject() -> AnyHashable? {
        AnyHashable([
            AnyHashable(root.coordinator.activeServerId),
            AnyHashable(root.coordinator.activeConnection.apiClient.map(ObjectIdentifier.init)),
        ])
    }

    /// Agents of another server never stay up while this server loads.
    override func subjectDidChange() { agents = [] }

    /// The active server's connection: the base reloads the page by itself when it
    /// installs an API client again after a rebuild.
    override func loadConnection() -> ServerConnection? { root.coordinator.activeConnection }

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
        sections.append(ListSection(.status, items: []))
        return sections
    }

    /// The Agents card carries the heading; the state row's card does not, so
    /// it gets no empty header above it.
    override func showsHeader(for section: Section) -> Bool { section != .status }

    /// A load settles the list in place; its rows should not slide.
    override var animatesUpdates: Bool { false }

    /// The saved Agents are what the load fetches: until they are here the list
    /// shows the loading row under Pi, and a failure row under whatever it has.
    override func stateSection() -> Section? { .status }

    override func hasContent() -> Bool { !agents.isEmpty }

    override func loadingCaption() -> String? { String(localized: "Loading saved Agents…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Agents") }

    override func inputs(of item: Item) -> AnyHashable {
        guard case .saved(let id) = item, let agent = agents.first(where: { $0.id == id }) else { return AnyHashable(0) }
        // The row draws the age as text ("2h ago"), which changes without the
        // agent changing: the string is the input, so a pass redraws it. The icon's
        // load generation is an input too: a row that drew an Agent's fallback
        // symbol redraws when its Genmoji arrives.
        return AnyHashable([
            AnyHashable(agent.name), AnyHashable(agent.version), AnyHashable(agent.description),
            AnyHashable(agent.icon), AnyHashable(agent.updatedAt.relativeString()),
            AnyHashable(EntityIcon.loadGeneration),
        ])
    }

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`.
    override var rowStyle: ListRowStyle { .card }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .pi:
            ListScreen.buttonRow(cell, identifier: "agents.row.pi", label: "Pi", value: "Global Pi configuration") { [weak self] in
                self?.openPi()
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                Self.row(
                    icon: Self.tile(PiAvatarRenderer.render(size: 22), size: 22, padding: 8, radius: 10, palette: palette),
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
            let assets = root.coordinator.activeConnection.iconAssetCache
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                let badge = ControlStatusPill()
                badge.apply(
                    text: "v\(agent.version)",
                    tone: palette.ui.comment,
                    emphasis: .quiet,
                    palette: palette,
                    monospacedDigit: true
                )
                let icon = UIImageView(image: EntityIcon.image(
                    .agent(agent.icon),
                    size: 22,
                    assets: assets
                ))
                icon.contentMode = .center
                icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
                let updated = UILabel()
                updated.text = agent.updatedAt.relativeString()
                updated.font = UIFont.scaled(.caption2, monospacedDigits: true)
                updated.adjustsFontForContentSizeCategory = true
                updated.textColor = palette.ui.comment
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
        let titleLabel = ControlRowViews.label(title, style: .headline, color: palette.ui.fg, lines: 1)
        let titleRow = ControlRowViews.stack([titleLabel] + (badge.map { [$0] } ?? []), axis: .horizontal, spacing: 8, alignment: .center)
        let caption = ControlRowViews.label(subtitle, style: .caption1, color: palette.ui.comment, lines: 2)
        let text = ControlRowViews.stack([titleRow, caption], spacing: 4, alignment: .leading)
        var views: [UIView] = [icon, text, ControlRowViews.spacer()]
        if let trailing { views.append(trailing) }
        return ControlRowViews.stack(views, axis: .horizontal, spacing: 12, alignment: .center)
    }

    /// An image on a rounded highlight tile (Pi's avatar).
    static func tile(_ image: UIImage, size: CGFloat, padding: CGFloat, radius: CGFloat, palette: ThemePalette) -> UIView {
        let tile = UIView()
        tile.backgroundColor = palette.ui.bgHighlight
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

    /// The active server's saved Agents: the base runs it on every appearance,
    /// on pull to refresh, after a Retry, and when the server or its client
    /// changes. Throws the reason the list's state row shows.
    override func load() async throws {
        let apiClient = try requireAPIClient()
        let loaded = try await apiClient.listAgents()
        // A load the page cancelled (it left, or another subject's load replaced
        // it) never replaces what this one shows.
        guard !Task.isCancelled else { return }
        agents = loaded
    }
}
