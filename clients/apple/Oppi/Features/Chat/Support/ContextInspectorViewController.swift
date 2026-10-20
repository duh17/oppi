import UIKit

/// Chat's Context panel: where the context window goes, top to bottom as a request
/// fills it, then collapsible sections for each source (AGENTS files, Skills, tools,
/// MCP servers, extensions) and the session's usage and cost.
///
/// The session row drives the window totals live; the breakdown comes from
/// `get_session_stats`, loaded when the panel opens and on refresh.
final class ContextInspectorViewController: UIViewController, UICollectionViewDelegate {
    private let readSession: () -> Session?
    private let readWorkspace: () -> Workspace?
    private let connection: ServerConnection
    private let loadSessionStats: @MainActor () async throws -> SessionStatsSnapshot?
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    private let onClose: () -> Void

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var model = Model.empty
    private var stats: SessionStatsSnapshot?
    private var statsLoading = false
    private var statsError: String?
    private var loadTask: Task<Void, Never>?
    private var themeID: ThemeID?

    /// Open groups, kept for the app run so the panel reopens the way it was left.
    @MainActor private static var expanded: Set<Item> = []

    enum Section: String, Hashable, CaseIterable {
        case context
        case agentsFiles
        case skills
        case tools
        case mcpServers
        case extensions
        case usage
    }

    enum UsageMetric: String, Hashable {
        case promptInput, cached, uncached, output, cost, cacheWaste
    }

    enum Item: Hashable {
        case card
        case segment(SessionContextCompositionKind)
        case freeSpace
        case onDemand
        case header(Section)
        case status(Section)
        case agentsFile(String)
        case skill(String)
        case toolGroup(String)
        case tool(group: String, name: String)
        case extensionResource(String)
        case usage(UsageMetric)
        case modelUsage(String)
    }

    init(
        session: @escaping () -> Session?,
        workspace: @escaping () -> Workspace?,
        connection: ServerConnection,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        loadSessionStats: @escaping @MainActor () async throws -> SessionStatsSnapshot?,
        onClose: @escaping () -> Void
    ) {
        readSession = session
        readWorkspace = workspace
        self.connection = connection
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        self.loadSessionStats = loadSessionStats
        self.onClose = onClose
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
    }

