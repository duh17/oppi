import UIKit

// Pins in the File Browser: the Pinned section at the top of the Home and
// workspace roots, and the Pin and Unpin items of rows, the viewer, and View
// Options. A pin is a saved place the browser can already open; opening one
// goes through the same routes and scoped locks as browsing to it.

/// The Pinned section of one File Browser screen. `FileBrowserViewController`
/// puts its rows in its own list, draws them as its own rows, and forwards
/// their taps, menus, swipes, drags, and Edit-mode reordering here.
///
/// Home shows every pin of the server; a workspace's root shows that
/// workspace's pins. Whether the section is collapsed is kept on the device.
/// Edit puts the rows in the list's edit mode: reorder handles and delete
/// controls change a local order, and Done saves it in one write.
@MainActor
final class FileBrowserPinsSection {
    /// One pin row as it draws: the list reconfigures a row when this changes.
    struct Row: Equatable {
        let id: String
        let key: String
        let title: String
        let detail: String?
        /// A file's icon; nil for a folder.
        let icon: FileIcon?
        let isDirectory: Bool
        /// Not there, or its workspace is gone: dimmed, and a tap offers Remove Pin.
        let isGone: Bool
        let isLocked: Bool
        let isEditing: Bool
    }

    struct Header: Equatable {
        let isCollapsed: Bool
        let isEditing: Bool
        let count: Int
    }

    struct Content: Equatable {
        let header: Header
        let rows: [Row]
    }

    struct Hooks {
        let connection: @MainActor () -> ServerConnection?
        let navigation: @MainActor () -> SceneNavigation?
        /// The folder the browser lists now (`a/b/`, or empty at the root).
        let currentFolder: @MainActor () -> String
        /// Opens a folder of this screen's own scope the way a row tap does.
        let openFolderHere: @MainActor (String) -> Void
        let setEditing: @MainActor (Bool) -> Void
        let changed: @MainActor () -> Void
    }

    private let serverId: String
    private let scope: FileBrowserScope
    private weak var presenter: UIViewController?
    private let hooks: Hooks
    private(set) var isEditing = false
    private var requestedFirstRead = false
    private var editingOrder: [String] = []
    private var editingRemoved: Set<String> = []
    private var isCollapsed: Bool { FileBrowserViewOptionsStore.shared.pinsCollapsed }

