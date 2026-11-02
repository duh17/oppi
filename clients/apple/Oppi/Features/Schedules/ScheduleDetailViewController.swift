import UIKit

/// One schedule: what it does, what it runs with, Run Now, the Enabled
/// switch (or Restore), and its recent runs. Edit opens the native editor;
/// the actions menu offers Archive; the compact Oppi bar describes a change.
/// Changes go back to the list through `onChanged`.
///
/// A `ListScreenController`: the base owns the list, the snapshot, the section
/// headings, and the load on appearance and pull to refresh. This page keeps
/// its rows, its bar items, the composer, and the sheets it opens.
@MainActor
final class ScheduleDetailViewController: ListScreenController<ScheduleDetailViewController.Section, ScheduleDetailViewController.Item> {
    enum Section: Hashable, Sendable { case summary, status, instructions, runWith, actions, history }
    enum Item: Hashable, Sendable {
        case summary
        case prompt
        case detail(title: String, value: String)
        case caption(String)
        case runNow
        case restore
        case enabled
        case noRuns
        case run(String)
    }

    private let root: AppRootEnvironment
    private let scheduleId: String
    private let onChanged: (AgentScheduleSummary) -> Void
    private let editItem = UIBarButtonItem()
    private let actionsItem = UIBarButtonItem()

    private let nativeEditor = RouterModalPresenter()
    private let promptReader = RouterModalPresenter()
    private let composer: GuidedControlComposerController