    private var palette: ThemePalette {
        (themeID ?? ThemeRuntimeState.currentThemeID()).palette
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Context"
        navigationItem.largeTitleDisplayMode = .never
        // Set before the bar first draws; `updateProperties` follows theme changes.
        overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.onClose()
        })
        close.accessibilityIdentifier = "chat.context.close"
        navigationItem.leftBarButtonItem = close
        let refresh = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.reloadStats() }
        )
        refresh.accessibilityLabel = "Refresh"
        refresh.accessibilityIdentifier = "chat.context.refresh"
        navigationItem.rightBarButtonItem = refresh

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "chat.context.list"
        let refreshControl = UIRefreshControl()
        refreshControl.addAction(UIAction { [weak self] _ in self?.reloadStats() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
        reloadStats()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the session row or theme changes.
        let current = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        if current != themeID {
            themeID = current
            // System cards follow the trait; match it to the palette's scheme.
            overrideUserInterfaceStyle = current.preferredColorScheme == .light ? .light : .dark
            view.backgroundColor = UIColor(palette.bg)
            collectionView.backgroundColor = UIColor(palette.bg)
        }
        rebuild(session: readSession(), workspace: readWorkspace())
    }

    private func reloadStats() {
        loadTask?.cancel()
        statsLoading = true
        statsError = nil
        rebuild()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loadSessionStats()
                guard !Task.isCancelled else { return }
                stats = loaded
            } catch {
                guard !Task.isCancelled else { return }
                stats = nil
                statsError = error.localizedDescription
            }
            statsLoading = false
            collectionView.refreshControl?.endRefreshing()
            rebuild()
        }
    }

    // MARK: - Model

    /// Everything a cell paints, rebuilt from the session row and the loaded stats.
    private struct Model {
        var usage: ContextUsageSnapshot
        var segments: [SessionContextCompositionSegment]
        var freeSpace: Int
        var onDemandCount: Int
        var onDemandTokens: Int
        var agentsFiles: [ContextFileTokenSnapshot]
        var skills: [SessionResourceSnapshot]
        var toolGroups: [ContextToolGroup]
        var mcpGroups: [ContextToolGroup]
        var extensions: [SessionResourceSnapshot]
        var tools: [ContextToolSnapshot]
        var usageStats: SessionStatsSnapshot?
        /// The session runs on the host, so the paths it reports are host paths. A sandbox
        /// (or a workspace not loaded yet) reports guest paths, and a host read of one would
        /// follow links the guest planted, so nothing here opens on the host then.
        var isHostSession: Bool
        var skillCwd: String?

        static let empty = Self(
            usage: ContextUsageSnapshot(tokens: nil, window: nil),
            segments: [], freeSpace: 0, onDemandCount: 0, onDemandTokens: 0,
            agentsFiles: [], skills: [], toolGroups: [], mcpGroups: [], extensions: [],
            tools: [], usageStats: nil, isHostSession: false, skillCwd: nil
        )

        var groupsByID: [String: ContextToolGroup] {
            Dictionary(uniqueKeysWithValues: (toolGroups + mcpGroups).map { ($0.id, $0) })
        }
    }

    private var lastSession: Session?
    private var lastWorkspace: Workspace?

    private func rebuild(session: Session?, workspace: Workspace?) {
        lastSession = session
        lastWorkspace = workspace
        rebuild()
    }

    private func rebuild() {
        let session = lastSession
        let usage = ContextUsageSnapshot(
            tokens: session?.contextTokens,
            window: session?.contextWindow ?? session?.model.flatMap(inferContextWindow(from:))
        )
        let composition = stats?.contextComposition
        let segments = composition.map {
            SessionContextCompositionProjection.segments(
                totalContextTokens: usage.usedTokens,
                contextWindow: usage.window,
                composition: $0
            )
        } ?? []
        let reserve = segments.first { $0.kind == .compactionReserve }?.tokens ?? 0
        let tools = composition?.tools ?? []
        let onDemand = tools.filter { !$0.inContext }
        let groups = ContextToolGroup.groups(tools)
        model = Model(
            usage: usage,
            segments: segments,
            freeSpace: max(usage.windowTokens - usage.usedTokens - reserve, 0),
            onDemandCount: onDemand.count,
            onDemandTokens: onDemand.reduce(0) { $0 + $1.tokens },
            agentsFiles: composition?.agentsFiles ?? [],
            skills: (stats?.loadedResources?.skills ?? []).sorted { $0.name < $1.name },
            toolGroups: groups.filter { $0.kind != .mcp },
            mcpGroups: groups.filter { $0.kind == .mcp },
            extensions: (stats?.loadedResources?.extensions ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            tools: tools,
            usageStats: stats ?? session.map(SessionStatsSnapshot.fallback(from:)),
            isHostSession: lastWorkspace?.runtime == .host,
            skillCwd: lastWorkspace?.runtime == .host ? lastWorkspace?.hostMount : nil
        )
        applySnapshot()
    }

    // MARK: - Layout and data source

    private static func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            config.backgroundColor = .clear
            // The window card heads the first section; every other section opens
            // with its own collapsible header row.
            config.headerMode = sectionIndex == 0 ? .none : .firstItemInSection
            return .list(using: config, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let card = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = cardConfiguration()
            cell.accessibilityIdentifier = "chat.context.card"
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            if case .card = item {
                return collectionView.dequeueConfiguredReusableCell(using: card, for: indexPath, item: item)
            }
            return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        dataSource.sectionSnapshotHandlers.willExpandItem = { item in
            Self.expanded.insert(item)
        }
        dataSource.sectionSnapshotHandlers.willCollapseItem = { item in
            Self.expanded.remove(item)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        for section in Section.allCases {
            var snapshot = NSDiffableDataSourceSectionSnapshot<Item>()
            switch section {
            case .context:
                snapshot.append(contextItems())
            default:
                let header = Item.header(section)
                snapshot.append([header])
                let children = childItems(for: section)
                snapshot.append(children.map(\.item), to: header)
                for child in children where !child.grandchildren.isEmpty {
                    snapshot.append(child.grandchildren, to: child.item)
                }
                let openable = Set(snapshot.items)
                snapshot.expand(Self.expanded.filter { openable.contains($0) }.map { $0 })
            }
            dataSource.apply(snapshot, to: section, animatingDifferences: false)
        }
        // Items keep their identity across loads; repaint them with the new model.
        var whole = dataSource.snapshot()
        whole.reconfigureItems(whole.itemIdentifiers)
        dataSource.apply(whole, animatingDifferences: false)
    }

    private func contextItems() -> [Item] {
        var items: [Item] = [.card]
        items += model.segments.map { .segment($0.kind) }
        if model.usage.windowTokens > 0, !model.segments.isEmpty {
            items.append(.freeSpace)
        }
        if model.onDemandCount > 0 {
            items.append(.onDemand)
        }
        if model.segments.isEmpty, needsStatusRow {
            items.append(.status(.context))
        }
        return items
    }

    private var needsStatusRow: Bool {
        statsLoading || statsError != nil || stats != nil
    }

    private func childItems(for section: Section) -> [(item: Item, grandchildren: [Item])] {
        let flat: [Item]
        switch section {
        case .context:
            return []
        case .agentsFiles:
            flat = model.agentsFiles.map { .agentsFile($0.path) }
        case .skills:
            flat = model.skills.map { .skill($0.name) }
        case .tools:
            return groupItems(model.toolGroups, section: section)
        case .mcpServers:
            return groupItems(model.mcpGroups, section: section)
        case .extensions:
            flat = model.extensions.map { .extensionResource($0.id) }
        case .usage:
            return usageItems().map { ($0, []) }
        }
        if flat.isEmpty { return [(.status(section), [])] }
        // A diffable snapshot traps on a repeated item; keep the first of any repeat.
        var seen = Set<Item>()
        return flat.filter { seen.insert($0).inserted }.map { ($0, []) }
    }

    private func groupItems(_ groups: [ContextToolGroup], section: Section) -> [(item: Item, grandchildren: [Item])] {
        if groups.isEmpty { return [(.status(section), [])] }
        return groups.map { group in
            var seen = Set<String>()
            let tools = group.tools.filter { seen.insert($0.name).inserted }
            return (.toolGroup(group.id), tools.map { .tool(group: group.id, name: $0.name) })
        }
    }

    private func usageItems() -> [Item] {
        guard let stats = model.usageStats else { return [.status(.usage)] }
        var items: [Item] = [.usage(.promptInput), .usage(.cached), .usage(.uncached), .usage(.output), .usage(.cost)]
        if let waste = stats.cacheWaste, waste.missedTokens > 0 {
            items.append(.usage(.cacheWaste))
        }
        if stats.modelBreakdown.count > 1 {
            items += stats.modelBreakdown.map { .modelUsage($0.id) }
        }
        return items
    }

    // MARK: - Cells

    private func cardConfiguration() -> ContextWindowCardConfiguration {
        let palette = palette
        let usage = model.usage
        let window = Double(usage.windowTokens)
        var segments: [ContextWindowCardConfiguration.Segment] = []
        if window > 0 {
            segments = model.segments.map { segment in
                .init(
                    color: color(for: segment.kind),
                    fraction: Double(segment.tokens) / window,
                    isReserve: segment.kind == .compactionReserve
                )
            }
            if segments.isEmpty, let progress = usage.progress {
                segments = [.init(color: UIColor(palette.blue), fraction: progress, isReserve: false)]
            }
        }
        let percentColor: UIColor = switch usage.progress ?? 0 {
        case 0.9...: UIColor(palette.red)
        case 0.7...: UIColor(palette.orange)
        default: UIColor(palette.comment)
        }
        let usageText: String = if let tokens = usage.tokens, usage.windowTokens > 0 {
            "\(SessionFormatting.tokenCount(tokens)) of \(SessionFormatting.tokenCount(usage.windowTokens)) tokens"
        } else if usage.windowTokens > 0 {
            "Usage unknown until the next response, for example right after compaction."
        } else {
            "Context window unknown."
        }
        return ContextWindowCardConfiguration(
            percentText: usage.progress == nil ? "" : "\(Self.percent(usage.usedTokens, of: usage.windowTokens)) used",
            percentColor: percentColor,
            usageText: usageText,
            segments: segments,
            foreground: UIColor(palette.fg),
            secondary: UIColor(palette.comment),
            track: UIColor(palette.comment).withAlphaComponent(0.2),
            accessibilityLabel: usage.accessibilityLabel
        )
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = palette
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.accessibilityTraits = []
        switch item {
        case .card:
            return
        case .header(let section):
            var content = UIListContentConfiguration.header()
            content.text = headerTitle(section)
            content.textProperties.color = UIColor(palette.fg)
            cell.contentConfiguration = content
            var accessories: [UICellAccessory] = []
            if let summary = headerSummary(section) {
                accessories.append(.label(text: summary, options: .init(tintColor: UIColor(palette.comment))))
            }
            accessories.append(.outlineDisclosure(options: .init(style: .header)))
            cell.accessories = accessories
            cell.accessibilityIdentifier = "chat.context.section.\(section.rawValue)"
        case .segment(let kind):
            guard let segment = model.segments.first(where: { $0.kind == kind }) else { return }
            legendRow(cell, symbol: "circle.fill", tint: color(for: kind), title: segment.label, tokens: segment.tokens, share: true)
            cell.accessibilityIdentifier = "chat.context.segment.\(kind.rawValue)"
        case .freeSpace:
            legendRow(cell, symbol: "circle", tint: UIColor(palette.comment), title: "Free space", tokens: model.freeSpace, share: true)
            cell.accessibilityIdentifier = "chat.context.segment.free"
        case .onDemand:
            legendRow(
                cell,
                symbol: "circle.dashed",
                tint: UIColor(palette.comment),
                title: "Loaded on demand (\(model.onDemandCount))",
                tokens: model.onDemandTokens,
                share: false
            )
            cell.accessibilityIdentifier = "chat.context.segment.onDemand"
        case .status(let section):
            var content = UIListContentConfiguration.cell()
            content.text = statusText(section)
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = statsError != nil && stats == nil && section != .usage
                ? UIColor(palette.orange)
                : UIColor(palette.comment)
            cell.contentConfiguration = content
        case .agentsFile(let path):
            guard let file = model.agentsFiles.first(where: { $0.path == path }) else { return }
            var content = UIListContentConfiguration.cell()
            content.text = Self.displayPath(file.path)
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.numberOfLines = 2
            cell.contentConfiguration = content
            cell.accessories = [tokenLabel(file.tokens)] + (opensOnHost(file.path) ? [.disclosureIndicator()] : [])
            cell.accessibilityIdentifier = "chat.context.agentsFile"
        case .skill(let name):
            guard let skill = model.skills.first(where: { $0.name == name }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = skill.name
            content.secondaryText = skill.description ?? "No description available"
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            content.secondaryTextProperties.numberOfLines = 2
            cell.contentConfiguration = content
            cell.accessories = [tokenLabel(Self.skillPromptTokens(skill), approximate: true)]
                + (model.isHostSession ? [.disclosureIndicator()] : [])
            cell.accessibilityIdentifier = "chat.context.skill.\(skill.name)"
        case .toolGroup(let id):
            guard let group = model.groupsByID[id] else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = Self.groupTitle(group)
            content.secondaryText = Self.groupDetail(group)
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessories = [
                tokenLabel(group.inContextTokens + group.onDemandTokens),
                .outlineDisclosure(options: .init(style: .cell)),
            ]
            cell.accessibilityIdentifier = "chat.context.toolGroup"
        case .tool(let groupID, let name):
            guard let tool = model.groupsByID[groupID]?.tools.first(where: { $0.name == name }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = tool.name
            content.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = tool.inContext ? nil : "On demand"
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessories = [tokenLabel(tool.tokens)]
        case .extensionResource(let id):
            guard let resource = model.extensions.first(where: { $0.id == id }) else { return }
            let tools = tools(of: resource)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = resource.name
            content.secondaryText = tools.isEmpty
                ? (resource.path.isEmpty ? nil : Self.displayPath(resource.path))
                : Self.toolCountDetail(tools)
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            content.secondaryTextProperties.numberOfLines = 2
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "chat.context.extension.\(resource.name)"
        case .usage(let metric):
            guard let stats = model.usageStats else { return }
            usageRow(cell, metric: metric, stats: stats)
        case .modelUsage(let id):
            guard let usage = model.usageStats?.modelBreakdown.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = usage.model
            let tokens = "\(SessionFormatting.tokenCount(usage.tokens)) tokens"
            content.secondaryText = usage.provider.map { $0.isEmpty ? tokens : "\($0) · \(tokens)" } ?? tokens
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessories = [.label(text: SessionFormatting.costString(usage.cost), options: .init(tintColor: UIColor(palette.fg)))]
        }
    }

    private func legendRow(
        _ cell: UICollectionViewListCell,
        symbol: String,
        tint: UIColor,
        title: String,
        tokens: Int,
        share: Bool
    ) {
        var content = UIListContentConfiguration.valueCell()
        content.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        content.imageProperties.tintColor = tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 14, height: 14)
        content.text = title
        content.textProperties.color = UIColor(palette.fg)
        let tokenText = SessionFormatting.tokenCount(tokens)
        content.secondaryText = share && model.usage.windowTokens > 0
            ? "\(tokenText)  \(Self.percent(tokens, of: model.usage.windowTokens))"
            : tokenText
        content.secondaryTextProperties.color = UIColor(palette.comment)
        content.secondaryTextProperties.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        cell.contentConfiguration = content
    }

    private func usageRow(_ cell: UICollectionViewListCell, metric: UsageMetric, stats: SessionStatsSnapshot) {
        let tokens = stats.tokens
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        switch metric {
        case .promptInput:
            content.text = "Prompt input"
            content.secondaryText = SessionFormatting.tokenCount(tokens.promptInput)
        case .cached:
            content.text = "Cached"
            let hit = tokens.cacheHitRate.map { String(format: " · %.1f%% hit", $0 * 100) } ?? ""
            content.secondaryText = "\(SessionFormatting.tokenCount(tokens.cacheRead))\(hit)"
        case .uncached:
            content.text = "Uncached"
            let written = tokens.cacheWrite > 0 ? " · \(SessionFormatting.tokenCount(tokens.cacheWrite)) written" : ""
            content.secondaryText = "\(SessionFormatting.tokenCount(tokens.uncachedInput))\(written)"
        case .output:
            content.text = "Output"
            content.secondaryText = SessionFormatting.tokenCount(tokens.output)
        case .cost:
            content.text = "Total cost"
            content.secondaryText = SessionFormatting.costString(stats.cost)
            content.secondaryTextProperties.color = UIColor(palette.fg)
        case .cacheWaste:
            guard let waste = stats.cacheWaste else { return }
            var subtitle = UIListContentConfiguration.subtitleCell()
            subtitle.image = UIImage(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
            subtitle.imageProperties.tintColor = UIColor(palette.orange)
            subtitle.text = "Cache re-billed"
            subtitle.secondaryText = Self.cacheWasteDetail(waste)
            subtitle.textProperties.color = UIColor(palette.fg)
            subtitle.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = subtitle
            return
        }
        cell.contentConfiguration = content
    }

    private func tokenLabel(_ tokens: Int, approximate: Bool = false) -> UICellAccessory {
        let text = (approximate ? "~" : "") + SessionFormatting.tokenCount(tokens)
        return .label(text: text, options: .init(tintColor: UIColor(palette.comment), font: .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )))
    }

    private func color(for kind: SessionContextCompositionKind) -> UIColor {
        let palette = palette
        return switch kind {
        case .systemPrompt: UIColor(palette.purple)
        case .agentsFiles: UIColor(palette.cyan)
        case .skills: UIColor(palette.yellow)
        case .messages: UIColor(palette.blue)
        case .tools: UIColor(palette.orange)
        case .mcpTools: UIColor(palette.green)
        case .compactionReserve: UIColor(palette.comment)
        }
    }

    // MARK: - Copy

    private func headerTitle(_ section: Section) -> String {
        switch section {
        case .context: "Context window"
        case .agentsFiles: "AGENTS files"
        case .skills: "Skills"
        case .tools: "Tools"
        case .mcpServers: "MCP servers"
        case .extensions: "Extensions"
        case .usage: "Session usage"
        }
    }

    private func headerSummary(_ section: Section) -> String? {
        switch section {
        case .context:
            return nil
        case .agentsFiles:
            guard !model.agentsFiles.isEmpty else { return nil }
            return "\(model.agentsFiles.count) · \(SessionFormatting.tokenCount(model.agentsFiles.reduce(0) { $0 + $1.tokens }))"
        case .skills:
            guard !model.skills.isEmpty else { return nil }
            let tokens = stats?.contextComposition?.skillsListingTokens ?? 0
            return tokens > 0
                ? "\(model.skills.count) · \(SessionFormatting.tokenCount(tokens))"
                : "\(model.skills.count)"
        case .tools:
            return Self.sectionToolSummary(model.toolGroups.flatMap(\.tools))
        case .mcpServers:
            guard !model.mcpGroups.isEmpty else { return nil }
            let tools = model.mcpGroups.reduce(0) { $0 + $1.tools.count }
            return "\(model.mcpGroups.count) · \(tools) tools"
        case .extensions:
            return model.extensions.isEmpty ? nil : "\(model.extensions.count)"
        case .usage:
            return model.usageStats.map { SessionFormatting.costString($0.cost) }
        }
    }

    private func statusText(_ section: Section) -> String {
        if stats == nil {
            if statsLoading { return "Loading…" }
            if let statsError { return "Breakdown unavailable: \(statsError)" }
        }
        return switch section {
        case .context: "No breakdown for this session yet."
        case .agentsFiles: "No AGENTS files loaded."
        case .skills: "No skills loaded."
        case .tools: "This session's runtime does not report its tools."
        case .mcpServers: "No MCP servers."
        case .extensions: "No extensions loaded."
        case .usage: "Session usage is not available yet."
        }
    }

    private static func sectionToolSummary(_ tools: [ContextToolSnapshot]) -> String? {
        guard !tools.isEmpty else { return nil }
        let inContext = tools.filter(\.inContext)
        return "\(inContext.count) · \(SessionFormatting.tokenCount(inContext.reduce(0) { $0 + $1.tokens }))"
    }

    private static func groupTitle(_ group: ContextToolGroup) -> String {
        group.kind == .builtIn ? "Built-in" : group.name
    }

    private static func groupDetail(_ group: ContextToolGroup) -> String {
        var parts: [String] = []
        if group.inContextCount > 0 { parts.append("\(group.inContextCount) in context") }
        if group.onDemandCount > 0 { parts.append("\(group.onDemandCount) on demand") }
        return parts.joined(separator: " · ")
    }

    static func toolCountDetail(_ tools: [ContextToolSnapshot]) -> String {
        let tokens = tools.reduce(0) { $0 + $1.tokens }
        let noun = tools.count == 1 ? "tool" : "tools"
        return "\(tools.count) \(noun) · \(SessionFormatting.tokenCount(tokens))"
    }

    /// Share of the context window, one decimal: what the legend's right column shows.
    static func percent(_ tokens: Int, of window: Int) -> String {
        guard window > 0 else { return "" }
        return String(format: "%.1f%%", Double(tokens) / Double(window) * 100)
    }

    /// Host paths under a home folder read as `~/…`.
    static func displayPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home" else { return path }
        return "~/" + parts.dropFirst(3).joined(separator: "/")
    }

    private static func cacheWasteDetail(_ waste: SessionCacheWasteSnapshot) -> String {
        let misses = waste.missCount == 1 ? "1 miss" : "\(waste.missCount) misses"
        let cost = waste.missedCost >= 0.0005
            ? ", about \(SessionFormatting.costString(waste.missedCost)) extra"
            : ""
        return "\(SessionFormatting.tokenCount(waste.missedTokens)) tokens across \(misses)\(cost)."
    }

    /// The `<skill>` entry the Skills list adds to the system prompt for one Skill.
    private static func skillPromptTokens(_ skill: SessionResourceSnapshot) -> Int {
        let snippet = """
          <skill>
            <name>\(skill.name)</name>
            <description>\(skill.description ?? "")</description>
            <location>\(skill.path)</location>
          </skill>
        """
        return max(1, Int(ceil(Double(snippet.count) / 4.0)))
    }

    private func tools(of resource: SessionResourceSnapshot) -> [ContextToolSnapshot] {
        model.tools.filter { tool in
            tool.sourceKind == .piExtension
                && (resource.path.isEmpty ? tool.sourceName == resource.name : tool.sourcePath == resource.path)
        }
    }

    // MARK: - Selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .header, .toolGroup, .extensionResource: true
        case .skill: model.isHostSession
        case .agentsFile(let path): opensOnHost(path)
        default: false
        }
    }

    /// A path the host file viewer can open for this session: a host session's
    /// absolute or home-relative path. Host reads have no working directory.
    private func opensOnHost(_ path: String) -> Bool {
        model.isHostSession && Self.isHostReadablePath(path)
    }

    /// One line, and absolute or under `~/`: the paths a host-origin read resolves.
    static func isHostReadablePath(_ path: String) -> Bool {
        !path.contains(where: \.isNewline) && (path.hasPrefix("/") || path.hasPrefix("~/"))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .header, .toolGroup:
            toggle(item, at: indexPath)
        case .skill(let name):
            openSkill(name)
        case .agentsFile(let path):
            openHostFile(path)
        case .extensionResource(let id):
            openExtension(id)
        default:
            break
        }
    }

    private func toggle(_ item: Item, at indexPath: IndexPath) {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
        var snapshot = dataSource.snapshot(for: section)
        if snapshot.isExpanded(item) {
            snapshot.collapse([item])
            Self.expanded.remove(item)
        } else {
            snapshot.expand([item])
            Self.expanded.insert(item)
        }
        dataSource.apply(snapshot, to: section, animatingDifferences: true)
    }

    // Pushed SwiftUI pages run in their own screen, so this chat's server and
    // review scope go on explicitly.

    private func openSkill(_ name: String) {
        let cwd = model.skillCwd
        let connection = connection
        let scope = reviewCommentSelectionScope
        Router.push(from: self) {
            SkillDetailView(skillName: name, cwd: cwd)
                .withServerScopedEnvironment(connection)
                .environment(\.reviewCommentSelectionScope, scope)
        }
    }

    private func openHostFile(_ path: String) {
        let fileName = (path as NSString).lastPathComponent
        let viewer = FileViewerViewController(
            configuration: .init(
                workspaceId: "",
                serverId: connection.currentServerId,
                filePath: path,
                fileName: fileName,
                title: fileName,
                source: .hostFile,
                reviewCommentSelectionScope: reviewCommentSelectionScope
            ),
            services: .init(connection: connection)
        )
        Router.push(viewer, from: self)
    }

    private func openExtension(_ id: String) {
        guard let resource = model.extensions.first(where: { $0.id == id }) else { return }
        let page = SessionExtensionContextViewController(
            resource: resource,
            tools: tools(of: resource),
            isHostSession: model.isHostSession,
            openHostFile: { [weak self] path in self?.openHostFile(path) },
            editWithOppi: { [weak self] in self?.editExtension(resource) }
        )
        Router.push(page, from: self)
    }

    // MARK: - Edit with Oppi

    private weak var editSheet: UIViewController?

    /// Starts a control session that edits the extension's file, then closes the
    /// panel and opens that session.
    private func editExtension(_ resource: SessionResourceSnapshot) {
        guard let root = HostFactory.root(near: self) else { return }
        let connection = connection
        let sheet = GuidedControlSessionViewController(
            configuration: GuidedControlComposerConfiguration(
                domain: .extensions,
                intent: .revise,
                targetId: resource.path,
                targetName: resource.name,
                targetPath: resource.path,
                allowsEmptyRequest: true,
                placeholder: "Describe how this extension should change…"
            ),
            root: root,
            connection: { connection },
            onSessionPrepared: { [weak self] target in self?.openEditSession(target) }
        )
        editSheet = sheet
        Router.present(sheet, presentation: .sheet.inNavigation(), from: self, theme: root.themeStore, onDismiss: nil)
    }

    private func openEditSession(_ target: WorkspaceSessionNavTarget) {
        guard let navigation = HostFactory.root(near: self)?.navigation else { return }
        if let editSheet { Router.finish(editSheet) }
        onClose()
        Task { @MainActor in
            await Task.yield()
            navigation.openWorkspaceSession(target)
        }
    }
}

