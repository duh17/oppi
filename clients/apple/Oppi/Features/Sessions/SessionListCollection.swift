import UIKit

// UIKit pieces every session list shares (All Sessions, a workspace's
// sessions): the collection view with its snapshot, the values a row draws,
// the trailing swipes and long-press menu, the search bar binding, Stop,
// Resume, and Delete requests, the delete confirmation and error alert, the
// section header (titled or expandable), and the bar items. The row is
// `SessionListEntryConfiguration`.

/// What one session-list cell draws, computed by the list in
/// `updateProperties()`. A list reconfigures an item only when this changes.
struct SessionListRowContent: Equatable {
    let entry: SessionListEntry
    /// The row session's presentation (`entry.session`).
    let presentation: SessionRowPresentation
    /// Status of every session the entry draws: the row, its thread members,
    /// and the root it links to.
    let statuses: [String: SessionStatusKind]
    /// Workspace names to show for sessions outside the list's workspace.
    var foreignWorkspaceNames: [String: String] = [:]
    /// Lock badge of every drawn session that has one (`lockBadges(of:target:)`).
    var lockBadges: [String: ScopedLockState] = [:]
    /// Durable Sessions experiment: the row session runs on the durable engine.
    var isDurable = false

    func status(of session: Session) -> SessionStatusKind {
        statuses[session.id] ?? SessionStatusKind.resolve(session: session, seenAt: nil)
    }

    func lockBadge(of session: Session) -> ScopedLockState {
        lockBadges[session.id] ?? .none
    }

    /// Lock badges for the sessions an entry draws. Read in `updateProperties()`,
    /// so a lock or unlock reconfigures the row.
    @MainActor
    static func lockBadges(
        of entry: SessionListEntry,
        target: (Session) -> ScopedLockTarget?
    ) -> [String: ScopedLockState] {
        var badges: [String: ScopedLockState] = [:]
        for session in drawnSessions(of: entry) {
            guard let target = target(session) else { continue }
            let badge = ScopedLockService.shared.badge(target)
            if badge != .none { badges[session.id] = badge }
        }
        return badges
    }

    static func isDurable(_ session: Session) -> Bool {
        AppPreferences.Experiments.durableSessionsEnabled && session.engine == .durable
    }

    /// Every session whose status the entry draws.
    static func drawnSessions(of entry: SessionListEntry) -> [Session] {
        var sessions = [entry.session]
        if let thread = entry.thread {
            sessions.append(contentsOf: thread.members)
        }
        if let root = entry.outsideRoot {
            sessions.append(root)
        }
        return sessions
    }

    /// A row's values from its server's stores. `workspaceContext` names the
    /// row's workspace (All Sessions); `foreignWorkspaceName` names a drawn
    /// session's workspace when it is not the list's own.
    @MainActor
    static func make(
        entry: SessionListEntry,
        connection: ServerConnection,
        workspaceContext: String? = nil,
        foreignWorkspaceName: (Session) -> String? = { _ in nil },
        searchSnippet: AttributedString?,
        lockTarget: (Session) -> ScopedLockTarget?
    ) -> Self {
        var statuses: [String: SessionStatusKind] = [:]
        var foreignNames: [String: String] = [:]
        for session in Self.drawnSessions(of: entry) {
            statuses[session.id] = SessionStatusKind.resolve(
                session: session,
                pendingAskCount: connection.sessionListAskCount(for: session.id),
                seenAt: connection.sessionStore.seenAt(for: session.id)
            )
            if let name = foreignWorkspaceName(session) {
                foreignNames[session.id] = name
            }
        }
        let session = entry.session
        return Self(
            entry: entry,
            presentation: SessionRowPresentationBuilder.make(
                session: session,
                pendingAskCount: connection.sessionListAskCount(for: session.id),
                pendingAsk: connection.askRequestStore.pending(for: session.id),
                workspaceContext: workspaceContext,
                seenAt: connection.sessionStore.seenAt(for: session.id),
                searchSnippet: searchSnippet,
                catalogModels: connection.chatState.cachedModels
            ),
            statuses: statuses,
            foreignWorkspaceNames: foreignNames,
            lockBadges: Self.lockBadges(of: entry, target: lockTarget),
            isDurable: Self.isDurable(session)
        )
    }
}

extension ServerConnection {
    /// Questions and extension dialogs waiting on a session, as its list row counts them.
    func sessionListAskCount(for sessionId: String) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: hasPendingExtensionDialog(for: sessionId)
        )
    }
}

// MARK: - Collection

/// A session list's collection view: the list layout, the diffable data
/// source, the values each cell and header draws, and the row taps, trailing
/// swipes, and long-press menu. Session rows draw `SessionListRowContent`;
/// every other row (a prompt, a state, a local session) is the list's own
/// `Row`, drawn by `configureRow`. The list builds a `Snapshot` in
/// `updateProperties()` and applies it; only items whose values changed
/// reconfigure, and a theme or row-appearance change reconfigures them all.
@MainActor
final class SessionListCollection<
    Section: Hashable & Sendable,
    Item: Hashable & Sendable,
    Row: Equatable,
    Toggle: Equatable