    /// One Edit button for the header's life (lesson: one accessory control, mutated).
    private lazy var editButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.toggleEditing()
        })
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityIdentifier = "fileBrowser.pinned.edit"
        return button
    }()

    init(serverId: String, scope: FileBrowserScope, presenter: UIViewController, hooks: Hooks) {
        self.serverId = serverId
        self.scope = scope
        self.presenter = presenter
        self.hooks = hooks
    }

    private var store: (pins: PinStore, api: APIClient)? {
        guard let connection = hooks.connection(), connection.pinsAvailable, let api = connection.apiClient else { return nil }
        return (connection.pins, api)
    }

    /// Reads the list again; a root screen calls this as it appears.
    func refresh() {
        guard let (pins, api) = store else { return }
        Task { await pins.refresh(api: api) }
    }

    // MARK: Rows

    /// The section's rows at the root, or nil when it shows nothing: below the
    /// root, while searching, on a server without pins, or with no pins here.
    func content(atRoot: Bool) -> Content? {
        guard atRoot, let connection = hooks.connection(), connection.pinsAvailable else { return nil }
        // A screen that appeared before its server was ready has not read the list yet.
        if connection.pins.list == nil, !requestedFirstRead {
            requestedFirstRead = true
            refresh()
        }
        var shown = connection.pins.pins.filter(belongsHere)
        if isEditing {
            let byId = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            shown = editingOrder.compactMap { byId[$0] }
        }
        guard !shown.isEmpty || isEditing else { return nil }
        let header = Header(isCollapsed: isCollapsed && !isEditing, isEditing: isEditing, count: shown.count)
        let rows = header.isCollapsed ? [] : shown.map { row(for: $0, connection: connection) }
        return Content(header: header, rows: rows)
    }

    private func belongsHere(_ pin: Pin) -> Bool {
        switch scope {
        case .hostHome: true
        case .workspace(let workspaceId, nil): pin.target.workspaceId == workspaceId
        case .workspace: false
        }
    }

    private func row(for pin: Pin, connection: ServerConnection) -> Row {
        let workspaceName = pin.target.workspaceId.flatMap { id in
            connection.workspaceStore.workspaces.first { $0.id == id }?.name
        }
        let locked = pin.target.workspaceId.map {
            ScopedLockService.shared.isLocked(.workspace(serverId: serverId, workspaceId: $0))
        } ?? false
        return Row(
            id: pin.id,
            key: pin.target.accessibilityKey,
            title: pin.displayName(workspaceName: workspaceName),
            detail: pin.subtitle(workspaceName: workspaceName),
            icon: pin.kind == .directory ? nil : FileIcon.forPath(pin.target.path),
            isDirectory: pin.kind == .directory,
            isGone: pin.status == .missing || pin.status == .workspaceMissing,
            isLocked: locked,
            isEditing: isEditing
        )
    }

    /// Adds a pin row's own parts to the browser's row look: Edit mode's
    /// delete and reorder controls, the lock, and its accessibility.
    func decorate(_ cell: UICollectionViewListCell, row: Row, palette: ThemePalette) {
        var accessories: [UICellAccessory] = [
            .delete(displayed: .whenEditing) { [weak self] in self?.removeWhileEditing(row.id) },
            .reorder(displayed: .whenEditing),
        ]
        if row.isLocked {
            let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
            lock.tintColor = palette.ui.comment
            lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
            accessories.append(.customView(configuration: .init(customView: lock, placement: .trailing(), isHidden: row.isEditing)))
        }
        cell.accessories = accessories + cell.accessories
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [row.title, row.detail, row.isLocked ? String(localized: "Locked") : nil]
            .compactMap { $0 }.joined(separator: ", ")
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = "fileBrowser.pin.\(row.key)"
        cell.accessibilityCustomActions = row.isEditing ? nil : accessibilityActions(pinId: row.id, cell: cell)
    }

    func configureHeader(_ cell: UICollectionViewListCell, header: Header, palette: ThemePalette) {
        var content = UIListContentConfiguration.header()
        content.text = String(localized: "Pinned")
        content.textProperties.color = palette.ui.comment
        content.image = UIImage(systemName: header.isCollapsed ? "chevron.right" : "chevron.down")
        content.imageProperties.tintColor = palette.ui.comment
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        cell.contentConfiguration = content
        var accessories: [UICellAccessory] = []
        if !header.isCollapsed {
            editButton.configuration?.title = header.isEditing ? String(localized: "Done") : String(localized: "Edit")
            editButton.configuration?.baseForegroundColor = palette.ui.blue
            accessories.append(.customView(configuration: .init(customView: editButton, placement: .trailing())))
        }
        cell.accessories = accessories
        cell.backgroundConfiguration = Self.background(palette)
        // The title toggles the section; the Edit button stays its own element.
        cell.isAccessibilityElement = false
        let toggle = UIAccessibilityElement(accessibilityContainer: cell)
        toggle.accessibilityLabel = String(localized: "Pinned")
        toggle.accessibilityValue = header.isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        toggle.accessibilityTraits = .button
        toggle.accessibilityIdentifier = "fileBrowser.pinned.header"
        toggle.accessibilityFrameInContainerSpace = cell.contentView.frame
        cell.accessibilityElements = header.isCollapsed ? [toggle] : [toggle, editButton]
    }

    /// The heading of the folder's own listing under the Pinned section, so
    /// it is plain where the pins end. Shown only with the section.
    static func configureListingHeader(_ cell: UICollectionViewListCell, palette: ThemePalette) {
        var content = UIListContentConfiguration.header()
        content.text = String(localized: "Files")
        content.textProperties.color = palette.ui.comment
        cell.contentConfiguration = content
        cell.accessories = []
        cell.backgroundConfiguration = background(palette)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.text
        cell.accessibilityTraits = .header
        cell.accessibilityIdentifier = "fileBrowser.listing.header"
    }

    private static func background(_ palette: ThemePalette) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = palette.ui.bg
        return background
    }

    // MARK: Taps

    func toggleCollapsed() {
        guard !isEditing else { return }
        FileBrowserViewOptionsStore.shared.setPinsCollapsed(!isCollapsed)
        hooks.changed()
    }

    func select(_ id: String) {
        guard !isEditing, let pin = pin(id) else { return }
        if pin.status == .missing || pin.status == .workspaceMissing {
            offerRemoval(pin)
            return
        }
        open(pin)
    }

    private func open(_ pin: Pin) {
        guard let navigation = hooks.navigation() else { return }
        switch (pin.target, pin.kind) {
        case (.host(let path), .directory):
            let folder = FileBrowserHostHomePath.directoryPath(rawPath: path)
            if scope == .hostHome {
                hooks.openFolderHere(folder)
            } else {
                navigation.pushWorkspaceFileBrowser(FileBrowserNavTarget(serverId: serverId, scope: .hostHome, path: folder))
            }
        case (.workspace(let workspaceId, let path), .directory):
            let folder = path.isEmpty ? "" : path + "/"
            let pinScope = FileBrowserScope.workspace(workspaceId: workspaceId, worktreeId: nil)
            if scope == pinScope {
                hooks.openFolderHere(folder)
            } else {
                // The browser's own lock cover asks for the workspace's unlock.
                navigation.pushWorkspaceFileBrowser(FileBrowserNavTarget(serverId: serverId, scope: pinScope, path: folder))
            }
        case (.host(let path), .file):
            navigation.openWorkspaceLinkedFile(.hostFile(serverId: serverId, workspaceId: "", path: path))
        case (.workspace(let workspaceId, let path), .file):
            navigation.openWorkspaceLinkedFile(.workspaceFile(serverId: serverId, workspaceId: workspaceId, path: path))
        }
    }

    private func offerRemoval(_ pin: Pin) {
        guard let presenter else { return }
        let name = pin.displayName(workspaceName: nil)
        Confirmation(
            title: String(localized: "\u{201C}\(name)\u{201D} isn\u{2019}t there anymore"),
            message: pin.status == .workspaceMissing
                ? String(localized: "Its workspace was removed.")
                : String(localized: "It may have been moved, renamed, or deleted."),
            actionTitle: String(localized: "Remove Pin"),
            style: .alert,
            actionIdentifier: "fileBrowser.pin.removeMissing"
        ).present(from: presenter, anchor: nil) { [weak self] in
            self?.unpin(pin.id)
        }
    }

    // MARK: Menus, swipes, drags

    func contextMenu(pinId: String) -> UIContextMenuConfiguration? {
        guard !isEditing, let pin = pin(pinId), let view = presenter?.view else { return nil }
        let entry = pin.paneEntry(serverId: serverId)
        let configuration = UIContextMenuConfiguration(identifier: pinId as NSString, previewProvider: nil) { [weak self, weak view] _ in
            guard let self, let view else { return nil }
            let panes = PaneOpenMenu.items(near: view) { [weak self, weak view] placement in
                if placement == .here {
                    self?.select(pinId)
                    return
                }
                guard let view else { return }
                PaneOpenMenu.open(placement, from: view) { PaneOpenContent(entry: entry) }
            }
            let open = panes.isEmpty
                ? [Self.action(String(localized: "Open"), "arrow.up.forward.square", "fileBrowser.pin.open") { [weak self] in
                    self?.select(pinId)
                }]
                : panes.map(\.element)
            let rename = Self.action(String(localized: "Rename\u{2026}"), "character.cursor.ibeam", "fileBrowser.pin.rename") { [weak self] in
                self?.askRename(pinId)
            }
            let unpin = Self.action(String(localized: "Unpin"), "pin.slash", "fileBrowser.pin.unpin") { [weak self] in
                self?.unpin(pinId)
            }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: open),
                UIMenu(options: .displayInline, children: [rename, unpin]),
            ])
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    func trailingSwipe(pinId: String) -> UISwipeActionsConfiguration? {
        guard !isEditing else { return nil }
        let unpin = UIContextualAction(style: .destructive, title: String(localized: "Unpin")) { [weak self] _, _, done in
            self?.unpin(pinId)
            done(true)
        }
        unpin.image = UIImage(systemName: "pin.slash")
        return UISwipeActionsConfiguration(actions: [unpin])
    }

    func dragItems(pinId: String) -> [UIDragItem] {
        guard !isEditing, let pin = pin(pinId), pin.status != .missing, pin.status != .workspaceMissing else { return [] }
        let provider = NSItemProvider()
        provider.suggestedName = pin.displayName(workspaceName: nil)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = PaneDragPayload(entry: pin.paneEntry(serverId: serverId))
        return [item]
    }

    private func accessibilityActions(pinId: String, cell: UIView) -> [UIAccessibilityCustomAction] {
        let own = [
            UIAccessibilityCustomAction(name: String(localized: "Rename")) { [weak self] _ in
                self?.askRename(pinId)
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Unpin")) { [weak self] _ in
                self?.unpin(pinId)
                return true
            },
        ]
        guard let pin = pin(pinId), let view = presenter?.view else { return own }
        let entry = pin.paneEntry(serverId: serverId)
        return own + PaneOpenMenu.accessibilityActions(near: view, includesOpenHere: false) { [weak view] placement in
            guard let view else { return }
            PaneOpenMenu.open(placement, from: view) { PaneOpenContent(entry: entry) }
        }
    }

    /// Pin or Unpin for a browser row at `rowPath` (a folder's ends in "/").
    func rowMenuElement(rowPath: String) -> UIMenuElement? {
        rowToggle(rowPath: rowPath)?.action
    }

    /// The same Pin or Unpin as the row's accessibility action.
    func rowAccessibilityAction(rowPath: String) -> UIAccessibilityCustomAction? {
        rowToggle(rowPath: rowPath)?.accessibilityAction
    }

    private func rowToggle(rowPath: String) -> PinMenu.Toggle? {
        target(forRowPath: rowPath).flatMap { toggle(for: $0, isFolder: rowPath.hasSuffix("/"), current: false) }
    }

    /// View Options' Pin This Folder or Unpin This Folder, for the folder listed now.
    func viewOptionsElements() -> [UIMenuElement] {
        guard let target = target(forRowPath: hooks.currentFolder().isEmpty ? "/" : hooks.currentFolder()),
              let toggle = toggle(for: target, isFolder: true, current: true) else { return [] }
        return [UIMenu(options: .displayInline, children: [toggle.action])]
    }

    /// The target a row names, as the server stores it; nil where pins do
    /// not reach (a worktree, the chat panel's checkout).
    private func target(forRowPath rowPath: String) -> PinTarget? {
        let isFolder = rowPath.hasSuffix("/")
        switch scope {
        case .hostHome:
            return .host(path: isFolder ? FileBrowserHostHomePath.rawPath(relativePath: rowPath) : rowPath)
        case .workspace(let workspaceId, nil):
            let path = rowPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .workspace(id: workspaceId, path: path)
        case .workspace:
            return nil
        }
    }

    private func toggle(for target: PinTarget, isFolder: Bool, current: Bool) -> PinMenu.Toggle? {
        guard let (pins, api) = store, let view = presenter?.view else { return nil }
        return PinMenu.toggle(target: target, isFolder: isFolder, current: current, pins: pins, api: api, view: view)
    }

    // MARK: Changes

    private func pin(_ id: String) -> Pin? {
        hooks.connection()?.pins.pins.first { $0.id == id }
    }

    private func unpin(_ id: String) {
        guard let (pins, api) = store else { return }
        Task { [weak self] in
            do {
                try await pins.remove(id, api: api)
            } catch {
                self?.report(error, title: String(localized: "Couldn\u{2019}t Unpin"))
            }
        }
    }

    private func askRename(_ id: String) {
        guard let pin = pin(id), let presenter else { return }
        let name = pin.displayName(workspaceName: nil)
        TextPrompt(
            title: String(localized: "Rename Pin"),
            message: String(localized: "Leave it empty to use the name \u{201C}\(pin.target.name.isEmpty ? name : pin.target.name)\u{201D}."),
            placeholder: pin.target.name,
            text: pin.label ?? "",
            actionTitle: String(localized: "Rename"),
            fieldIdentifier: "fileBrowser.pin.renameField",
            actionIdentifier: "fileBrowser.pin.renameSave"
        ).present(from: presenter) { [weak self] label in
            guard let self, let (pins, api) = store else { return }
            Task { [weak self] in
                do {
                    try await pins.rename(id, to: label, api: api)
                } catch {
                    self?.report(error, title: String(localized: "Couldn\u{2019}t Rename"))
                }
            }
        }
    }

    private func toggleEditing() {
        if isEditing {
            finishEditing()
        } else {
            guard let content = content(atRoot: true) else { return }
            editingOrder = content.rows.map(\.id)
            editingRemoved = []
            isEditing = true
            hooks.setEditing(true)
            hooks.changed()
        }
    }

    /// The list moved a pin: `ids` is the section's new order.
    func didReorder(_ ids: [String]) {
        guard isEditing else { return }
        editingOrder = ids
    }

    private func removeWhileEditing(_ id: String) {
        editingOrder.removeAll { $0 == id }
        editingRemoved.insert(id)
        hooks.changed()
    }

    /// Done: saves the order and removals once, then leaves edit mode.
    private func finishEditing() {
        let order = editingOrder
        let removed = editingRemoved
        isEditing = false
        hooks.setEditing(false)
        hooks.changed()
        guard let (pins, api) = store else { return }
        Task { [weak self] in
            do {
                // Only this screen's pins move, within their own places; no change sends nothing.
                try await pins.setOrder(order, removed: removed, api: api)
            } catch {
                self?.report(error, title: String(localized: "Couldn\u{2019}t Save Pins"))
            }
        }
    }

    private func report(_ error: Error, title: String) {
        presenter?.errorAlerts.show(title: title, message: PinMenu.message(for: error))
    }

    private static func action(_ title: String, _ symbol: String, _ identifier: String, run: @escaping @MainActor () -> Void) -> UIAction {
        let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
        action.accessibilityIdentifier = identifier
        return action
    }
}