// MARK: - Window card

/// The top card: share used, the window bar split by source, and the totals.
struct ContextWindowCardConfiguration: UIContentConfiguration, Equatable {
    struct Segment: Equatable {
        let color: UIColor
        let fraction: Double
        /// Space kept free rather than used: painted lighter.
        let isReserve: Bool
    }

    var percentText: String
    var percentColor: UIColor
    var usageText: String
    var segments: [Segment]
    var foreground: UIColor
    var secondary: UIColor
    var track: UIColor
    var accessibilityLabel: String

    func makeContentView() -> UIView & UIContentView {
        ContextWindowCardView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> Self { self }
}

private final class ContextWindowCardView: UIView, UIContentView {
    private let titleLabel = UILabel()
    private let percentLabel = UILabel()
    private let bar = ContextWindowBarView()
    private let usageLabel = UILabel()
    private var current: ContextWindowCardConfiguration

    var configuration: UIContentConfiguration {
        get { current }
        set {
            guard let next = newValue as? ContextWindowCardConfiguration, next != current else { return }
            current = next
            apply()
        }
    }

    init(configuration: ContextWindowCardConfiguration) {
        current = configuration
        super.init(frame: .zero)
        titleLabel.text = "Context window"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        percentLabel.font = .preferredFont(forTextStyle: .subheadline)
        percentLabel.adjustsFontForContentSizeCategory = true
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        usageLabel.font = .preferredFont(forTextStyle: .footnote)
        usageLabel.adjustsFontForContentSizeCategory = true
        usageLabel.numberOfLines = 0

        // Centered, not baseline-aligned: before usage is known the percent
        // label is empty, and baseline alignment against an empty label left
        // the card's self-sized height unbounded.
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        percentLabel.textAlignment = .right
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, percentLabel])
        titleRow.alignment = .center
        titleRow.spacing = 8
        let stack = UIStackView(arrangedSubviews: [titleRow, bar, usageLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 12),
        ])
        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func apply() {
        titleLabel.textColor = current.foreground
        percentLabel.text = current.percentText
        percentLabel.textColor = current.percentColor
        usageLabel.text = current.usageText
        usageLabel.textColor = current.secondary
        bar.segments = current.segments
        bar.track = current.track
        accessibilityLabel = current.accessibilityLabel
    }
}

private final class ContextWindowBarView: UIView {
    var segments: [ContextWindowCardConfiguration.Segment] = [] { didSet { setNeedsDisplay() } }
    var track: UIColor = .systemFill { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        let bounds = self.bounds
        let radius = bounds.height / 2
        track.setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: radius).fill()

        // Segments sit left to right in request order with hairline gaps; a
        // non-empty one stays visible even when it rounds to nothing.
        let gap: CGFloat = 1.5
        var x: CGFloat = 0
        UIBezierPath(roundedRect: bounds, cornerRadius: radius).addClip()
        for segment in segments where segment.fraction > 0 {
            let width = min(max(bounds.width * segment.fraction, 2), bounds.width - x)
            guard width > 0 else { break }
            let rect = CGRect(x: x, y: 0, width: width, height: bounds.height)
            (segment.isReserve ? segment.color.withAlphaComponent(0.45) : segment.color).setFill()
            UIBezierPath(rect: rect).fill()
            x += width + gap
        }
    }
}
