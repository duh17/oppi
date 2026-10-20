import Observation
import UIKit

enum AgentResourceSelectionMode: String, CaseIterable {
    case inherit
    case exact

    var title: String {
        switch self {
        case .inherit: "Inherit Pi settings"
        case .exact: "Exact selection"
        }
    }
}

/// What Edit Agent edits. The screen and the selection pages it pushes read
/// and change this one model: each pushed page is its own SwiftUI graph, so a
/// binding into screen state would not refresh it.
@MainActor @Observable
final class AgentNativeEditDraft {
    let agent: StoredAgentDefinition
    let connection: ServerConnection

    var name: String
    var description: String
    var usesCustomInstructions: Bool
    var instructionMode: AgentInstructionMode
    var instructionText: String
    var model: String
    var thinkingLevel: ThinkingLevel?
    /// This device's chat style for the Agent's sessions; nil follows
    /// Settings → Chat → Style. Never sent to the server.
    var chatStyle: AppPreferences.ChatDisplay.Style?
    var toolSelectionMode: AgentToolSelectionMode
    var selectedToolNames: Set<String>
    var skillSelectionMode: AgentResourceSelectionMode
    var selectedSkillPaths: Set<String>
    var extensionSelectionMode: AgentResourceSelectionMode
    var selectedExtensionIds: Set<String>
    var workspaceConstraintMode: AgentResourceSelectionMode
    var selectedAllowedWorkspaceIds: Set<String>
    var requiredRuntime: WorkspaceRuntime?
    var extensionToolDetailsById: [String: ServerExtensionDetail] = [:]
    var isLoadingExtensionTools = false
    var isLoadingResources = false
    var isSaving = false
    var error: String?
    @ObservationIgnored private var extensionToolInspectionIds: Set<String> = []

    init(agent: StoredAgentDefinition, connection: ServerConnection) {
        self.agent = agent
        self.connection = connection
        let definition = agent.definition
        let defaults = definition.sessionDefaults
        name = definition.name
        description = definition.description ?? ""
        usesCustomInstructions = definition.instructions != nil
        instructionMode = definition.instructions?.mode ?? .append
        instructionText = definition.instructions?.text ?? ""
        model = defaults?.model ?? ""
        thinkingLevel = defaults?.thinkingLevel
        chatStyle = connection.currentServerId.flatMap {
            AppPreferences.ChatDisplay.agentStyle(serverId: $0, agentId: agent.id)
        }
        toolSelectionMode = if defaults?.tools != nil {
            .exact
        } else if defaults?.excludeTools != nil || defaults?.noTools != nil {
            .existingPolicy
        } else {
            .inherit
        }
        selectedToolNames = Set(defaults?.tools ?? [])
        skillSelectionMode = definition.resources?.skillPaths == nil ? .inherit : .exact
        selectedSkillPaths = Set(definition.resources?.skillPaths ?? [])
        extensionSelectionMode = definition.resources?.extensionIds == nil ? .inherit : .exact
        selectedExtensionIds = Set(definition.resources?.extensionIds ?? [])
        workspaceConstraintMode = definition.launchConstraints?.allowedWorkspaceIds == nil ? .inherit : .exact
        selectedAllowedWorkspaceIds = Set(definition.launchConstraints?.allowedWorkspaceIds ?? [])
        requiredRuntime = definition.launchConstraints?.requiredRuntime
    }

