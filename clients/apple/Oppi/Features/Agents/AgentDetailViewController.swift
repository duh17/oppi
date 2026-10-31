import UIKit

/// A saved Agent: its definition, system prompt, Pi session defaults,
/// resources, launch constraints, and Run (schedule, start). Edit opens the native
/// editor; the actions menu offers Archive; an active Agent's Start Session
/// row (under Schedule Recurring Run) opens Quick Session with the Agent, and
/// it carries the compact Oppi bar to describe a change. Start Session is a
/// labeled row, not a bottom-bar compose glyph, so it does not read as a third
/// edit control beside Edit and the change bar. Edits go back to the list
/// through `onUpdated`.
///
/// A `ListScreenController`: the base owns the list, the snapshot, the section
/// headings, and the load on appearance and pull to refresh. This page keeps
/// its rows, its bar items, the composer, and the sheets it opens.
@MainActor
final class AgentDetailViewController: ListScreenController<AgentDetailViewController.Section, AgentDetailViewController.Item> {
    enum Section: Hashable, Sendable { case definition, prompt, defaults, resources, constraints, run }
    enum Item: Hashable, Sendable {
        case icon
        case value(title: String, value: String)
        case block(title: String, value: String)
        case resourceList(title: String, value: String)
        case prompt
        case notice(text: String, systemImage: String, warning: Bool)
        case schedule
        case startSession
        case caption(String)
    }

    private let root: AppRootEnvironment
    private let agentId: String
    private let onUpdated: (StoredAgentDefinition) -> Void
    private let editItem = UIBarButtonItem()
    private let actionsItem = UIBarButtonItem()

    private let nativeEditor = RouterModalPresenter()
    private let iconPicker = RouterModalPresenter()
    private let definitionReview = RouterModalPresenter()
    private let scheduleSheet = RouterModalPresenter()
    private let composer: GuidedControlComposerController

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
    private var showsDefinitionReview = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsSchedule = false {
        didSet { setNeedsUpdateProperties() }
    }

