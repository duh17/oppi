import UIKit

/// Agents: Pi (the server's global Pi configuration) and the saved Agents,
/// with the guided composer to describe a new one. A row pushes its detail,
/// which reports edits back.
@MainActor
final class AgentListViewController: UIViewController, UICollectionViewDelegate {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private enum Item: Hashable {
        case pi
        case saved(String)
        case loading
    }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>?
    private let refreshControl = UIRefreshControl()
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
    private var loadTask: Task<Void, Never>?
    private let errorAlert = ControlErrorAlert()

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
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Agents"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "agents.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        ControlScreenList.pinFullWidth(collectionView, in: view)
        installDataSource()
        composer.install(in: self)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Like the SwiftUI `.task` it replaces, a load each time it shows.
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadAgents() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // An error that arrived while the screen was off screen shows now.
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        ControlScreenList.setBarItems(trailing: [], leading: sidebarItems(), on: navigationItem)
        applySnapshot()
        errorAlert.show(title: "Agents", message: error, from: self) { [weak self] in self?.error = nil }
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

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(AgentManagementPresentation.rows(savedAgents: agents).map { row in
            switch row {
            case .pi: .pi
            case .saved(let agent): .saved(agent.id)
            }
        })
        if isLoading && agents.isEmpty {
            snapshot.appendItems([.loading])
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, _ in
            var content = UIListContentConfiguration.header()
            content.text = "Agents"
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "Pi uses the server's global Pi configuration. Saved Agents add reusable instructions, resources, and session defaults."
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .pi:
            ControlScreenList.buttonRow(cell, identifier: "agents.row.pi", label: "Pi", value: "Global Pi configuration") { [weak self] in
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
            ControlScreenList.buttonRow(
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
                updated.font = ControlScreenList.monospacedDigitFont(.caption2)
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
        case .loading:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Loading saved Agents…")
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

    private func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadAgents()
            self?.refreshControl.endRefreshing()
        }
    }

    private func loadAgents() async {
        guard let apiClient = root.coordinator.activeConnection.apiClient else {
            error = "Server is offline"
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let loaded = try await apiClient.listAgents()
            guard !Task.isCancelled else { return }
            agents = loaded
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
