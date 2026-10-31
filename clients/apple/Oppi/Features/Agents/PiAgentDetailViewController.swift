import UIKit

/// Pi: the server's global Pi configuration. Its system prompt (read it, or
/// read and comment on SYSTEM.md), its tools (a pushed page), and the compact
/// Oppi bar, which starts a guided session that edits SYSTEM.md.
///
/// A `ListScreenController`: the base owns the list, the failure row, and the
/// pull to refresh. This page loads once when it appears, so coming back from
/// Tools keeps the selection that page saved.
@MainActor
final class PiAgentDetailViewController: ListScreenController<PiAgentDetailViewController.Section, PiAgentDetailViewController.Item> {
    enum Section: Hashable, Sendable { case identity, status, prompt, tools }
    enum Item: Hashable, Sendable { case identity, file, prompt, tools }

    private let root: AppRootEnvironment
    private let tools = PiToolsEditor()

    private let fileReview = RouterModalPresenter()
    private let defaultPromptViewer = RouterModalPresenter()
    private let composer: GuidedControlComposerController

    private var prompt: PiSystemPromptSnapshot? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = false {
        didSet { setNeedsUpdateProperties() }
    }
    /// Why the last load failed. It shows as a state row with Retry, never an
    /// alert; `tools.error` (a failed save) is the only alert.
    private var loadError: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsFilePromptReview = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsDefaultPrompt = false {
        didSet { setNeedsUpdateProperties() }
    }

