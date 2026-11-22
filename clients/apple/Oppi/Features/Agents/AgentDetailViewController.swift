import UIKit

/// A saved Agent: its icon as a large circle at the top of the page, which opens
/// the icon picker, then its definition, system prompt, Pi session defaults,
/// tools, context, launch constraints, and Run (schedule, start). Edit opens the
/// native editor; the actions menu offers Archive; an active Agent's Start Session
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
    enum Section: Hashable, Sendable { case hero, definition, status, prompt, defaults, tools, context, constraints, run }
    enum Item: Hashable, Sendable {
        case hero
        case value(title: String, value: String)
        case block(title: String, value: String)
        case resourceList(title: String, value: String)
        case prompt
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
    /// A failure of something the page did (a failed archive), which shows as an
    /// alert. A failed load is the base's `loadFailure`.
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isArchiving = false {
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
            dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
        editItem.primaryAction = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.editingAgent = self?.agent
        }
        editItem.accessibilityIdentifier = "agents.detail.edit"
        actionsItem.image = UIImage(systemName: "ellipsis.circle")
        actionsItem.accessibilityLabel = "Agent actions"
        actionsItem.accessibilityIdentifier = "agents.detail.actions"
        SystemVerticalBar.prefersRail(editItem)
        SystemVerticalBar.prefersRail(actionsItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var connection: ServerConnection { root.windowConnectionOrStandIn }
    /// Whether this server can save what the editor writes; an older one cannot.
    private var editsAgentCapabilities: Bool { connection.editsAgentCapabilities }
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
        // OK clears only the error the person read, never a newer one. A failed
        // load is the base's row, not this alert.
        errorAlerts.sync(title: "Agent", message: error) { [weak self] shown in
            guard let self, error == shown else { return }
            error = nil
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
        // An older server cannot save what the editor writes, so Edit stays where it is and says
        // why rather than opening a form whose Save would be refused.
        editItem.isEnabled = editsAgentCapabilities
        editItem.accessibilityValue = editsAgentCapabilities
            ? nil
            : "This server needs an update to edit its Agents"
        ListScreen.setBarItems(trailing: [actionsItem, editItem], leading: [], on: navigationItem)
    }

    // MARK: - List

    /// The hero's circle. Large enough to read as the Agent's portrait on an
    /// iPhone and on the iPad mini, and small enough to leave the Definition card
    /// on the first screen.
    private static let heroSide: CGFloat = 96

    override func sections() -> [ListSection<Section, Item>] {
        // Without an Agent there are no rows: the page is its state.
        guard let agent else { return [] }
        let definition = agent.definition
        // The icon is the page's portrait above the heading, not a row in it.
        var sections: [ListSection<Section, Item>] = [ListSection(.hero, items: [.hero])]

        var items: [Item] = [.value(title: "Name", value: definition.name)]
        if let description = definition.description, !description.isEmpty {
            items.append(.block(title: "Description", value: description))
        }
        items.append(.value(title: "Status", value: agent.status.rawValue.capitalized))
        items.append(.value(title: "Version", value: "v\(agent.version)"))
        sections.append(ListSection(.definition, header: "Definition", items: items))
        sections.append(ListSection(.status, items: []))

        if let instructions = definition.instructions {
            sections.append(ListSection(
                .prompt, header: Self.systemPromptTitle(instructions.mode), items: [.prompt]
            ))
        }

        let defaults = definition.sessionDefaults
        sections.append(ListSection(.defaults, header: "Pi Session Defaults", items: [
            .value(title: "Model", value: defaults?.model?.nilIfBlank ?? "Server default"),
            .value(title: "Thinking Level", value: defaults?.thinkingLevel?.rawValue ?? "Default"),
        ]))

        if editsAgentCapabilities {
            sections.append(ListSection(.tools, header: "Tools", items: capabilityItems(definition.capabilities)))
            sections.append(ListSection(.context, header: "Context", items: contextItems(definition.context)))
        } else {
            // An older server stores Pi tool lists and Extension IDs, which this app cannot read:
            // say so instead of showing capabilities that are not there.
            sections.append(ListSection(.tools, header: "Tools", items: [
                .caption("Update this server to see and edit this Agent’s tools, plugins, MCP servers, and context."),
            ]))
        }

        if let constraints = definition.launchConstraints {
            sections.append(ListSection(.constraints, header: "Launch Constraints", items: [
                .value(title: "Runtime", value: constraints.requiredRuntime?.rawValue.capitalized ?? "Any"),
                .value(title: "Engine", value: constraints.requiredEngine?.rawValue.capitalized ?? "Any"),
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

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's connection: the base reloads the page by itself when it
    /// installs an API client again after a rebuild.
    override func loadConnection() -> ServerConnection? { connection }

    /// The definition, resources, and run carry headings; the state row, which
    /// has none of its own, gets no empty header above it, and neither does the
    /// hero above the Definition heading.
    override func showsHeader(for section: Section) -> Bool { section != .status && section != .hero }

    /// A failed load keeps the rows it already had and says so under them, with
    /// Retry; with no Agent there is nothing to list, so the page is its whole
    /// screen's state.
    override func stateSection() -> Section? { .status }

    override func loadingCaption() -> String? { String(localized: "Loading agent…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Agent") }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .hero:
            // `IconChoiceUIView` redraws itself when artwork arrives, so a load
            // never rebuilds the row (and restarts a playing image).
            return AnyHashable(agent?.definition.icon)
        case .prompt:
            guard let instructions = agent?.definition.instructions else { return AnyHashable(0) }
            return AnyHashable([AnyHashable(Self.systemPromptTitle(instructions.mode)), AnyHashable(instructions.text)])
        case .value(let title, let value):
            // The value is selectable text: a pass that redrew the row would
            // drop a selection or the copy menu, so the row is keyed by it.
            return AnyHashable([AnyHashable(title), AnyHashable(value)])
        case .block(let title, let value):
            return AnyHashable([AnyHashable(title), AnyHashable(value)])
        case .resourceList(let title, let value):
            return AnyHashable([AnyHashable(title), AnyHashable(value)])
        case .schedule:
            return AnyHashable(connection.workspaceStore.workspaces.isEmpty)
        case .startSession:
            return AnyHashable([
                AnyHashable(agent?.name), AnyHashable(agent?.status.rawValue),
                AnyHashable(connection.workspaceStore.workspaces.isEmpty),
                AnyHashable(connection.currentServerId),
            ])
        // A caption is a label; the kit's default draws it again.
        default:
            return super.inputs(of: item)
        }
    }

    /// The same rows the editor's Tools and Context sections show, read-only: what
    /// this Agent may do, and what its sessions read.
    private func capabilityItems(_ capabilities: AgentCapabilities?) -> [Item] {
        let capabilities = capabilities ?? AgentCapabilities()
        return [
            .value(
                title: "Pi Tools",
                value: AgentManagementPresentation.agentToolsSummary(tools: capabilities.tools)
            ),
            .value(
                title: "Edits files",
                value: Self.yesNo(capabilities.canEditFiles)
            ),
            .value(title: "Ask me", value: Self.yesNo(capabilities.canAsk)),
            .value(title: "Notify me", value: Self.yesNo(capabilities.canNotify)),
            .value(title: "Delegate", value: Self.yesNo(capabilities.canDelegate)),
            .resourceList(title: "Plugins", value: Self.pluginSummary(capabilities.plugins)),
            .resourceList(title: "MCP Servers", value: Self.mcpSummary(capabilities.mcp)),
        ]
    }

    private func contextItems(_ context: AgentContext?) -> [Item] {
        let context = context ?? AgentContext()
        var items: [Item] = [
            .value(title: "Read AGENTS.md", value: Self.yesNo(context.readsContextFiles)),
            .value(title: "Read past sessions", value: Self.yesNo(context.readsSessionHistory)),
        ]
        if let skills = context.skills {
            items.append(.resourceList(
                title: "Skills",
                value: skills.isEmpty ? "None" : skills.sorted().joined(separator: ", ")
            ))
        } else {
            items.append(.value(title: "Skills", value: "All"))
        }
        return items
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    private static func pluginSummary(_ plugins: [String]?) -> String {
        guard let plugins else { return "All" }
        return plugins.isEmpty ? "None" : plugins.sorted().joined(separator: ", ")
    }

    private static func mcpSummary(_ mcp: [String: AgentMcpTools]?) -> String {
        guard let mcp else { return "All" }
        guard !mcp.isEmpty else { return "None" }
        return mcp.keys.sorted().map { server -> String in
            switch mcp[server] ?? .all {
            case .all: "\(server): all tools"
            case .tools(let names): "\(server): \(names.count) tools"
            }
        }.joined(separator: ", ")
    }

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`.
    override var rowStyle: ListRowStyle { .card }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        let rowInsets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        switch item {
        case .hero:
            guard let agent else { return }
            ListScreen.buttonRow(
                cell,
                identifier: "agents.detail.icon",
                label: "Icon",
                value: IconPickerPurpose.agent.description(agent.definition.icon),
                hint: "Opens the Agent icon picker"
            ) { [weak self] in
                self?.showsIconPicker = true
            }
            // A portrait, not a card: the circle sits on the page itself.
            ListScreen.background(cell, grouped: false, palette: palette)
            let assets = connection.iconAssetCache
            cell.contentConfiguration = ControlViewContent(
                insets: .init(top: 20, leading: 0, bottom: 12, trailing: 0)
            ) {
                // The Agent's own page plays its icon, like the picker, and shows
                // it as a circle.
                let icon = IconChoiceUIView(frameSize: Self.heroSide, animates: true, shape: .circle)
                icon.apply(.choice(agent.definition.icon, purpose: .agent, sandbox: false), assetCache: assets)
                icon.accessibilityIdentifier = "agents.detail.iconImage"
                return ControlRowViews.stack([icon], spacing: 0, alignment: .center)
            }
        case .value(let title, let value):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                ControlRowViews.valueRow(title, value, palette: palette)
            }
        case .block(let title, let value):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: rowInsets) {
                let block = ControlRowViews.stack([
                    ControlRowViews.label(title, style: .subheadline, color: palette.ui.comment),
                    ControlRowViews.selectableText(value, style: .body, color: palette.ui.fg),
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
                    ControlRowViews.label(title, style: .subheadline, weight: .medium, color: palette.ui.fg),
                    ControlRowViews.selectableText(value, style: .caption1, color: palette.ui.comment),
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
                    ControlRowViews.label(instructions.text, style: .body, color: palette.ui.fg),
                    ControlRowViews.symbolLabel(
                        "Read and comment",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        style: .caption1,
                        weight: .medium,
                        color: palette.ui.blue
                    ),
                ], spacing: 10, alignment: .leading)
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
            let tint = palette.ui.blue.withAlphaComponent(enabled ? 1 : 0.4)
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
            let tint = palette.ui.blue.withAlphaComponent(enabled ? 1 : 0.4)
            content.textProperties.color = tint
            content.imageProperties.tintColor = tint
            cell.contentConfiguration = content
        case .caption(let text):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(text, style: .caption1, color: palette.ui.comment)
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
                        serverName: root.windowServerName,
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
                    let apiClient = connection.apiClient
                    return IconPickerViewController(source: .init(
                        purpose: .agent,
                        savedValue: agent.definition.icon,
                        assetCache: connection.iconAssetCache,
                        uploadAsset: IconPickerViewController.uploadAsset(using: apiClient),
                        commit: { icon in
                            guard let apiClient else { throw IconPickerViewController.offlineError }
                            saved(try await apiClient.updateAgentIcon(agentId: agent.id, icon: icon))
                        }
                    ))
                }
            }
        )
        definitionReview.update(
            id: showsDefinitionReview && agent != nil ? "definition" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in
                self?.showsDefinitionReview = false
                // The prompt may have been edited in place: the row and the version
                // this page holds follow the server.
                self?.setNeedsLoad()
            },
            screen: { [weak self] in
                .controller {
                    ReviewableControlMarkdownViewController(
                        content: agent.flatMap { self?.definitionMarkdown($0) } ?? "",
                        domain: .agents,
                        targetId: agent?.id ?? "",
                        targetName: agent?.name ?? "",
                        sourceLabel: "\(agent?.name ?? "") definition",
                        sourcePath: "Agents/\(agent?.id ?? "")/Definition.md",
                        // The pencil edits the prompt alone, not the pieced-together
                        // document, and keeps the Agent's append/replace mode.
                        subject: agent.map { .agentInstructions(agentId: $0.id) } ?? .snapshot,
                        connection: connection,
                        // After an edit the reader shows the whole definition again,
                        // read from the Agent the server now holds.
                        refreshDocument: { [weak self] in
                            guard let self, let id = agent?.id,
                                  let fresh = try? await connection.apiClient?.getAgent(id) else { return nil }
                            return self.definitionMarkdown(fresh)
                        }
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
        let capabilities = definition.capabilities ?? AgentCapabilities()
        let context = definition.context ?? AgentContext()
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
            "",
            "## Tools",
            "",
            "- **Pi Tools:** \(AgentManagementPresentation.agentToolsSummary(tools: capabilities.tools))",
            "- **Edits files:** \(Self.yesNo(capabilities.canEditFiles))",
            "- **Ask me:** \(Self.yesNo(capabilities.canAsk))",
            "- **Notify me:** \(Self.yesNo(capabilities.canNotify))",
            "- **Delegate:** \(Self.yesNo(capabilities.canDelegate))",
            "- **Plugins:** \(Self.pluginSummary(capabilities.plugins))",
            "- **MCP Servers:** \(Self.mcpSummary(capabilities.mcp))",
            "",
            "## Context",
            "",
            "- **Read AGENTS.md:** \(Self.yesNo(context.readsContextFiles))",
            "- **Read past sessions:** \(Self.yesNo(context.readsSessionHistory))",
            "- **Skills:** \(context.skills.map { $0.isEmpty ? "None" : $0.sorted().joined(separator: ", ") } ?? "All")",
        ]
        return lines.joined(separator: "\n")
    }

    private func allowedWorkspaceNames(_ ids: [String]?) -> String {
        guard let ids else { return "Any" }
        let workspaces = connection.workspaceStore.workspaces
        return ids.map { id in workspaces.first(where: { $0.id == id })?.name ?? id }.joined(separator: ", ")
    }

    // MARK: - Actions

    /// The Agent and its resource catalogs: the base runs it on every appearance,
    /// on pull to refresh, and after a Retry. A failed catalog load leaves the
    /// store's own sync state to its rows.
    override func load() async throws {
        let apiClient = try requireAPIClient()
        guard let serverId = connection.currentServerId else { throw noConnectionFailure() }
        agent = try await apiClient.getAgent(agentId)
        guard !Task.isCancelled else { return }
        // A page that just loaded says nothing of a change that failed before.
        error = nil
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