    // MARK: Validation

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!usesCustomInstructions
                || !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && canSaveResourceSelections
            && canSaveLaunchConstraints
            && canSaveToolSelection
            && !isSaving
    }

    private var canSaveLaunchConstraints: Bool {
        guard workspaceConstraintMode == .exact else { return true }
        guard !selectedAllowedWorkspaceIds.isEmpty else { return false }
        return workspaces.contains { workspace in
            selectedAllowedWorkspaceIds.contains(workspace.id)
                && (requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true)
        }
    }

    private var canSaveResourceSelections: Bool {
        let skillsAllowed = skillSelectionMode != .exact
            || AgentResourceCatalogState.isExactSelectionSaveAllowed(
                initialSelectionWasInherited: agent.definition.resources?.skillPaths == nil,
                catalogState: skillCatalogState
            )
        let extensionsAllowed = extensionSelectionMode != .exact
            || AgentResourceCatalogState.isExactSelectionSaveAllowed(
                initialSelectionWasInherited: agent.definition.resources?.extensionIds == nil,
                catalogState: extensionCatalogState
            )
        return skillsAllowed && extensionsAllowed
    }

    private var canSaveToolSelection: Bool {
        guard toolSelectionMode == .exact else { return true }
        return agent.definition.sessionDefaults?.tools != nil || !availableBuiltInTools.isEmpty
    }

    // MARK: Catalogs

    var workspaces: [Workspace] { connection.workspaceStore.workspaces }

    var availableBuiltInTools: [ServerToolSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.builtInTools(forServer: serverId)
    }

    var availableSkills: [ServerSkillSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.skills(forServer: serverId)
    }

    var availableExtensions: [ServerExtensionSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.extensions(forServer: serverId)
    }

    var effectiveExtensionToolGroups: [AgentExtensionToolGroup] {
        let effectiveExtensions = availableExtensions.filter { resource in
            switch extensionSelectionMode {
            case .inherit:
                resource.state == .on
            case .exact:
                selectedExtensionIds.contains(resource.id)
            }
        }
        return effectiveExtensions.compactMap { resource in
            let details = extensionToolDetailsById[resource.id]
            let tools = details?.contributedToolDetails
                ?? resource.contributedToolDetails
                ?? (details?.contributedTools ?? resource.contributedTools ?? []).map {
                    ServerToolSummary(name: $0)
                }
            guard !tools.isEmpty else { return nil }
            return AgentExtensionToolGroup(id: resource.id, name: resource.name, tools: tools)
        }
    }

    var unavailableSelectedToolNames: [String] {
        let known = Set(availableBuiltInTools.map(\.name) + effectiveExtensionToolGroups.flatMap { $0.tools.map(\.name) })
        return selectedToolNames.subtracting(known).sorted()
    }

    var effectiveDefaultToolNames: Set<String> {
        let defaults = agent.definition.sessionDefaults
        var names = Set(availableBuiltInTools.filter { $0.defaultEnabled == true }.map(\.name))
        names.formUnion(effectiveExtensionToolGroups.flatMap { $0.tools.map(\.name) })
        names.subtract(defaults?.excludeTools ?? [])
        if defaults?.noTools == .all {
            names.removeAll()
        } else if defaults?.noTools == .builtin {
            names.subtract(availableBuiltInTools.map(\.name))
        }
        return names
    }

    var existingToolPolicySummary: String? {
        let defaults = agent.definition.sessionDefaults
        guard defaults?.tools == nil,
              defaults?.excludeTools != nil || defaults?.noTools != nil else { return nil }
        if let noTools = defaults?.noTools {
            return noTools.displayName
        }
        if let excluded = defaults?.excludeTools, !excluded.isEmpty {
            return "Excludes \(excluded.joined(separator: ", "))"
        }
        return "Existing advanced policy"
    }

    var skillCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .skills, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedSkills(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availableSkills.isEmpty
        )
    }

    var extensionCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availableExtensions.isEmpty
        )
    }

    // MARK: Summaries

    var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    var toolSelectionSummary: String {
        switch toolSelectionMode {
        case .inherit:
            return "Pi defaults"
        case .exact:
            return selectedToolNames.isEmpty ? "None" : "\(selectedToolNames.count) selected"
        case .existingPolicy:
            return "Existing policy"
        }
    }

    /// Changes when the selected extensions or the catalog do, which is when
    /// the screen re-inspects selected extensions for their tools.
    var extensionToolRefreshKey: String {
        let catalogIds = availableExtensions.map(\.id).sorted().joined(separator: ",")
        let selectedIds = selectedExtensionIds.sorted().joined(separator: ",")
        return "\(extensionSelectionMode.rawValue):\(selectedIds):\(catalogIds)"
    }

    // MARK: Loading

    func refreshResources(apiClient: APIClient?) async {
        guard let apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    func refreshSelectedExtensionToolDetails(apiClient: APIClient?) async {
        guard extensionSelectionMode == .exact, let apiClient else { return }
        let resources = availableExtensions.filter {
            selectedExtensionIds.contains($0.id)
                && $0.contributedToolDetails == nil
                && $0.contributedTools == nil
                && extensionToolDetailsById[$0.id] == nil
                && !extensionToolInspectionIds.contains($0.id)
        }
        guard !resources.isEmpty else { return }

        isLoadingExtensionTools = true
        defer { isLoadingExtensionTools = false }
        for resource in resources {
            guard !Task.isCancelled else { return }
            guard extensionToolDetailsById[resource.id] == nil,
                  extensionToolInspectionIds.insert(resource.id).inserted else { continue }
            defer { extensionToolInspectionIds.remove(resource.id) }
            do {
                extensionToolDetailsById[resource.id] = try await apiClient.inspectAgentExtensionTools(id: resource.id)
            } catch {
                // Keep the resource selection intact. The tool screen presents
                // saved unknown names as unavailable rather than dropping them.
            }
        }
    }

    // MARK: Saving

    /// Sends the definition, then keeps the chat style on this device.
    /// Nil when the save failed; `error` says why.
    func save(apiClient: APIClient?) async -> StoredAgentDefinition? {
        guard let apiClient else {
            error = "Server is offline"
            return nil
        }
        isSaving = true
        defer { isSaving = false }

        let originalDefaults = agent.definition.sessionDefaults
        let toolPolicy: (tools: [String]?, excluded: [String]?, noTools: AgentNoToolsMode?)
        switch toolSelectionMode {
        case .inherit:
            toolPolicy = (nil, nil, nil)
        case .exact:
            toolPolicy = (selectedToolNames.sorted(), nil, nil)
        case .existingPolicy:
            toolPolicy = (originalDefaults?.tools, originalDefaults?.excludeTools, originalDefaults?.noTools)
        }

        do {
            let updated = try await apiClient.updateAgentNative(
                agentId: agent.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.managementNilIfBlank,
                instructions: usesCustomInstructions
                    ? AgentInstructions(mode: instructionMode, text: instructionText)
                    : nil,
                model: model.managementNilIfBlank,
                thinkingLevel: thinkingLevel,
                skillPaths: skillSelectionMode == .inherit ? nil : selectedSkillPaths.sorted(),
                extensionIds: extensionSelectionMode == .inherit ? nil : selectedExtensionIds.sorted(),
                launchConstraints: resolvedLaunchConstraints,
                previouslyHadLaunchConstraints: agent.definition.launchConstraints != nil,
                tools: toolPolicy.tools,
                excludeTools: toolPolicy.excluded,
                noTools: toolPolicy.noTools
            )
            if let serverId = connection.currentServerId {
                AppPreferences.ChatDisplay.setAgentStyle(chatStyle, serverId: serverId, agentId: agent.id)
            }
            return updated
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private var resolvedLaunchConstraints: AgentLaunchConstraints? {
        let constraints = AgentLaunchConstraints(
            allowedWorkspaceIds: workspaceConstraintMode == .inherit ? nil : selectedAllowedWorkspaceIds.sorted(),
            requiredRuntime: requiredRuntime
        )
        return constraints.isEmpty ? nil : constraints
    }
}

/// Edit Agent: a saved Agent's definition, plus this device's chat style for
/// its sessions. Presented in a navigation controller; the selection pages
/// are SwiftUI screens it pushes (`AgentNativeEditPages`) and the model
/// picker is a UIKit sheet over it.
final class AgentNativeEditViewController: UIViewController, UICollectionViewDelegate {
    private let draft: AgentNativeEditDraft
    private let apiClient: APIClient?
    private let onSaved: (StoredAgentDefinition) -> Void
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var renderedRows: RowInputs?
    private var loadTask: Task<Void, Never>?
    private var extensionToolTask: Task<Void, Never>?
    private var extensionToolRefreshKey: String?
    private lazy var cancelItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        Router.finish(self)
    })
    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = "Save"
        item.accessibilityIdentifier = "agent.nativeEdit.save"
        return item
    }()
    private lazy var savingItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityLabel = "Saving"
        return UIBarButtonItem(customView: spinner)
    }()

    private enum Section: Hashable { case identity, prompt, defaults, chat, resources, constraints, error }
    private enum Item: Hashable {
        case name, description
        case customPrompt, promptMode, prompt
        case model, useServerModel, thinking, tools
        case chatStyle
        case skillMode, skills, extensionMode, extensions, loadingResources, skillStatus, extensionStatus
        case runtime, workspaceMode, workspaces
        case error
    }

    init(
        agent: StoredAgentDefinition,
        apiClient: APIClient?,
        connection: ServerConnection,
        onSaved: @escaping (StoredAgentDefinition) -> Void
    ) {
        draft = AgentNativeEditDraft(agent: agent, connection: connection)
        self.apiClient = apiClient
        self.onSaved = onSaved
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = "Edit Agent"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // The text editors grow as their text does.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.accessibilityIdentifier = "agent.nativeEdit.list"
        pinCollectionViewAboveKeyboard()
        installDataSource()
        navigationItem.leftBarButtonItem = cancelItem
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceDidChange), name: .oppiThemeDidChange, object: nil)
        // The Chat Style menu names the Settings style it follows.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil
        )
        loadTask = Task { [draft, apiClient] in await draft.refreshResources(apiClient: apiClient) }
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            loadTask?.cancel()
            extensionToolTask?.cancel()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appearanceDidChange() { setNeedsUpdateProperties() }

    /// The form ends at the keyboard, so the prompt editor can scroll above it.
    private func pinCollectionViewAboveKeyboard() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let maxWidth = collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: IPadReadableContentWidth.form)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth,
            fillWidth,
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Everything a row shows is read here, so any change re-runs this pass.
        // UIKit also runs it for a presented menu or a trait change, and
        // applying rebuilds every pop-up button, which dismisses the menu a
        // tap just opened; apply only when a row's input changed.
        let rows = RowInputs(draft: draft, themeID: themeID, settingsChatStyle: AppPreferences.ChatDisplay.style)
        if rows != renderedRows {
            renderedRows = rows
            applySnapshot()
        }

        let isSaving = draft.isSaving
        let trailingItem = isSaving ? savingItem : saveItem
        if navigationItem.rightBarButtonItem !== trailingItem {
            navigationItem.rightBarButtonItem = trailingItem
        }
        saveItem.isEnabled = draft.canSave
        cancelItem.isEnabled = !isSaving
        collectionView.isUserInteractionEnabled = !isSaving
        isModalInPresentation = isSaving

        let key = draft.extensionToolRefreshKey
        if key != extensionToolRefreshKey {
            extensionToolRefreshKey = key
            extensionToolTask?.cancel()
            extensionToolTask = Task { [draft, apiClient] in
                await draft.refreshSelectedExtensionToolDetails(apiClient: apiClient)
            }
        }
    }

    /// Every value a row is drawn from.
    private struct RowInputs: Equatable {
        let name: String
        let description: String
        let usesCustomInstructions: Bool
        let instructionMode: AgentInstructionMode
        let instructionText: String
        let model: String
        let thinkingLevel: ThinkingLevel?
        let chatStyle: AppPreferences.ChatDisplay.Style?
        let toolSelectionMode: AgentToolSelectionMode
        let selectedToolNames: Set<String>
        let skillSelectionMode: AgentResourceSelectionMode
        let selectedSkillPaths: Set<String>
        let extensionSelectionMode: AgentResourceSelectionMode
        let selectedExtensionIds: Set<String>
        let workspaceConstraintMode: AgentResourceSelectionMode
        let selectedAllowedWorkspaceIds: Set<String>
        let requiredRuntime: WorkspaceRuntime?
        let skillCatalogState: AgentResourceCatalogState
        let extensionCatalogState: AgentResourceCatalogState
        let isLoadingResources: Bool
        let error: String?
        /// The Settings row shows the Settings-wide style.
        let settingsChatStyle: AppPreferences.ChatDisplay.Style
        let themeID: ThemeID

        @MainActor
        init(draft: AgentNativeEditDraft, themeID: ThemeID, settingsChatStyle: AppPreferences.ChatDisplay.Style) {
            name = draft.name
            description = draft.description
            usesCustomInstructions = draft.usesCustomInstructions
            instructionMode = draft.instructionMode
            instructionText = draft.instructionText
            model = draft.model
            thinkingLevel = draft.thinkingLevel
            chatStyle = draft.chatStyle
            toolSelectionMode = draft.toolSelectionMode
            selectedToolNames = draft.selectedToolNames
            skillSelectionMode = draft.skillSelectionMode
            selectedSkillPaths = draft.selectedSkillPaths
            extensionSelectionMode = draft.extensionSelectionMode
            selectedExtensionIds = draft.selectedExtensionIds
            workspaceConstraintMode = draft.workspaceConstraintMode
            selectedAllowedWorkspaceIds = draft.selectedAllowedWorkspaceIds
            requiredRuntime = draft.requiredRuntime
            skillCatalogState = draft.skillCatalogState
            extensionCatalogState = draft.extensionCatalogState
            isLoadingResources = draft.isLoadingResources
            error = draft.error
            self.settingsChatStyle = settingsChatStyle
            self.themeID = themeID
        }
    }

    private func save() {
        guard draft.canSave else { return }
        view.endEditing(true)
        Task { [weak self] in
            guard let self, let updated = await draft.save(apiClient: apiClient) else { return }
            onSaved(updated)
            Router.finish(self)
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.identity, .prompt, .defaults, .chat, .resources, .constraints])
        snapshot.appendItems([.name, .description], toSection: .identity)
        snapshot.appendItems(
            draft.usesCustomInstructions ? [.customPrompt, .promptMode, .prompt] : [.customPrompt],
            toSection: .prompt
        )
        snapshot.appendItems(
            [.model] + (draft.model.isEmpty ? [] : [.useServerModel]) + [.thinking, .tools],
            toSection: .defaults
        )
        snapshot.appendItems([.chatStyle], toSection: .chat)

        var resources: [Item] = [.skillMode]
        if draft.skillSelectionMode == .exact { resources.append(.skills) }
        resources.append(.extensionMode)
        if draft.extensionSelectionMode == .exact { resources.append(.extensions) }
        if draft.isLoadingResources { resources.append(.loadingResources) }
        if draft.skillCatalogState.statusMessage(for: "Skills") != nil { resources.append(.skillStatus) }
        if draft.extensionCatalogState.statusMessage(for: "Extensions") != nil { resources.append(.extensionStatus) }
        snapshot.appendItems(resources, toSection: .resources)

        snapshot.appendItems(
            [.runtime, .workspaceMode] + (draft.workspaceConstraintMode == .exact ? [.workspaces] : []),
            toSection: .constraints
        )
        if draft.error != nil {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error], toSection: .error)
        }
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
        refreshVisibleFooters()
    }

    private func installDataSource() {
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                text: draft.name,
                placeholder: "Name",
                identifier: "agent.nativeEdit.name",
                autocapitalization: .sentences,
                autocorrection: .default
            ) { [weak self] in self?.draft.name = $0 }
        }
        let textView = UICollectionView.CellRegistration<AgentNativeEditTextViewCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let segmented = UICollectionView.CellRegistration<AgentNativeEditSegmentedCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                titles: ["Append", "Replace"],
                selectedIndex: draft.instructionMode == .append ? 0 : 1,
                identifier: "agent.nativeEdit.promptMode"
            ) { [weak self] index in
                self?.draft.instructionMode = index == 0 ? .append : .replace
            }
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.section(at: indexPath).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            self?.configureFooter(view, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .name:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            case .description, .prompt:
                collectionView.dequeueConfiguredReusableCell(using: textView, for: indexPath, item: item)
            case .promptMode:
                collectionView.dequeueConfiguredReusableCell(using: segmented, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func section(at indexPath: IndexPath) -> Section? {
        dataSource?.sectionIdentifier(for: indexPath.section)
    }

    private func configureFooter(_ view: UICollectionViewListCell, at indexPath: IndexPath) {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = section(at: indexPath).flatMap(footer)
        content.textProperties.numberOfLines = 0
        view.contentConfiguration = content
    }

    /// Diffable updates keep a section's footer view, so the System Prompt
    /// footer is rewritten here when the toggle or Append/Replace changes.
    /// Reloading the section would rebuild the prompt editor mid-typing.
    private func refreshVisibleFooters() {
        let kind = UICollectionView.elementKindSectionFooter
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? UICollectionViewListCell else { continue }
            configureFooter(view, at: indexPath)
        }
    }

    private static func header(_ section: Section) -> String? {
        switch section {
        case .identity: "Identity"
        case .prompt: "System Prompt"
        case .defaults: "Pi Session Defaults"
        case .chat: "Chat"
        case .resources: "Resources"
        case .constraints: "Launch Constraints"
        case .error: nil
        }
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .prompt:
            guard draft.usesCustomInstructions else { return "Uses the server's default system prompt." }
            return draft.instructionMode == .append
                ? "Adds these instructions after the server's default system prompt."
                : "Uses these instructions instead of the server's default system prompt."
        case .chat:
            return "How this Agent's sessions look on this device. Settings follows Settings \u{2192} Chat \u{2192} Style. Other devices keep their own choice."
        case .resources:
            return "Inherit follows normal Pi discovery. Exact selection can be empty to give this Agent no Skills or optional Extensions. Exact selections explicitly override server discovery, including resources currently Disabled or Off, for this Agent only."
        case .constraints:
            return "Only compatible workspaces appear when this Agent starts. The server enforces the same restrictions for API and scheduled launches."
        case .identity, .defaults, .error:
            return nil
        }
    }

    // MARK: - Cells

    private func configure(_ cell: AgentNativeEditTextViewCell, item: Item) {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        switch item {
        case .description:
            cell.configure(
                text: draft.description,
                placeholder: "Description (optional)",
                identifier: "agent.nativeEdit.description",
                accessibilityLabel: "Description",
                minHeight: lineHeight * 2 + AgentNativeEditTextViewCell.verticalInsets,
                maxHeight: lineHeight * 5 + AgentNativeEditTextViewCell.verticalInsets,
                onChange: { [weak self] in self?.draft.description = $0 },
                onCaretMove: { [weak self] in self?.scrollCaretVisible(in: $0) }
            )
        case .prompt:
            cell.configure(
                text: draft.instructionText,
                placeholder: "",
                identifier: "agent.nativeEdit.prompt",
                accessibilityLabel: "System prompt",
                minHeight: 180,
                maxHeight: nil,
                onChange: { [weak self] in self?.draft.instructionText = $0 },
                onCaretMove: { [weak self] in self?.scrollCaretVisible(in: $0) }
            )
        default:
            break
        }
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = ThemeRuntimeState.currentThemeID().palette
        var content = UIListContentConfiguration.valueCell()
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.accessibilityTraits = .none
        switch item {
        case .customPrompt:
            content.text = "Custom system prompt"
            cell.accessories = [.settingsToggle(draft.usesCustomInstructions, identifier: "agent.nativeEdit.customPrompt") { [weak self] in
                self?.draft.usesCustomInstructions = $0
            }]
        case .model:
            content.text = "Model"
            content.secondaryText = draft.modelDisplayName
            navigationRow(cell, identifier: "agent.nativeEdit.model")
        case .useServerModel:
            content = UIListContentConfiguration.cell()
            content.text = "Use Server Default Model"
            content.textProperties.color = UIColor(palette.blue)
            cell.accessibilityIdentifier = "agent.nativeEdit.useServerModel"
            cell.accessibilityTraits = .button
        case .thinking:
            content.text = "Thinking"
            let levels: [ThinkingLevel?] = [nil] + ThinkingLevel.allCases.map(Optional.some)
            cell.accessories = [.settingsPopUpMenu(
                identifier: "agent.nativeEdit.thinking",
                options: levels.map { level in
                    (
                        title: level?.displayTitle ?? "Default",
                        selected: draft.thinkingLevel == level,
                        action: { [weak self] in self?.draft.thinkingLevel = level }
                    )
                }
            )]
        case .tools:
            content.text = "Tools"
            content.secondaryText = draft.toolSelectionSummary
            navigationRow(cell, identifier: "agent.nativeEdit.tools")
        case .chatStyle:
            content.text = "Chat Style"
            let settingsLabel = "Settings (\(AppPreferences.ChatDisplay.style.label))"
            let styles: [AppPreferences.ChatDisplay.Style?] = [nil] + AppPreferences.ChatDisplay.Style.allCases.map(Optional.some)
            cell.accessories = [.settingsPopUpMenu(
                identifier: "agent.nativeEdit.chatStyle",
                options: styles.map { style in
                    (
                        title: style?.label ?? settingsLabel,
                        selected: draft.chatStyle == style,
                        action: { [weak self] in self?.draft.chatStyle = style }
                    )
                }
            )]
        case .skillMode:
            content.text = "Skills"
            cell.accessories = [modeMenu(draft.skillSelectionMode, identifier: "agent.nativeEdit.skillMode") { [weak self] in
                self?.draft.skillSelectionMode = $0
            }]
        case .skills:
            content.text = "Selected Skills"
            content.secondaryText = Self.selectionCount(draft.selectedSkillPaths.count)
            navigationRow(cell, identifier: "agent.nativeEdit.skills")
        case .extensionMode:
            content.text = "Extensions"
            cell.accessories = [modeMenu(draft.extensionSelectionMode, identifier: "agent.nativeEdit.extensionMode") { [weak self] in
                self?.draft.extensionSelectionMode = $0
            }]
        case .extensions:
            content.text = "Selected Extensions"
            content.secondaryText = Self.selectionCount(draft.selectedExtensionIds.count)
            navigationRow(cell, identifier: "agent.nativeEdit.extensions")
        case .loadingResources:
            content = UIListContentConfiguration.cell()
            content.text = "Refreshing discovered resources\u{2026}"
            content.textProperties.font = .preferredFont(forTextStyle: .caption1)
            content.textProperties.color = UIColor(palette.comment)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
        case .skillStatus, .extensionStatus:
            content = UIListContentConfiguration.cell()
            content.text = item == .skillStatus
                ? draft.skillCatalogState.statusMessage(for: "Skills")
                : draft.extensionCatalogState.statusMessage(for: "Extensions")
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = UIColor(palette.orange)
            content.textProperties.font = .preferredFont(forTextStyle: .caption1)
            content.textProperties.color = UIColor(palette.orange)
        case .runtime:
            content.text = "Runtime"
            cell.accessories = [.settingsPopUpMenu(
                identifier: "agent.nativeEdit.requiredRuntime",
                options: [
                    (title: "Any runtime", selected: draft.requiredRuntime == nil, action: { [weak self] in self?.draft.requiredRuntime = nil }),
                    (title: "Host", selected: draft.requiredRuntime == .host, action: { [weak self] in self?.draft.requiredRuntime = .host }),
                    (title: "Sandbox", selected: draft.requiredRuntime == .sandbox, action: { [weak self] in self?.draft.requiredRuntime = .sandbox }),
                ]
            )]
        case .workspaceMode:
            content.text = "Workspaces"
            cell.accessories = [.settingsPopUpMenu(
                identifier: "agent.nativeEdit.workspaceMode",
                options: [
                    (title: "Any workspace", selected: draft.workspaceConstraintMode == .inherit, action: { [weak self] in self?.draft.workspaceConstraintMode = .inherit }),
                    (title: "Allowed list", selected: draft.workspaceConstraintMode == .exact, action: { [weak self] in self?.draft.workspaceConstraintMode = .exact }),
                ]
            )]
        case .workspaces:
            content.text = "Allowed Workspaces"
            content.secondaryText = Self.selectionCount(draft.selectedAllowedWorkspaceIds.count)
            navigationRow(cell, identifier: "agent.nativeEdit.workspaces")
        case .error:
            content = UIListContentConfiguration.cell()
            content.text = draft.error
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = UIColor(palette.red)
            content.textProperties.color = UIColor(palette.red)
        case .name, .description, .promptMode, .prompt:
            break
        }
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
    }

    private func navigationRow(_ cell: UICollectionViewListCell, identifier: String) {
        cell.accessories = [.disclosureIndicator()]
        cell.accessibilityIdentifier = identifier
        cell.accessibilityTraits = .button
    }

    private func modeMenu(
        _ mode: AgentResourceSelectionMode,
        identifier: String,
        onSelect: @escaping (AgentResourceSelectionMode) -> Void
    ) -> UICellAccessory {
        .settingsPopUpMenu(
            identifier: identifier,
            options: AgentResourceSelectionMode.allCases.map { option in
                (title: option.title, selected: option == mode, action: { onSelect(option) })
            }
        )
    }

    private static func selectionCount(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }

    private func scrollCaretVisible(in textView: UITextView) {
        // After the cell grows for the new line.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, let range = textView.selectedTextRange else { return }
            let caret = textView.convert(textView.caretRect(for: range.end), to: collectionView)
            collectionView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -12), animated: false)
        }
    }

    // MARK: - Selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource?.itemIdentifier(for: indexPath) {
        case .model, .useServerModel, .tools, .skills, .extensions, .workspaces: true
        default: false
        }
    }

    /// The picker gets this editor's server explicitly.
    private func presentModelPicker(root: AppRootEnvironment) {
        let draft = draft
        let picker = ModelPickerViewController(
            currentModel: draft.model.managementNilIfBlank,
            chatState: draft.connection.chatState,
            apiClient: apiClient,
            onSelect: { selected in
                draft.model = ModelSwitchPolicy.fullModelID(for: selected)
                AppPreferences.RecentModels.record(draft.model)
            }
        )
        Router.present(picker, presentation: .sheet.inNavigation(), from: self, theme: root.themeStore, onDismiss: nil)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        if item == .useServerModel {
            draft.model = ""
            return
        }
        guard let root = HostFactory.root(near: self) else { return }
        let navigator = ScreenNavigator.forUIKitScreen(self, root: root)
        switch item {
        case .model:
            presentModelPicker(root: root)
        case .tools:
            AgentNativeEditPages.pushTools(draft, navigator: navigator)
        case .skills:
            AgentNativeEditPages.pushSkills(draft, navigator: navigator)
        case .extensions:
            AgentNativeEditPages.pushExtensions(draft, navigator: navigator)
        case .workspaces:
            AgentNativeEditPages.pushWorkspaces(draft, navigator: navigator)
        default:
            break
        }
    }
}

