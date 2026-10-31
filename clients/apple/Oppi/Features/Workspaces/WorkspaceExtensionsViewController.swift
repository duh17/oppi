import UIKit

/// Oppi and Pi extensions for one workspace, one switch each. A switch writes
/// Pi's settings at once; the list shows the server's answer after the write.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it; this page only reads the model. Its
/// loading, empty, and failed states read like the workspace Skills page's.
@MainActor
final class WorkspaceExtensionsViewController: ListScreenController<
    WorkspaceExtensionsViewController.Section,
    WorkspaceExtensionsViewController.Item
> {
    enum Section: Hashable, Sendable { case loading, oppi, pi }

    enum Item: Hashable, Sendable {
        case loading
        case empty
        case ext(String)
        case error
    }

    private let model: WorkspaceSettingsModel
    private let root: AppRootEnvironment
    private var loadTask: Task<Void, Never>?
    /// Bumped when a switch's write ends, so it is redrawn from the stored
    /// value even where that value did not change (a failed write).
    private var toggleRevision = 0

    init(model: WorkspaceSettingsModel, root: AppRootEnvironment) {
        self.model = model
        self.root = root
        super.init(
            title: String(localized: "Extensions"),
            listIdentifier: "workspace.edit.extensions.list",
            scope: .workspace(model.workspace.name),
            headers: true,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        let model = model
        loadTask?.cancel()
        loadTask = Task { await model.loadPiResourcesIfNeeded() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        if model.isLoadingExtensions && model.extensions.isEmpty {
            return [ListSection(.loading, items: [.loading])]
        }
        var sections: [ListSection<Section, Item>] = []
        let oppi = model.extensions.filter(\.isOppi)
        let pi = model.extensions.filter { !$0.isOppi }
        if !oppi.isEmpty {
            sections.append(ListSection(
                .oppi,
                header: String(localized: "Oppi Extensions"),
                items: oppi.map { .ext($0.name) }
            ))
        }
        var piItems: [Item] = pi.isEmpty ? [.empty] : pi.map { .ext($0.name) }
        if model.extensionsError != nil { piItems.append(.error) }
        let serverName = model.serverName(in: root.coordinator.serverStore)
        sections.append(ListSection(
            .pi,
            header: String(localized: "Pi Extensions"),
            footer: model.piResourceFooter(serverName: serverName),
            items: piItems
        ))
        return sections
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .loading, .empty:
            return AnyHashable(0)
        case .ext(let name):
            guard let ext = extensionInfo(named: name) else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(ext.name),
                AnyHashable(ext.subtitle),
                AnyHashable(isEnabled(ext)),
                AnyHashable(model.isPending(.extensions, path: ext.path)),
                AnyHashable(model.canTogglePiResources),
                AnyHashable(toggleRevision),
            ])
        case .error:
            return AnyHashable(model.extensionsError)
        }
    }

    private func extensionInfo(named name: String) -> ExtensionInfo? {
        model.extensions.first { $0.name == name }
    }

    private func isEnabled(_ ext: ExtensionInfo) -> Bool {
        model.displayedEnabled(.extensions, path: ext.path, server: ext.enabled)
    }

    private lazy var extensionRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        guard let self, case .ext(let name) = item, let ext = extensionInfo(named: name) else { return }
        configureExtension(cell, ext: ext)
    }

    /// Loading, empty, and the inline error: read-only rows.
    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .loading:
            cell.configure(.loading(String(localized: "Loading extensions\u{2026}")))
        case .error:
            let model = self.model
            cell.configure(
                .failure(model.extensionsError ?? "", retry: { [model] in model.startPiResourceReload() }),
                identifier: "workspace.edit.extensions.error"
            )
        default:
            cell.configure(.message(String(localized: "No Pi extensions discovered for this folder yet.")))
        }
    }

    override func prepareRegistrations() {
        _ = (extensionRow, stateRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        if case .ext = item {
            return collectionView.dequeueConfiguredReusableCell(using: extensionRow, for: indexPath, item: item)
        }
        return collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
    }

    private func configureExtension(_ cell: UICollectionViewListCell, ext: ExtensionInfo) {
        let enabled = isEnabled(ext)
        let path = ext.path
        detailToggleRow(
            cell,
            row: WorkspaceToggleRow(
                title: ext.name,
                detail: ext.subtitle,
                dimsTitle: !enabled,
                monospacedDetail: true,
                isOn: enabled,
                isPending: model.isPending(.extensions, path: path),
                isEnabled: model.canTogglePiResources,
                identifier: "workspace.edit.extension.\(ext.name)"
            )
        ) { [weak self] on in
            guard let self else { return }
            let model = model
            Task { [weak self] in
                await model.setPiResource(.extensions, path: path, enabled: on)
                // A refused or failed write leaves the stored value as it
                // was, so redraw the switch from it.
                self?.toggleRevision += 1
                self?.setNeedsUpdateProperties()
            }
        }
    }
}