    init(root: AppRootEnvironment, agentId: String, onUpdated: @escaping (StoredAgentDefinition) -> Void) {
        self.root = root
        self.agentId = agentId
        self.onUpdated = onUpdated
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .agents,
                intent: .revise,
                presentation: .compact,
                placeholder: "Describe a change…"
            ),
            root: root
        )
        super.init(
            title: "Agent", listIdentifier: "agents.detail.list",
            headers: true,
            dismissesKeyboardOnDrag: true, pullsToRefresh: true
        )
        traitOverrides.appRootEnvironment = root
        editItem.primaryAction = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.editingAgent = self?.agent
        }
        editItem.accessibilityIdentifier = "agents.detail.edit"
        actionsItem.image = UIImage(systemName: "ellipsis.circle")
        actionsItem.accessibilityLabel = "Agent actions"
        actionsItem.accessibilityIdentifier = "agents.detail.actions"
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
        [nativeEditor, iconPicker, definitionReview, scheduleSheet]
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.install(in: self)
        for presenter in presenters { presenter.anchor = self }
        // The icon picker's style follows the size classes.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in presenters { presenter.sync() }
        // An error that arrived while the screen was off screen shows now.
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The base cancels the load that was running; its resource flag is this
        // page's to clear, since a cancelled load skips its own reset so it
        // cannot clear a newer load's flag.
        isLoadingResources = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        title = agent?.name ?? "Agent"
        updateBarItems()
        updateComposer()
        updateModals()
        // OK clears only the error the person read, never a newer one.
        errorAlerts.sync(title: "Agent", message: error) { [weak self] shown in
            if self?.error == shown { self?.error = nil }
        }
    }

    /// Only an active Agent can be revised, as its menu item was only offered then.
    private func updateComposer() {
        let revisable = agent.flatMap { $0.status == .active ? $0 : nil }
        composer.model.updateTarget(id: revisable?.id, name: revisable?.name, path: nil)
        composer.setHidden(revisable == nil)
    }

    private func updateBarItems() {
        guard let agent, agent.status == .active else {
            ListScreen.setBarItems(trailing: [], leading: [], on: navigationItem)
            return
        }
        let archive = UIAction(
            title: "Archive Agent",
            image: UIImage(systemName: "archivebox"),
            attributes: isArchiving ? [.destructive, .disabled] : .destructive
        ) { [weak self] _ in
            self?.archiveAgent()
        }
        archive.accessibilityIdentifier = "agents.detail.archive"
        actionsItem.menu = UIMenu(children: [archive])
        ListScreen.setBarItems(trailing: [actionsItem, editItem], leading: [], on: navigationItem)
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        // Without an Agent there are no rows: the page is its state.
        guard let agent else { return [] }
        let definition = agent.definition
        var sections: [ListSection<Section, Item>] = []

        var items: [Item] = [.icon, .value(title: "Name", value: definition.name)]
        if let description = definition.description, !description.isEmpty {
            items.append(.block(title: "Description", value: description))
        }
        items.append(.value(title: "Status", value: agent.status.rawValue.capitalized))
        items.append(.value(title: "Version", value: "v\(agent.version)"))
        sections.append(ListSection(.definition, header: "Definition", items: items))

        if let instructions = definition.instructions {
            sections.append(ListSection(
                .prompt, header: Self.systemPromptTitle(instructions.mode), items: [.prompt]
            ))
        }

        let defaults = definition.sessionDefaults
        sections.append(ListSection(.defaults, header: "Pi Session Defaults", items: [
            .value(title: "Model", value: defaults?.model?.nilIfBlank ?? "Server default"),
            .value(title: "Thinking Level", value: defaults?.thinkingLevel?.rawValue ?? "Default"),
        ] + toolDefaultItems(defaults)))

        sections.append(ListSection(.resources, header: "Resources", items: resourceItems(definition.resources)))

        if let constraints = definition.launchConstraints {
            sections.append(ListSection(.constraints, header: "Launch Constraints", items: [
                .value(title: "Runtime", value: constraints.requiredRuntime?.rawValue.capitalized ?? "Any"),
                .value(title: "Workspaces", value: allowedWorkspaceNames(constraints.allowedWorkspaceIds)),
            ]))
        }

        var run: [Item] = [.schedule]
        // Only an active Agent starts a session, as only it offers Edit.
        if agent.status == .active { run.append(.startSession) }
        run.append(.caption(connection.workspaceStore.workspaces.isEmpty
            ? "Create or sync a workspace before starting or scheduling this Agent."
            : "Schedules can run this Agent with a recurring briefing prompt, selected workspace, and repeat time."))
        sections.append(ListSection(.run, header: "Run", items: run))
        return sections
    }

    /// A load settles the page in place; its rows should not slide.
    override var animatesUpdates: Bool { false }

    /// Nothing loaded yet, or no such Agent: the page is its state.
    override func wholeScreenState() -> LoadState? {
        guard agent == nil else { return nil }
        return isLoading
            ? .loading(String(localized: "Loading agent…"))
            : .empty(title: String(localized: "Agent Not Found"), systemImage: "questionmark.circle")
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .icon:
            return AnyHashable(agent?.definition.icon)
        case .prompt:
            guard let instructions = agent?.definition.instructions else { return AnyHashable(0) }
            return AnyHashable([AnyHashable(Self.systemPromptTitle(instructions.mode)), AnyHashable(instructions.text)])
        case .schedule:
            return AnyHashable(connection.workspaceStore.workspaces.isEmpty)
        case .startSession:
            return AnyHashable([
                AnyHashable(agent?.name), AnyHashable(agent?.status.rawValue),
                AnyHashable(connection.workspaceStore.workspaces.isEmpty),
                AnyHashable(connection.currentServerId),
            ])
        case .value, .block, .resourceList, .notice, .caption:
            return AnyHashable(0)
        }
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
        let rowInsets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        switch item {
        case .icon:
            guard let agent else { return }
            ListScreen.buttonRow(
                cell,
                identifier: "agents.detail.icon",
                label: "Icon",
                value: AgentIconPicker.description(agent.definition.icon),
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
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                ControlRowViews.valueRow(title, value, palette: palette)
            }
        case .block(let title, let value):
            ListScreen.staticRow(cell)
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
            ListScreen.staticRow(cell)
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
            ListScreen.buttonRow(
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
            ListScreen.staticRow(cell)
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
            ListScreen.buttonRow(
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
        case .startSession:
            let enabled = !connection.workspaceStore.workspaces.isEmpty && connection.currentServerId != nil
            ListScreen.buttonRow(
                cell,
                identifier: "agents.detail.launch",
                label: "Start Session with \(agent?.name ?? "Agent")",
                enabled: enabled
            ) { [weak self] in
                self?.startQuickSession()
            }
            var content = UIListContentConfiguration.cell()
            content.text = "Start Session"
            content.image = UIImage(systemName: "plus.bubble")
            let tint = UIColor(palette.blue).withAlphaComponent(enabled ? 1 : 0.4)
            content.textProperties.color = tint
            content.imageProperties.tintColor = tint
            cell.contentConfiguration = content
        case .caption(let text):
            ListScreen.staticRow(cell)
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
        let root = root
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
                        serverName: root.activeServerName,
                        onSaved: saved
                    )
                }
            }
        )
        iconPicker.update(
            id: showsIconPicker && agent != nil ? "icon-picker" : nil,
            presentation: .iconPicker(for: traitCollection),
            root: root,
            clear: { [weak self] in self?.showsIconPicker = false },
            screen: {
                .controller {
                    guard let agent else { preconditionFailure("The icon picker presents only with its Agent") }
                    return AgentIconPicker.viewController(agent: agent, connection: connection, onSaved: saved)
                }
            }
        )
        definitionReview.update(
            id: showsDefinitionReview && agent != nil ? "definition" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in self?.showsDefinitionReview = false },
            screen: { [weak self] in
                .controller {
                    ReviewableControlMarkdownViewController(
                        content: agent.flatMap { self?.definitionMarkdown($0) } ?? "",
                        domain: .agents,
                        targetId: agent?.id ?? "",
                        targetName: agent?.name ?? "",
                        sourceLabel: "\(agent?.name ?? "") definition",
                        sourcePath: "Agents/\(agent?.id ?? "")/Definition.md"
                    )
                }
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

    /// The Agent and its resource catalogs: on every appearance, on pull to
    /// refresh, and after a Retry.
    override func refresh() async {
        // A cancelled load skips its resource flag reset so it cannot clear a
        // newer load's flag; the canceller clears it instead.
        isLoadingResources = false
        await loadAgent()
        guard !Task.isCancelled else { return }
        await loadResources()
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
            // A load cancelled under the page (Back, a replaced connection) is not a failure to report.
            guard !Task.isCancelled, !error.isLoadCancellation else { return }
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
