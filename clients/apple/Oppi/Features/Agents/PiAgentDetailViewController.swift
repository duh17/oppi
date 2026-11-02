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
    private let composer: GuidedControlComposerController

    private var prompt: PiSystemPromptSnapshot? {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsFilePromptReview = false {
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
            dismissesKeyboardOnDrag: true
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
        fileReview.anchor = self
    }

    /// The Pi configuration: the base loads it once when the page appears and
    /// keeps it (see `loadPolicy`), and again on pull to refresh, after a Retry,
    /// or when the server or its client changes.
    override var loadPolicy: LoadPolicy { .onceUntilSubjectChanges }

    /// The server and the client serving it: a connection that comes up, drops,
    /// or is replaced is another subject, so a load in flight for the old one is
    /// cancelled instead of landing here.
    override func loadSubject() -> AnyHashable? {
        AnyHashable([
            AnyHashable(root.coordinator.activeServerId),
            AnyHashable(root.coordinator.activeConnection.apiClient.map(ObjectIdentifier.init)),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fileReview.sync()
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
        [
            ListSection(.identity, items: [.identity]),
            ListSection(.status, items: []),
            ListSection(.prompt, header: "System Prompt", items: [.file, .prompt]),
            ListSection(
                .tools,
                footer: "Chooses Pi's built-in tools and optional tools such as codemode. Extension tools stay enabled.",
                items: [.tools]
            ),
        ]
    }

    /// Only the system prompt's section carries a heading.
    override func showsHeader(for section: Section) -> Bool { section == .prompt }

    /// A load settles the page in place; its rows should not slide.
    override var animatesUpdates: Bool { false }

    /// A failed load: one row between the identity and the system prompt, with
    /// Retry, which turns into the loading row while the Retry runs. It is a row,
    /// never an alert; `tools.error` (a failed save) is the only alert.
    override func stateSection() -> Section? { .status }

    override func loadingCaption() -> String? { String(localized: "Loading Pi settings…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Pi Settings") }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .prompt:
            return AnyHashable([
                AnyHashable(source == .file), AnyHashable(prompt?.content), AnyHashable(isLoading),
            ])
        case .tools:
            return AnyHashable(AgentManagementPresentation.piToolsSummary(defaultTools: tools.defaultTools))
        case .file:
            // The path is selectable text: a pass that redrew the row would drop
            // a selection or the copy menu, so the row is keyed by it.
            return AnyHashable(AgentManagementPresentation.globalSystemPromptPath)
        // The identity row is labels; the kit's default draws it again.
        default:
            return super.inputs(of: item)
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
                    ControlRowViews.label("Pi", style: .title2, weight: .bold, color: palette.ui.fg, lines: 1),
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
                    views.append(ControlRowViews.label(content, style: .body, color: palette.ui.fg, lines: 8))
                } else if isLoading {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    views.append(ControlRowViews.stack([
                        spinner,
                        ControlRowViews.label("Loading prompt…", style: .body, color: palette.ui.comment),
                    ], axis: .horizontal, spacing: 8, alignment: .center))
                }
                if source == .file {
                    views.append(ControlRowViews.symbolLabel(
                        "Read and comment",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        style: .caption1,
                        weight: .medium,
                        color: palette.ui.blue
                    ))
                } else {
                    views.append(ControlRowViews.label(
                        AgentManagementPresentation.piDefaultPromptInUseLabel,
                        style: .caption1,
                        color: palette.ui.comment
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
            content.textProperties.color = palette.ui.fg
            content.secondaryText = summary
            content.secondaryTextProperties.color = palette.ui.comment
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
    }

    // MARK: - Modals

    private func updateModals() {
        let prompt = prompt
        let connection = root.coordinator.activeConnection
        let serverName = root.activeServerName
        fileReview.update(
            // The reader opens whether or not SYSTEM.md exists: a missing file is
            // still the prompt's document, and the reader is where its pencil is.
            id: showsFilePromptReview && prompt != nil ? "file-prompt" : nil,
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
                        targetPath: prompt?.resolvedPath,
                        // Pi's prompt is one document whether or not the file is
                        // there: a SYSTEM.md that does not exist yet reads as an
                        // editable document whose editor starts from Pi's default
                        // prompt — the text this reader is showing — so leaving it
                        // alone writes nothing and the first real edit creates the
                        // file. The server decides: a server without
                        // `piFileEditing`, or a symlinked SYSTEM.md, answers no
                        // editable read.
                        subject: .piFile(
                            path: AgentManagementPresentation.piSystemPromptFilePath,
                            seedText: prompt?.source == .default ? prompt?.content : nil
                        ),
                        connection: connection,
                        refreshDocument: { [weak self] in
                            guard let api = connection.apiClient else { return nil }
                            return (try? await api.getPiSystemPrompt())?.content
                        },
                        // Done asks before writing Pi's own file (Auto-Save off), and
                        // says what else reads it: every new session on this server.
                        editSaveMessage: String(
                            localized: "Pi uses this file for every new session on \(serverName)."
                        )
                    )
                }
            }
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
        showsFilePromptReview = true
    }

    /// The Pi configuration: the base loads it once when the page appears (see
    /// `loadPolicy`), and again on pull to refresh or after a Retry.
    override func load() async throws {
        guard let apiClient = root.coordinator.activeConnection.apiClient else {
            throw LoadFailure(String(localized: "Server is offline"))
        }
        async let fetchedPrompt = apiClient.getPiSystemPrompt()
        async let fetchedTools = apiClient.getPiDefaultTools()
        // Only the tool catalogs: no plugin rows, so the page also loads from an older server.
        async let fetchedCatalog = apiClient.listServerExtensions(plugins: false)
        let (resolvedPrompt, resolvedTools, catalog) = try await (fetchedPrompt, fetchedTools, fetchedCatalog)
        guard !Task.isCancelled else { return }
        prompt = resolvedPrompt
        tools.apiClient = apiClient
        tools.applyLoaded(
            resolvedTools.defaultTools,
            builtInTools: catalog.builtInTools,
            optionalTools: catalog.optionalTools ?? []
        )
    }
}
