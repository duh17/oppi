import UIKit

/// One schedule: what it does, what it runs with, Run Now, the Enabled
/// switch (or Restore), and its recent runs. Edit opens the native editor;
/// the actions menu offers Edit with Oppi and Archive. Changes go back to the
/// list through `onChanged`.
@MainActor
final class ScheduleDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case state, summary, instructions, runWith, actions, history }
    private enum Item: Hashable {
        case loading
        case notFound
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
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let refreshControl = UIRefreshControl()
    private let editItem = UIBarButtonItem()
    private let actionsItem = UIBarButtonItem()

    private let nativeEditor = RouterModalPresenter()
    private let revisionSheet = RouterModalPresenter()
    private let promptReader = RouterModalPresenter()

    private var schedule: AgentSchedule? {
        didSet { setNeedsUpdateProperties() }
    }
    private var runs: [AgentScheduleRunSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var agentNamesById: [String: String] = [:] {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var isMutating = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var showNativeEdit = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showRevision = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showPromptReader = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?
    private let errorAlert = ControlErrorAlert()

    init(root: AppRootEnvironment, scheduleId: String, onChanged: @escaping (AgentScheduleSummary) -> Void) {
        self.root = root
        self.scheduleId = scheduleId
        self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
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
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "schedule.detail.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        ControlScreenList.pinFullWidth(collectionView, in: view)
        installDataSource()
        for presenter in [nativeEditor, revisionSheet, promptReader] { presenter.anchor = self }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [nativeEditor, revisionSheet, promptReader] { presenter.sync() }
        // An error that arrived while the screen was off screen shows now.
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        title = schedule?.name ?? "Schedule"
        updateBarItems()
        applySnapshot()
        updateModals()
        errorAlert.show(title: "Schedule", message: error, from: self) { [weak self] in self?.error = nil }
    }

    private func updateBarItems() {
        guard let schedule else {
            ControlScreenList.setBarItems(trailing: [], leading: [], on: navigationItem)
            return
        }
        editItem.isEnabled = !isMutating
        let disabled: UIMenuElement.Attributes = isMutating ? .disabled : []
        let editWithOppi = UIAction(
            title: "Edit with Oppi",
            image: UIImage(systemName: "text.bubble"),
            attributes: disabled
        ) { [weak self] _ in
            self?.showRevision = true
        }
        editWithOppi.accessibilityIdentifier = "schedule.detail.edit"
        var children: [UIMenuElement] = [editWithOppi]
        if schedule.status != .archived {
            let archive = UIAction(
                title: "Archive",
                image: UIImage(systemName: "archivebox"),
                attributes: disabled.union(.destructive)
            ) { [weak self] _ in
                self?.confirmArchive()
            }
            archive.accessibilityIdentifier = "schedule.detail.archive"
            children.append(archive)
        }
        actionsItem.menu = UIMenu(children: children)
        // Native Edit beside the actions menu, as on an Agent's detail.
        ControlScreenList.setBarItems(
            trailing: schedule.status == .archived ? [actionsItem] : [actionsItem, editItem],
            leading: [],
            on: navigationItem
        )
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let schedule {
            snapshot.appendSections([.summary, .instructions, .runWith, .actions, .history])
            snapshot.appendItems([.summary], toSection: .summary)
            snapshot.appendItems([.prompt], toSection: .instructions)
            snapshot.appendItems(runWithItems(schedule.action), toSection: .runWith)
            snapshot.appendItems([.runNow, schedule.status == .archived ? .restore : .enabled], toSection: .actions)
            snapshot.appendItems(runs.isEmpty ? [.noRuns] : runs.map { .run($0.id) }, toSection: .history)
        } else {
            snapshot.appendSections([.state])
            snapshot.appendItems([isLoading ? .loading : .notFound], toSection: .state)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        // Reconfiguring items leaves headers as they were; Run History's
        // carries the run count.
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell else { continue }
            configureHeader(header, section: dataSource.sectionIdentifier(for: indexPath.section))
        }
    }

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

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configureHeader(view, section: self?.dataSource?.sectionIdentifier(for: indexPath.section))
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func configureHeader(_ view: UICollectionViewListCell, section: Section?) {
        var content = UIListContentConfiguration.header()
        switch section {
        case .instructions: content.text = "Instructions"
        case .runWith: content.text = schedule.map { SchedulePresentation.runWithSectionTitle($0.action) }
        case .history:
            content.text = "Run History"
            if !runs.isEmpty {
                content.secondaryText = "\(runs.count) recent"
                content.secondaryTextProperties.color = UIColor(palette.comment)
                content.prefersSideBySideTextAndSecondaryText = true
            }
        default: content.text = nil
        }
        view.contentConfiguration = content
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .loading:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Loading schedule…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .notFound:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.unavailable(
                "Schedule Not Found",
                systemImage: "questionmark.circle",
                palette: palette
            )
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .summary:
            ControlScreenList.staticRow(cell)
            guard let schedule else { return }
            cell.contentConfiguration = ControlViewContent { [palette] in
                Self.summaryView(schedule, palette: palette)
            }
        case .prompt:
            guard let schedule else { return }
            let prompt = SchedulePresentation.prompt(in: schedule.action)
            ControlScreenList.buttonRow(
                cell,
                identifier: "schedule.detail.prompt",
                label: "What it does. \(prompt). Show full schedule instructions",
                hint: "Opens the prompt as full-screen Markdown"
            ) { [weak self] in
                self?.showPromptReader = true
            }
            cell.contentConfiguration = ControlViewContent { [palette] in
                let heading = ControlRowViews.stack([
                    ControlRowViews.label("What it does", style: .subheadline, weight: .medium, color: UIColor(palette.fg), lines: 1),
                    ControlRowViews.spacer(),
                    ControlRowViews.label("Show instructions", style: .caption1, weight: .medium, color: UIColor(palette.blue), lines: 1),
                ], axis: .horizontal, spacing: 8, alignment: .center)
                let body = ControlRowViews.label(prompt, style: .subheadline, color: UIColor(palette.fg), lines: 5)
                return ControlRowViews.stack([heading, body], spacing: 8)
            }
        case .detail(let title, let value):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) { [palette] in
                ControlRowViews.valueRow(title, value, palette: palette)
            }
        case .caption(let text):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent { [palette] in
                ControlRowViews.label(text, style: .caption1, color: UIColor(palette.comment))
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
            ControlScreenList.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = "Enabled"
            content.textProperties.color = UIColor(palette.fg)
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
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.unavailable(
                "No Runs Yet",
                systemImage: "clock.arrow.circlepath",
                description: "Scheduled and manual runs will appear here.",
                palette: palette
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
        ControlScreenList.buttonRow(cell, identifier: identifier, label: title, enabled: enabled, action: action)
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.image = UIImage(systemName: systemImage)
        let tint = UIColor(palette.blue).withAlphaComponent(enabled ? 1 : 0.4)
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
            ControlScreenList.buttonRow(
                cell,
                identifier: "schedule.run.\(run.id)",
                label: label,
                hint: "Opens the run session"
            ) { [weak self] in
                self?.openRunSession(run)
            }
        } else {
            ControlScreenList.staticRow(cell, identifier: "schedule.run.\(run.id)")
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
                ControlRowViews.label(status, style: .subheadline, weight: .semibold, color: UIColor(palette.fg)),
                ControlRowViews.label(detail, style: .caption1, color: UIColor(palette.comment)),
            ]
            if let errorSummary {
                lines.append(ControlRowViews.label(errorSummary, style: .caption1, color: UIColor(palette.red), lines: 3))
            }
            var row: [UIView] = [icon, ControlRowViews.stack(lines, spacing: 4)]
            if opensSession {
                let chevron = UIImageView(image: UIImage(
                    systemName: "chevron.forward",
                    withConfiguration: UIImage.SymbolConfiguration(font: UIFont.scaled(.footnote, .semibold))
                ))
                chevron.tintColor = UIColor(palette.comment)
                chevron.setContentHuggingPriority(.required, for: .horizontal)
                row.append(chevron)
            }
            return ControlRowViews.stack(row, axis: .horizontal, spacing: 12, alignment: .top)
        }
    }

    private static func summaryView(_ schedule: AgentSchedule, palette: ThemePalette) -> UIView {
        var titleRow: [UIView] = [
            ControlRowViews.selectableText(schedule.name, style: .title3, weight: .semibold, color: UIColor(palette.fg)),
        ]
        if schedule.status != .active {
            let pill = ControlStatusPill()
            pill.apply(
                text: schedule.status.rawValue.capitalized,
                tone: UIColor(schedule.status == .paused ? palette.orange : palette.comment),
                emphasis: .tinted,
                palette: palette
            )
            titleRow.append(ControlRowViews.spacer())
            titleRow.append(pill)
        }
        let timing = schedule.trigger.detailTimingSummary()
        let when = ControlRowViews.symbolLabel(timing, systemImage: "calendar", style: .subheadline, color: UIColor(palette.comment))
        when.accessibilityLabel = timing
        when.accessibilityIdentifier = "schedule.detail.when"
        return ControlRowViews.stack([
            ControlRowViews.stack(titleRow, axis: .horizontal, spacing: 8, alignment: .center),
            when,
        ], spacing: 10)
    }

    private static func runTone(_ status: AgentScheduleRunStatus, palette: ThemePalette) -> UIColor {
        switch status {
        case .completed: UIColor(palette.green)
        case .running, .claimed, .pending: UIColor(palette.blue)
        case .failed: UIColor(palette.red)
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
        nativeEditor.update(
            id: showNativeEdit && schedule != nil ? "native-edit" : nil,
            presentation: .fullScreen.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showNativeEdit = false },
            screen: {
                ScheduleHostedScreens.nativeEdit(schedule) { [weak self] updated, summary in
                    self?.schedule = updated
                    self?.onChanged(summary)
                }
            }
        )
        revisionSheet.update(
            id: showRevision && schedule != nil ? "revision" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showRevision = false },
            screen: { [root] in
                .controller {
                    GuidedControlSessionViewController(
                        configuration: GuidedControlComposerConfiguration(
                            domain: .schedules,
                            intent: .revise,
                            targetId: schedule?.id,
                            targetName: schedule?.name,
                            allowsEmptyRequest: true,
                            placeholder: "Describe how this Schedule should change…"
                        ),
                        root: root
                    )
                }
            }
        )
        promptReader.update(
            id: showPromptReader && schedule != nil ? "prompt" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in self?.showPromptReader = false },
            screen: { ScheduleHostedScreens.promptReader(schedule) }
        )
    }

    private func confirmArchive() {
        let alert = UIAlertController(
            title: "Archive this schedule?",
            message: "It stops running and moves to Archived. You can restore it later.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Archive", style: .destructive) { [weak self] _ in self?.mutate(.archive) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Data

    private enum Mutation {
        case pause, resume, archive, restore
    }

    private func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load()
            self?.refreshControl.endRefreshing()
        }
    }

    private func load() async {
        guard let apiClient = connection.apiClient else {
            error = "Server is offline"
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
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
                agentNamesById = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
            }
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
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