>: NSObject, UICollectionViewDelegate {
    typealias Header = SessionListSectionHeader<Toggle>

    /// One pass's sections and items and what each draws.
    struct Snapshot {
        enum Cell {
            case session(SessionListRowContent)
            case row(Row)
        }

        fileprivate var items = NSDiffableDataSourceSnapshot<Section, Item>()
        fileprivate var sessions: [Item: SessionListRowContent] = [:]
        fileprivate var rows: [Item: Row] = [:]
        fileprivate var headers: [Section: Header] = [:]

        /// A section, with its header when it has one.
        mutating func appendSection(_ section: Section, header: Header? = nil) {
            items.appendSections([section])
            headers[section] = header
        }

        /// A section holding one row that is not a session: a prompt or a state.
        mutating func appendSection(_ section: Section, item: Item, row: Row) {
            appendSection(section)
            items.appendItems([item], toSection: section)
            rows[item] = row
        }

        /// Rows in order. A diffable snapshot traps on a repeated item, so a
        /// repeat is skipped before its values are made; so is an element
        /// with no cell.
        mutating func append<Element>(
            _ elements: [Element],
            to section: Section,
            item: (Element) -> Item,
            cell: (Element) -> Cell?
        ) {
            var ids: [Item] = []
            ids.reserveCapacity(elements.count)
            for element in elements {
                let id = item(element)
                guard sessions[id] == nil, rows[id] == nil else { continue }
                switch cell(element) {
                case .session(let content): sessions[id] = content
                case .row(let row): rows[id] = row
                case nil: continue
                }
                ids.append(id)
            }
            items.appendItems(ids, toSection: section)
        }

        /// Session rows in order.
        mutating func append(
            sessions entries: [SessionListEntry],
            to section: Section,
            item: (String) -> Item,
            content: (SessionListEntry) -> SessionListRowContent?
        ) {
            append(entries, to: section, item: { item($0.id) }, cell: { content($0).map(Cell.session) })
        }
    }

    let collectionView: UICollectionView
    let refreshControl = UIRefreshControl()
    /// Whether a row that is not a session takes a tap, and what the tap does.
    var isRowSelectable: (Row) -> Bool = { _ in false }
    var didSelectRow: (Row) -> Void = { _ in }

    private let root: AppRootEnvironment
    private let actions: SessionListRowActions
    private let iconAssetCache: () -> IconAssetCache?
    private let configureRow: (UICollectionViewListCell, Row) -> Void
    private let onToggle: (Toggle) -> Void
    private let leadingDragGuard = SessionListLeadingDragGuard()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var current = Snapshot()
    /// The saved row appearance (Settings, Sessions, Session Rows) and the
    /// theme the cells last drew.
    private var display = SessionRowDisplay.standard
    private var themeID: ThemeID?
    private var hasApplied = false

    /// `iconAssetCache` is the list's server's, for saved-Agent Genmoji.
    /// `configureRow` draws a non-session row on a cell already given the
    /// list's background; `onToggle` runs an expandable header's toggle.
    init(
        root: AppRootEnvironment,
        appearance: UICollectionLayoutListConfiguration.Appearance,
        actions: SessionListRowActions,
        iconAssetCache: @escaping () -> IconAssetCache?,
        configureRow: @escaping (UICollectionViewListCell, Row) -> Void,
        onToggle: @escaping (Toggle) -> Void
    ) {
        self.root = root
        self.actions = actions
        self.iconAssetCache = iconAssetCache
        self.configureRow = configureRow
        self.onToggle = onToggle
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init()
        collectionView.setCollectionViewLayout(makeLayout(appearance), animated: false)
        collectionView.delegate = self
        // A row's height follows its content: Compact rejoins its details at a
        // narrower width, a search snippet, Thread strip, or lock appears, and
        // the row rearranges its stacks for all of those without the list
        // reconfiguring the item. Measure a cell again whenever its constraints
        // change, not only when its configuration does.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "workspace.sessionList"
        collectionView.refreshControl = refreshControl
        // Pull-to-refresh needs the bounce even when the rows fit on screen.
        collectionView.alwaysBounceVertical = true
        leadingDragGuard.install(on: collectionView)
        installDataSource(
            headerInset: appearance == .insetGrouped
                ? SessionListSectionHeaderView.insetGroupedInset
                : SessionListSectionHeaderView.plainInset
        )
    }

    /// Applies the pass's snapshot, animated once the list has rows on
    /// screen. Call from `updateProperties()`: the row appearance and theme
    /// read here are tracked.
    func apply(_ next: Snapshot) {
        guard let dataSource else { return }
        let display = root.sessionRows.display
        let themeID = root.themeStore.activeThemeID
        let reconfigureAll = display != self.display || themeID != self.themeID
        self.display = display
        self.themeID = themeID

        var items = next.items
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let changed = items.itemIdentifiers.filter { item in
            guard existing.contains(item) else { return false }
            if reconfigureAll { return true }
            if let session = next.sessions[item] { return current.sessions[item] != session }
            return current.rows[item] != next.rows[item]
        }
        let headersChanged = reconfigureAll || current.headers != next.headers
        current = next
        items.reconfigureItems(changed)

        let animated = hasApplied && collectionView.window != nil
        hasApplied = true
        dataSource.apply(items, animatingDifferences: animated) { [weak self] in
            if headersChanged { self?.refreshVisibleHeaders() }
        }
    }

    /// Empties the list; the next snapshot applies without animation.
    func removeAll() {
        current = Snapshot()
        hasApplied = false
        dataSource?.apply(NSDiffableDataSourceSnapshot<Section, Item>(), animatingDifferences: false)
    }

    /// The first of `items` with a cell on screen (a confirmation's anchor).
    func cell(forFirstOf items: [Item]) -> UIView? {
        for item in items {
            if let indexPath = dataSource?.indexPath(for: item), let cell = collectionView.cellForItem(at: indexPath) {
                return cell
            }
        }
        return nil
    }

    /// A section has a header exactly when the snapshot gave it one. A plain
    /// list draws separators between session rows only, never under a
    /// prompt or state row.
    private func makeLayout(_ appearance: UICollectionLayoutListConfiguration.Appearance) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: appearance)
            configuration.backgroundColor = .clear
            let hasHeader = self?.dataSource?.sectionIdentifier(for: index)
                .flatMap { self?.current.headers[$0] } != nil
            configuration.headerMode = hasHeader ? .supplementary : .none
            if appearance == .plain {
                configuration.showsSeparators = hasHeader
            }
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipe(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func installDataSource(headerInset: CGFloat) {
        let sessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = current.sessions[item] else { return }
            cell.contentConfiguration = SessionListEntryConfiguration(
                row: row,
                display: display,
                themeID: root.themeStore.activeThemeID,
                iconAssetCache: iconAssetCache(),
                actions: actions
            )
            cell.backgroundConfiguration = rowBackground()
            // No tap highlight, as the rows have always had none.
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        let rowCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = current.rows[item] else { return }
            cell.accessibilityIdentifier = nil
            cell.accessories = []
            cell.backgroundConfiguration = rowBackground()
            cell.automaticallyUpdatesBackgroundConfiguration = false
            configureRow(cell, row)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            if self?.current.sessions[item] != nil {
                collectionView.dequeueConfiguredReusableCell(using: sessionCell, for: indexPath, item: item)
            } else {
                collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<SessionListSectionHeaderView>(
            elementKind: SessionListSectionHeaderView.elementKind
        ) { [weak self] view, _, indexPath in
            view.horizontalInset = headerInset
            self?.configure(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
    }

    private func rowBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = root.themeStore.backgroundColor
        return background
    }

    private func configure(_ view: SessionListSectionHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource?.sectionIdentifier(for: indexPath.section),
              let header = current.headers[section] else { return }
        let palette = root.themeStore.activeThemeID.palette
        switch header {
        case .title(let title):
            view.configure(title: title, palette: palette)
        case .group(let title, let detail, let isExpanded, let accessibilityIdentifier, let toggle):
            view.configure(
                title: title,
                detail: detail,
                isExpanded: isExpanded,
                accessibilityIdentifier: accessibilityIdentifier,
                palette: palette
            ) { [weak self] in
                self?.onToggle(toggle)
            }
        }
    }

    private func refreshVisibleHeaders() {
        let kind = SessionListSectionHeaderView.elementKind
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? SessionListSectionHeaderView else { continue }
            configure(view, at: indexPath)
        }
    }

    private func session(at indexPath: IndexPath) -> Session? {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return current.sessions[item]?.entry.session
    }

    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let session = session(at: indexPath) else { return nil }
        return SessionListRowMenus.trailingSwipe(
            for: session,
            actions: actions,
            palette: root.themeStore.activeThemeID.palette
        )
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        if current.sessions[item] != nil { return true }
        return current.rows[item].map(isRowSelectable) ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        if let session = current.sessions[item]?.entry.session {
            actions.open(session)
        } else if let row = current.rows[item], isRowSelectable(row) {
            didSelectRow(row)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let session = session(at: indexPath) else {
            return nil
        }
        return SessionListRowMenus.contextMenu(for: session, actions: actions)
    }
}

/// A session-list section's header: a plain title ("Your Turn"), or an
/// expandable group (a stopped day) whose `toggle` the list runs on a tap.
/// `detail` is a count shown before the chevron.
enum SessionListSectionHeader<Toggle: Equatable>: Equatable {
    case title(String)
    case group(title: String, detail: String? = nil, isExpanded: Bool, accessibilityIdentifier: String?, toggle: Toggle)
}

extension UIContentUnavailableConfiguration {
    /// A session search the server is still answering.
    static func sessionListSearching() -> Self {
        var content = loading()
        content.text = String(localized: "Searching sessions…")
        return content
    }

    static func sessionListNoMatches(query: String) -> Self {
        var content = empty()
        content.image = UIImage(systemName: "magnifyingglass")
        content.text = String(localized: "No Matching Sessions")
        content.secondaryText = String(localized: "No sessions match “\(query)”.")
        return content
    }
}

// MARK: - Search

extension ScreenSearchController {
    /// Keeps a session list's saved search (`AppNavigation`, kept across
    /// pushes) in step with this bar: typing and presenting write it, and
    /// `show(_:toolbar:)` puts it back on the bar.
    func bind(
        get: @escaping () -> SessionListSearchNavigationPersistence.State,
        set: @escaping (SessionListSearchNavigationPersistence.State) -> Void
    ) {
        onTextChange = { text in
            var next = get()
            guard next.searchText != text else { return }
            next.searchText = text
            set(next)
        }
        onPresentationChange = { presented in
            var next = get()
            guard next.isSearchPresented != presented else { return }
            next.isSearchPresented = presented
            set(next)
        }
    }

    /// The saved search on the bar. While Now Playing shares the bottom bar,
    /// searching keeps the navigation bar in place.
    func show(_ state: SessionListSearchNavigationPersistence.State, toolbar: InAppNowPlayingChrome.SessionListToolbar) {
        searchController.hidesNavigationBarDuringPresentation = !toolbar.avoidsHidingContentWhileSearching
        setText(state.searchText)
        setPresented(state.isSearchPresented)
    }
}

extension SessionSearchStore {
    /// A list's matches for `query`: its sessions by name (and
    /// `extraCandidates`), then the server's content matches; nil without a
    /// query. A content match would say what a locked session contains, so
    /// locked sessions match by name only.
    @MainActor
    func sessionListMatches(
        localSessions: [Session],
        query: String,
        serverId: String?,
        extraCandidates: (Session) -> [String?] = { _ in [] }
    ) -> [SessionListSearchPresentation.Match]? {
        SessionListSearchPresentation.flattenedMatches(
            localSessions: localSessions,
            query: query,
            extraCandidates: extraCandidates,
            serverResults: results.filter { result in
                guard let session = result.session, let serverId else { return true }
                return !ScopedLockService.shared.isLocked(.session(session, serverId: serverId))
            },
            completedServerQuery: completedServerQuery,
            activeServerQuery: activeServerQuery,
            snippetsBySessionId: snippetsBySessionId
        )
    }
}

// MARK: - Lifecycle requests

/// Stop, Resume, and Delete from a session list, sent to the session's
/// server on `scope`. A failed request reports the list's alert message.
@MainActor
enum SessionListLifecycle {
    /// Stops or resumes the session and stores the server's answer. False
    /// when nothing was sent (no client) or the request failed.
    @discardableResult
    static func setRunning(
        _ running: Bool,
        _ session: Session,
        scope: SessionRouteScope,
        connection: ServerConnection,
        onError: (String) -> Void
    ) async -> Bool {
        guard let api = connection.apiClient else { return false }
        do {
            let updated = running
                ? try await api.resumeSession(scope: scope, sessionId: session.id)
                : try await api.stopSession(scope: scope, sessionId: session.id)
            connection.sessionStore.upsert(updated)
            return true
        } catch {
            onError("\(running ? "Resume" : "Stop") failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Drops the session from the list and this device's cached timeline,
    /// then deletes it on the server. Its lock and draft go only once the
    /// server no longer has it (deleted, or already gone: 404); a failed
    /// delete brings it back on the next sync, still locked.
    static func delete(
        _ session: Session,
        scope: SessionRouteScope,
        serverId: String,
        connection: ServerConnection,
        drafts: ComposerDraftStore,
        onError: (String) -> Void
    ) async {
        guard let api = connection.apiClient else { return }
        connection.sessionStore.remove(id: session.id)
        await TimelineCache.shared.removeTrace(session.id, serverId: serverId)
        do {
            try await api.deleteSession(scope: scope, sessionId: session.id)
        } catch let apiError as APIError {
            guard case .server(let status, _) = apiError, status == 404 else {
                onError("Delete failed: \(apiError.localizedDescription)")
                return
            }
        } catch {
            onError("Delete failed: \(error.localizedDescription)")
            return
        }
        ScopedLockService.shared.forgetSession(serverId: serverId, sessionId: session.id)
        drafts.clearDraft(serverID: serverId, workspaceID: scope.composerDraftScopeID, sessionID: session.id)
    }
}

// MARK: - Swipes and menu

/// Long-press menu (Open, Stop/Resume, Lock/Unlock, Copy Session ID, Delete)
/// and trailing swipes for every session row. Swipe left is lifecycle: full
/// swipe stops; a stopped row offers Resume and Delete with no full swipe, so
/// a swipe never starts or deletes a session without a deliberate tap. There
/// is no leading swipe: a row's leading-edge drag belongs to the workspace
/// drawer, and Lock/Unlock lives only in the long-press menu. The list's
/// `SessionListRowActions` is the owner of every action.
@MainActor
enum SessionListRowMenus {
    /// Stop anything not stopped (idle included); Resume or Delete a stopped
    /// session. Swipe buttons are filled glyphs on a tinted background.
    static func trailingSwipe(
        for session: Session,
        actions: SessionListRowActions,
        palette: ThemePalette
    ) -> UISwipeActionsConfiguration {
        let isStopped = session.status == .stopped
        var buttons: [UIContextualAction] = []
        // UIContextualAction has no public accessibilityIdentifier: UI tests
        // find these by their visible titles after the swipe.
        if isStopped {
            if canResume(session) {
                buttons.append(swipeButton("Resume", symbol: "play.fill", color: UIColor(palette.green)) {
                    actions.resume(session)
                })
            }
            if let delete = actions.delete(session) {
                // Delete only asks (the confirmation deletes), so it is not destructive here.
                buttons.append(swipeButton("Delete", symbol: "trash.fill", color: UIColor(palette.red), action: delete))
            }
        } else {
            buttons.append(swipeButton("Stop", symbol: "stop.fill", color: UIColor(palette.orange)) {
                actions.stop(session)
            })
        }
        let configuration = UISwipeActionsConfiguration(actions: buttons)
        configuration.performsFirstActionWithFullSwipe = !isStopped
        return configuration
    }

    static func contextMenu(
        for session: Session,
        actions: SessionListRowActions
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: session.id as NSString, previewProvider: nil) { _ in
            menu(for: session, actions: actions)
        }
    }

    /// System menu rows: plain outline symbols, no tint, like Mail and Files.
    static func menu(for session: Session, actions: SessionListRowActions) -> UIMenu {
        var main: [UIMenuElement] = [
            UIAction(title: String(localized: "Open"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { _ in
                actions.open(session)
            },
        ]
        if session.status == .stopped {
            if canResume(session) {
                main.append(menuAction("Resume", symbol: "play.circle", id: "session.resume.\(session.id)") {
                    actions.resume(session)
                })
            }
        } else {
            main.append(menuAction("Stop", symbol: "stop.circle", id: "session.stop.\(session.id)") {
                actions.stop(session)
            })
        }
        if let target = actions.lockTarget(session) {
            main.append(lockAction(target, sessionId: session.id))
        }
        main.append(menuAction("Copy Session ID", symbol: "doc.on.doc", id: "session.copyId.\(session.id)") {
            UIPasteboard.general.string = session.id
            AppHaptics.impact(style: .light, intensity: 0.8)
            TransientConfirmationPill.show(String(localized: "Session ID Copied"))
        })
        guard session.status == .stopped, let delete = actions.delete(session) else {
            return UIMenu(children: main)
        }
        let deleteAction = menuAction("Delete", symbol: "trash", id: "session.menuDelete.\(session.id)", action: delete)
        deleteAction.attributes = .destructive
        // Two inline groups draw the divider above Delete.
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: main),
            UIMenu(options: .displayInline, children: [deleteAction]),
        ])
    }

    /// Incognito sessions cannot resume.
    private static func canResume(_ session: Session) -> Bool {
        session.status == .stopped && session.ephemeral != true
    }

    /// Lock never asks; Unlock removes the lock and asks for device authentication.
    private static func lockAction(_ target: ScopedLockTarget, sessionId: String) -> UIAction {
        let locks = ScopedLockService.shared
        let scope = target.scope
        if locks.isFlagged(scope) {
            return menuAction("Unlock", symbol: "lock.open", id: "session.unlock.\(sessionId)") {
                Task { _ = await locks.removeLock(scope) }
            }
        }
        return menuAction("Lock", symbol: "lock", id: "session.lock.\(sessionId)") {
            locks.lock(scope, workspaceId: target.workspaceId)
        }
    }

    private static func menuAction(
        _ title: String.LocalizationValue,
        symbol: String,
        id: String,
        action: @escaping () -> Void
    ) -> UIAction {
        let item = UIAction(title: String(localized: title), image: UIImage(systemName: symbol)) { _ in action() }
        item.accessibilityIdentifier = id
        return item
    }

    private static func swipeButton(
        _ title: String.LocalizationValue,
        symbol: String,
        color: UIColor,
        action: @escaping () -> Void
    ) -> UIContextualAction {
        let button = UIContextualAction(style: .normal, title: String(localized: title)) { _, _, completion in
            action()
            completion(true)
        }
        button.image = UIImage(systemName: symbol)
        button.backgroundColor = color
        return button
    }
}

// MARK: - Leading drag

/// Keeps a row's leading-edge drag from opening it. There is no leading swipe,
/// so nothing claims a rightward drag and the cell would select on touch-up.
/// This pan claims it alongside every other recognizer (vertical scroll, the
/// trailing swipe and its swipe-back close, the workspace drawer's edge pan)
/// and cancels the cell's touch, the way the SwiftUI row's tap recognizer
/// failed once the touch became a drag. A tap still selects.
@MainActor
final class SessionListLeadingDragGuard: NSObject, UIGestureRecognizerDelegate {
    private let pan = UIPanGestureRecognizer()

    func install(on collectionView: UICollectionView) {
        pan.delegate = self
        pan.cancelsTouchesInView = true
        collectionView.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        let leading: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        return velocity.x * leading > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Alerts

@MainActor
enum SessionListAlerts {
    /// "Delete Session?" with the deletion's full reach as its message. The
    /// sheet anchors to `sourceView` (the row) where it is a popover.
    static func confirmDelete(
        _ session: Session,
        from presenter: UIViewController,
        sourceView: UIView?,
        onDelete: @escaping () -> Void
    ) {
        let sheet = UIAlertController(
            title: String(localized: "Delete Session?"),
            message: SessionDeleteConfirmationPolicy.deleteMessage(for: session),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Delete Session"), style: .destructive) { _ in
            onDelete()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            if let sourceView, sourceView.window != nil {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
            } else {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        presenter.present(sheet, animated: true)
    }

    /// "Error" with OK. A second error while one shows replaces its message.
    static func presentError(_ message: String, from presenter: UIViewController) {
        if let shown = presenter.presentedViewController as? SessionListErrorAlert {
            shown.message = message
            return
        }
        guard presenter.presentedViewController == nil else { return }
        let alert = SessionListErrorAlert(title: String(localized: "Error"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// Shows a held error once the list is in a window and nothing else is
    /// presented over it; until then it stays held.
    static func presentPendingError(_ pending: inout String?, from presenter: UIViewController) {
        guard presenter.viewIfLoaded?.window != nil, let message = pending else { return }
        guard presenter.presentedViewController == nil || presenter.presentedViewController is SessionListErrorAlert else {
            return
        }
        pending = nil
        presentError(message, from: presenter)
    }
}

/// Marks the list's error alert, so a later error updates it instead of stacking.
final class SessionListErrorAlert: UIAlertController {}

// MARK: - Section headers

/// A session-list section header: a plain title ("Your Turn"), or an
/// expandable group (a stopped day) that is one button with its title,
/// an optional count, an Expanded/Collapsed value, and a chevron.
final class SessionListSectionHeaderView: UICollectionReusableView {
    static let elementKind = UICollectionView.elementKindSectionHeader

    /// Covers the header for an expandable group; hidden for a titled one.
    private let button = UIButton(type: .custom)
    private let row = UIStackView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let header = UIListContentConfiguration.header()
        titleLabel.font = header.textProperties.font
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .default)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(detailLabel)
        row.addArrangedSubview(chevron)
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(button)
        button.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)

        let margins = layoutMarginsGuide
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: margins.topAnchor),
            row.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: header.directionalLayoutMargins.top,
            leading: Self.plainInset,
            bottom: header.directionalLayoutMargins.bottom,
            trailing: Self.plainInset
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Header text sits 16 pt in on a plain list and 20 pt in on an inset
    /// grouped one (level with the rows' text), as SwiftUI's did.
    static let plainInset: CGFloat = 16
    static let insetGroupedInset: CGFloat = 20

    var horizontalInset: CGFloat = SessionListSectionHeaderView.plainInset {
        didSet {
            directionalLayoutMargins.leading = horizontalInset
            directionalLayoutMargins.trailing = horizontalInset
        }
    }

    /// A titled header. Reuse clears the expandable state.
    func configure(title: String, palette: ThemePalette) {
        apply(title: title, palette: palette)
        onToggle = nil
        detailLabel.isHidden = true
        chevron.isHidden = true
        button.isHidden = true
        button.accessibilityIdentifier = nil
        button.accessibilityValue = nil
        row.accessibilityElementsHidden = false
        titleLabel.accessibilityTraits = .header
    }

    /// An expandable group header: the whole header toggles the group, for
    /// touch and accessibility activation alike. `detail` (a count) sits
    /// before the chevron.
    func configure(
        title: String,
        detail: String? = nil,
        isExpanded: Bool,
        accessibilityIdentifier: String?,
        palette: ThemePalette,
        onToggle: @escaping () -> Void
    ) {
        apply(title: title, palette: palette)
        self.onToggle = onToggle
        detailLabel.text = detail
        detailLabel.textColor = UIColor(palette.comment)
        detailLabel.isHidden = detail == nil
        chevron.isHidden = false
        chevron.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
        chevron.tintColor = UIColor(palette.comment)
        button.isHidden = false
        button.accessibilityLabel = detail.map { "\(title), \($0)" } ?? title
        button.accessibilityValue = isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        button.accessibilityIdentifier = accessibilityIdentifier
        // The button speaks for the row beneath it.
        row.accessibilityElementsHidden = true
    }

    private func apply(title: String, palette: ThemePalette) {
        titleLabel.text = title
        // SwiftUI's section header color; the chevron and count keep the theme's.
        titleLabel.textColor = .secondaryLabel
        backgroundColor = UIColor(palette.bg)
    }
}

// MARK: - Bar items

/// Bar items the session lists share, in UIKit. On the Duo's vertical rail an
/// item prefers the rail (`axisBehavior`) and keeps its overflow rank
/// (`visibilityPriority` from `VerticalRailItemPriority`); a top-leading item
/// stays in the horizontal bar.
@MainActor
enum SessionListBarItems {
    /// Whether the system places a vertical bar for these traits.
    static func joinsRail(_ traits: UITraitCollection) -> Bool {
        SystemVerticalBar.traitIsActive(traits)
    }

    /// The tint of a rail control. SwiftUI toolbar buttons on the vertical rail
    /// ignored `.foregroundStyle(.themeFg)` and drew in the app tint
    /// (`.tint(.themeBlue)`); only a menu label or a static label stayed
    /// `themeFg`. Horizontal bars honor the foreground style and keep `fg`.
    static func railTint(_ palette: ThemePalette) -> UIColor {
        UIColor(palette.blue)
    }

    /// Navigation outranks the frequent actions, and an accessory leaves first.
    static func railItem(_ item: UIBarButtonItem, priority: VerticalRailItemPriority) -> UIBarButtonItem {
        if #available(iOS 27.1, *) {
            item.axisBehavior = .verticalPreferred
            item.visibilityPriority = switch priority {
            case .navigation: UIBarButtonItemVisibilityPriority(higherThan: .high)
            case .keep: .high
            case .overflowFirst: .low
            }
        }
        return item
    }

    /// Keeps a leading control in the top-left corner when a side rail exists.
    static func horizontalOnly(_ item: UIBarButtonItem) -> UIBarButtonItem {
        if #available(iOS 27.1, *) {
            item.axisBehavior = .horizontalOnly
        }
        return item
    }

    /// Opens the workspace drawer. The rail shows its title; the bar a symbol.
    static func sidebarOpen(joinsRail: Bool, tint: UIColor, action: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: joinsRail ? String(localized: "Workspaces") : nil,
            image: UIImage(systemName: "sidebar.left"),
            primaryAction: UIAction { _ in action() }
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Show workspaces")
        item.accessibilityIdentifier = "workspace.sidebar.open"
        return joinsRail ? railItem(item, priority: .navigation) : horizontalOnly(item)
    }

    /// Folder for the trailing bottom-bar capsule. On the rail, `railTitle`
    /// makes it a labeled symbol so the system shows the folder and keeps the
    /// title for overflow.
    static func files(
        isEnabled: Bool,
        accessibilityLabel: String,
        railTitle: String?,
        palette: ThemePalette,
        action: @escaping () -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: railTitle,
            image: UIImage(systemName: "folder"),
            primaryAction: UIAction { _ in action() }
        )
        item.isEnabled = isEnabled
        // The rail draws the app tint; a disabled item dims itself.
        item.tintColor = railTitle != nil
            ? railTint(palette)
            : UIColor(isEnabled ? palette.fg : palette.fgDim)
        item.accessibilityLabel = accessibilityLabel
        item.accessibilityIdentifier = "workspace.files.open"
        return railTitle == nil ? item : railItem(item, priority: .keep)
    }

    /// Rail or horizontal bar: the bars rebuild when the vertical bar edge changes.
    static func updatesWithVerticalBarEdge(_ controller: UIViewController) {
        if #available(iOS 27.1, *) {
            let traits = UITraitCollection.systemTraitsAffectingVerticalBarEdge
            controller.registerForTraitChanges(traits) { (controller: UIViewController, _: UITraitCollection) in
                controller.setNeedsUpdateProperties()
            }
        }
    }
}

/// A session list's Message and Now Playing controls. On the horizontal
/// bottom bar they are the hosted Message capsule and the Now Playing pill,
/// kept across passes so they update in place instead of rebuilding the bar
/// item; on the vertical rail, labeled symbols. Each opens Quick Session,
/// dictation, or the player through the list's closures.
@MainActor
final class SessionListBottomBar {
    /// The Message capsule's host, once the horizontal bar has asked for it.
    private(set) var composeHost: HostedContentController?
    private var composeParams: ComposeParams?
    private var pill: InAppNowPlayingPillView?
    private let root: AppRootEnvironment
    private let onStart: () -> Void
    private let onDictate: () -> Void
    private let onNowPlaying: () -> Void

    init(
        root: AppRootEnvironment,
        onStart: @escaping () -> Void,
        onDictate: @escaping () -> Void,
        onNowPlaying: @escaping () -> Void
    ) {
        self.root = root
        self.onStart = onStart
        self.onDictate = onDictate
        self.onNowPlaying = onNowPlaying
    }

    /// Brings the horizontal bar's capsule up to date, and the pill when
    /// Now Playing shows. The capsule rebuilds only when its inputs change.
    func update(
        showsDictation: Bool,
        hasActivePlayback: Bool,
        toolbar: InAppNowPlayingChrome.SessionListToolbar,
        player: AudioPlayerService?,
        columnWidth: CGFloat
    ) {
        let params = ComposeParams(
            showsDictation: showsDictation,
            hasActivePlayback: hasActivePlayback,
            columnWidth: columnWidth
        )
        if composeParams != params || composeHost == nil {
            composeParams = params
            composeHost = SessionListHostedChrome.composeCapsule(
                updating: composeHost,
                root: root,
                showsDictation: showsDictation,
                hasActivePlayback: hasActivePlayback,
                columnWidth: columnWidth,
                onStart: onStart,
                onDictate: onDictate
            )
        }
        guard toolbar.showsNowPlayingPill, let player else { return }
        if let pill {
            pill.update(audioPlayer: player, density: toolbar.pillDensity)
        } else {
            pill = InAppNowPlayingPillView(
                audioPlayer: player,
                accessibilityPrefix: "sessionList.nowPlaying",
                density: toolbar.pillDensity,
                onOpen: onNowPlaying
            )
        }
    }

    /// The horizontal bottom bar: Message, then Now Playing parked beside it
    /// or centered, then `files` trailing.
    func items(showsNowPlaying: Bool, parksNowPlayingNextToCompose: Bool, files: UIBarButtonItem) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if let composeHost {
            items.append(UIBarButtonItem(customView: composeHost.view))
        }
        if showsNowPlaying, let pill {
            items.append(parksNowPlayingNextToCompose ? .fixedSpace() : .flexibleSpace())
            items.append(UIBarButtonItem(customView: pill))
        }
        items.append(.flexibleSpace())
        items.append(files)
        return items
    }

    /// Drops the controls with the list's content; the next update makes them again.
    func reset() {
        composeHost = nil
        composeParams = nil
        pill = nil
    }

    /// The rail's compose control. The rail has no room for the capsule's
    /// mic, so long-press keeps Dictate.
    func railCompose(showsDictation: Bool, tint: UIColor) -> UIBarButtonItem {
        let onStart = onStart
        let onDictate = onDictate
        var menuItems: [UIMenuElement] = []
        if showsDictation {
            menuItems.append(UIAction(title: String(localized: "Dictate"), image: UIImage(systemName: "mic")) { _ in onDictate() })
        }
        let item = UIBarButtonItem(
            title: String(localized: "Message"),
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { _ in onStart() },
            menu: menuItems.isEmpty ? nil : UIMenu(children: menuItems)
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Start Quick Session")
        item.accessibilityIdentifier = "workspace.quickSession.start"
        item.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Dictate Quick Session")) { _ in
                onDictate()
                return true
            },
        ]
        return SessionListBarItems.railItem(item, priority: .keep)
    }

    /// Now Playing is a wide pill. On the rail it is a labeled symbol that
    /// opens the same player.
    func railNowPlaying(tint: UIColor) -> UIBarButtonItem {
        let onOpen = onNowPlaying
        let item = UIBarButtonItem(
            title: String(localized: "Playing"),
            image: UIImage(systemName: "waveform"),
            primaryAction: UIAction { _ in onOpen() }
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Now Playing")
        item.accessibilityIdentifier = "sessionList.nowPlaying.rail"
        return SessionListBarItems.railItem(item, priority: .overflowFirst)
    }

    private struct ComposeParams: Equatable {
        let showsDictation: Bool
        let hasActivePlayback: Bool
        let columnWidth: CGFloat
    }
}

// MARK: - Server switcher

/// The session lists' server switcher: the current server's pill in the bar
/// (on the rail, its status-colored symbol) with the switcher menu.
/// `HostSwitcherModel` owns the rows and actions; the menu is built each time
/// it opens, so it always lists current states.
@MainActor
final class SessionListServerSwitcher {
    private var model: HostSwitcherModel
    private lazy var pill = ServerSwitcherPillButton()
    private(set) var item: UIBarButtonItem
    /// The rail item and the bar pill are different items; a change makes a new switcher.
    let joinsRail: Bool

    init(model: HostSwitcherModel, joinsRail: Bool) {
        self.model = model
        self.joinsRail = joinsRail
        item = UIBarButtonItem()
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])
        if joinsRail {
            item.menu = menu
        } else {
            item.customView = pill
            pill.menu = menu
            pill.showsMenuAsPrimaryAction = true
        }
        update(model)
    }

    /// Repaints the pill from the model's current state. Call from `updateProperties()`.
    func update(_ model: HostSwitcherModel) {
        self.model = model
        let state = model.badgeState(for: model.current)
        let colors = SessionRowStyle.for(ThemeRuntimeState.currentThemeID()).colors
        if joinsRail {
            item.image = UIImage(systemName: model.current.resolvedBadgeIcon.symbolName)
            item.tintColor = state.uiColor(colors)
            item.accessibilityLabel = model.accessibilityLabel
            item.accessibilityValue = state.title
        } else {
            pill.apply(model, state: state, colors: colors)
        }
    }

    /// Servers, the Connection row, then the destinations. A menu draws its
    /// glyphs in its own color, so they carry the app blue themselves, as the
    /// SwiftUI menu's did.
    private func menuElements() -> [UIMenuElement] {
        let model = model
        let blue = SessionRowStyle.for(ThemeRuntimeState.currentThemeID()).colors.blue
        func glyph(_ name: String) -> UIImage? {
            UIImage(systemName: name)?.withTintColor(blue, renderingMode: .alwaysOriginal)
        }
        let servers: [UIMenuElement] = model.servers.map { server in
            let action = UIAction(title: model.menuTitle(for: server), image: glyph(model.menuImage(for: server))) { _ in
                model.switchHost(server)
            }
            action.accessibilityValue = model.menuAccessibilityValue(for: server)
            return action
        }
        let connection = model.connection
        let connectionRow = UIAction(title: connection.title, image: glyph(connection.systemImage)) { _ in
            model.retryConnection()
        }
        let destinations: [UIMenuElement] = model.destinations.map { item in
            let action = UIAction(title: item.menuTitle, image: glyph(item.systemImage)) { _ in
                model.open(item)
            }
            action.accessibilityIdentifier = item.accessibilityIdentifier
            return action
        }
        return [
            UIMenu(options: .displayInline, children: servers),
            UIMenu(title: String(localized: "Connection"), options: .displayInline, children: [connectionRow]),
            UIMenu(options: .displayInline, children: destinations),
        ]
    }
}

