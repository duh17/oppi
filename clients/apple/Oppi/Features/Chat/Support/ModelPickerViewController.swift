import UIKit

/// The model picker: models grouped by provider, with the user's recent
/// picks on top, a context-window column, and (where the presenter can
/// persist one) a star that saves the Pi or Agent default.
///
/// Every presenter shows this controller at the root of a router navigation
/// controller (`.inNavigation()`), so it owns its bar (title, Cancel, the
/// saving spinner) and its `UISearchController`: search, selection, and close
/// have one owner. The presenter passes the server's API client and
/// `ChatSessionState` explicitly; `chatState.cachedModels` opens the list
/// instantly and a refresh runs once per open. Selecting a model reports it
/// through `onSelect` and closes.
///
/// Providers collapse by tapping their header (not while searching). Search
/// uses `FuzzyMatch` across name, id, and provider, best score first.
final class ModelPickerViewController: UIViewController, UICollectionViewDelegate {
    private enum SectionID: Hashable {
        case recent
        case provider(String)
    }

    private struct ProviderGroup {
        let provider: String
        let models: [ModelInfo]
        /// All the provider's models, not just those a search shows.
        let modelCount: Int
    }

    /// The presenter's current model; a live presenter updates it in place.
    var currentModel: String? {
        didSet {
            if currentModel != oldValue, isViewLoaded { reload() }
        }
    }

    private let chatState: ChatSessionState
    private let apiClient: APIClient?
    private let defaultAgentId: String?
    private let onSelect: (ModelInfo) -> Void
    private let onSetDefault: ((ModelInfo) async throws -> Void)?

    private let search = ScreenSearchController(prompt: "Search models…")
    private var query = ""
    private var collapsedProviders: Set<String> = []
    private var providerQuotas: ProviderQuotasInfo?
    private var quotaReferenceDate = Date()
    private var modelLoadError: String?
    private var isSavingDefault = false {
        didSet {
            guard isSavingDefault != oldValue, isViewLoaded else { return }
            updateSavingChrome()
            reload()
        }
    }
    private var agentDefaultModelId: String?
    private var piDefaultModelId: String?

    private var models: [ModelInfo] = []
    private var modelsCacheReady = false
    private var recentModels: [ModelInfo] = []
    private var groups: [ProviderGroup] = []
    private var modelsByID: [String: ModelInfo] = [:]
    private var themeID: ThemeID?

