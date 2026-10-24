import UIKit

/// Pi: the server's global Pi configuration. Its system prompt (read it, or
/// read and comment on SYSTEM.md), its tools (a pushed page), and a guided
/// session that edits SYSTEM.md.
@MainActor
final class PiAgentDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case identity, prompt, tools, edit }
    private enum Item: Hashable { case identity, file, prompt, tools, edit }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let refreshControl = UIRefreshControl()
    private let tools = PiToolsEditor()
    private let errorAlert = ControlErrorAlert()

    private let guidedSheet = RouterModalPresenter()
    private let fileReview = RouterModalPresenter()
    private let defaultPromptViewer = RouterModalPresenter()

    private var prompt: PiSystemPromptSnapshot? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsSystemPromptSession = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsFilePromptReview = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsDefaultPrompt = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Pi"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var source: PiSystemPromptSnapshot.Source { prompt?.source ?? .default }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "agents.pi.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        ControlScreenList.pinFullWidth(collectionView, in: view)
        installDataSource()
        for presenter in [guidedSheet, fileReview, defaultPromptViewer] { presenter.anchor = self }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Coming back from Tools keeps the selection it saved.
        guard !tools.hasLoadedTools else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [guidedSheet, fileReview, defaultPromptViewer] { presenter.sync() }
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
        _ = tools.defaultTools
        applySnapshot()
        updateModals()
        errorAlert.show(title: "Pi", message: tools.error, from: self) { [tools] in tools.error = nil }
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.identity, .prompt, .tools, .edit])
        snapshot.appendItems([.identity], toSection: .identity)
        snapshot.appendItems([.file, .prompt], toSection: .prompt)
        snapshot.appendItems([.tools], toSection: .tools)
        snapshot.appendItems([.edit], toSection: .edit)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .prompt ? "System Prompt" : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .tools:
                content.text = "Chooses Pi's built-in tools and optional tools such as codemode. Extension tools stay enabled."
            case .edit:
                content.text = "Opens a Pi Control session so Pi can inspect, create, or edit the global file. Pi is not stored as a saved Agent."
            default:
                content.text = nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .identity:
            ControlScreenList.staticRow(cell)
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
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                let row = ControlRowViews.valueRow("File", AgentManagementPresentation.globalSystemPromptPath, palette: palette, style: .body)
                row.accessibilityIdentifier = "agents.pi.systemPromptPath"
                return row
            }
        case .prompt:
            let source = source
            ControlScreenList.buttonRow(
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
            ControlScreenList.buttonRow(cell, identifier: "agents.pi.tools", label: "Tools", value: summary) { [weak self] in
                self?.openTools()
            }
            var content = UIListContentConfiguration.valueCell()
            content.text = "Tools"
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = summary
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .edit:
            ControlScreenList.buttonRow(cell, identifier: "agents.pi.editSystemPrompt", label: "Edit SYSTEM.md with Pi") { [weak self] in
                self?.showsSystemPromptSession = true
            }
            var content = UIListContentConfiguration.cell()
            content.text = "Edit SYSTEM.md with Pi"
            content.image = UIImage(systemName: "text.bubble")
            content.textProperties.color = UIColor(palette.blue)
            content.imageProperties.tintColor = UIColor(palette.blue)
            cell.contentConfiguration = content
        }
    }

    // MARK: - Modals

    private func updateModals() {
        let systemPromptPath = prompt?.resolvedPath ?? AgentManagementPresentation.globalSystemPromptPath
        guidedSheet.update(
            id: showsSystemPromptSession ? "system-prompt-session" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showsSystemPromptSession = false },
            screen: { [root] in
                .controller {
                    GuidedControlSessionViewController(
                        configuration: GuidedControlComposerConfiguration(
                            domain: .agents,
                            intent: .revise,
                            targetName: "Pi global configuration",
                            targetPath: systemPromptPath,
                            initialRequest: "Help me create or edit Pi's global system prompt.",
                            allowsEmptyRequest: false,
                            placeholder: "Describe how Pi's global system prompt should change…"
                        ),
                        root: root
                    )
                }
            }
        )
        let prompt = prompt
        fileReview.update(
            id: showsFilePromptReview && prompt?.resolvedPath != nil ? "file-prompt" : nil,
            presentation: .sheet,
            root: root,
            clear: { [weak self] in self?.showsFilePromptReview = false },
            screen: {
                AgentHostedScreens.reviewableMarkdown(
                    content: prompt?.content ?? "",
                    targetId: "pi",
                    targetName: "Pi",
                    sourceLabel: "SYSTEM.md",
                    sourcePath: prompt?.resolvedPath ?? "",
                    targetPath: prompt?.resolvedPath
                )
            }
        )
        defaultPromptViewer.update(
            id: showsDefaultPrompt ? "default-prompt" : nil,
            presentation: .fullScreen,
            root: root,
            clear: { [weak self] in self?.showsDefaultPrompt = false },
            screen: { AgentHostedScreens.defaultPrompt(prompt?.content ?? "") }
        )
    }

    // MARK: - Actions

    /// Pushes the Tools page. It edits `tools`, which saves each change and
    /// once more when the page closes.
    private func openTools() {
        tools.pickerDidOpen()
        Router.push(AgentHostedScreens.piTools(tools, root: root), from: self)
    }

    private func openPrompt() {
        if AgentManagementPresentation.piPromptIsReviewable(source) {
            showsFilePromptReview = true
        } else if prompt?.content != nil {
            showsDefaultPrompt = true
        }
    }

    private func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load()
            self?.refreshControl.endRefreshing()
        }
    }

    private func load() async {
        guard let apiClient = root.coordinator.activeConnection.apiClient else { return }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            async let fetchedPrompt = apiClient.getPiSystemPrompt()
            async let fetchedTools = apiClient.getPiDefaultTools()
            async let fetchedCatalog = apiClient.listServerExtensions()
            let (resolvedPrompt, resolvedTools, catalog) = try await (fetchedPrompt, fetchedTools, fetchedCatalog)
            guard !Task.isCancelled else { return }
            prompt = resolvedPrompt
            tools.apiClient = apiClient
            tools.applyLoaded(
                resolvedTools.defaultTools,
                builtInTools: catalog.builtInTools,
                optionalTools: catalog.optionalTools ?? []
            )
            tools.error = nil
        } catch {
            guard !Task.isCancelled else { return }
            tools.error = error.localizedDescription
        }
    }
}
