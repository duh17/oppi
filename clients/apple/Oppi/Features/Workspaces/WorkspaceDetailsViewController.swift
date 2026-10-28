import UIKit

/// Name, description, icon, and folder of one workspace. Edits are a draft
/// (`WorkspaceDetailsModel`): Save writes the changed fields, back discards
/// them. A folder that differs from the saved one is checked on the server as
/// it is typed, and a missing one can be created here after a confirmation.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `settings` to it.
@MainActor
final class WorkspaceDetailsViewController: SettingsListViewController<
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
    /// A save that finishes after Back must not pop whatever is on top now.
    private var isOnScreen = false
    private var keyboardInset: KeyboardContentInset?

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
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The folder check grows and shrinks as the folder is typed.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        keyboardInset = KeyboardContentInset(view: view, scrollView: collectionView)
        iconPicker.anchor = self
        // The icon picker's style follows the size classes.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keyboardInset?.update()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        model.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        iconPicker.sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
    }

    override func updateProperties() {
        super.updateProperties()
        saveItem.isEnabled = model.canSave
        ControlScreenList.setBarItems(trailing: [saveItem], leading: [], on: navigationItem)
        updateIconPicker()
    }

    // MARK: - Rows

    private var serverName: String {
        workspaceModel.serverName(in: root.coordinator.serverStore) ?? String(localized: "the server")
    }

    /// The folder is optional, so the field says only what a folder looks like.
    static let folderPlaceholder = "~/workspace/project"
    static let folderFooter = String(localized: "Leave empty to let Oppi create a folder. If the folder doesn\u{2019}t exist, use Create This Folder; Oppi asks before creating one directory.")

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        var folder: [Item] = [.folder]
        if model.folderCheck != .none { folder.append(.folderCheck) }
        var sections = [
            SettingsSectionModel<Section, Item>(.identity, items: [.name, .description, .icon]),
            SettingsSectionModel<Section, Item>(
                .folder,
                header: String(localized: "Workspace Folder"),
                footer: Self.folderFooter,
                items: folder
            ),
        ]
        if model.error != nil { sections.append(SettingsSectionModel(.error, items: [.error])) }
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

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
        self?.configureField(cell, item: item)
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
            value: WorkspaceIconPickerView.description(icon),
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
        _ = (fieldRow, iconRow, checkRow, errorRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .name, .description, .folder:
            collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .icon:
            collectionView.dequeueConfiguredReusableCell(using: iconRow, for: indexPath, item: item)
        case .folderCheck:
            collectionView.dequeueConfiguredReusableCell(using: checkRow, for: indexPath, item: item)
        case .error:
            collectionView.dequeueConfiguredReusableCell(using: errorRow, for: indexPath, item: item)
        }
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let title = SettingsStyle.current.title
        switch item {
        case .name:
            cell.configure(
                text: model.draft.name,
                placeholder: String(localized: "Required"),
                identifier: "workspace.edit.name",
                label: String(localized: "Name"),
                autocapitalization: .sentences,
                textColor: title,
                labelColor: title,
                returnKey: .next,
                onReturn: { [weak self] in self?.focus(.description) }
            ) { [weak self] in self?.model.setName($0) }
        case .description:
            cell.configure(
                text: model.draft.description,
                placeholder: String(localized: "Optional"),
                identifier: "workspace.edit.description",
                label: String(localized: "Description"),
                autocapitalization: .sentences,
                autocorrection: .default,
                textColor: title,
                labelColor: title,
                returnKey: .next,
                onReturn: { [weak self] in self?.focus(.folder) }
            ) { [weak self] in self?.model.setDescription($0) }
        default:
            cell.configure(
                text: model.draft.hostMount,
                placeholder: Self.folderPlaceholder,
                identifier: "workspace.edit.hostMount",
                monospaced: true,
                textColor: title,
                labelColor: title,
                returnKey: .done,
                onReturn: { [weak self] in self?.view.endEditing(true) }
            ) { [weak self] in self?.model.setHostMount($0) }
            cell.textField.accessibilityLabel = String(localized: "Folder")
        }
    }

    /// Return moves on to the next field.
    private func focus(_ item: Item) {
        guard let path = dataSource?.indexPath(for: item),
              let cell = collectionView.cellForItem(at: path) as? SSHTerminalTextFieldCell else { return }
        cell.textField.becomeFirstResponder()
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
        iconPicker.update(
            id: showsIconPicker ? "icon-picker" : nil,
            presentation: WorkspaceIconPickerView.presentation(traitCollection),
            root: root,
            clear: { [weak self] in self?.showsIconPicker = false },
            screen: {
                WorkspaceIconPickerView.screen(
                    icon: { model.draft.icon },
                    setIcon: { model.setIcon($0) },
                    upload: { data, description in
                        try await WorkspaceIconPickerView.uploadGenmoji(data: data, contentDescription: description, apiClient: apiClient)
                    }
                )
            }
        )
    }

    // MARK: - Save

    private func save() {
        view.endEditing(true)
        let model = model
        Task { [weak self] in
            let outcome = await model.save()
            guard let self, outcome == .saved, isOnScreen else { return }
            Router.finish(self)
        }
    }
}