/// Collection-view hooks a pin row needs that only the delegate answers.
extension FileBrowserViewController {
    /// A pin moves only among the pins, below the section's header.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section == originalIndexPath.section else { return originalIndexPath }
        return proposedIndexPath.item == 0 ? IndexPath(item: 1, section: proposedIndexPath.section) : proposedIndexPath
    }
}

/// Pin and Unpin for anything that names a place: a browser row, View
/// Options' folder, the viewer's file. Success shows a pill; a failure says why.
@MainActor
enum PinMenu {
    /// One Pin or Unpin: the menu item and the accessibility action run the same `run`.
    @MainActor
    struct Toggle {
        let title: String
        let symbol: String
        let identifier: String
        let run: @MainActor () -> Void

        var action: UIAction {
            let run = run
            let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
            action.accessibilityIdentifier = identifier
            return action
        }

        var accessibilityAction: UIAccessibilityCustomAction {
            let run = run
            return UIAccessibilityCustomAction(name: title) { _ in
                run()
                return true
            }
        }
    }

    static func toggle(
        target: PinTarget,
        isFolder: Bool,
        current: Bool,
        pins: PinStore,
        api: APIClient,
        view: UIView
    ) -> Toggle {
        let saved = pins.pin(for: target)
        let title = switch (saved != nil, current && isFolder) {
        case (false, false): String(localized: "Pin")
        case (true, false): String(localized: "Unpin")
        case (false, true): String(localized: "Pin This Folder")
        case (true, true): String(localized: "Unpin This Folder")
        }
        return Toggle(
            title: title,
            symbol: saved == nil ? "pin" : "pin.slash",
            identifier: saved == nil ? "fileBrowser.pin.add" : "fileBrowser.pin.remove"
        ) { [weak view] in
            Task { @MainActor in
                do {
                    if let saved {
                        try await pins.remove(saved.id, api: api)
                        if let view { TransientConfirmationPill.show(String(localized: "Unpinned"), systemImage: "pin.slash", in: view) }
                    } else {
                        try await pins.add(target, api: api)
                        if let view { TransientConfirmationPill.show(String(localized: "Pinned"), systemImage: "pin.fill", in: view) }
                    }
                } catch {
                    view?.nearestViewController?.errorAlerts.show(
                        title: saved == nil ? String(localized: "Couldn\u{2019}t Pin") : String(localized: "Couldn\u{2019}t Unpin"),
                        message: Self.message(for: error, adding: saved == nil ? pins.pins.count : nil)
                    )
                }
            }
        }
    }