    private let list: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<SectionID, String>!
    private lazy var cancelItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        Router.finish(self)
    })

    init(
        currentModel: String?,
        chatState: ChatSessionState,
        apiClient: APIClient?,
        defaultAgentId: String? = nil,
        onSelect: @escaping (ModelInfo) -> Void,
        onSetDefault: ((ModelInfo) async throws -> Void)? = nil
    ) {
        self.currentModel = currentModel
        self.chatState = chatState
        self.apiClient = apiClient
        self.defaultAgentId = defaultAgentId
        self.onSelect = onSelect
        self.onSetDefault = onSetDefault
        list = UICollectionView(frame: .zero, collectionViewLayout: Self.listLayout())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette {
        (themeID ?? ThemeRuntimeState.currentThemeID()).palette
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Models"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = cancelItem
        search.install(on: self, alwaysVisible: false)
        search.onTextChange = { [weak self] text in
            guard let self, text != query else { return }
            query = text
            reload()
        }
        buildViews()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.reload()
        }

        Task { [weak self] in await self?.loadAgentDefault() }
        Task { [weak self] in
            // Refresh once whenever the picker opens; cached models keep the initial UI instant.
            guard let self, let api = apiClient else { return }
            async let refresh: Void = loadModels(api: api)
            async let usage: Void = loadProviderQuotas(api: api)
            _ = await (refresh, usage)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the catalog or theme store changes.
        let cached = chatState.cachedModels
        let ready = chatState.modelsCacheReady
        let theme = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        guard isViewLoaded, cached != models || ready != modelsCacheReady || theme != themeID else { return }
        models = cached
        modelsCacheReady = ready
        themeID = theme
        view.backgroundColor = UIColor(palette.bg)
        reload()
    }

    // MARK: - Views

    private static func listLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            config.backgroundColor = .clear
            config.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func buildViews() {
        view.backgroundColor = UIColor(palette.bg)
        list.backgroundColor = .clear
        list.delegate = self
        let cell = UICollectionView.CellRegistration<ModelPickerCell, String> { [weak self] cell, _, id in
            guard let self, let model = modelsByID[id] else { return }
            cell.configure(
                model: model,
                id: id,
                isCurrent: isCurrent(model),
                isEnabled: !isSavingDefault,
                star: onSetDefault == nil ? nil : .init(isDefault: isDefault(model), isEnabled: !isSavingDefault),
                palette: palette,
                onSelect: { [weak self] in self?.choose(model) },
                onStar: { [weak self] in self?.saveDefault(model) }
            )
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<ModelPickerHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            self?.configure(header, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        setContentScrollView(list, for: .top)
    }

    private func updateSavingChrome() {
        cancelItem.isEnabled = !isSavingDefault
        list.isUserInteractionEnabled = !isSavingDefault
        isModalInPresentation = isSavingDefault
    }

    // MARK: - Content

    /// Recent models first (when not searching), then one group per provider.
    private func reload() {
        guard isViewLoaded else { return }
        let fullIDs = Dictionary(models.map { (ModelSwitchPolicy.fullModelID(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let recentIDs = AppPreferences.RecentModels.load()
        recentModels = recentIDs.compactMap { fullIDs[$0] }
        groups = makeGroups(recentIDs: Set(recentIDs))
        modelsByID = fullIDs

        var snapshot = NSDiffableDataSourceSnapshot<SectionID, String>()
        var shown = Set<String>()
        func append(_ models: [ModelInfo], to section: SectionID) {
            // A diffable list needs unique ids; a repeated id shows once.
            let ids = models.map(ModelSwitchPolicy.fullModelID(for:)).filter { shown.insert($0).inserted }
            snapshot.appendSections([section])
            snapshot.appendItems(ids, toSection: section)
        }
        if query.isEmpty, !recentModels.isEmpty {
            append(recentModels, to: .recent)
        }
        for group in groups {
            append(isCollapsed(group.provider) ? [] : group.models, to: .provider(group.provider))
        }
        // Rows are keyed by id: reconfigure the ones that stay, so they pick
        // up the current/default state and the theme.
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: !UIAccessibility.isReduceMotionEnabled && list.window != nil)
        refreshHeaders()

        var content = unavailableConfiguration()
        list.isHidden = content != nil
        content?.textProperties.color = UIColor(palette.fg)
        content?.secondaryTextProperties.color = UIColor(palette.comment)
        content?.imageProperties.tintColor = UIColor(palette.comment)
        content?.background.backgroundColor = UIColor(palette.bg)
        contentUnavailableConfiguration = content
    }

    private func unavailableConfiguration() -> UIContentUnavailableConfiguration? {
        guard models.isEmpty else { return nil }
        if !modelsCacheReady, modelLoadError == nil {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = "Loading models…"
            return loading
        }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: modelLoadError == nil ? "cpu" : "wifi.exclamationmark")
        empty.text = modelLoadError == nil ? "No Models Available" : "Models Unavailable"
        empty.secondaryText = modelLoadError ?? "Server returned no models."
        if modelLoadError != nil, let apiClient {
            empty.button = .plain()
            empty.button.title = "Try Again"
            empty.button.baseForegroundColor = UIColor(palette.blue)
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                Task { await self?.loadModels(api: apiClient) }
            }
        }
        return empty
    }

    /// All models grouped by provider, excluding any in the recent section.
    /// When searching, ranks across name, id, and provider.
    private func makeGroups(recentIDs: Set<String>) -> [ProviderGroup] {
        let filtered: [ModelInfo]
        if query.isEmpty {
            filtered = models.filter { !recentIDs.contains(ModelSwitchPolicy.fullModelID(for: $0)) }
        } else if let fuzzy = FuzzyMatch.Query(query) {
            let scored = models.compactMap { model in
                FuzzyMatch.bestScore(fuzzy, fields: [model.name, model.id, model.provider]).map { (model, $0) }
            }
            filtered = scored.sorted { $0.1 > $1.1 }.map(\.0)
        } else {
            filtered = models
        }
        let grouped = Dictionary(grouping: filtered, by: \.provider)
        let counts = Dictionary(grouping: models, by: \.provider).mapValues(\.count)
        let shown: [String] = query.isEmpty ? Array(counts.keys) : Array(grouped.keys)
        let providers = ModelPickerProviderOrdering.sortProviders(shown, recentModels: recentModels)
        return providers.map { provider in
            ProviderGroup(
                provider: provider,
                models: grouped[provider] ?? [],
                modelCount: counts[provider] ?? grouped[provider]?.count ?? 0
            )
        }
    }

    private func isCollapsed(_ provider: String) -> Bool {
        query.isEmpty && collapsedProviders.contains(provider)
    }

    private func isCurrent(_ model: ModelInfo) -> Bool {
        guard let currentModel else { return false }
        return currentModel == ModelSwitchPolicy.fullModelID(for: model) || currentModel == model.id
    }

    private func isDefault(_ model: ModelInfo) -> Bool {
        let id = ModelSwitchPolicy.fullModelID(for: model)
        if defaultAgentId != nil { return agentDefaultModelId == id }
        if let piDefaultModelId { return piDefaultModelId == id }
        return model.isDefault
    }

    // MARK: - Headers

    private func refreshHeaders() {
        for indexPath in list.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            if let header = list.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath) as? ModelPickerHeaderView {
                configure(header, at: indexPath)
            }
        }
    }

    private func configure(_ header: ModelPickerHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
        switch section {
        case .recent:
            header.configure(recentWith: palette)
        case .provider(let provider):
            guard let group = groups.first(where: { $0.provider == provider }) else { return }
            let badges = providerQuotas?.providerBadges(for: provider, relativeTo: quotaReferenceDate) ?? []
            let collapsed = isCollapsed(provider)
            header.configure(
                provider: provider,
                badges: badges,
                modelCount: group.modelCount,
                hasVisibleModels: !group.models.isEmpty,
                isCollapsed: collapsed,
                isSearching: !query.isEmpty,
                isEnabled: !isSavingDefault,
                palette: palette
            ) { [weak self] in
                guard let self else { return }
                if collapsedProviders.remove(provider) == nil { collapsedProviders.insert(provider) }
                reload()
            }
        }
    }

    // MARK: - Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let model = modelsByID[id] else { return }
        choose(model)
    }

    private func choose(_ model: ModelInfo) {
        AppHaptics.selectionChanged()
        onSelect(model)
        Router.finish(self)
    }

    private func saveDefault(_ model: ModelInfo) {
        guard let onSetDefault, !isSavingDefault else { return }
        AppHaptics.selectionChanged()
        isSavingDefault = true
        Task { [weak self] in
            do {
                try await onSetDefault(model)
                guard let self else { return }
                let id = ModelSwitchPolicy.fullModelID(for: model)
                if defaultAgentId != nil { agentDefaultModelId = id } else { piDefaultModelId = id }
                isSavingDefault = false
                Router.finish(self)
            } catch {
                self?.isSavingDefault = false
                self?.showDefaultError(error.localizedDescription)
            }
        }
    }

    private func showDefaultError(_ message: String?) {
        guard view.window != nil else { return }
        let alert = UIAlertController(
            title: "Couldn't Set Default Model",
            message: message ?? "Please try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        alert.view.tintColor = UIColor(palette.blue)
        // Not `present(_:)` on self: with a search active the picker is
        // already presenting the search controller, which drops the alert.
        Router.topPresenter(from: self).present(alert, animated: true)
    }

    // MARK: - Loading

    private func loadAgentDefault() async {
        guard let defaultAgentId, let apiClient else { return }
        do {
            let agent = try await apiClient.getAgent(defaultAgentId)
            agentDefaultModelId = agent.definition.sessionDefaults?.model
            reload()
        } catch {
            showDefaultError(error.localizedDescription)
        }
    }

    private func loadModels(api: APIClient) async {
        modelLoadError = nil
        reload()
        do {
            chatState.cachedModels = try await api.listModels()
            chatState.modelsCacheReady = true
        } catch {
            modelLoadError = error.localizedDescription
        }
        reload()
    }

    private func loadProviderQuotas(api: APIClient) async {
        // Missing quota data must not block model selection.
        guard let quotas = try? await api.fetchProviderQuotas() else { return }
        providerQuotas = quotas
        quotaReferenceDate = Date()
        refreshHeaders()
    }
}

// MARK: - Provider ordering and default persistence

@MainActor
enum ModelPickerProviderOrdering {
    struct Stats: Equatable {
        var count = 0
        var bestRecentIndex = Int.max
    }

    static func sortProviders(_ providers: [String], recentModels: [ModelInfo]) -> [String] {
        let stats = providerStats(from: recentModels)
        return providers.sorted { lhs, rhs in
            let lhsFamily = providerFamily(lhs)
            let rhsFamily = providerFamily(rhs)
            let lhsStats = stats[lhsFamily] ?? Stats()
            let rhsStats = stats[rhsFamily] ?? Stats()

            if lhsStats.count != rhsStats.count {
                return lhsStats.count > rhsStats.count
            }
            if lhsStats.bestRecentIndex != rhsStats.bestRecentIndex {
                return lhsStats.bestRecentIndex < rhsStats.bestRecentIndex
            }

            let lhsBoost = providerBoost(lhsFamily)
            let rhsBoost = providerBoost(rhsFamily)
            if lhsBoost != rhsBoost {
                return lhsBoost < rhsBoost
            }

            let lhsName = ProviderIcon.displayName(for: lhs)
            let rhsName = ProviderIcon.displayName(for: rhs)
            let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    static func providerFamily(_ provider: String) -> String {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "openai-codex":
            return "openai"
        default:
            return normalized
        }
    }

    private static func providerStats(from recentModels: [ModelInfo]) -> [String: Stats] {
        var stats: [String: Stats] = [:]
        for (index, model) in recentModels.enumerated() {
            let family = providerFamily(model.provider)
            var entry = stats[family] ?? Stats()
            entry.count += 1
            entry.bestRecentIndex = min(entry.bestRecentIndex, index)
            stats[family] = entry
        }
        return stats
    }

    private static func providerBoost(_ family: String) -> Int {
        family == "openai" ? 0 : 1
    }
}

/// One persistence path for Quick Session and an already-running saved Agent.
@MainActor
enum ModelDefaultPersistence {
    static func save(_ model: ModelInfo, agentId: String?, api: APIClient) async throws {
        let modelId = ModelSwitchPolicy.fullModelID(for: model)
        if let agentId {
            let agent = try await api.getAgent(agentId)
            guard agent.status == .active else { throw ModelDefaultSaveError.archivedAgent }
            _ = try await api.setAgentDefaultModel(
                agentId: agentId,
                version: agent.version,
                model: modelId
            )
        } else {
            try await api.setPiDefaultModel(modelId)
        }
    }
}

private enum ModelDefaultSaveError: LocalizedError {
    case archivedAgent

    var errorDescription: String? {
        "This Agent is no longer active. Choose another Agent."
    }
}
