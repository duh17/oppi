import UIKit

/// Settings > Sessions: Auto-Name and the session row editor.
///
/// Auto-Name is two settings in two places, in two sections:
/// - The **provider** is this device's: who names a session started here (the
///   server, Apple's on-device model, or nobody). It is a device setting and
///   never touches the server.
/// - The **server** section is the server's, for every device: whether it names
///   sessions (`enabled`) and with which model.
///
/// Both come from `SettingsCatalog` and are read and written by
/// `SettingsStore`; this page owns only the list of models the server offers.
/// The page mixes scopes, so it has none of its own and each section says where
/// its settings are kept.
final class SettingsSessionsViewController: SettingsListViewController<SettingsSessionsViewController.Section, SettingsSessionsViewController.Item> {
    enum Section: Hashable, Sendable { case provider, server, rows }

    enum Item: Hashable, Sendable {
        case provider
        case serverEnabled
        case serverModel
        /// The failure line under the declared setting with this id.
        case failure(String)
        /// The server's model list could not be loaded.
        case modelsFailure
        case sessionRows
    }

    /// The models the visible server offers, for the Model menu.
    private enum Models {
        case idle
        case loading
        case loaded([ModelInfo])
        case failed(String)
    }

    private let root: AppRootEnvironment
    private var models = Models.idle
    private var modelsServerId: String?
    private var modelsTask: Task<Void, Never>?

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(
            title: String(localized: "Sessions"),
            listIdentifier: "settings.sessions.list",
            scope: nil,
            settings: root.settings,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    deinit { modelsTask?.cancel() }

    // MARK: - Models

    private func loadModels() {
        guard let serverId = root.coordinator.activeServerId else { return }
        modelsTask?.cancel()
        models = .loading
        modelsTask = Task { [weak self] in
            let result: Models
            do {
                guard let api = await self?.root.coordinator.apiClientReady(for: serverId) else {
                    throw SettingsError.unavailable(String(localized: "The server is not reachable."))
                }
                result = .loaded(try await api.listModels())
            } catch is CancellationError {
                return
            } catch {
                result = .failed(String(localized: "Could not load models. \(error.localizedDescription)"))
            }
            guard let self, !Task.isCancelled, modelsServerId == serverId else { return }
            models = result
            setNeedsUpdateProperties()
        }
    }

    override func updateProperties() {
        // The server follows the app's visible one: attach before anything reads.
        let serverId = root.coordinator.activeServerId
        settings?.attach(serverId: serverId)
        if modelsServerId != serverId {
            modelsServerId = serverId
            modelsTask?.cancel()
            models = .idle
        }
        super.updateProperties()
        if case .idle = models, serverId != nil { loadModels() }
    }

    // MARK: - Sections

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let provider = SettingsCatalog.autoNameProvider
        let enabled = SettingsCatalog.autoNameServerEnabled
        let model = SettingsCatalog.autoNameServerModel
        var serverItems = settingRows(enabled, .serverEnabled) { .failure($0) }
            + settingRows(model, .serverModel) { .failure($0) }
        if case .failed = models { serverItems.append(.modelsFailure) }
        return [
            SettingsSectionModel(
                .provider,
                footer: providerFooter,
                scope: settingScope(provider),
                items: settingRows(provider, .provider) { .failure($0) }
            ),
            SettingsSectionModel(
                .server,
                footer: enabled.copy.footer,
                scope: settingScope(enabled),
                items: serverItems
            ),
            SettingsSectionModel(
                .rows,
                footer: String(localized: "Choose the details shown on session rows in every session list."),
                items: [.sessionRows]
            ),
        ]
    }

    private var providerFooter: String {
        switch settings?.read(SettingsCatalog.autoNameProvider).current ?? SettingsCatalog.autoNameProvider.default {
        case .server: String(localized: "Titles come from the server, set below.")
        case .onDevice: String(localized: "Apple's on-device language model creates titles without network access. Quality may vary.")
        case .off: String(localized: "Sessions will show the first message as their title.")
        }
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .provider: settingInputs(SettingsCatalog.autoNameProvider)
        case .serverEnabled: settingInputs(SettingsCatalog.autoNameServerEnabled)
        case .serverModel: AnyHashable([settingInputs(SettingsCatalog.autoNameServerModel), AnyHashable(modelChoiceSignature)])
        case .failure(let id): settingFailureInputs(id)
        case .modelsFailure:
            if case .failed(let reason) = models { AnyHashable(reason) } else { AnyHashable(0) }
        case .sessionRows: AnyHashable(AppPreferences.SessionRows.display.density)
        }
    }

    // MARK: - Rows

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .provider:
            settingChoiceRow(cell, SettingsCatalog.autoNameProvider, choices: AppPreferences.Session.AutoTitleProvider.allCases.map {
                SettingChoice(value: $0, title: $0.label)
            })
        case .serverModel:
            settingChoiceRow(
                cell,
                SettingsCatalog.autoNameServerModel,
                groups: modelChoices,
                placeholder: String(localized: "Choose a Model")
            )
        default:
            break
        }
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let density = AppPreferences.SessionRows.display.density.label
        cell.configure(
            title: String(localized: "Session Rows"),
            systemImage: nil,
            value: density,
            identifier: "settings.sessionRows"
        ) { [weak self] in self?.openSessionRows() }
    }

    private func openSessionRows() {
        ScreenNavigator.forUIKitScreen(self, root: root).push(SessionRowDisplayEditorViewController(root: root))
    }

    private lazy var modelsFailureRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        guard let self, case .failed(let reason) = models else { return }
        cell.configure(.failure(reason, retry: { [weak self] in
            self?.models = .idle
            self?.setNeedsUpdateProperties()
        }), identifier: "settings.sessions.autoNameServerModel.modelsFailure")
    }

    override func prepareRegistrations() {
        _ = (menuRow, indexRow, modelsFailureRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .provider, .serverModel:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .serverEnabled:
            super.dequeue(item, at: indexPath)
        case .failure(let id):
            dequeueSettingFailure(id, at: indexPath)
        case .modelsFailure:
            collectionView.dequeueConfiguredReusableCell(using: modelsFailureRow, for: indexPath, item: item)
        case .sessionRows:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        if item == .serverEnabled { settingToggleRow(cell, SettingsCatalog.autoNameServerEnabled) }
    }

    // MARK: - Model choices

    /// The server's compatible models by provider. The stored model is always
    /// offered, even before the list arrives or when the server no longer lists it.
    private var modelChoices: [SettingChoiceGroup<String>] {
        var groups: [SettingChoiceGroup<String>] = []
        if case .loaded(let infos) = models {
            groups = AutoTitleModelCatalog.compatibleModelGroups(from: infos).map { group in
                SettingChoiceGroup(title: group.provider, choices: group.models.map { SettingChoice(value: $0.fullId, title: $0.name) })
            }
        }
        let stored = settings?.read(SettingsCatalog.autoNameServerModel).current ?? ""
        if !stored.isEmpty, !groups.contains(where: { $0.choices.contains { $0.value == stored } }) {
            groups.insert(SettingChoiceGroup(title: nil, choices: [SettingChoice(value: stored, title: stored)]), at: 0)
        }
        return groups
    }

    /// Redraws the Model row when the menu's choices change.
    private var modelChoiceSignature: [String] {
        modelChoices.flatMap { group in group.choices.map(\.value) }
    }

    override func isSelectable(_ item: Item) -> Bool { item == .sessionRows }

    override func select(_ item: Item) {
        if item == .sessionRows { openSessionRows() }
    }
}
