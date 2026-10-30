import UIKit

/// Edit Agent: a saved Agent's definition, plus this device's chat style for
/// its sessions. A draft form on the settings base: its edits live in
/// `AgentNativeEditDraft`, Save sends them and Cancel drops them. Presented in
/// a navigation controller; the pages that choose tools, Skills, Extensions,
/// and workspaces are pushed above it and edit the same draft, and the model
/// picker is a sheet over it.
final class AgentNativeEditViewController: ListScreenController<
    AgentNativeEditViewController.Section, AgentNativeEditViewController.Item
> {
    enum Section: Hashable, Sendable { case identity, prompt, defaults, chat, resources, constraints, error }
    enum Item: Hashable, Sendable {
        case name, description
        case customPrompt, promptMode, prompt
        case model, useServerModel, thinking, tools
        case chatStyle
        case skillMode, skills, extensionMode, extensions, loadingResources, skillStatus, extensionStatus
        case runtime, workspaceMode, workspaces
        case error
    }

    private let draft: AgentNativeEditDraft
    private let apiClient: APIClient?
    private let onSaved: (StoredAgentDefinition) -> Void
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

    private lazy var textViewRow = UICollectionView.CellRegistration<SettingsTextViewRowCell, Item> { [weak self] cell, _, item in
        self?.configureTextView(cell, item: item)
    }
    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        self?.configureIndex(cell, item: item)
    }
    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        self?.configureMenu(cell, item: item)
    }
    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(title: "Use Server Default Model", identifier: "agent.nativeEdit.useServerModel") { [weak self] in
            self?.draft.model = ""
        }
    }
    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        self?.configureState(cell, item: item)
    }

    init(
        agent: StoredAgentDefinition,
        apiClient: APIClient?,
        connection: ServerConnection,
        serverName: String,
        onSaved: @escaping (StoredAgentDefinition) -> Void
    ) {
        draft = AgentNativeEditDraft(agent: agent, connection: connection, serverName: serverName)
        self.apiClient = apiClient
        self.onSaved = onSaved
        super.init(
            title: "Edit Agent",
            listIdentifier: "agent.nativeEdit.list",
            scope: .server(serverName),
            headers: true,
            footers: true,
            // The prompt editor scrolls above the keyboard.
            endsAtKeyboard: true,
            dismissesKeyboardOnDrag: true
        )
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The text editors grow as their text does.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        navigationItem.leftBarButtonItem = cancelItem
        // The Chat Style menu names the Settings style it follows.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chatStyleDidChange),
            name: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil
        )
        loadTask = Task { [draft, apiClient] in await draft.refreshResources(apiClient: apiClient) }
    }

    @objc private func chatStyleDidChange() { setNeedsUpdateProperties() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            loadTask?.cancel()
            extensionToolTask?.cancel()
        }
    }

    override func updateProperties() {
        super.updateProperties()
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

    private func save() {
        guard draft.canSave else { return }
        view.endEditing(true)
        Task { [weak self] in
            guard let self, let updated = await draft.save(apiClient: apiClient) else { return }
            onSaved(updated)
            Router.finish(self)
        }
    }

    // MARK: - Sections

    override func sections() -> [ListSection<Section, Item>] {
        var resources: [Item] = [.skillMode]
        if draft.skillSelectionMode == .exact { resources.append(.skills) }
        resources.append(.extensionMode)
        if draft.extensionSelectionMode == .exact { resources.append(.extensions) }
        if draft.isLoadingResources { resources.append(.loadingResources) }
        if draft.skillCatalogState.statusMessage(for: "Skills") != nil { resources.append(.skillStatus) }
        if draft.extensionCatalogState.statusMessage(for: "Extensions") != nil { resources.append(.extensionStatus) }

        var sections: [ListSection<Section, Item>] = [
            .init(.identity, header: "Identity", items: [.name, .description]),
            .init(
                .prompt,
                header: "System Prompt",
                footer: promptFooter,
                items: draft.usesCustomInstructions ? [.customPrompt, .promptMode, .prompt] : [.customPrompt]
            ),
            .init(
                .defaults,
                header: "Pi Session Defaults",
                items: [.model] + (draft.model.isEmpty ? [] : [.useServerModel]) + [.thinking, .tools]
            ),
            // The chat style is this device's own, so the section says it.
            .init(
                .chat,
                header: "Chat",
                footer: "How this Agent's sessions look. Settings follows Settings \u{2192} Chat \u{2192} Style. Other devices keep their own choice.",
                scope: .device,
                items: [.chatStyle]
            ),
            .init(
                .resources,
                header: "Resources",
                footer: "Inherit follows normal Pi discovery. Exact selection can be empty to give this Agent no Skills or optional Extensions. Exact selections explicitly override server discovery, including resources currently Disabled or Off, for this Agent only.",
                items: resources
            ),
            .init(
                .constraints,
                header: "Launch Constraints",
                footer: "Only compatible workspaces appear when this Agent starts. The server enforces the same restrictions for API and scheduled launches.",
                items: [.runtime, .workspaceMode] + (draft.workspaceConstraintMode == .exact ? [.workspaces] : [])
            ),
        ]
        if draft.error != nil {
            sections.append(.init(.error, items: [.error]))
        }
        return sections
    }

    private var promptFooter: String {
        guard draft.usesCustomInstructions else { return "Uses the server's default system prompt." }
        return draft.instructionMode == .append
            ? "Adds these instructions after the server's default system prompt."
            : "Uses these instructions instead of the server's default system prompt."
    }

    /// The draft values a row is drawn from. A pass reconfigures only the rows
    /// whose inputs changed, because reconfiguring a pop-up row rebuilds its
    /// button and dismisses the menu it has open, and UIKit runs a pass for the
    /// menu itself and for a change to any other row (resources finishing
    /// their load, for one).
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .name: AnyHashable(draft.name)
        case .description: AnyHashable(draft.description)
        case .customPrompt: AnyHashable(draft.usesCustomInstructions)
        case .promptMode: AnyHashable(draft.instructionMode)
        case .prompt: AnyHashable(draft.instructionText)
        case .model: AnyHashable(draft.model)
        case .useServerModel: AnyHashable(0)
        case .thinking: AnyHashable(draft.thinkingLevel)
        case .tools: AnyHashable([AnyHashable(draft.toolSelectionMode), AnyHashable(draft.selectedToolNames)])
        case .chatStyle: AnyHashable([AnyHashable(draft.chatStyle), AnyHashable(AppPreferences.ChatDisplay.style)])
        case .skillMode: AnyHashable(draft.skillSelectionMode)
        case .skills: AnyHashable(draft.selectedSkillPaths)
        case .extensionMode: AnyHashable(draft.extensionSelectionMode)
        case .extensions: AnyHashable(draft.selectedExtensionIds)
        case .loadingResources: AnyHashable(0)
        case .skillStatus: AnyHashable(String(describing: draft.skillCatalogState))
        case .extensionStatus: AnyHashable(String(describing: draft.extensionCatalogState))
        case .runtime: AnyHashable(draft.requiredRuntime)
        case .workspaceMode: AnyHashable(draft.workspaceConstraintMode)
        case .workspaces: AnyHashable(draft.selectedAllowedWorkspaceIds)
        case .error: AnyHashable(draft.error)
        }
    }

    // MARK: - Rows

    override func prepareRegistrations() {
        _ = (textViewRow, indexRow, menuRow, actionRow, stateRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .name, .description, .prompt:
            collectionView.dequeueConfiguredReusableCell(using: textViewRow, for: indexPath, item: item)
        case .model, .tools, .skills, .extensions, .workspaces:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .useServerModel:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .promptMode, .thinking, .chatStyle, .skillMode, .extensionMode, .runtime, .workspaceMode:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .loadingResources, .skillStatus, .extensionStatus, .error:
            collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .customPrompt:
            super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard item == .customPrompt else { return }
        toggleRow(
            cell,
            title: "Custom system prompt",
            isOn: draft.usesCustomInstructions,
            identifier: "agent.nativeEdit.customPrompt"
        ) { [weak self] in self?.draft.usesCustomInstructions = $0 }
    }

    private func configureTextView(_ cell: SettingsTextViewRowCell, item: Item) {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        switch item {
        case .name:
            cell.configure(
                text: draft.name,
                placeholder: "Name",
                identifier: "agent.nativeEdit.name",
                accessibilityLabel: "Name",
                minHeight: lineHeight + SettingsTextViewRowCell.verticalInsets,
                maxHeight: nil,
                singleLine: true,
                onChange: { [weak self] in self?.draft.name = $0 },
                onCaretMove: { [weak self] in self?.scrollCaretVisible(in: $0) }
            )
        case .description:
            cell.configure(
                text: draft.description,
                placeholder: "Description (optional)",
                identifier: "agent.nativeEdit.description",
                accessibilityLabel: "Description",
                minHeight: lineHeight * 2 + SettingsTextViewRowCell.verticalInsets,
                maxHeight: lineHeight * 5 + SettingsTextViewRowCell.verticalInsets,
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

    private func configureIndex(_ cell: SettingsIndexRowCell, item: Item) {
        switch item {
        case .model:
            cell.configure(title: "Model", systemImage: nil, value: draft.modelDisplayName, identifier: "agent.nativeEdit.model") { [weak self] in
                self?.presentModelPicker()
            }
        case .tools:
            cell.configure(title: "Tools", systemImage: nil, value: draft.toolSelectionSummary, identifier: "agent.nativeEdit.tools") { [weak self] in
                guard let self else { return }
                Router.push(AgentToolSelectionViewController(selection: .agent(draft)), from: self)
            }
        case .skills:
            cell.configure(
                title: "Selected Skills", systemImage: nil,
                value: Self.selectionCount(draft.selectedSkillPaths.count), identifier: "agent.nativeEdit.skills"
            ) { [weak self] in
                guard let self else { return }
                Router.push(AgentResourceSelectionViewController(kind: .skills, draft: draft), from: self)
            }
        case .extensions:
            cell.configure(
                title: "Selected Extensions", systemImage: nil,
                value: Self.selectionCount(draft.selectedExtensionIds.count), identifier: "agent.nativeEdit.extensions"
            ) { [weak self] in
                guard let self else { return }
                Router.push(AgentResourceSelectionViewController(kind: .extensions, draft: draft), from: self)
            }
        case .workspaces:
            cell.configure(
                title: "Allowed Workspaces", systemImage: nil,
                value: Self.selectionCount(draft.selectedAllowedWorkspaceIds.count), identifier: "agent.nativeEdit.workspaces"
            ) { [weak self] in
                guard let self else { return }
                Router.push(AgentWorkspaceSelectionViewController(draft: draft), from: self)
            }
        default:
            break
        }
    }

    private func configureMenu(_ cell: SettingsMenuRowCell, item: Item) {
        switch item {
        case .promptMode:
            cell.configure(
                title: "Prompt Mode",
                identifier: "agent.nativeEdit.promptMode",
                options: [
                    (title: "Append", selected: draft.instructionMode == .append, action: { [weak self] in self?.draft.instructionMode = .append }),
                    (title: "Replace", selected: draft.instructionMode == .replace, action: { [weak self] in self?.draft.instructionMode = .replace }),
                ]
            )
        case .thinking:
            let levels: [ThinkingLevel?] = [nil] + ThinkingLevel.allCases.map(Optional.some)
            cell.configure(
                title: "Thinking",
                identifier: "agent.nativeEdit.thinking",
                options: levels.map { level in
                    (
                        title: level?.displayTitle ?? "Default",
                        selected: draft.thinkingLevel == level,
                        action: { [weak self] in self?.draft.thinkingLevel = level }
                    )
                }
            )
        case .chatStyle:
            let settingsLabel = "Settings (\(AppPreferences.ChatDisplay.style.label))"
            let styles: [AppPreferences.ChatDisplay.Style?] = [nil] + AppPreferences.ChatDisplay.Style.allCases.map(Optional.some)
            cell.configure(
                title: "Chat Style",
                identifier: "agent.nativeEdit.chatStyle",
                options: styles.map { style in
                    (
                        title: style?.label ?? settingsLabel,
                        selected: draft.chatStyle == style,
                        action: { [weak self] in self?.draft.chatStyle = style }
                    )
                }
            )
        case .skillMode:
            cell.configure(
                title: "Skills",
                identifier: "agent.nativeEdit.skillMode",
                options: modeOptions(draft.skillSelectionMode) { [weak self] in self?.draft.skillSelectionMode = $0 }
            )
        case .extensionMode:
            cell.configure(
                title: "Extensions",
                identifier: "agent.nativeEdit.extensionMode",
                options: modeOptions(draft.extensionSelectionMode) { [weak self] in self?.draft.extensionSelectionMode = $0 }
            )
        case .runtime:
            cell.configure(
                title: "Runtime",
                identifier: "agent.nativeEdit.requiredRuntime",
                options: [
                    (title: "Any runtime", selected: draft.requiredRuntime == nil, action: { [weak self] in self?.draft.requiredRuntime = nil }),
                    (title: "Host", selected: draft.requiredRuntime == .host, action: { [weak self] in self?.draft.requiredRuntime = .host }),
                    (title: "Sandbox", selected: draft.requiredRuntime == .sandbox, action: { [weak self] in self?.draft.requiredRuntime = .sandbox }),
                ]
            )
        case .workspaceMode:
            cell.configure(
                title: "Workspaces",
                identifier: "agent.nativeEdit.workspaceMode",
                options: [
                    (title: "Any workspace", selected: draft.workspaceConstraintMode == .inherit, action: { [weak self] in self?.draft.workspaceConstraintMode = .inherit }),
                    (title: "Allowed list", selected: draft.workspaceConstraintMode == .exact, action: { [weak self] in self?.draft.workspaceConstraintMode = .exact }),
                ]
            )
        default:
            break
        }
    }

    private func modeOptions(
        _ mode: AgentResourceSelectionMode,
        onSelect: @escaping (AgentResourceSelectionMode) -> Void
    ) -> [(title: String, selected: Bool, action: () -> Void)] {
        AgentResourceSelectionMode.allCases.map { option in
            (title: option.title, selected: option == mode, action: { onSelect(option) })
        }
    }

    private func configureState(_ cell: SettingsStateRowCell, item: Item) {
        switch item {
        case .loadingResources:
            cell.configure(.loading("Refreshing discovered resources\u{2026}"))
        case .skillStatus:
            cell.configure(.failure(draft.skillCatalogState.statusMessage(for: "Skills") ?? "", retry: nil))
        case .extensionStatus:
            cell.configure(.failure(draft.extensionCatalogState.statusMessage(for: "Extensions") ?? "", retry: nil))
        default:
            cell.configure(.failure(draft.error ?? "", retry: nil), identifier: "agent.nativeEdit.error")
        }
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

    // MARK: - Model picker

    /// The picker gets this editor's server explicitly.
    private func presentModelPicker() {
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
        Router.present(picker, presentation: .sheet.inNavigation(), from: self)
    }
}