/// The horizontal bar's pill: server badge, name, lock, a connection word
/// while not connected, and the chevron. The bar draws the capsule.
final class ServerSwitcherPillButton: UIButton {
    private let stack = UIStackView()
    private let badge = UIView()
    private let badgeSymbol = UIImageView()
    private let nameLabel = UILabel()
    private let lockLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stateLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        badge.layer.cornerRadius = 10
        badge.layer.borderWidth = 1
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeSymbol.translatesAutoresizingMaskIntoConstraints = false
        badgeSymbol.contentMode = .center
        badge.addSubview(badgeSymbol)
        nameLabel.font = .scaled(.caption1, .semibold)
        stateLabel.font = .scaled(.caption2, .semibold)
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        chevron.image = .scaledSymbol("chevron.down", style: .caption2, weight: .semibold)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        [badge, nameLabel, lockLabel, spinner, stateLabel, chevron].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badgeSymbol.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeSymbol.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for subview in stack.arrangedSubviews {
            subview.isAccessibilityElement = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ model: HostSwitcherModel, state: ServerBadgeConnectionState, colors: ComposerThemeColors) {
        let tint = state.uiColor(colors)
        let server = model.current
        badge.backgroundColor = tint.withAlphaComponent(0.16)
        badge.layer.borderColor = tint.withAlphaComponent(0.5).cgColor
        let symbolName = UIImage(systemName: server.resolvedBadgeIcon.symbolName) == nil
            ? "desktopcomputer" : server.resolvedBadgeIcon.symbolName
        badgeSymbol.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(UIImage.SymbolConfiguration(hierarchicalColor: tint))
        )
        nameLabel.text = server.name
        nameLabel.textColor = colors.fg
        SessionRowText.setLockBadge(model.currentLockBadge, on: lockLabel, color: colors.comment)
        let connected = state == .connected
        let busy = state == .connecting || state == .recovering
        spinner.isHidden = connected || !busy
        spinner.color = tint
        if spinner.isHidden { spinner.stopAnimating() } else { spinner.startAnimating() }
        stateLabel.isHidden = connected
        stateLabel.text = state.title
        stateLabel.textColor = tint
        chevron.tintColor = colors.comment
        accessibilityLabel = model.accessibilityLabel
        accessibilityValue = state.title
    }
}

extension ServerBadgeConnectionState {
    /// `tintColor` in UIKit.
    func uiColor(_ colors: ComposerThemeColors) -> UIColor {
        switch tintColor.role {
        case .green: colors.green
        case .blue: colors.blue
        case .orange: colors.orange
        default: colors.red
        }
    }
}
