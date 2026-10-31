import UIKit

/// Oppi and Pi extensions for one workspace, one switch each. A switch writes
/// Pi's settings at once; the list shows the server's answer after the write.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it; this page only reads the model. Its
/// loading, empty, and failed states read like the workspace Skills page's: the
/// model's own load, drawn by the base's state row.
@MainActor
final class WorkspaceExtensionsViewController: ListScreenController<
    WorkspaceExtensionsViewController.Section,
    WorkspaceExtensionsViewController.Item
> {
    enum Section: Hashable, Sendable { case oppi, pi }

    enum Item: Hashable, Sendable { case ext(String) }

    private let model: WorkspaceSettingsModel
    private let root: AppRootEnvironment
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

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    /// The model loads the two Pi resource lists once per scope, so a load each
    /// appearance asks it for nothing after the first; a failed one is retried
    /// by the next ask (the base's Retry, or the page appearing again).
    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func load() async throws {
        // A read or a write that failed is what a Retry is for: it reads the list
        // again rather than keeping what the server last said.
        if model.extensionsError != nil { model.startPiResourceReload() }
        await model.loadPiResourcesIfNeeded()
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
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
        // The Pi group always shows: it is where the state row goes when the
        // folder has no Pi extensions, is loading them, or could not.
        let serverName = model.serverName(in: root.coordinator.serverStore)
        sections.append(ListSection(
            .pi,
            header: String(localized: "Pi Extensions"),
            footer: model.piResourceFooter(serverName: serverName),
            items: pi.map { .ext($0.name) },
            state: stateRow(
                hasContent: !pi.isEmpty,
                isLoading: isLoading,
                failure: failureReport(reason: model.extensionsError)
            )
        ))
        return sections
    }

    override func loadingCaption() -> String? { String(localized: "Loading extensions…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Extensions") }

    /// Nothing resolved yet: the folder has no Pi extensions.
    override func emptyState() -> LoadState? {
        .empty(title: String(localized: "No Pi extensions discovered for this folder yet."), systemImage: "puzzlepiece.extension")
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard case .ext(let name) = item, let ext = extensionInfo(named: name) else { return AnyHashable(0) }
        return AnyHashable([
            AnyHashable(ext.name),
            AnyHashable(ext.subtitle),
            AnyHashable(isEnabled(ext)),
            AnyHashable(model.isPending(.extensions, path: ext.path)),
            AnyHashable(model.canTogglePiResources),
            AnyHashable(toggleRevision),
        ])
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

    override func prepareRegistrations() {
        _ = extensionRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: extensionRow, for: indexPath, item: item)
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
