import UIKit

/// The Allowed Hosts a person is editing, as one host per line. An omitted
/// list means every host is allowed, which is what an empty saved config
/// shows (`*`); an empty draft saves an empty list, which blocks the network.
struct WorkspaceAllowedHostsDraft: Equatable {
    var text: String

    /// A saved list as the editor shows it.
    init(saved hosts: [String]?) {
        text = (hosts ?? ["*"]).joined(separator: "\n")
    }

    /// The hosts the text says: trimmed, one per line, blank lines dropped.
    var hosts: [String] {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether the text says something other than the saved list.
    func isDirty(against saved: [String]?) -> Bool {
        hosts != (saved ?? ["*"])
    }
}

/// Allowed Hosts of a sandbox workspace. The text is a draft: Save writes it,
/// back discards it. The write carries the sandbox's other config unchanged.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it.
@MainActor
final class WorkspaceNetworkAccessViewController: SettingsListViewController<
    WorkspaceNetworkAccessViewController.Section,
    WorkspaceNetworkAccessViewController.Item
> {
    enum Section: Hashable, Sendable { case hosts, error }
    enum Item: Hashable, Sendable { case editor, error }

    private let model: WorkspaceSettingsModel
    private let root: AppRootEnvironment
    private var draft: WorkspaceAllowedHostsDraft {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    /// A save that finishes after Back must not pop whatever is on top now.
    private var isOnScreen = false

    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = String(localized: "Save")
        item.accessibilityIdentifier = "workspace.edit.networkAccess.save"
        return item
    }()

    init(model: WorkspaceSettingsModel, root: AppRootEnvironment) {
        self.model = model
        self.root = root
        draft = WorkspaceAllowedHostsDraft(saved: model.workspace.sandboxConfig?.allowedHosts)
        super.init(
            title: String(localized: "Network Access"),
            listIdentifier: "workspace.edit.networkAccess.list",
            scope: .workspace(model.workspace.name),
            headers: true,
            footers: true,
            endsAtKeyboard: true
        )
        traitOverrides.appRootEnvironment = root
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The editor row grows as the text does.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
    }

    override func updateProperties() {
        super.updateProperties()
        saveItem.isEnabled = draft.isDirty(against: model.workspace.sandboxConfig?.allowedHosts) && !model.isWritingSandboxConfig
        ControlScreenList.setBarItems(trailing: [saveItem], leading: [], on: navigationItem)
    }

    // MARK: - Rows

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        var sections = [SettingsSectionModel<Section, Item>(
            .hosts,
            header: String(localized: "Allowed Hosts"),
            footer: Self.footer,
            items: [.editor]
        )]
        if error != nil { sections.append(SettingsSectionModel(.error, items: [.error])) }
        return sections
    }

    /// In user terms: what the list does, not how the sandbox is built.
    static let footer = String(localized: "This workspace can only reach the hosts listed here, one per line. Leave it empty to block all network access. Use * to allow every host.")

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        // Typing is the text view's own state; a redraw must not rewrite it.
        case .editor: AnyHashable(0)
        case .error: AnyHashable(error)
        }
    }

    private lazy var editorRow = UICollectionView.CellRegistration<WorkspaceTextEditorCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            style: WorkspaceTextEditorCell.Style(minimumHeight: 120),
            text: draft.text,
            identifier: "workspace.edit.allowedHosts",
            label: String(localized: "Allowed Hosts")
        ) { [weak self] text in self?.draft.text = text }
    }

    private lazy var errorRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(.failure(self?.error ?? "", retry: nil), identifier: "workspace.edit.networkAccess.error")
    }

    override func prepareRegistrations() {
        _ = (editorRow, errorRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .editor: collectionView.dequeueConfiguredReusableCell(using: editorRow, for: indexPath, item: item)
        case .error: collectionView.dequeueConfiguredReusableCell(using: errorRow, for: indexPath, item: item)
        }
    }

    // MARK: - Save

    private func save() {
        error = nil
        view.endEditing(true)
        let hosts = draft.hosts
        let model = model
        Task { [weak self] in
            let outcome = await model.saveAllowedHosts(hosts)
            guard let self else { return }
            switch outcome {
            case .saved:
                if isOnScreen { Router.finish(self) }
            case .failed(let message):
                error = message
            case .superseded:
                break
            }
        }
    }
}
