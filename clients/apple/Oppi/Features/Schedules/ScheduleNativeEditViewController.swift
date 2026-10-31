import UIKit

/// Edit Schedule: a schedule's name, trigger, prompt, and what it starts. A
/// draft form on the settings base: its edits live in `ScheduleEditDraft`, Save
/// sends them and Cancel drops them. Presented in a navigation controller; the
/// time zone list and the model picker are sheets over it.
final class ScheduleNativeEditViewController: ListScreenController<
    ScheduleNativeEditViewController.Section, ScheduleNativeEditViewController.Item
> {
    enum Section: Hashable, Sendable { case schedule, instructions, target, error }
    enum Item: Hashable, Sendable {
        case name, cadence, runAt, interval, weekday, time, cron, timeZone
        case prompt
        case workspace, agent, model, useDefaultModel, thinking, sessionName, session, delivery
        case error
    }

    private let draft: ScheduleEditDraft
    private let apiClient: APIClient?
    private let onSaved: (AgentSchedule, AgentScheduleSummary) -> Void
    private var loadTask: Task<Void, Never>?

    private lazy var cancelItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        Router.finish(self)
    })
    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = "Save"
        item.accessibilityIdentifier = "schedule.nativeEdit.save"
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
    private lazy var dateRow = UICollectionView.CellRegistration<ScheduleDateRowCell, Item> { [weak self] cell, _, item in
        self?.configureDate(cell, item: item)
    }
    private lazy var cronRow = UICollectionView.CellRegistration<ScheduleCronRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let trigger = draft.triggerDraft
        cell.configure(
            expression: trigger.customExpression,
            fieldLabels: trigger.customFieldLabels,
            hint: trigger.customAccessibilityHint,
            error: trigger.customExpressionError,
            guidance: trigger.customGuidanceText,
            identifier: "schedule.nativeEdit.cronExpression"
        ) { [weak self] in self?.draft.triggerDraft.customExpression = $0 }
    }
    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        self?.configureIndex(cell, item: item)
    }
    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        self?.configureMenu(cell, item: item)
    }
    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(title: "Use Agent or Server Default Model", identifier: "schedule.nativeEdit.useDefaultModel") { [weak self] in
            self?.draft.model = ""
        }
    }
    private lazy var errorRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(.failure(self?.draft.error ?? "", retry: nil), identifier: "schedule.nativeEdit.error")
    }

    init(
        schedule: AgentSchedule,
        apiClient: APIClient?,
        connection: ServerConnection,
        serverName: String,
        onSaved: @escaping (AgentSchedule, AgentScheduleSummary) -> Void
    ) {
        draft = ScheduleEditDraft(schedule: schedule, connection: connection, serverName: serverName)
        self.apiClient = apiClient
        self.onSaved = onSaved
        super.init(
            title: "Edit Schedule",
            listIdentifier: "schedule.nativeEdit.list",
            scope: .server(serverName),
            headers: true,
            // The prompt editor scrolls above the keyboard.
            endsAtKeyboard: true,
            dismissesKeyboardOnDrag: true
        )
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The prompt editor grows as its text does.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        navigationItem.leftBarButtonItem = cancelItem
        loadTask = Task { [draft, apiClient] in await draft.loadAgents(apiClient: apiClient) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            loadTask?.cancel()
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
    }

    private func save() {
        guard draft.canSave else { return }
        view.endEditing(true)
        Task { [weak self] in
            guard let self, let saved = await draft.save(apiClient: apiClient) else { return }
            onSaved(saved.schedule, saved.summary)
            Router.finish(self)
        }
    }

    // MARK: - Sections

    override func sections() -> [ListSection<Section, Item>] {
        var schedule: [Item] = [.name, .cadence]
        switch draft.triggerDraft.cadence {
        case .oneTime: schedule.append(.runAt)
        case .interval: schedule.append(.interval)
        case .daily: schedule.append(.time)
        case .weekly: schedule += [.weekday, .time]
        case .custom: schedule.append(.cron)
        }
        schedule.append(.timeZone)

        let target: [Item] = draft.isNewSessionAction
            ? [.workspace, .agent, .model] + (draft.model.isEmpty ? [] : [.useDefaultModel]) + [.thinking, .sessionName]
            : [.workspace, .session, .delivery]
        var sections: [ListSection<Section, Item>] = [
            .init(.schedule, header: "Schedule", items: schedule),
            .init(.instructions, header: "Instructions", items: [.prompt]),
            .init(.target, header: draft.isNewSessionAction ? "Start New Session" : "Existing Session", items: target),
        ]
        if draft.error != nil {
            sections.append(.init(.error, items: [.error]))
        }
        return sections
    }

    /// The draft values a row is drawn from; see `AgentNativeEditViewController`.
    override func inputs(of item: Item) -> AnyHashable {
        let trigger = draft.triggerDraft
        switch item {
        case .name: return AnyHashable(draft.name)
        case .cadence: return AnyHashable(trigger.cadence)
        case .runAt: return AnyHashable([AnyHashable(trigger.oneTimeDate), AnyHashable(trigger.timeZone)])
        case .interval: return AnyHashable([AnyHashable(trigger.intervalMs), AnyHashable(draft.intervalOptions)])
        case .weekday: return AnyHashable(trigger.weekday)
        case .time: return AnyHashable([AnyHashable(trigger.timeOfDay), AnyHashable(trigger.timeZone)])
        case .cron: return AnyHashable([trigger.customExpression])
        case .timeZone: return AnyHashable(trigger.timeZone)
        case .prompt: return AnyHashable(draft.prompt)
        case .workspace: return AnyHashable([
            AnyHashable(draft.workspaceId), AnyHashable(draft.workspaces.map(\.id)), AnyHashable(EntityIcon.loadGeneration),
        ])
        case .agent: return AnyHashable([
            AnyHashable(draft.agentId), AnyHashable(draft.agents.map(\.id)), AnyHashable(EntityIcon.loadGeneration),
        ])
        case .model: return AnyHashable(draft.model)
        case .useDefaultModel: return AnyHashable(0)
        case .thinking: return AnyHashable(draft.thinkingLevel)
        case .sessionName: return AnyHashable(draft.sessionName)
        case .session: return AnyHashable([AnyHashable(draft.targetSessionId), AnyHashable(draft.availableSessions.map(\.id))])
        case .delivery: return AnyHashable(draft.streamingBehavior)
        case .error: return AnyHashable(draft.error)
        }
    }

    // MARK: - Rows

    override func prepareRegistrations() {
        _ = (textViewRow, dateRow, cronRow, indexRow, menuRow, actionRow, errorRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .name, .sessionName, .prompt:
            collectionView.dequeueConfiguredReusableCell(using: textViewRow, for: indexPath, item: item)
        case .runAt, .time:
            collectionView.dequeueConfiguredReusableCell(using: dateRow, for: indexPath, item: item)
        case .cron:
            collectionView.dequeueConfiguredReusableCell(using: cronRow, for: indexPath, item: item)
        case .timeZone, .model:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .cadence, .interval, .weekday, .workspace, .agent, .thinking, .session, .delivery:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .useDefaultModel:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .error:
            collectionView.dequeueConfiguredReusableCell(using: errorRow, for: indexPath, item: item)
        }
    }

    private func configureTextView(_ cell: SettingsTextViewRowCell, item: Item) {
        let line = UIFont.preferredFont(forTextStyle: .body).lineHeight + SettingsTextViewRowCell.verticalInsets
        let scroll: (UITextView) -> Void = { [weak self] in self?.scrollCaretVisible(in: $0) }
        switch item {
        case .name:
            cell.configure(
                text: draft.name, placeholder: "Name", identifier: "schedule.nativeEdit.name",
                accessibilityLabel: "Name", minHeight: line, maxHeight: nil, singleLine: true,
                onChange: { [weak self] in self?.draft.name = $0 }, onCaretMove: scroll
            )
        case .sessionName:
            cell.configure(
                text: draft.sessionName, placeholder: "Session title (optional)",
                identifier: "schedule.nativeEdit.sessionName", accessibilityLabel: "Session title",
                minHeight: line, maxHeight: nil, singleLine: true,
                onChange: { [weak self] in self?.draft.sessionName = $0 }, onCaretMove: scroll
            )
        default:
            cell.configure(
                text: draft.prompt, placeholder: "", identifier: "schedule.nativeEdit.prompt",
                accessibilityLabel: "Schedule prompt", minHeight: 180, maxHeight: nil,
                onChange: { [weak self] in self?.draft.prompt = $0 }, onCaretMove: scroll
            )
        }
    }

    private func configureDate(_ cell: ScheduleDateRowCell, item: Item) {
        let trigger = draft.triggerDraft
        let timeZone = TimeZone(identifier: trigger.timeZone) ?? .current
        if item == .runAt {
            cell.configure(
                title: "Run At", mode: .dateAndTime, date: trigger.oneTimeDate, timeZone: timeZone,
                identifier: "schedule.nativeEdit.runAt"
            ) { [weak self] in self?.draft.triggerDraft.oneTimeDate = $0 }
        } else {
            cell.configure(
                title: "Time", mode: .time, date: trigger.timeOfDay, timeZone: timeZone,
                identifier: "schedule.nativeEdit.time"
            ) { [weak self] in self?.draft.triggerDraft.timeOfDay = $0 }
        }
    }

    private func configureIndex(_ cell: SettingsIndexRowCell, item: Item) {
        if item == .timeZone {
            cell.configure(
                title: "Time Zone",
                systemImage: nil,
                value: Self.timeZoneDisplayName(draft.triggerDraft.timeZone),
                identifier: "schedule.nativeEdit.timeZone"
            ) { [weak self] in self?.presentTimeZonePicker() }
        } else {
            // The model's own provider mark; a model that follows the Agent or the
            // server has none to show.
            let mark = draft.model.managementNilIfBlank.map { EntityIcon.image(.model($0), size: 22) }
            cell.configure(
                title: "Model",
                systemImage: nil,
                image: mark,
                value: draft.modelDisplayName,
                identifier: "schedule.nativeEdit.model"
            ) { [weak self] in self?.presentModelPicker() }
        }
    }

    private func configureMenu(_ cell: SettingsMenuRowCell, item: Item) {
        let trigger = draft.triggerDraft
        let assets = draft.connection.iconAssetCache
        switch item {
        case .cadence:
            cell.configure(
                title: "Cadence",
                identifier: "schedule.nativeEdit.cadence",
                options: ScheduleTriggerDraft.Cadence.allCases.map { cadence in
                    (title: cadence.title, selected: trigger.cadence == cadence, action: { [weak self] in
                        self?.draft.triggerDraft.cadence = cadence
                    })
                }
            )
        case .interval:
            cell.configure(
                title: "Repeat",
                identifier: "schedule.nativeEdit.interval",
                options: draft.intervalOptions.map { interval in
                    (
                        title: "Every \(AgentScheduleTrigger.intervalSummary(interval))",
                        selected: trigger.intervalMs == interval,
                        action: { [weak self] in self?.draft.triggerDraft.intervalMs = interval }
                    )
                }
            )
        case .weekday:
            cell.configure(
                title: "Day",
                identifier: "schedule.nativeEdit.weekday",
                options: (0..<7).map { weekday in
                    (title: ScheduleTriggerDraft.weekdayTitle(weekday), selected: trigger.weekday == weekday, action: { [weak self] in
                        self?.draft.triggerDraft.weekday = weekday
                    })
                }
            )
        case .workspace:
            let workspaces = draft.workspaces
            let listed = workspaces.first { $0.id == draft.workspaceId }
            cell.configure(
                title: "Workspace",
                image: listed.map { Self.workspaceIcon($0, assets: assets) },
                identifier: "schedule.nativeEdit.workspace",
                value: listed?.name ?? "Current workspace",
                menu: { [weak self] in
                    guard let self else { return [] }
                    var options: [SettingsMenuOption] = []
                    if listed == nil {
                        options.append(SettingsMenuOption(title: "Current workspace", selected: true) {})
                    }
                    options += workspaces.map { workspace in
                        SettingsMenuOption(
                            title: workspace.name,
                            image: Self.workspaceIcon(workspace, assets: assets),
                            selected: workspace.id == draft.workspaceId
                        ) { [weak self] in self?.draft.selectWorkspace(workspace.id) }
                    }
                    return options
                }
            )
        case .agent:
            let agents = draft.agents
            // No saved Agent follows Pi: the row and its choice wear the Pi avatar.
            let saved = agents.first { $0.id == draft.agentId }
            let current: IconEntity = saved.map { .agent($0.icon) } ?? (draft.agentId.isEmpty ? .pi : .agent(nil))
            cell.configure(
                title: "Agent",
                image: EntityIcon.image(current, size: 22, assets: assets),
                identifier: "schedule.nativeEdit.agent",
                value: saved?.name ?? (draft.agentId.isEmpty ? "No saved Agent" : "Current saved Agent"),
                menu: { [weak self] in
                    guard let self else { return [] }
                    var options: [SettingsMenuOption] = [
                        SettingsMenuOption(
                            title: "No saved Agent",
                            image: EntityIcon.image(.pi, size: 22),
                            selected: draft.agentId.isEmpty
                        ) { [weak self] in self?.draft.agentId = "" },
                    ]
                    if !draft.agentId.isEmpty, saved == nil {
                        options.append(SettingsMenuOption(title: "Current saved Agent", selected: true) {})
                    }
                    options += agents.map { agent in
                        SettingsMenuOption(
                            title: agent.name,
                            image: EntityIcon.image(.agent(agent.icon), size: 22, assets: assets),
                            selected: agent.id == draft.agentId
                        ) { [weak self] in self?.draft.agentId = agent.id }
                    }
                    return options
                }
            )
        case .thinking:
            let levels: [ThinkingLevel?] = [nil] + ThinkingLevel.allCases.map(Optional.some)
            cell.configure(
                title: "Thinking",
                identifier: "schedule.nativeEdit.thinking",
                options: levels.map { level in
                    (
                        title: level?.displayTitle ?? "Agent or server default",
                        selected: draft.thinkingLevel == level,
                        action: { [weak self] in self?.draft.thinkingLevel = level }
                    )
                }
            )
        case .session:
            let sessions = draft.availableSessions
            var options: [(title: String, selected: Bool, action: () -> Void)] = []
            if !draft.targetSessionId.isEmpty, !sessions.contains(where: { $0.id == draft.targetSessionId }) {
                options.append((title: "Current session", selected: true, action: {}))
            }
            options += sessions.map { session in
                (title: session.displayTitle, selected: session.id == draft.targetSessionId, action: { [weak self] in
                    self?.draft.targetSessionId = session.id
                })
            }
            cell.configure(title: "Session", identifier: "schedule.nativeEdit.session", options: options)
        case .delivery:
            let behaviors: [ExistingSessionStreamingBehavior?] = [nil] + ExistingSessionStreamingBehavior.allCases.map(Optional.some)
            cell.configure(
                title: "Delivery",
                identifier: "schedule.nativeEdit.delivery",
                options: behaviors.map { behavior in
                    (
                        title: behavior?.displayName ?? "Automatic",
                        selected: draft.streamingBehavior == behavior,
                        action: { [weak self] in self?.draft.streamingBehavior = behavior }
                    )
                }
            )
        default:
            break
        }
    }

    private static func timeZoneDisplayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    /// A workspace's artwork with its sandbox mark, as every other row draws it.
    private static func workspaceIcon(_ workspace: Workspace, assets: IconAssetCache?) -> UIImage {
        EntityIcon.image(.workspace(workspace.icon, sandbox: workspace.runtime == .sandbox), size: 22, assets: assets)
    }

    private func scrollCaretVisible(in textView: UITextView) {
        // After the cell grows for the new line.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, let range = textView.selectedTextRange else { return }
            let caret = textView.convert(textView.caretRect(for: range.end), to: collectionView)
            collectionView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -12), animated: false)
        }
    }

    // MARK: - Sheets

    private func presentTimeZonePicker() {
        let draft = draft
        let picker = ScheduleTimeZonePickerViewController(
            selection: draft.triggerDraft.timeZone,
            serverName: draft.serverName
        ) { draft.triggerDraft.timeZone = $0 }
        Router.present(picker, presentation: .sheet.inNavigation(), from: self)
    }

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

