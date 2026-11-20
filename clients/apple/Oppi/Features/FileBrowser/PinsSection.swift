import UIKit

// Pins in a list: the File Browser's Pinned section at the top of the Home
// and workspace roots (`FileBrowserPinsSection`), and the Pinned screen
// (`PinnedViewController`). A pin is a saved place the app can already open;
// opening one goes through the same routes and scoped locks as browsing to it.

/// One list's pins. The list puts their rows in its own snapshot, draws them
/// in its own row look, and forwards their taps, menus, swipes, drags, and
/// Edit-mode reordering here.
///
/// Edit puts the rows in the list's edit mode: reorder handles and delete
/// controls change a local order, and Done saves it in one write. A list
/// that shows its pins in groups moves each pin only within its group.
@MainActor
class PinsSection {
    /// One pin row as it draws: the list reconfigures a row when this changes.
    struct Row: Equatable {
        let id: String
        let key: String
        let title: String
        let detail: String?
        /// A file's icon; nil for a folder.
        let icon: FileIcon?
        /// Its kind's symbol, drawn where there is no file icon.
        let symbol: String
        let isDirectory: Bool
        /// Not there (a deleted session or game too), or its workspace is
        /// gone: dimmed, and a tap offers Remove Pin.
        let isGone: Bool
        /// A game while Godot Pane is off here (this build, the experiment, or
        /// the server's switch): dimmed, it offers no Open or drag, and a tap
        /// says why as a Godot link does.
        let isOff: Bool
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
        /// Whether one of the server's pins belongs in this list.
        let shows: @MainActor (Pin) -> Bool
        /// Opens a pin that is there: a tap (`inMainPane` false), or the
        /// menu's Open Here (true).
        let open: @MainActor (Pin, _ inMainPane: Bool) -> Void
        /// A view in the pane the menu's Open in New Pane and Open in Pane
        /// items open from; nil, or a view outside the panes, offers none.
        let paneSource: @MainActor () -> UIView?
        /// Whether the section is collapsed, kept on the device by the list.
        let isCollapsed: @MainActor () -> Bool
        let setCollapsed: @MainActor (Bool) -> Void
        let setEditing: @MainActor (Bool) -> Void
        let changed: @MainActor () -> Void
    }

    let serverId: String
    /// Where the section's accessibility identifiers start: `fileBrowser`, `pinned`.
    let identifierPrefix: String
    private(set) weak var presenter: UIViewController?
    private let hooks: Hooks
    private(set) var isEditing = false
    private var requestedFirstRead = false
    /// Edit mode's order: each group's pins, in their new order.
    private var editingGroups: [[String]] = []
    private var editingRemoved: Set<String> = []