    private var schedule: AgentSchedule? {
        didSet { setNeedsUpdateProperties() }
    }
    private var runs: [AgentScheduleRunSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var agentNamesById: [String: String] = [:] {
        didSet { setNeedsUpdateProperties() }
    }
    private var isMutating = false {
        didSet { setNeedsUpdateProperties() }
    }
    /// A failure of something the page did (a failed run or change), which shows
    /// as an alert. A failed load is the base's `loadFailure`.
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var showNativeEdit = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showPromptReader = false {
        didSet { setNeedsUpdateProperties() }
    }

    init(root: AppRootEnvironment, scheduleId: String, onChanged: @escaping (AgentScheduleSummary) -> Void) {
        self.root = root
        self.scheduleId = scheduleId
        self.onChanged = onChanged
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .schedules,
                intent: .revise,
                presentation: .compact,
                placeholder: "Describe a change…"
            ),
            root: root
        )
        super.init(
            title: "Schedule", listIdentifier: "schedule.detail.list",
            headers: true,
            dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
        editItem.title = "Edit"
        editItem.image = UIImage(systemName: "pencil")
        editItem.accessibilityIdentifier = "schedule.detail.nativeEdit"
        editItem.primaryAction = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.showNativeEdit = true
        }
        actionsItem.image = UIImage(systemName: "ellipsis.circle")
        actionsItem.accessibilityLabel = "Schedule actions"
        actionsItem.accessibilityIdentifier = "schedule.detail.actions"
        if #available(iOS 27.1, *) {
            editItem.axisBehavior = .verticalPreferred
            actionsItem.axisBehavior = .verticalPreferred
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var connection: ServerConnection { root.coordinator.activeConnection }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.install(in: self)
        for presenter in [nativeEditor, promptReader] { presenter.anchor = self }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [nativeEditor, promptReader] { presenter.sync() }
        // An error that arrived while the screen was off screen shows now.
        setNeedsUpdateProperties()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        title = schedule?.name ?? "Schedule"
        updateBarItems()
        updateComposer()
        updateModals()
        // OK clears only the error the person read, never a newer one. A failed
        // load is the base's row, not this alert.
        errorAlerts.sync(title: "Schedule", message: error) { [weak self] shown in
            guard let self, error == shown else { return }
            error = nil
        }
    }

    /// Any loaded schedule can be revised, archived or not, until a change to
    /// it is in flight, as its menu item was.
    private func updateComposer() {
        composer.model.updateTarget(id: schedule?.id, name: schedule?.name, path: nil)
        composer.model.isDisabled = isMutating
        composer.setHidden(schedule == nil)
    }

    private func updateBarItems() {
        guard let schedule else {
            ListScreen.setBarItems(trailing: [], leading: [], on: navigationItem)
            return
        }
        editItem.isEnabled = !isMutating
        // An archived schedule has only Restore (a row) and the Oppi bar.
        guard schedule.status != .archived else {
            ListScreen.setBarItems(trailing: [], leading: [], on: navigationItem)
            return
        }
        let archive = UIAction(
            title: "Archive",
            image: UIImage(systemName: "archivebox"),
            attributes: isMutating ? [.disabled, .destructive] : .destructive
        ) { [weak self] _ in
            self?.confirmArchive()
        }
        archive.accessibilityIdentifier = "schedule.detail.archive"
        actionsItem.menu = UIMenu(children: [archive])
        // Native Edit beside the actions menu, as on an Agent's detail.
        ListScreen.setBarItems(trailing: [actionsItem, editItem], leading: [], on: navigationItem)
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        // Without a schedule there are no rows: the page is its state.
        guard let schedule else { return [] }
        // A diffable list traps on a repeated item; a repeated run id shows once.
        var seenRuns = Set<String>()
        let runItems = runs.filter { seenRuns.insert($0.id).inserted }.map { Item.run($0.id) }
        return [
            ListSection(.summary, items: [.summary]),
            ListSection(.status, items: []),
            ListSection(.instructions, header: "Instructions", items: [.prompt]),
            ListSection(
                .runWith,
                header: SchedulePresentation.runWithSectionTitle(schedule.action),
                items: runWithItems(schedule.action)
            ),
            ListSection(.actions, items: [.runNow, schedule.status == .archived ? .restore : .enabled]),
            ListSection(.history, header: "Run History", items: runs.isEmpty ? [.noRuns] : runItems),
        ]
    }

    /// A load settles the page in place; its rows should not slide.
    override var animatesUpdates: Bool { false }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The summary and the actions carry no heading.
    override func showsHeader(for section: Section) -> Bool {
        section == .instructions || section == .runWith || section == .history
    }

    /// Run History's heading carries how many runs it lists.
    override func decorate(header content: inout UIListContentConfiguration, section: Section) {
        guard section == .history, !runs.isEmpty else { return }
        content.secondaryText = "\(runs.count) recent"
        content.secondaryTextProperties.color = palette.ui.comment
        content.prefersSideBySideTextAndSecondaryText = true
    }

    /// A failed load keeps the rows it already had and says so under them, with
    /// Retry; with no schedule there is nothing to list, so the page is its whole
    /// screen's state.
    override func stateSection() -> Section? { .status }

    override func loadingCaption() -> String? { String(localized: "Loading schedule…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Schedule") }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .summary:
            guard let schedule else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(schedule.name), AnyHashable(schedule.status.rawValue),
                AnyHashable(schedule.trigger.detailTimingSummary()),
            ])
        case .runNow, .restore:
            return AnyHashable([AnyHashable(isMutating), AnyHashable(schedule?.status.rawValue)])
        case .enabled:
            return AnyHashable([AnyHashable(schedule?.status.rawValue), AnyHashable(isMutating)])
        case .run(let id):
            guard let run = runs.first(where: { $0.id == id }) else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(run.status.rawValue), AnyHashable(run.createdAt), AnyHashable(run.kind),
                AnyHashable(run.sessionId), AnyHashable(SchedulePresentation.runErrorSummary(run.error)),
            ])
        case .prompt:
            // The row draws the schedule's prompt: a native edit or a guided
            // change replaces it, and only a changed input redraws the row.
            guard let schedule else { return AnyHashable(0) }
            return AnyHashable(SchedulePresentation.prompt(in: schedule.action))
        case .detail(let title, let value):
            // The value is selectable text: a pass that redrew the row would drop
            // a selection or the copy menu, so the row is keyed by it.
            return AnyHashable([AnyHashable(title), AnyHashable(value)])
        // A caption or the no-runs state row holds nothing a reconfigure would
        // disturb, so the kit's default draws it again.
        default:
            return super.inputs(of: item)
        }
    }

    // MARK: - Rows

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`.
    override var rowStyle: ListRowStyle { .card }

    private func runWithItems(_ action: AgentScheduleAction) -> [Item] {
        switch action {
        case .newSession(let workspaceId, _, let agentId, let model, let thinkingLevel, _, let name):
            var items: [Item] = [.detail(title: "Workspace", value: humanWorkspaceName(workspaceId))]
            if let agent = humanAgentName(agentId) {
                items.append(.detail(title: "Agent", value: agent))
            }
            if let model, !model.isEmpty {
                items.append(.detail(title: "Model", value: SessionFormatting.shortModelName(model) ?? model))
            }
            if let thinkingLevel {
                items.append(.detail(title: "Thinking", value: thinkingLevel.displayTitle))
            }
            if let name, !name.isEmpty {
                items.append(.detail(title: "Session title", value: name))
            }
            items.append(.caption("Starts a new session each run"))
            return items
        case .existingSession(let workspaceId, let sessionId, _, let streamingBehavior):
            return [
                .detail(title: "Workspace", value: humanWorkspaceName(workspaceId)),
                .detail(title: "Session", value: humanSessionTitle(sessionId)),
                .detail(
                    title: "Delivery",
                    value: streamingBehavior.map { $0 == .steer ? "Steers the session" : "Sends as follow-up" } ?? "Auto"
                ),
                .caption("Sends into an existing session"),
            ]
        }
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .summary:
            ListScreen.staticRow(cell)
            guard let schedule else { return }
            cell.contentConfiguration = ControlViewContent { [palette] in
                Self.summaryView(schedule, palette: palette)
            }
        case .prompt:
            guard let schedule else { return }
            let prompt = SchedulePresentation.prompt(in: schedule.action)
            ListScreen.buttonRow(
                cell,
                identifier: "schedule.detail.prompt",
                label: "What it does. \(prompt). Show full schedule instructions",
                hint: "Opens the prompt as full-screen Markdown"
            ) { [weak self] in
                self?.showPromptReader = true
            }
            cell.contentConfiguration = ControlViewContent { [palette] in
                let heading = ControlRowViews.stack([
                    ControlRowViews.label("What it does", style: .subheadline, weight: .medium, color: palette.ui.fg, lines: 1),
                    ControlRowViews.spacer(),
                    ControlRowViews.label("Show instructions", style: .caption1, weight: .medium, color: palette.ui.blue, lines: 1),
                ], axis: .horizontal, spacing: 8, alignment: .center)
                let body = ControlRowViews.label(prompt, style: .subheadline, color: palette.ui.fg, lines: 5)
                return ControlRowViews.stack([heading, body], spacing: 8)
            }
        case .detail(let title, let value):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) { [palette] in
                ControlRowViews.valueRow(title, value, palette: palette)
            }
        case .caption(let text):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent { [palette] in
                ControlRowViews.label(text, style: .caption1, color: palette.ui.comment)
            }
        case .runNow:
            let enabled = !isMutating && schedule?.status != .archived
            actionRow(cell, title: "Run Now", systemImage: "play.fill", identifier: "schedule.detail.run", enabled: enabled) { [weak self] in
                self?.runNow()
            }
        case .restore:
            actionRow(
                cell,
                title: "Restore and Activate",
                systemImage: "arrow.uturn.backward",
                identifier: "schedule.detail.restore",
                enabled: !isMutating
            ) { [weak self] in
                self?.mutate(.restore)
            }
        case .enabled:
            ListScreen.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = "Enabled"
            content.textProperties.color = palette.ui.fg
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = schedule?.status == .active
            toggle.isEnabled = !isMutating
            toggle.accessibilityIdentifier = "schedule.detail.enabled"
            toggle.accessibilityLabel = "Enabled"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.setEnabled(toggle?.isOn ?? false)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        case .noRuns:
            // The list's own state, inside the card this page's rows are.
            ListScreen.stateRow(
                cell,
                .empty(
                    title: String(localized: "No Runs Yet"),
                    systemImage: "clock.arrow.circlepath",
                    message: String(localized: "Scheduled and manual runs will appear here.")
                ),
                palette: palette,
                keepsCard: true
            )
        case .run(let id):
            guard let run = runs.first(where: { $0.id == id }) else { return }
            configureRun(cell, run: run, palette: palette)
        }
    }

    private func actionRow(
        _ cell: SidebarListCell,
        title: String,
        systemImage: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) {
        ListScreen.buttonRow(cell, identifier: identifier, label: title, enabled: enabled, action: action)
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.image = UIImage(systemName: systemImage)
        let tint = palette.ui.blue.withAlphaComponent(enabled ? 1 : 0.4)
        content.textProperties.color = tint
        content.imageProperties.tintColor = tint
        cell.contentConfiguration = content
    }

    private func configureRun(_ cell: SidebarListCell, run: AgentScheduleRunSummary, palette: ThemePalette) {
        let status = run.status.rawValue.capitalized
        let detail = "\(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(SchedulePresentation.runSourceLabel(run.kind))"
        let errorSummary = SchedulePresentation.runErrorSummary(run.error)
        let label = [status, detail, errorSummary].compactMap { $0 }.joined(separator: ", ")
        if run.sessionId != nil {
            ListScreen.buttonRow(
                cell,
                identifier: "schedule.run.\(run.id)",
                label: label,
                hint: "Opens the run session"
            ) { [weak self] in
                self?.openRunSession(run)
            }
        } else {
            ListScreen.staticRow(cell, identifier: "schedule.run.\(run.id)")
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = label
        }
        let tone = Self.runTone(run.status, palette: palette)
        let opensSession = run.sessionId != nil
        cell.contentConfiguration = ControlViewContent { [palette] in
            let icon = UIImageView(image: UIImage(
                systemName: Self.runIconName(run.status),
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
            ))
            icon.tintColor = tone
            icon.contentMode = .center
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            var lines: [UIView] = [
                ControlRowViews.label(status, style: .subheadline, weight: .semibold, color: palette.ui.fg),
                ControlRowViews.label(detail, style: .caption1, color: palette.ui.comment),
            ]
            if let errorSummary {
                lines.append(ControlRowViews.label(errorSummary, style: .caption1, color: palette.ui.red, lines: 3))
            }
            var row: [UIView] = [icon, ControlRowViews.stack(lines, spacing: 4)]
            if opensSession {
                let chevron = UIImageView(image: UIImage(
                    systemName: "chevron.forward",
                    withConfiguration: UIImage.SymbolConfiguration(font: UIFont.scaled(.footnote, .semibold))
                ))
                chevron.tintColor = palette.ui.comment
                chevron.setContentHuggingPriority(.required, for: .horizontal)
                row.append(chevron)
            }
            return ControlRowViews.stack(row, axis: .horizontal, spacing: 12, alignment: .top)
        }
    }

    private static func summaryView(_ schedule: AgentSchedule, palette: ThemePalette) -> UIView {
        var titleRow: [UIView] = [
            ControlRowViews.selectableText(schedule.name, style: .title3, weight: .semibold, color: palette.ui.fg),
        ]
        if schedule.status != .active {
            let pill = ControlStatusPill()
            pill.apply(
                text: schedule.status.rawValue.capitalized,
                tone: schedule.status == .paused ? palette.orange : palette.comment,
                emphasis: .tinted,
                palette: palette
            )
            titleRow.append(ControlRowViews.spacer())
            titleRow.append(pill)
        }
        let timing = schedule.trigger.detailTimingSummary()
        let when = ControlRowViews.symbolLabel(timing, systemImage: "calendar", style: .subheadline, color: palette.ui.comment)
        when.accessibilityLabel = timing
        when.accessibilityIdentifier = "schedule.detail.when"
        return ControlRowViews.stack([
            ControlRowViews.stack(titleRow, axis: .horizontal, spacing: 8, alignment: .center),
            when,
        ], spacing: 10)
    }

    private static func runTone(_ status: AgentScheduleRunStatus, palette: ThemePalette) -> UIColor {
        switch status {
        case .completed: palette.ui.green
        case .running, .claimed, .pending: palette.ui.blue
        case .failed: palette.ui.red
        }
    }

    private static func runIconName(_ status: AgentScheduleRunStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .running: "play.circle.fill"
        case .claimed, .pending: "clock.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Modals

    private func updateModals() {
        let schedule = schedule
        let connection = connection
        let root = root
        nativeEditor.update(
            id: showNativeEdit && schedule != nil ? "native-edit" : nil,
            presentation: .fullScreen.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showNativeEdit = false },
            screen: {
                .controller {
                    // Opened only from the loaded schedule's Edit.
                    guard let schedule else { preconditionFailure("The editor presents only with its schedule") }
                    return ScheduleNativeEditViewController(
                        schedule: schedule,
                        apiClient: connection.apiClient,
                        connection: connection,
                        serverName: root.activeServerName
                    ) { [weak self] updated, summary in
                        self?.schedule = updated
                        self?.onChanged(summary)
                    }
                }
            }
        )
        promptReader.update(
            id: showPromptReader && schedule != nil ? "prompt" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in
                self?.showPromptReader = false
                // The prompt may have been edited in place: the row and the version
                // this page holds follow the server.
                self?.setNeedsLoad()
            },
            screen: {
                .controller {
                    // Opened only from the loaded schedule's prompt row.
                    guard let schedule else { preconditionFailure("The prompt review opens only for a loaded schedule") }
                    return ReviewableControlMarkdownViewController(
                        content: SchedulePresentation.prompt(in: schedule.action),
                        domain: .schedules,
                        targetId: schedule.id,
                        targetName: schedule.name,
                        sourceLabel: "\(schedule.name) prompt",
                        sourcePath: "Schedules/\(schedule.id)/Prompt.md",
                        // The pencil edits the schedule's own prompt, saved against
                        // the version this screen read.
                        subject: .schedulePrompt(scheduleId: schedule.id),
                        connection: connection,
                        // After an edit the reader shows the schedule's prompt as the
                        // server now holds it.
                        refreshDocument: {
                            guard let fresh = try? await connection.apiClient?.getAgentSchedule(schedule.id)
                            else { return nil }
                            return SchedulePresentation.prompt(in: fresh.action)
                        }
                    )
                }
            }
        )
    }

    private func confirmArchive() {
        Confirmation(
            title: "Archive this schedule?",
            message: "It stops running and moves to Archived. You can restore it later.",
            actionTitle: "Archive",
            style: .alert
        ).present(from: self, anchor: nil) { [weak self] in self?.mutate(.archive) }
    }

    // MARK: - Data

    private enum Mutation {
        case pause, resume, archive, restore
    }

    /// The schedule, its runs, and the Agent names: the base runs it on every
    /// appearance, on pull to refresh, and after a Retry.
    override func load() async throws {
        guard let apiClient = connection.apiClient else {
            throw LoadFailure(String(localized: "Server is offline"))
        }
        async let fetchedSchedule = apiClient.getAgentSchedule(scheduleId)
        async let fetchedRuns = apiClient.listAgentScheduleRuns(scheduleId: scheduleId, limit: 20)
        async let fetchedAgents = apiClient.listAgents(includeArchived: true)
        let loadedSchedule = try await fetchedSchedule
        let loadedRuns = try await fetchedRuns
        let agents = try? await fetchedAgents
        guard !Task.isCancelled else { return }
        schedule = loadedSchedule
        runs = loadedRuns
        if let agents {
            agentNamesById = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        // A page that just loaded says nothing of a change that failed before.
        error = nil
    }

    private func setEnabled(_ isEnabled: Bool) {
        guard !isMutating, let schedule else { return }
        if isEnabled, schedule.status == .paused {
            mutate(.resume)
        } else if !isEnabled, schedule.status == .active {
            mutate(.pause)
        }
    }

    private func runNow() {
        guard let apiClient = connection.apiClient else { return }
        isMutating = true
        let scheduleId = scheduleId
        Task { [weak self] in
            defer { self?.isMutating = false }
            do {
                let run = try await apiClient.runAgentSchedule(scheduleId)
                guard let self else { return }
                runs = scheduleRunsByInsertingNewest(run, into: runs, limit: 20)
                if run.sessionId != nil {
                    openRunSession(run)
                }
                error = nil
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    private func mutate(_ mutation: Mutation) {
        guard let apiClient = connection.apiClient else { return }
        isMutating = true
        let scheduleId = scheduleId
        Task { [weak self] in
            defer { self?.isMutating = false }
            do {
                let updated: AgentScheduleSummary = switch mutation {
                case .pause: try await apiClient.pauseAgentSchedule(scheduleId)
                case .resume: try await apiClient.resumeAgentSchedule(scheduleId)
                case .archive: try await apiClient.archiveAgentSchedule(scheduleId)
                case .restore: try await apiClient.restoreAgentSchedule(scheduleId)
                }
                guard let self else { return }
                if var current = schedule {
                    current.status = updated.status
                    current.updatedAt = updated.updatedAt
                    current.archivedAt = updated.archivedAt
                    // A pause leaves the definition's version alone, but keep it in
                    // step if the server's answer carries a different one.
                    if let version = updated.version { current.version = version }
                    schedule = current
                }
                onChanged(updated)
                error = nil
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    private func openRunSession(_ run: AgentScheduleRunSummary) {
        guard let sessionId = run.sessionId,
              let serverId = connection.workspaceStore.activeServerId else { return }
        root.navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: run.action.workspaceId)
        )
    }

    private func humanWorkspaceName(_ workspaceId: String) -> String {
        connection.workspaceStore.workspaces.first(where: { $0.id == workspaceId })?.name ?? "Unknown workspace"
    }

    private func humanSessionTitle(_ sessionId: String) -> String {
        connection.sessionStore.session(id: sessionId)?.displayTitle ?? "Existing session"
    }

    /// Prefer a resolved agent name. Never surface opaque agent IDs in primary UI.
    private func humanAgentName(_ agentId: String?) -> String? {
        guard let agentId, !agentId.isEmpty else { return nil }
        if let name = agentNamesById[agentId], !name.isEmpty {
            return name
        }
        return "Saved agent"
    }
}