/// The time zones a schedule can run in, filtered by the search bar in the
/// navigation bar. Choosing one reports it and closes the sheet.
final class ScheduleTimeZonePickerViewController: ListScreenController<
    ScheduleTimeZonePickerViewController.Section, String
> {
    enum Section: Hashable, Sendable { case zones }

    private let selection: String
    private let onSelect: (String) -> Void
    private let search = ScreenSearchController(prompt: "Search time zones")
    private var searchText = "" {
        didSet { setNeedsUpdateProperties() }
    }
    private lazy var zoneRow = UICollectionView.CellRegistration<SettingsSelectionRowCell, String> { [weak self] cell, _, identifier in
        guard let self else { return }
        cell.configure(
            title: identifier.replacingOccurrences(of: "_", with: " "),
            mark: .trailingCheck,
            isChosen: identifier == selection,
            identifier: "schedule.timeZone.\(identifier)"
        ) { [weak self] in
            guard let self else { return }
            onSelect(identifier)
            Router.finish(self)
        }
    }

    init(selection: String, serverName: String, onSelect: @escaping (String) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
        super.init(title: "Time Zone", listIdentifier: "schedule.timeZone.list", scope: .server(serverName))
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        search.install(on: self, alwaysVisible: false)
        search.onTextChange = { [weak self] text in
            guard let self, text != searchText else { return }
            searchText = text
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    /// `_` is a word separator for the matcher, so "new york" finds America/New_York.
    override func sections() -> [ListSection<Section, String>] {
        let identifiers = searchText.isEmpty
            ? TimeZone.knownTimeZoneIdentifiers
            : TimeZone.knownTimeZoneIdentifiers.filter { FuzzyMatch.matchesAny(query: searchText, fields: [$0]) }
        return [ListSection(.zones, items: identifiers)]
    }

    override func inputs(of item: String) -> AnyHashable {
        AnyHashable(item == selection)
    }

    override func prepareRegistrations() {
        _ = zoneRow
    }

    override func dequeue(_ item: String, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: zoneRow, for: indexPath, item: item)
    }
}