    /// The most pins a server keeps (`protocol/pins-http.json`).
    static let maximumPins = 50

    /// A failed pin change as a plain sentence; the server's own text never
    /// shows. `adding`: the pin count before a Pin, which explains a refusal
    /// at the limit.
    static func message(for error: Error, adding count: Int? = nil) -> String {
        let status: Int? = switch error {
        case APIError.server(let status, _), APIError.codedServer(let status, _, _): status
        default: nil
        }
        switch (error, status) {
        case (is PinsRevisionConflict, _):
            return String(localized: "Pins changed on another device. Try again.")
        case (_, 404?):
            return String(localized: "It isn\u{2019}t there anymore. It may have been moved, renamed, or deleted.")
        case (_, 400?) where (count ?? 0) >= maximumPins:
            return String(localized: "A server keeps up to \(maximumPins) pins. Unpin one to add another.")
        case (_, 400?):
            return String(localized: "The server didn\u{2019}t accept this change.")
        case (_, .some(500...)):
            return String(localized: "The server can\u{2019}t save pins right now. Try again later.")
        case (is URLError, _):
            return String(localized: "Oppi couldn\u{2019}t reach the server. Check the connection and try again.")
        default:
            return String(localized: "Something went wrong. Try again.")
        }
    }
}

extension PinTarget {
    /// The pin row's identifier suffix: the Home path, or `<workspace>:<path>`.
    var accessibilityKey: String {
        switch self {
        case .host(let path): path
        case .workspace(let id, let path): "\(id):\(path)"
        }
    }
}