/// A growing text editor in an inset-grouped list, with a placeholder. Past
/// `maxHeight` it scrolls inside the row.
final class AgentNativeEditTextViewCell: UICollectionViewListCell, UITextViewDelegate {
    static let verticalInsets: CGFloat = 22

    let textView = UITextView()
    private let placeholderLabel = UILabel()
    private var onChange: ((String) -> Void)?
    private var onCaretMove: ((UITextView) -> Void)?
    private var minHeight: NSLayoutConstraint?
    private var cappedHeight: NSLayoutConstraint?
    private var maxHeight: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: Self.verticalInsets / 2, left: 0, bottom: Self.verticalInsets / 2, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        contentView.addSubview(textView)
        contentView.addSubview(placeholderLabel)
        let minHeight = textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let bottom = textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottom,
            minHeight,
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: Self.verticalInsets / 2),
        ])
        self.minHeight = minHeight
        accessibilityElements = [textView]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        text: String,
        placeholder: String,
        identifier: String,
        accessibilityLabel: String,
        minHeight: CGFloat,
        maxHeight: CGFloat?,
        onChange: @escaping (String) -> Void,
        onCaretMove: @escaping (UITextView) -> Void
    ) {
        self.onChange = onChange
        self.onCaretMove = onCaretMove
        if !textView.isFirstResponder, textView.text != text {
            textView.text = text
        }
        textView.accessibilityIdentifier = identifier
        textView.accessibilityLabel = accessibilityLabel
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !textView.text.isEmpty
        self.minHeight?.constant = minHeight
        self.maxHeight = maxHeight
        updateScrolling()
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateScrolling()
        onChange?(textView.text)
        onCaretMove?(textView)
    }

    /// Grows with its text up to `maxHeight`, then holds that height and scrolls.
    private func updateScrolling() {
        var scrolls = false
        if let maxHeight, textView.bounds.width > 0 {
            let fitting = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            ).height
            scrolls = fitting > maxHeight
            cappedHeight = cappedHeight ?? textView.heightAnchor.constraint(equalToConstant: maxHeight)
            cappedHeight?.constant = maxHeight
        }
        guard scrolls != textView.isScrollEnabled else { return }
        cappedHeight?.isActive = scrolls
        textView.isScrollEnabled = scrolls
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrolling()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onCaretMove = nil
        textView.accessibilityIdentifier = nil
    }
}

/// A full-width segmented control row.
final class AgentNativeEditSegmentedCell: UICollectionViewListCell {
    private let control = UISegmentedControl()
    private var onChange: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(control.selectedSegmentIndex)
        }, for: .valueChanged)
        contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        accessibilityElements = [control]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(titles: [String], selectedIndex: Int, identifier: String, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        if (0..<control.numberOfSegments).map({ control.titleForSegment(at: $0) }) != titles {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() {
                control.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
        control.selectedSegmentIndex = selectedIndex
        control.accessibilityIdentifier = identifier
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
    }
}