    init(root: AppRootEnvironment) {
        self.root = root
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .agents,
                intent: .revise,
                presentation: .compact,
                targetName: "Pi global configuration",
                placeholder: "Describe a change…"
            ),
            root: root
        )
        super.init(
            title: "Pi", listIdentifier: "agents.pi.list",
            headers: true, footers: true,
            dismissesKeyboardOnDrag: true, pullsToRefresh: true
        )
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var source: PiSystemPromptSnapshot.Source { prompt?.source ?? .default }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.install(in: self)
        for presenter in [fileReview, defaultPromptViewer] { presenter.anchor = self }
    }

    /// Coming back from Tools keeps the selection it saved: the page loads
    /// once, and a pull to refresh or a Retry loads again.
    override var loadsWhenAppearing: Bool { !tools.hasLoadedTools }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [fileReview, defaultPromptViewer] { presenter.sync() }
        // A failed save that arrived while the screen was off screen shows now.
        setNeedsUpdateProperties()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        // Only a SYSTEM.md that exists is a host file to name.
        composer.model.updateTarget(id: nil, name: "Pi global configuration", path: prompt?.resolvedPath)
        _ = tools.defaultTools
        updateModals()
        // A failed save of the tools, which the Tools page made.
        errorAlerts.sync(title: "Pi", message: tools.error) { [tools] shown in
            if tools.error == shown { tools.error = nil }
        }
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        var sections: [ListSection<Section, Item>] = [ListSection(.identity, items: [.identity])]
        if let state = stateRow() { sections.append(ListSection(.status, items: [], state: state)) }
        sections.append(ListSection(.prompt, header: "System Prompt", items: [.file, .prompt]))
        sections.append(ListSection(
            .tools,
            footer: "Chooses Pi's built-in tools and optional tools such as codemode. Extension tools stay enabled.",
            items: [.tools]
        ))
        return sections
    }

    /// Only the system prompt's section carries a heading.
    override func showsHeader(for section: Section) -> Bool { section == .prompt }

    /// A load settles the page in place; its rows should not slide.
    override var animatesUpdates: Bool { false }

    /// A failed load: one row between the identity and the system prompt, with
    /// Retry. It is a row, never an alert; `tools.error` (a failed save) is the
    /// only alert.
    private func stateRow() -> ListStateRow? {
        guard let loadError else { return nil }
        // A Retry keeps its row and turns it into the loading row.
        if !isLoading {
            return ListStateRow(
                state: .failed(
                    title: loadError,
                    message: nil,
                    retry: RetryAction { [weak self] in self?.setNeedsRefresh() }
                ),
                identifier: "agents.pi.state"
            )
        }
        return ListStateRow(state: .loading("Loading Pi settings…"), identifier: "agents.pi.state")
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .identity, .file:
            return AnyHashable(0)
        case .prompt:
            return AnyHashable([
                AnyHashable(source == .file), AnyHashable(prompt?.content), AnyHashable(isLoading),
            ])
        case .tools:
            return AnyHashable(AgentManagementPresentation.piToolsSummary(defaultTools: tools.defaultTools))
        }
    }

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`.
    override var rowStyle: ListRowStyle { .card }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .identity:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                let identity = ControlRowViews.stack([
                    AgentListViewController.tile(PiAvatarRenderer.render(size: 44, themeID: nil), size: 44, padding: 6, radius: 14, palette: palette),
                    ControlRowViews.label("Pi", style: .title2, weight: .bold, color: UIColor(palette.fg), lines: 1),
                ], axis: .horizontal, spacing: 14, alignment: .center)
                identity.isAccessibilityElement = true
                identity.accessibilityLabel = AgentManagementPresentation.piIdentityAccessibilityLabel
                identity.accessibilityIdentifier = "agents.pi.identity"
                return identity
            }
        case .file:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                let row = ControlRowViews.valueRow("File", AgentManagementPresentation.globalSystemPromptPath, palette: palette, style: .body)
                row.accessibilityIdentifier = "agents.pi.systemPromptPath"
                return row
            }
        case .prompt:
            let source = source
            ListScreen.buttonRow(
                cell,
                identifier: "agents.pi.systemPrompt",
                label: AgentManagementPresentation.piSystemPromptAccessibilityLabel(source: source),
                value: AgentManagementPresentation.piSystemPromptAccessibilityValue(source: source) ?? ""
            ) { [weak self] in
                self?.openPrompt()
            }
            let content = prompt?.content
            let isLoading = isLoading
            cell.contentConfiguration = ControlViewContent {
                var views: [UIView] = []
                if let content, !content.isEmpty {
                    views.append(ControlRowViews.label(content, style: .body, color: UIColor(palette.fg), lines: 8))
                } else if isLoading {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    views.append(ControlRowViews.stack([
                        spinner,
                        ControlRowViews.label("Loading prompt…", style: .body, color: UIColor(palette.comment)),
                    ], axis: .horizontal, spacing: 8, alignment: .center))
                }
                if source == .file {
                    views.append(ControlRowViews.symbolLabel(
                        "Read and comment",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        style: .caption1,
                        weight: .medium,
                        color: UIColor(palette.blue)
                    ))
                } else {
                    views.append(ControlRowViews.label(
                        AgentManagementPresentation.piDefaultPromptInUseLabel,
                        style: .caption1,
                        color: UIColor(palette.comment)
                    ))
                }
                return ControlRowViews.stack(views, spacing: 10, alignment: .leading)
            }
        case .tools:
            let summary = AgentManagementPresentation.piToolsSummary(defaultTools: tools.defaultTools)
            ListScreen.buttonRow(cell, identifier: "agents.pi.tools", label: "Tools", value: summary) { [weak self] in
                self?.openTools()
            }
            var content = UIListContentConfiguration.valueCell()
            content.text = "Tools"
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = summary
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
    }

    // MARK: - Modals

    private func updateModals() {
        let prompt = prompt
        fileReview.update(
            id: showsFilePromptReview && prompt?.resolvedPath != nil ? "file-prompt" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in self?.showsFilePromptReview = false },
            screen: {
                .controller {
                    ReviewableControlMarkdownViewController(
                        content: prompt?.content ?? "",
                        domain: .agents,
                        targetId: "pi",
                        targetName: "Pi",
                        sourceLabel: "SYSTEM.md",
                        sourcePath: prompt?.resolvedPath ?? "",
                        targetPath: prompt?.resolvedPath
                    )
                }
            }
        )
        defaultPromptViewer.update(
            id: showsDefaultPrompt ? "default-prompt" : nil,
            presentation: .fullScreen,
            root: root,
            clear: { [weak self] in self?.showsDefaultPrompt = false },
            screen: { .controller { PiDefaultPromptViewController(content: prompt?.content ?? "") } }
        )
    }

    // MARK: - Actions

    /// Pushes the Tools page. It edits `tools`, which saves each change and
    /// once more when the page closes.
    private func openTools() {
        tools.pickerDidOpen()
        Router.push(AgentToolSelectionViewController(selection: .pi(tools, serverName: root.activeServerName)), from: self)
    }

    private func openPrompt() {
        if AgentManagementPresentation.piPromptIsReviewable(source) {
            showsFilePromptReview = true
        } else if prompt?.content != nil {
            showsDefaultPrompt = true
        }
    }

    /// The Pi configuration: on pull to refresh and after a Retry; the page
    /// loads once when it appears (see `loadsWhenAppearing`).
    override func refresh() async {
        await load()
    }

    private func load() async {
        guard let apiClient = root.coordinator.activeConnection.apiClient else {
            // A cancelled load leaves the flag to the load that replaced it.
            isLoading = false
            loadError = "Server offline"
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            async let fetchedPrompt = apiClient.getPiSystemPrompt()
            async let fetchedTools = apiClient.getPiDefaultTools()
            async let fetchedCatalog = apiClient.listServerExtensions()
            let (resolvedPrompt, resolvedTools, catalog) = try await (fetchedPrompt, fetchedTools, fetchedCatalog)
            guard !Task.isCancelled, isCurrent(apiClient) else { return }
            prompt = resolvedPrompt
            tools.apiClient = apiClient
            tools.applyLoaded(
                resolvedTools.defaultTools,
                builtInTools: catalog.builtInTools,
                optionalTools: catalog.optionalTools ?? []
            )
            loadError = nil
        } catch {
            // A load cancelled under the page (Back, a replaced connection) is not a failure to report.
            guard !Task.isCancelled, isCurrent(apiClient), !error.isLoadCancellation else { return }
            loadError = error.localizedDescription
        }
    }

    /// Whether `apiClient` still serves the active server: an answer that
    /// arrives after the connection was replaced is not this page's.
    private func isCurrent(_ apiClient: APIClient) -> Bool {
        root.coordinator.activeConnection.apiClient === apiClient
    }
}
