import UIKit

/// Name, description, icon, and folder of one workspace. Edits are a draft
/// (`WorkspaceDetailsModel`): Save writes the changed fields, back discards
/// them. A folder that differs from the saved one is checked on the server as
/// it is typed, and a missing one can be created here after a confirmation.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `settings` to it.
@MainActor
final class WorkspaceDetailsViewController: ListScreenController<
    WorkspaceDetailsViewController.Section,
    WorkspaceDetailsViewController.Item
> {
    enum Section: Hashable, Sendable { case identity, folder, error }

    enum Item: Hashable, Sendable {
        case name, description, icon
        case folder, folderCheck
        case error
    }

    let model: WorkspaceDetailsModel
    private let workspaceModel: WorkspaceSettingsModel
    private let root: AppRootEnvironment
    private let connection: ServerConnection
    private let iconPicker = RouterModalPresenter()
    private var showsIconPicker = false {
        didSet { setNeedsUpdateProperties() }
    }

    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = String(localized: "Save")
        item.accessibilityIdentifier = "workspace.edit.save"
        return item
    }()

    init(
        settings: WorkspaceSettingsModel,
        connection: ServerConnection,
        root: AppRootEnvironment,
        model: WorkspaceDetailsModel? = nil
    ) {
        workspaceModel = settings
        self.connection = connection
        self.root = root
        self.model = model ?? WorkspaceDetailsModel(settings: settings)
        super.init(
            title: String(localized: "Details"),
            listIdentifier: "workspace.edit.details.list",
            scope: .workspace(settings.workspace.name),
            headers: true,
            footers: true,
            endsAtKeyboard: true
        )
        traitOverrides.appRootEnvironment = root
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The folder check grows and shrinks as the folder is typed.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        iconPicker.anchor = self
        // The icon picker's style follows the size classes.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        iconPicker.sync()
    }

    override func updateProperties() {
        super.updateProperties()
        saveItem.isEnabled = model.canSave
        ListScreen.setBarItems(trailing: [saveItem], leading: [], on: navigationItem)
        updateIconPicker()
    }

    // MARK: - Rows

    private var serverName: String {
        workspaceModel.serverName(in: root.coordinator.serverStore) ?? String(localized: "the server")
    }

    /// The folder is optional, so the field says only what a folder looks like.
    static let folderPlaceholder = "~/workspace/project"
    static let folderFooter = String(localized: "Leave empty to let Oppi create a folder. If the folder doesn\u{2019}t exist, use Create This Folder; Oppi asks before creating one directory.")

    override func sections() -> [ListSection<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        var folder: [Item] = [.folder]
        if model.folderCheck != .none { folder.append(.folderCheck) }
        var sections = [
            ListSection<Section, Item>(.identity, items: [.name, .description, .icon]),
            ListSection<Section, Item>(
                .folder,
                header: String(localized: "Workspace Folder"),
                footer: Self.folderFooter,
                items: folder
            ),
        ]
        if model.error != nil { sections.append(ListSection(.error, items: [.error])) }
        return sections
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        // Typing is the text field's own state; a redraw must not rewrite it.
        case .name, .description: AnyHashable(0)
        case .folder: AnyHashable(model.draft.hostMount)
        case .folderCheck:
            AnyHashable([
                AnyHashable(model.folderCheck),
                AnyHashable(model.hostPathPendingCreation == model.trimmedHostMount),
                AnyHashable(model.isCreatingHostDirectory),
                AnyHashable(serverName),
            ])
        case .icon: AnyHashable(model.draft.icon)
        case .error: AnyHashable(model.error)
        }
    }

    private lazy var nameRow = UICollectionView.CellRegistration<WorkspaceFieldCell, Item> { [weak self] cell, _, _ in
        self?.configureName(cell)
    }

    private lazy var editorRow = UICollectionView.CellRegistration<WorkspaceTextEditorCell, Item> { [weak self] cell, _, item in
        self?.configureEditor(cell, item: item)
    }

    private lazy var iconRow = UICollectionView.CellRegistration<WorkspaceIconRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let icon = model.draft.icon
        cell.configure(
            title: String(localized: "Icon"),
            choice: icon,
            assetCache: connection.iconAssetCache,
            identifier: "workspace.edit.icon",
            label: String(localized: "Workspace icon"),
            value: WorkspaceIconPicker.description(icon),
            hint: String(localized: "Opens the icon picker")
        ) { [weak self] in self?.showsIconPicker = true }
    }

    private lazy var checkRow = UICollectionView.CellRegistration<WorkspaceFolderCheckCell, Item> { [weak self] cell, _, _ in
        self?.configureFolderCheck(cell)
    }

    private lazy var errorRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(.failure(self?.model.error ?? "", retry: nil), identifier: "workspace.edit.details.error")
    }

    override func prepareRegistrations() {
        _ = (nameRow, editorRow, iconRow, checkRow, errorRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .name:
            collectionView.dequeueConfiguredReusableCell(using: nameRow, for: indexPath, item: item)
        case .description, .folder:
            collectionView.dequeueConfiguredReusableCell(using: editorRow, for: indexPath, item: item)
        case .icon:
            collectionView.dequeueConfiguredReusableCell(using: iconRow, for: indexPath, item: item)
        case .folderCheck:
            collectionView.dequeueConfiguredReusableCell(using: checkRow, for: indexPath, item: item)
        case .error:
            collectionView.dequeueConfiguredReusableCell(using: errorRow, for: indexPath, item: item)
        }
    }

    private func configureName(_ cell: WorkspaceFieldCell) {
        cell.configure(
            title: String(localized: "Name"),
            accessibilityLabel: String(localized: "Name"),
            text: model.draft.name,
            placeholder: String(localized: "Required"),
            identifier: "workspace.edit.name",
            autocapitalization: .sentences,
            returnKey: .next,
            onReturn: { [weak self] in self?.focus(.description) }
        ) { [weak self] in self?.model.setName($0) }
    }

    /// Description and folder wrap instead of clipping: a long description or a
    /// deep path stays readable at any text size.
    private func configureEditor(_ cell: WorkspaceTextEditorCell, item: Item) {
        if item == .description {
            cell.configure(
                style: WorkspaceTextEditorCell.Style(
                    title: String(localized: "Description"),
                    placeholder: String(localized: "Optional"),
                    monospaced: false,
                    singleParagraph: true,
                    returnKey: .next,
                    autocapitalization: .sentences,
                    autocorrection: .default
                ),
                text: model.draft.description,
                identifier: "workspace.edit.description",
                label: String(localized: "Description"),
                onReturn: { [weak self] in self?.focus(.folder) }
            ) { [weak self] in self?.model.setDescription($0) }
        } else {
            // The section header names it: the field carries no label of its own.
            cell.configure(
                style: WorkspaceTextEditorCell.Style(placeholder: Self.folderPlaceholder, singleParagraph: true),
                text: model.draft.hostMount,
                identifier: "workspace.edit.hostMount",
                label: String(localized: "Folder")
            ) { [weak self] in self?.model.setHostMount($0) }
        }
    }

    /// Return moves on to the next field.
    private func focus(_ item: Item) {
        guard let path = indexPath(for: item) else { return }
        (collectionView.cellForItem(at: path) as? WorkspaceTextEditorCell)?.textView.becomeFirstResponder()
    }

    private func configureFolderCheck(_ cell: WorkspaceFolderCheckCell) {
        let folder = model.trimmedHostMount
        let model = model
        cell.configure(
            check: model.folderCheck,
            isConfirming: model.hostPathPendingCreation == folder,
            isCreating: model.isCreatingHostDirectory,
            serverName: serverName,
            palette: ThemeRuntimeState.currentPalette(),
            identifierPrefix: "workspace.edit",
            onRequestCreate: { model.hostPathPendingCreation = folder },
            onConfirm: { [weak self] in
                // The server's resolved path replaces the typed one; a field
                // still being edited would keep showing the old text.
                self?.view.endEditing(true)
                Task { await model.createHostDirectoryFromPendingPath() }
            },
            onCancel: { model.hostPathPendingCreation = nil }
        )
    }

    // MARK: - Icon picker

    private func updateIconPicker() {
        let model = model
        let apiClient = connection.apiClient
        let assetCache = connection.iconAssetCache
        iconPicker.update(
            id: showsIconPicker ? "icon-picker" : nil,
            presentation: .iconPicker(for: traitCollection),
            root: root,
            clear: { [weak self] in self?.showsIconPicker = false },
            screen: {
                .controller {
                    WorkspaceIconPicker.viewController(
                        icon: model.draft.icon,
                        apiClient: apiClient,
                        assetCache: assetCache,
                        commit: { model.setIcon($0) }
                    )
                }
            }
        )
    }

    // MARK: - Save

    private func save() {
        view.endEditing(true)
        let model = model
        Task { [weak self] in
            let outcome = await model.save()
            // A save that finishes after Back must not pop whatever is on top now.
            guard let self, outcome == .saved, isShowing else { return }
            Router.finish(self)
        }
    }
}