    /// One Edit button for the header's life (lesson: one accessory control, mutated).
    private lazy var editButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.toggleEditing()
        })
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityIdentifier = "\(identifierPrefix).pinned.edit"
        return button
    }()

    init(serverId: String, identifierPrefix: String, presenter: UIViewController, hooks: Hooks) {
        self.serverId = serverId
        self.identifierPrefix = identifierPrefix
        self.presenter = presenter
        self.hooks = hooks
    }

    /// The pins and the client that changes them; nil on a server without pins.
    var store: (pins: PinStore, api: APIClient)? {
        guard let connection = hooks.connection(), connection.pinsAvailable, let api = connection.apiClient else { return nil }
        return (connection.pins, api)
    }

    /// Reads the list again; a screen calls this as it appears.
    func refresh() {
        guard let (pins, api) = store else { return }
        Task { await pins.refresh(api: api) }
    }

    // MARK: Rows

    /// The section's header and rows, or nil when it shows nothing: on a
    /// server without pins, or with no pins here.
    func content() -> Content? {
        guard let connection = hooks.connection(), connection.pinsAvailable else { return nil }
        // A screen that appeared before its server was ready has not read the list yet.
        if connection.pins.list == nil, !requestedFirstRead {
            requestedFirstRead = true
            refresh()
        }
        var shown = connection.pins.pins.filter(hooks.shows)
        if isEditing {
            let byId = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            shown = editingGroups.joined().compactMap { byId[$0] }
        }
        guard !shown.isEmpty || isEditing else { return nil }
        let header = Header(isCollapsed: hooks.isCollapsed() && !isEditing, isEditing: isEditing, count: shown.count)
        let rows = header.isCollapsed ? [] : shown.map { row(for: $0, connection: connection) }
        return Content(header: header, rows: rows)
    }

    private func row(for pin: Pin, connection: ServerConnection) -> Row {
        let names = Self.names(for: pin, connection: connection)
        let locked = pin.target.workspaceId.map {
            ScopedLockService.shared.isLocked(.workspace(serverId: serverId, workspaceId: $0))
        } ?? false
        let isOff = Self.isOff(pin, connection: connection)
        let filePath: String? = if case .file(_, let path, _) = pin.target { path } else { nil }
        return Row(
            id: pin.id,
            key: pin.target.pinKey,
            title: pin.displayName(names),
            detail: isOff && !pin.isGone ? String(localized: "Godot Pane is off") : pin.subtitle(names),
            icon: filePath.map(FileIcon.forPath),
            symbol: pin.kind?.symbol ?? "pin",
            isDirectory: pin.kind == .folders,
            isGone: pin.isGone,
            isOff: isOff,
            isLocked: locked,
            isEditing: isEditing
        )
    }

    /// A row's own accessories, ahead of the list's: Edit mode's delete and
    /// reorder controls, and the lock.
    func accessories(for row: Row, palette: ThemePalette) -> [UICellAccessory] {
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
        return accessories
    }

    func rowIdentifier(_ row: Row) -> String {
        "\(identifierPrefix).pin.\(row.key)"
    }

    /// A tile's Edit remove button.
    func removeIdentifier(_ row: Row) -> String {
        "\(identifierPrefix).pin.remove.\(row.key)"
    }

    func accessibilityLabel(_ row: Row) -> String {
        [row.title, row.detail, row.isLocked ? String(localized: "Locked") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The workspace's and session's names a pin's row shows.
    static func names(for pin: Pin, connection: ServerConnection) -> PinNames {
        names(for: pin.target, connection: connection)
    }

    /// The workspace's and session's names a place shows.
    static func names(for route: PaneRoute, connection: ServerConnection) -> PinNames {
        let workspace = route.workspaceId.flatMap { id -> String? in
            guard let name = connection.workspaceStore.workspaces.first(where: { $0.id == id })?.name else {
                // A workspace newer than the catalog: the name shows once it is read again.
                connection.refreshCatalog(forUnknownWorkspace: id)
                return nil
            }
            return name
        }
        let session = route.sessionId.flatMap { connection.sessionStore.session(id: $0)?.displayTitle }
        return PinNames(workspace: workspace, session: session)
    }

    /// Whether `pin` is a game this device can't play from `connection`'s
    /// server now, as `AppOpener` decides for a Godot link.
    static func isOff(_ pin: Pin, connection: ServerConnection?) -> Bool {
        isOff(pin.target, connection: connection)
    }

    /// Whether `route` is a game this device can't play from `connection`'s
    /// server now.
    static func isOff(_ route: PaneRoute, connection: ServerConnection?) -> Bool {
        guard PinKind(route) == .games else { return false }
        return !GodotPaneAvailability.isOn || connection?.offers(.godotPane) == false
    }

    /// Rename, Unpin, and the pane items, as actions; none while editing.
    func accessibilityActions(_ row: Row) -> [UIAccessibilityCustomAction]? {
        row.isEditing ? nil : accessibilityActions(pinId: row.id)
    }

    /// A pin as a list row, as the File Browser's listing draws its folders
    /// and files: the file's icon or the kind's symbol, the name over its
    /// second line, and a chevron while it opens. One that is gone or off
    /// here is dimmed. The list keeps its own background; `decorate` adds
    /// the pin's parts.
    static func configureRow(_ cell: UICollectionViewListCell, row: Row, palette: ThemePalette) {
        let dimmed = row.isGone || row.isOff
        var content = UIListContentConfiguration.subtitleCell()
        if let icon = row.icon, !row.isGone {
            FileBrowserViewController.setListIcon(icon, on: &content)
        } else {
            content.image = UIImage(systemName: row.icon?.symbolName ?? row.symbol)
            content.imageProperties.tintColor = dimmed || row.icon != nil ? palette.ui.comment : palette.ui.blue
            content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
        }
        content.text = row.title
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.textProperties.color = dimmed ? palette.ui.comment : palette.ui.fg
        content.secondaryText = row.detail
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption2)
        content.secondaryTextProperties.color = palette.ui.comment
        content.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = content
        cell.accessories = !dimmed && !row.isEditing ? [.disclosureIndicator()] : []
    }

    /// Adds a pin row's own parts to a list cell that is its own
    /// accessibility element: the accessories, and its accessibility.
    func decorate(_ cell: UICollectionViewListCell, row: Row, palette: ThemePalette) {
        cell.accessories = accessories(for: row, palette: palette) + cell.accessories
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = accessibilityLabel(row)
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = rowIdentifier(row)
        cell.accessibilityCustomActions = accessibilityActions(row)
    }

    /// The header's Edit or Done; nil while the section is collapsed.
    func editAccessory(_ header: Header, palette: ThemePalette) -> UICellAccessory? {
        guard !header.isCollapsed else { return nil }
        editButton.configuration?.title = header.isEditing ? String(localized: "Done") : String(localized: "Edit")
        editButton.configuration?.baseForegroundColor = palette.ui.blue
        return .customView(configuration: .init(customView: editButton, placement: .trailing()))
    }

    /// The header as a list header row: a leading chevron, "Pinned", and Edit.
    func configureHeader(_ cell: UICollectionViewListCell, header: Header, palette: ThemePalette) {
        var content = UIListContentConfiguration.header()
        content.text = String(localized: "Pinned")
        content.textProperties.color = palette.ui.comment
        content.image = UIImage(systemName: header.isCollapsed ? "chevron.right" : "chevron.down")
        content.imageProperties.tintColor = palette.ui.comment
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        cell.contentConfiguration = content
        cell.accessories = editAccessory(header, palette: palette).map { [$0] } ?? []
        cell.backgroundConfiguration = Self.background(palette)
        // The title toggles the section; the Edit button stays its own element.
        cell.isAccessibilityElement = false
        let toggle = UIAccessibilityElement(accessibilityContainer: cell)
        toggle.accessibilityLabel = String(localized: "Pinned")
        toggle.accessibilityValue = header.isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        toggle.accessibilityTraits = .button
        toggle.accessibilityIdentifier = "\(identifierPrefix).pinned.header"
        toggle.accessibilityFrameInContainerSpace = cell.contentView.frame
        cell.accessibilityElements = header.isCollapsed ? [toggle] : [toggle, editButton]
    }

    /// The Edit button, as the header's second accessibility element.
    var editElement: UIView { editButton }

    static func background(_ palette: ThemePalette) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = palette.ui.bg
        return background
    }

    // MARK: Taps

    func toggleCollapsed() {
        guard !isEditing else { return }
        hooks.setCollapsed(!hooks.isCollapsed())
        hooks.changed()
    }

    /// A tap (or Open Here, `inMainPane`): opens the pin, or offers to remove
    /// one that is no longer there.
    func select(_ id: String, inMainPane: Bool = false) {
        guard !isEditing, let pin = pin(id) else { return }
        if pin.isGone {
            offerRemoval(pin)
            return
        }
        hooks.open(pin, inMainPane)
    }

    private func offerRemoval(_ pin: Pin) {
        guard let presenter else { return }
        let name = pin.displayName()
        let message = switch (pin.target.sessionId, pin.status) {
        case (_, .workspaceMissing): String(localized: "Its workspace was removed.")
        case (_?, _): String(localized: "The session was deleted.")
        default: String(localized: "It may have been moved, renamed, or deleted.")
        }
        Confirmation(
            title: String(localized: "\u{201C}\(name)\u{201D} isn\u{2019}t there anymore"),
            message: message,
            actionTitle: String(localized: "Remove Pin"),
            style: .alert,
            actionIdentifier: "\(identifierPrefix).pin.removeMissing"
        ).present(from: presenter, anchor: nil) { [weak self] in
            self?.unpin(pin.id)
        }
    }

    // MARK: Menus, swipes, drags

    func contextMenu(pinId: String) -> UIContextMenuConfiguration? {
        guard !isEditing, let pin = pin(pinId) else { return nil }
        let entry = pin.paneEntry(serverId: serverId)
        let prefix = identifierPrefix
        let isOff = Self.isOff(pin, connection: hooks.connection())
        let configuration = UIContextMenuConfiguration(identifier: pinId as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let source = isOff ? nil : hooks.paneSource()
            let panes = source.map { source in
                PaneOpenMenu.items(near: source) { [weak self, weak source] placement in
                    if placement == .here {
                        self?.select(pinId, inMainPane: true)
                        return
                    }
                    guard let source else { return }
                    PaneOpenMenu.open(placement, from: source) { PaneOpenContent(entry: entry) }
                }
            } ?? []
            let open = isOff ? [] : panes.isEmpty
                ? [Self.action(String(localized: "Open"), "arrow.up.forward.square", "\(prefix).pin.open") { [weak self] in
                    self?.select(pinId)
                }]
                : panes.map(\.element)
            let rename = Self.action(String(localized: "Rename\u{2026}"), "character.cursor.ibeam", "\(prefix).pin.rename") { [weak self] in
                self?.askRename(pinId)
            }
            let unpin = Self.action(String(localized: "Unpin"), "pin.slash", "\(prefix).pin.unpin") { [weak self] in
                self?.unpin(pinId)
            }
            // A session keeps its own name: it renames in its chat, not here.
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: open),
                UIMenu(options: .displayInline, children: Self.keepsOwnName(pin) ? [unpin] : [rename, unpin]),
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
        guard !isEditing, let pin = pin(pinId), !pin.isGone, !Self.isOff(pin, connection: hooks.connection()) else { return [] }
        let provider = NSItemProvider()
        provider.suggestedName = pin.displayName()
        let item = UIDragItem(itemProvider: provider)
        item.localObject = PaneDragPayload(entry: pin.paneEntry(serverId: serverId))
        return [item]
    }

    private func accessibilityActions(pinId: String) -> [UIAccessibilityCustomAction] {
        let rename = UIAccessibilityCustomAction(name: String(localized: "Rename")) { [weak self] _ in
            self?.askRename(pinId)
            return true
        }
        let unpin = UIAccessibilityCustomAction(name: String(localized: "Unpin")) { [weak self] _ in
            self?.unpin(pinId)
            return true
        }
        let own = pin(pinId).map(Self.keepsOwnName) == true ? [unpin] : [rename, unpin]
        guard let pin = pin(pinId), !Self.isOff(pin, connection: hooks.connection()),
              let source = hooks.paneSource() else { return own }
        let entry = pin.paneEntry(serverId: serverId)
        return own + PaneOpenMenu.accessibilityActions(near: source, includesOpenHere: false) { [weak source] placement in
            guard let source else { return }
            PaneOpenMenu.open(placement, from: source) { PaneOpenContent(entry: entry) }
        }
    }

    /// A session or thread keeps its own name: it renames in its chat, not here.
    private static func keepsOwnName(_ pin: Pin) -> Bool {
        switch pin.target {
        case .session, .thread: true
        default: false
        }
    }

    // MARK: Changes

    private func pin(_ id: String) -> Pin? {
        hooks.connection()?.pins.pins.first { $0.id == id }
    }

    func unpin(_ id: String) {
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
        let ownName = hooks.connection().map { pin.ownName(Self.names(for: pin, connection: $0)) } ?? pin.ownName()
        TextPrompt(
            title: String(localized: "Rename Pin"),
            message: String(localized: "Leave it empty to use the name \u{201C}\(ownName)\u{201D}."),
            placeholder: ownName,
            text: pin.label ?? "",
            actionTitle: String(localized: "Rename"),
            fieldIdentifier: "\(identifierPrefix).pin.renameField",
            actionIdentifier: "\(identifierPrefix).pin.renameSave"
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

    /// The header's Edit and Done: the section's pins as one group.
    private func toggleEditing() {
        if isEditing {
            finishEditing()
        } else if let content = content() {
            beginEditing(groups: [content.rows.map(\.id)])
        }
    }

    /// Enters Edit mode with the list's pins in `groups`, as the list shows them.
    func beginEditing(groups: [[String]]) {
        guard !isEditing else { return }
        editingGroups = groups
        editingRemoved = []
        isEditing = true
        hooks.setEditing(true)
        hooks.changed()
    }

    /// The list moved a pin: `groups` holds each group's new order.
    func didReorder(_ groups: [[String]]) {
        guard isEditing else { return }
        editingGroups = groups
    }

    /// Edit's remove: the pin leaves the list now and the server on Done.
    func removeWhileEditing(_ id: String) {
        editingGroups = editingGroups.map { $0.filter { $0 != id } }
        editingRemoved.insert(id)
        hooks.changed()
    }

    /// Done: saves the order and removals once, then leaves edit mode.
    func finishEditing() {
        guard isEditing else { return }
        let order = editingGroups
        let removed = editingRemoved
        isEditing = false
        hooks.setEditing(false)
        hooks.changed()
        guard let (pins, api) = store else { return }
        Task { [weak self] in
            do {
                // Only this list's pins move, each group within its own places; no change sends nothing.
                try await pins.setOrder(groups: order, removed: removed, api: api)
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

/// Pin and Unpin for anything that names a place: a browser row, View
/// Options' folder, the viewer's file, a session row, the chat's … menu.
/// Success shows a pill; a failure says why.
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

        /// A row's trailing swipe button.
        func swipeAction(color: UIColor) -> UIContextualAction {
            let run = run
            let button = UIContextualAction(style: .normal, title: title) { _, _, completion in
                run()
                completion(true)
            }
            button.image = UIImage(systemName: symbol + ".fill")
            button.backgroundColor = color
            return button
        }
    }

    /// Pin or Unpin for any route: `titles` say what the item names
    /// ("Pin This Folder", "Pin Session"), and `identifiers` are its
    /// accessibility identifier as Pin and as Unpin.
    static func toggle(
        route: PaneRoute,
        titles: (pin: String, unpin: String) = (String(localized: "Pin"), String(localized: "Unpin")),
        identifiers: (pin: String, unpin: String),
        pins: PinStore,
        api: APIClient,
        view: UIView
    ) -> Toggle {
        let saved = pins.pin(for: route)
        return toggle(
            target: route,
            saved: saved,
            title: saved == nil ? titles.pin : titles.unpin,
            identifier: saved == nil ? identifiers.pin : identifiers.unpin,
            pins: pins,
            api: api,
            view: view
        )
    }

    /// A session row's Pin or Unpin on `connection`'s server (`session.pin.<id>`
    /// or `session.unpin.<id>`); nil when that server keeps no pins.
    static func sessionRowToggle(_ session: Session, connection: ServerConnection?, view: UIView?) -> Toggle? {
        guard let connection, connection.pinsAvailable, let api = connection.apiClient, let view else { return nil }
        return toggle(route: .session(session.id), identifiers: ("session.pin.\(session.id)", "session.unpin.\(session.id)"), pins: connection.pins, api: api, view: view)
    }

    /// Unpins `saved`, or pins `target` when nothing is saved for it.
    private static func toggle(
        target: PaneRoute,
        saved: Pin?,
        title: String,
        identifier: String,
        pins: PinStore,
        api: APIClient,
        view: UIView
    ) -> Toggle {
        Toggle(title: title, symbol: saved == nil ? "pin" : "pin.slash", identifier: identifier) { [weak view] in
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