extension Pin {
    /// The label, else the target's own name (a workspace root reads as its workspace).
    func displayName(workspaceName: String?) -> String {
        if let label, !label.isEmpty { return label }
        let name = target.name
        return name.isEmpty ? (workspaceName ?? String(localized: "Workspace")) : name
    }

    /// A pin's second line, the same in the File Browser and the launcher:
    /// why it cannot open, else where it lives as a breadcrumb ("Home ›
    /// Books", or its workspace's name and folders). Nil for Home itself and
    /// a workspace root, whose title already says where.
    func subtitle(workspaceName: String?) -> String? {
        switch status {
        case .missing: return String(localized: "Not found")
        case .workspaceMissing: return String(localized: "Workspace removed")
        case .unreadable where kind == .directory: return String(localized: "Oppi can\u{2019}t read this folder")
        case .unreadable: return String(localized: "Oppi can\u{2019}t read this file")
        case .ok, .unknown: break
        }
        let folders = (target.path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        switch target {
        case .host(let path):
            guard path != "~" else { return nil }
            return ([String(localized: "Home")] + folders.dropFirst()).joined(separator: " \u{203A} ")
        case .workspace(_, let path):
            guard !path.isEmpty else { return nil }
            return ([workspaceName ?? String(localized: "Workspace")] + folders).joined(separator: " \u{203A} ")
        }
    }

    /// The pane entry this pin opens as: its folder's File Browser or its file.
    func paneEntry(serverId: String) -> PaneStackEntry {
        let route: PaneRoute = switch (target, kind) {
        case (.host(let path), .directory): .hostFiles(path: path == "~" ? nil : path)
        case (.host(let path), .file): .file(.host, path: path, line: nil)
        case (.workspace(let id, let path), .directory): .files(workspace: id, path: path.isEmpty ? nil : path)
        case (.workspace(let id, let path), .file): .file(.workspace(id: id, worktree: nil), path: path, line: nil)
        }
        return PaneStackEntry(serverId: serverId, route: route)
    }
}
