import UIKit

/// A saved Agent: its definition, system prompt, Pi session defaults,
/// resources, launch constraints, and automation. Edit opens the native
/// editor; the actions menu offers Edit with Oppi and Archive; Start Session
/// in the bottom bar opens Quick Session with the Agent. Edits go back to the
/// list through `onUpdated`.
@MainActor
final class AgentDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case state, definition, prompt, defaults, resources, constraints, automation }
    private enum Item: Hashable {
        case loading
        case notFound
        case icon
        case value(title: String, value: String)
        case block(title: String, value: String)
        case resourceList(title: String, value: String)
        case prompt
        case notice(text: String, systemImage: String, warning: Bool)
        case schedule
        case caption(String)
    }

    private let root: AppRootEnvironment
    private let agentId: String
    private let onUpdated: (StoredAgentDefinition) -> Void
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let refreshControl = UIRefreshControl()
    private let errorAlert = ControlErrorAlert()
    private let editItem = UIBarButtonItem()
    private let actionsItem = UIBarButtonItem()
    private let launchItem = UIBarButtonItem()

    private let nativeEditor = RouterModalPresenter()
    private let iconPicker = RouterModalPresenter()
    private let revisionSheet = RouterModalPresenter()
    private let definitionReview = RouterModalPresenter()
    private let scheduleSheet = RouterModalPresenter()

    private var agent: StoredAgentDefinition? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isArchiving = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoadingResources = false {
        didSet { setNeedsUpdateProperties() }
    }
    /// The Agent the native editor edits while it is up.
    private var editingAgent: StoredAgentDefinition? {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsIconPicker = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsRevision = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsDefinitionReview = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsSchedule = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?

    init(root: AppRootEnvironment, agentId: String, onUpdated: @escaping (StoredAgentDefinition) -> Void) {
        self.root = root
        self.agentId = agentId
        self.onUpdated = onUpdated
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        editItem.primaryAction = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.editingAgent = self?.agent
        }
        editItem.accessibilityIdentifier = "agents.detail.edit"
        actionsItem.image = UIImage(systemName: "ellipsis.circle")
        actionsItem.accessibilityLabel = "Agent actions"
        actionsItem.accessibilityIdentifier = "agents.detail.actions"
        // Start Session sits in the bottom bar, trailing with neutral chrome
        // (as the session inbox's compose).
        launchItem.primaryAction = UIAction(title: "Start Session", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.startQuickSession()
        }
        launchItem.accessibilityIdentifier = "agents.detail.launch"
        if #available(iOS 27.1, *) {
            editItem.axisBehavior = .verticalPreferred
            actionsItem.axisBehavior = .verticalPreferred
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var connection: ServerConnection { root.coordinator.activeConnection }
    private var presenters: [RouterModalPresenter] {
        [nativeEditor, iconPicker, revisionSheet, definitionReview, scheduleSheet]
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "agents.detail.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        ControlScreenList.pinFullWidth(collectionView, in: view)
        installDataSource()
        for presenter in presenters { presenter.anchor = self }
        // The icon picker's style follows the size classes.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        cancelLoad()
        loadTask = Task { [weak self] in
            await self?.loadAgent()
            // A replaced load leaves the resources to the load that replaced it.
            guard !Task.isCancelled else { return }
            await self?.loadResources()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in presenters { presenter.sync() }
        // An error that arrived while the screen was off screen shows now.
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelLoad()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        title = agent?.name ?? "Agent"
        updateBarItems()
        applySnapshot()
        updateModals()
        errorAlert.show(title: "Agent", message: error, from: self) { [weak self] in self?.error = nil }
    }

    private func updateBarItems() {
        guard let agent, agent.status == .active else {
            ControlScreenList.setBarItems(trailing: [], leading: [], on: navigationItem)
            setToolbarItemsIfChanged([])
            return
        }
        let revise = UIAction(title: "Edit with Oppi", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
            self?.showsRevision = true
        }
        revise.accessibilityIdentifier = "agents.detail.revise"
        let archive = UIAction(
            title: "Archive Agent",
            image: UIImage(systemName: "archivebox"),
            attributes: isArchiving ? [.destructive, .disabled] : .destructive
        ) { [weak self] _ in
            self?.archiveAgent()
        }
        archive.accessibilityIdentifier = "agents.detail.archive"
        actionsItem.menu = UIMenu(children: [revise, archive])
        ControlScreenList.setBarItems(trailing: [actionsItem, editItem], leading: [], on: navigationItem)
        launchItem.isEnabled = !connection.workspaceStore.workspaces.isEmpty && connection.currentServerId != nil
        launchItem.accessibilityLabel = "Start session with \(agent.name)"
        launchItem.tintColor = UIColor(palette.fg)
        setToolbarItemsIfChanged([.flexibleSpace(), launchItem])
    }

    private func setToolbarItemsIfChanged(_ items: [UIBarButtonItem]) {
        guard toolbarItems?.elementsEqual(items, by: ===) != true else { return }
        setToolbarItems(items, animated: false)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(items.isEmpty, animated: false)
        }
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let agent {
            let definition = agent.definition
            snapshot.appendSections([.definition])
            var items: [Item] = [.icon, .value(title: "Name", value: definition.name)]
            if let description = definition.description, !description.isEmpty {
                items.append(.block(title: "Description", value: description))
            }
            items.append(.value(title: "Status", value: agent.status.rawValue.capitalized))
            items.append(.value(title: "Version", value: "v\(agent.version)"))
            snapshot.appendItems(items, toSection: .definition)

            if definition.instructions != nil {
                snapshot.appendSections([.prompt])
                snapshot.appendItems([.prompt], toSection: .prompt)
            }

            snapshot.appendSections([.defaults])
            let defaults = definition.sessionDefaults
            snapshot.appendItems([
                .value(title: "Model", value: defaults?.model?.nilIfBlank ?? "Server default"),
                .value(title: "Thinking Level", value: defaults?.thinkingLevel?.rawValue ?? "Default"),
            ] + toolDefaultItems(defaults), toSection: .defaults)

            snapshot.appendSections([.resources])
            snapshot.appendItems(resourceItems(definition.resources), toSection: .resources)

            if let constraints = definition.launchConstraints {
                snapshot.appendSections([.constraints])
                snapshot.appendItems([
                    .value(title: "Runtime", value: constraints.requiredRuntime?.rawValue.capitalized ?? "Any"),
                    .value(title: "Workspaces", value: allowedWorkspaceNames(constraints.allowedWorkspaceIds)),
                ], toSection: .constraints)
            }

            snapshot.appendSections([.automation])
            snapshot.appendItems([
                .schedule,
                .caption(connection.workspaceStore.workspaces.isEmpty
                    ? "Create or sync a workspace before starting or scheduling this Agent."
                    : "Schedules can run this Agent with a recurring briefing prompt, selected workspace, and repeat time."),
            ], toSection: .automation)
        } else {
            snapshot.appendSections([.state])
            snapshot.appendItems([isLoading ? .loading : .notFound], toSection: .state)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func toolDefaultItems(_ defaults: AgentSessionDefaults?) -> [Item] {
        if defaults?.noTools == nil && defaults?.tools == nil && defaults?.excludeTools == nil {
            return [.value(title: "Tools", value: "Default")]
        }
        var items: [Item] = []
        if let noTools = defaults?.noTools {
            items.append(.value(title: "Tools", value: noTools.displayName))
        }
        if let allowed = defaults?.tools {
            items.append(.block(title: "Allowed Tools", value: allowed.isEmpty ? "None" : allowed.joined(separator: ", ")))
        }
        if let excluded = defaults?.excludeTools {
            items.append(.block(title: "Excluded Tools", value: excluded.isEmpty ? "None" : excluded.joined(separator: ", ")))
        }
        return items
    }

    private func resourceItems(_ resources: AgentResources?) -> [Item] {
        var items = [
            resourceItem("Skills", values: resources?.skillPaths, displayValues: skillDisplayNames(resources?.skillPaths)),
            resourceItem("Extensions", values: resources?.extensionIds, displayValues: extensionDisplayNames(resources?.extensionIds)),
        ]
        if resources?.noContextFiles == true {
            items.append(.notice(text: "Context files disabled", systemImage: "doc.badge.gearshape", warning: false))
        }
        if let message = skillCatalogState.statusMessage(for: "Skills") {
            items.append(.notice(text: message, systemImage: "exclamationmark.triangle", warning: true))
        }
        if let message = extensionCatalogState.statusMessage(for: "Extensions") {
            items.append(.notice(text: message, systemImage: "exclamationmark.triangle", warning: true))
        }
        return items
    }

    private func resourceItem(_ title: String, values: [String]?, displayValues: [String]?) -> Item {
        guard let values else { return .value(title: title, value: "Default discovery") }
        guard !values.isEmpty else { return .value(title: title, value: "None") }
        return .resourceList(title: title, value: (displayValues ?? values).joined(separator: ", "))
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section).flatMap { self?.title(for: $0) }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func title(for section: Section) -> String? {
        switch section {
        case .state: nil
        case .definition: "Definition"
        case .prompt: agent?.definition.instructions.map { Self.systemPromptTitle($0.mode) }
        case .defaults: "Pi Session Defaults"
        case .resources: "Resources"
        case .constraints: "Launch Constraints"
        case .automation: "Automation"
        }
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        let rowInsets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        switch item {
        case .loading:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Loading agent…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .notFound:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.unavailable("Agent Not Found", systemImage: "questionmark.circle", palette: palette)
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .icon:
            guard let agent else { return }
            ControlScreenList.buttonRow(
                cell,
                identifier: "agents.detail.icon",
                label: "Icon",
                value: AgentIconPickerView.description(agent.definition.icon),
                hint: "Opens the Agent icon picker"
            ) { [weak self] in
                self?.showsIconPicker = true
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 6, leading: 0, bottom: 6, trailing: 0)) {
                let icon = UIImageView(image: AgentIconRenderer.render(value: agent.definition.icon, size: 24))
                icon.contentMode = .center
                icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
                let row = ControlRowViews.stack([
                    ControlRowViews.label("Icon", style: .body, color: UIColor(palette.comment), lines: 1),
                    ControlRowViews.spacer(),
                    icon,
                ], axis: .horizontal, spacing: 12, alignment: .center)
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
                return row
            }
            cell.accessories = [.disclosureIndicator()]
        case .value(let title, let value):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                ControlRowViews.valueRow(title, value, palette: palette)
            }
        case .block(let title, let value):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                let block = ControlRowViews.stack([
                    ControlRowViews.label(title, style: .subheadline, color: UIColor(palette.comment)),
                    ControlRowViews.selectableText(value, style: .body, color: UIColor(palette.fg)),
                ], spacing: 6)
                block.isAccessibilityElement = true
                block.accessibilityLabel = title
                block.accessibilityValue = value
                return block
            }
        case .resourceList(let title, let value):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                let block = ControlRowViews.stack([
                    ControlRowViews.label(title, style: .subheadline, weight: .medium, color: UIColor(palette.fg)),
                    ControlRowViews.selectableText(value, style: .caption1, color: UIColor(palette.comment)),
                ], spacing: 4)
                block.isAccessibilityElement = true
                block.accessibilityLabel = title
                block.accessibilityValue = value
                return block
            }
        case .prompt:
            guard let instructions = agent?.definition.instructions else { return }
            ControlScreenList.buttonRow(
                cell,
                identifier: "agents.detail.definition",
                label: "Read and comment on Agent definition"
            ) { [weak self] in
                self?.showsDefinitionReview = true
            }
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.stack([
                    ControlRowViews.label(instructions.text, style: .body, color: UIColor(palette.fg)),
                    ControlRowViews.symbolLabel(
                        "Read and comment",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        style: .caption1,
                        weight: .medium,
                        color: UIColor(palette.blue)
                    ),
                ], spacing: 10, alignment: .leading)
            }
        case .notice(let text, let systemImage, let warning):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                ControlRowViews.symbolLabel(
                    text,
                    systemImage: systemImage,
                    style: warning ? .caption1 : .subheadline,
                    color: UIColor(warning ? palette.orange : palette.fg)
                )
            }
        case .schedule:
            let enabled = !connection.workspaceStore.workspaces.isEmpty
            ControlScreenList.buttonRow(
                cell,
                identifier: "agents.detail.schedule",
                label: "Schedule Recurring Run",
                enabled: enabled
            ) { [weak self] in
                self?.showsSchedule = true
            }
            var content = UIListContentConfiguration.cell()
            content.text = "Schedule Recurring Run"
            content.image = UIImage(systemName: "calendar.badge.clock")
            let tint = UIColor(palette.blue).withAlphaComponent(enabled ? 1 : 0.4)
            content.textProperties.color = tint
            content.imageProperties.tintColor = tint
            cell.contentConfiguration = content
        case .caption(let text):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(text, style: .caption1, color: UIColor(palette.comment))
            }
        }
    }

    // MARK: - Modals

    private func updateModals() {
        let agent = agent
        let saved: (StoredAgentDefinition) -> Void = { [weak self] updated in
            self?.agent = updated
            self?.onUpdated(updated)
        }
        let editing = editingAgent
        let connection = connection
        nativeEditor.update(
            id: editing.map { AnyHashable($0.id) },
            presentation: .fullScreen.inNavigation(),
            root: root,
            clear: { [weak self] in self?.editingAgent = nil },
            screen: {
                .controller {
                    guard let editing else { preconditionFailure("The editor presents only with its Agent") }
                    return AgentNativeEditViewController(
                        agent: editing,
                        apiClient: connection.apiClient,
                        connection: connection,
                        onSaved: saved
                    )
                }
            }
        )
        iconPicker.update(
            id: showsIconPicker && agent != nil ? "icon-picker" : nil,
            presentation: AgentHostedScreens.iconPickerPresentation(traitCollection),
            root: root,
            clear: { [weak self] in self?.showsIconPicker = false },
            screen: { AgentHostedScreens.iconPicker(agent, onSaved: saved) }
        )
        revisionSheet.update(
            id: showsRevision && agent != nil ? "revision" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showsRevision = false },
            screen: {
                guidedSheet(GuidedControlComposerConfiguration(
                    domain: .agents,
                    intent: .revise,
                    targetId: agent?.id,
                    targetName: agent?.name,
                    allowsEmptyRequest: true,
                    placeholder: "Describe how this Agent should change…"
                ))
            }
        )
        definitionReview.update(
            id: showsDefinitionReview && agent != nil ? "definition" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in self?.showsDefinitionReview = false },
            screen: { [weak self] in
                AgentHostedScreens.reviewableMarkdown(
                    content: agent.flatMap { self?.definitionMarkdown($0) } ?? "",
                    targetId: agent?.id ?? "",
                    targetName: agent?.name ?? "",
                    sourceLabel: "\(agent?.name ?? "") definition",
                    sourcePath: "Agents/\(agent?.id ?? "")/Definition.md"
                )
            }
        )
        scheduleSheet.update(
            id: showsSchedule && agent != nil ? "schedule" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showsSchedule = false },
            screen: {
                guidedSheet(GuidedControlComposerConfiguration(
                    domain: .schedules,
                    intent: .create,
                    initialRequest: "Create a schedule that runs saved Agent \(agent?.name ?? "") (canonical Agent ID: \(agent?.id ?? "")).",
                    allowsEmptyRequest: false,
                    placeholder: "Describe when and how this Agent should run…"
                ))
            }
        )
    }

    private func guidedSheet(_ configuration: GuidedControlComposerConfiguration) -> RouterScreen {
        let root = root
        return .controller { GuidedControlSessionViewController(configuration: configuration, root: root) }
    }

    // MARK: - Definition text

    private static func systemPromptTitle(_ mode: AgentInstructionMode) -> String {
        switch mode {
        case .append: "Append System Prompt"
        case .replace: "Replace System Prompt"
        }
    }

    private func definitionMarkdown(_ agent: StoredAgentDefinition) -> String {
        let definition = agent.definition
        let defaults = definition.sessionDefaults
        let resources = definition.resources
        let instructions: [String]
        if let instruction = definition.instructions {
            instructions = ["## \(Self.systemPromptTitle(instruction.mode))", "", instruction.text]
        } else {
            instructions = ["## System Prompt", "", "_Uses the server default._"]
        }

        var lines = ["# \(definition.name)", ""]
        if let description = definition.description?.nilIfBlank {
            lines.append(description)
            lines.append("")
        }
        lines += instructions
        lines += [
            "",
            "## Pi Session Defaults",
            "",
            "- **Model:** \(defaults?.model?.nilIfBlank ?? "Server default")",
            "- **Thinking level:** \(defaults?.thinkingLevel?.rawValue ?? "Default")",
            "- **Tools:** \(agentToolSummary(defaults))",
            "",
            "## Resources",
            "",
            "- **Skills:** \(resourceSummary(resources?.skillPaths, displayValues: skillDisplayNames(resources?.skillPaths)))",
            "- **Extensions:** \(resourceSummary(resources?.extensionIds, displayValues: extensionDisplayNames(resources?.extensionIds)))",
            "- **Context files:** \(resources?.noContextFiles == true ? "Disabled" : "Default discovery")",
        ]
        return lines.joined(separator: "\n")
    }

    private func agentToolSummary(_ defaults: AgentSessionDefaults?) -> String {
        if let noTools = defaults?.noTools { return noTools.displayName }
        if let allowed = defaults?.tools {
            return allowed.isEmpty ? "Allowed: None" : "Allowed: \(allowed.joined(separator: ", "))"
        }
        if let excluded = defaults?.excludeTools {
            return excluded.isEmpty ? "Excluded: None" : "Excluded: \(excluded.joined(separator: ", "))"
        }
        return "Default"
    }

    private func resourceSummary(_ values: [String]?, displayValues: [String]? = nil) -> String {
        guard let values else { return "Default discovery" }
        guard !values.isEmpty else { return "None" }
        return (displayValues ?? values).joined(separator: ", ")
    }

    private func allowedWorkspaceNames(_ ids: [String]?) -> String {
        guard let ids else { return "Any" }
        let workspaces = connection.workspaceStore.workspaces
        return ids.map { id in workspaces.first(where: { $0.id == id })?.name ?? id }.joined(separator: ", ")
    }

    private func skillDisplayNames(_ paths: [String]?) -> [String]? {
        guard let paths, let serverId = connection.currentServerId else { return nil }
        let catalog = connection.serverResourceStore.skills(forServer: serverId)
        return paths.map { path in catalog.first(where: { $0.path == path })?.name ?? path }
    }

    private func extensionDisplayNames(_ ids: [String]?) -> [String]? {
        guard let ids, let serverId = connection.currentServerId else { return nil }
        let catalog = connection.serverResourceStore.extensions(forServer: serverId)
        return ids.map { id in catalog.first(where: { $0.id == id })?.name ?? id }
    }

    private var skillCatalogState: AgentResourceCatalogState {
        let connection = connection
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .skills, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedSkills(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !store.skills(forServer: serverId).isEmpty
        )
    }

    private var extensionCatalogState: AgentResourceCatalogState {
        let connection = connection
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !store.extensions(forServer: serverId).isEmpty
        )
    }

    // MARK: - Actions

    private func refresh() {
        cancelLoad()
        loadTask = Task { [weak self] in
            await self?.loadAgent()
            if !Task.isCancelled { await self?.loadResources() }
            self?.refreshControl.endRefreshing()
        }
    }

    /// A cancelled load skips its resource flag reset so it cannot clear a
    /// newer load's flag; the canceller clears it instead.
    private func cancelLoad() {
        loadTask?.cancel()
        isLoadingResources = false
    }

    private func loadAgent() async {
        guard let apiClient = connection.apiClient else {
            error = "Server is offline"
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let loaded = try await apiClient.getAgent(agentId)
            guard !Task.isCancelled else { return }
            agent = loaded
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadResources() async {
        let connection = connection
        guard let apiClient = connection.apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { if !Task.isCancelled { isLoadingResources = false } }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    private func startQuickSession() {
        guard let agent, let serverId = connection.currentServerId else { return }
        root.navigation.presentQuickSession(
            QuickSessionStart(context: QuickSessionLaunchContext(serverId: serverId, agentId: agent.id)),
            from: .agents
        )
    }

    private func archiveAgent() {
        guard let apiClient = connection.apiClient else { return }
        isArchiving = true
        let agentId = agentId
        Task { [weak self] in
            defer { self?.isArchiving = false }
            do {
                let archived = try await apiClient.archiveAgent(agentId: agentId)
                self?.agent = archived
                self?.error = nil
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
