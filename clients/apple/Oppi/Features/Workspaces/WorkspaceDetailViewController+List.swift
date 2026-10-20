import UIKit

/// What the list shows: the rows read from the stores, the diffable
/// snapshot and its cells, and the collection view's taps and menus.
extension WorkspaceDetailViewController {
    private func viewData(_ detail: DetailState) -> ViewData {
        let startNs = SessionListPerf.timestampNs()
        let sessions = detail.sessions
        let localFiltered = filteredLocalSessions(query: detail.search.searchText, hasQuery: detail.hasSearchQuery)

        if let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: sessions,
            query: detail.search.searchText,
            extraCandidates: { _ in [] },
            // A content match would say what a locked session contains;
            // locked sessions match by name only.
            serverResults: searchStore.results.filter { result in
                guard let session = result.session else { return true }
                return !ScopedLockService.shared.isLocked(.session(session, serverId: serverId))
            },
            completedServerQuery: searchStore.completedServerQuery,
            activeServerQuery: searchStore.activeServerQuery,
            snippetsBySessionId: searchStore.snippetsBySessionId
        ) {
            let searchMatches = matches.map(\.session)
            SessionListPerf.recordViewDataCompute(
                startNs: startNs,
                activeCount: searchMatches.count,
                stoppedCount: 0,
                workspaceId: workspaceId
            )
            return ViewData(
                yourTurn: [],
                working: [],
                stopped: [],
                localFiltered: localFiltered,
                searchMatches: SessionListEntries.flat(searchMatches),
                isEmpty: sessions.isEmpty && localFiltered.isEmpty && searchMatches.isEmpty
            )
        }

        // Same sections and order as All Sessions; stopped history keeps this list's day/month grouping.
        let attention = { (session: Session) in self.attentionCounts(for: session, connection: detail.connection) }
        let split = SessionInboxGrouping.split(
            items: entries(for: sessions, connection: detail.connection),
            session: \.representative,
            attention: { attention($0.session) },
            sectionKind: { $0.sectionKind(attention: attention) },
            isBlocked: { $0.isBlocked(attention: attention) }
        )
        SessionListPerf.recordViewDataCompute(
            startNs: startNs,
            activeCount: split.yourTurn.count + split.working.count,
            stoppedCount: split.stopped.count,
            workspaceId: workspaceId
        )
        return ViewData(
            yourTurn: split.yourTurn,
            working: split.working,
            stopped: split.stopped,
            localFiltered: localFiltered,
            searchMatches: [],
            isEmpty: sessions.isEmpty
        )
    }

    /// Importable local Pi sessions. The server owns cwd/host-mount alignment,
    /// so the client applies only the search filter.
    private func filteredLocalSessions(query: String, hasQuery: Bool) -> [LocalSession] {
        guard hasQuery else { return state.localSessions }
        let normalized = SessionListSearchPresentation.normalizedQuery(query)
        return state.localSessions.filter { FuzzyMatch.match(query: normalized, candidate: $0.displayTitle) != nil }
    }

    /// This list's sessions; threads only when the Session Threads experiment is on.
    /// Threads are built over every loaded session so a thread keeps members from
    /// other workspaces and worktrees; a session whose root is elsewhere links to it.
    private func entries(for listed: [Session], connection: ServerConnection) -> [SessionListEntry] {
        SessionListEntries.entries(
            threadsEnabled: navigation.sessionThreadsEnabled,
            listed: listed,
            loaded: connection.sessionStore.listProjectionSessions
        )
    }

    /// An older-history bucket threads (experiment on) only within itself, so a thread never
    /// claims recent sessions that already have their own rows above.
    private func archiveEntries(for bucket: WorkspaceSessionArchiveBucket) -> [SessionListEntry] {
        let sessions = state.archiveStoppedSessionsByBucketID[bucket.id] ?? []
        return SessionListEntries.entries(threadsEnabled: navigation.sessionThreadsEnabled, listed: sessions, loaded: sessions)
    }

    private func attentionCounts(for session: Session, connection: ServerConnection) -> SessionListAttentionCounts {
        SessionRowPresentationBuilder.attentionCounts(
            sessionId: session.id,
            pendingAskCountForSession: { Self.pendingAskCount(for: $0, connection: connection) }
        )
    }

    static func pendingAskCount(for sessionId: String, connection: ServerConnection) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func rowContent(for entry: SessionListEntry, connection: ServerConnection) -> SessionListRowContent {
        let rowStartNs = SessionListPerf.timestampNs()
        var statuses: [String: SessionStatusKind] = [:]
        var foreignNames: [String: String] = [:]
        for session in SessionListRowContent.drawnSessions(of: entry) {
            statuses[session.id] = SessionStatusKind.resolve(
                session: session,
                pendingAskCount: Self.pendingAskCount(for: session.id, connection: connection),
                seenAt: connection.sessionStore.seenAt(for: session.id)
            )
            if let name = foreignWorkspaceName(for: session, connection: connection) {
                foreignNames[session.id] = name
            }
        }
        let session = entry.session
        let attention = attentionCounts(for: session, connection: connection)
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: attention.askCount,
            pendingAsk: connection.askRequestStore.pending(for: session.id),
            seenAt: connection.sessionStore.seenAt(for: session.id),
            searchSnippet: searchStore.snippetsBySessionId[session.id],
            catalogModels: connection.chatState.cachedModels
        )
        SessionListPerf.recordRowCompute(
            durationMs: Int((SessionListPerf.timestampNs() &- rowStartNs) / 1_000_000),
            rowCount: 1,
            workspaceId: workspaceId
        )
        return SessionListRowContent(
            entry: entry,
            presentation: presentation,
            statuses: statuses,
            foreignWorkspaceNames: foreignNames,
            lockBadges: SessionListRowContent.lockBadges(of: entry, target: rowActions.lockTarget),
            isDurable: SessionListRowContent.isDurable(session)
        )
    }

    /// Workspace name for a session that runs in another workspace; this list's own workspace is implied.
    private func foreignWorkspaceName(for session: Session, connection: ServerConnection) -> String? {
        guard let id = session.workspaceId, id != workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == id }?.name ?? session.workspaceName
    }

    private func isGroupExpanded(_ group: WorkspaceStoppedSessionGrouping.Group) -> Bool {
        if state.expandedStoppedGroupIDs.contains(group.id) { return true }
        if state.collapsedStoppedGroupIDs.contains(group.id) { return false }
        return group.isExpandedByDefault
    }

    private func isArchiveBucketExpanded(_ bucketId: String) -> Bool {
        state.expandedStoppedGroupIDs.contains(bucketId)
    }

    private func toggle(_ toggle: GroupToggle) {
        switch toggle {
        case .stopped(let groupID, let isExpanded):
            if isExpanded {
                state.expandedStoppedGroupIDs.remove(groupID)
                state.collapsedStoppedGroupIDs.insert(groupID)
            } else {
                state.collapsedStoppedGroupIDs.remove(groupID)
                state.expandedStoppedGroupIDs.insert(groupID)
            }
        case .archive(let bucket):
            if isArchiveBucketExpanded(bucket.id) {
                state.expandedStoppedGroupIDs.remove(bucket.id)
                state.collapsedStoppedGroupIDs.insert(bucket.id)
            } else {
                state.collapsedStoppedGroupIDs.remove(bucket.id)
                state.expandedStoppedGroupIDs.insert(bucket.id)
                Task { await ensureArchiveBucketLoaded(bucket) }
            }
        }
    }

    // MARK: Snapshot

    func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            let section = self?.dataSource?.sectionIdentifier(for: index)
            configuration.headerMode = section?.hasHeader == true ? .supplementary : .none
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipe(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    func installDataSource() {
        let sessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = rows[item] else { return }
            cell.contentConfiguration = SessionListEntryConfiguration(
                row: row,
                display: rowDisplay,
                themeID: root.themeStore.activeThemeID,
                iconAssetCache: connection?.iconAssetCache,
                actions: rowActions
            )
            cell.backgroundConfiguration = rowBackground()
            // No tap highlight, as the rows have always had none.
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        let localCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = localRows[item] else { return }
            let local = row.session
            cell.contentConfiguration = LocalSessionRowConfiguration(
                session: local,
                isEnabled: row.isEnabled,
                themeID: root.themeStore.activeThemeID
            ) { [weak self] in
                Task { await self?.importAndResumeLocal(local) }
            }
            cell.backgroundConfiguration = rowBackground()
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        let stateCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = stateRows[item] else { return }
            configure(cell, row: row)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .session, .stoppedSession, .archiveSession:
                collectionView.dequeueConfiguredReusableCell(using: sessionCell, for: indexPath, item: item)
            case .local, .archiveLocal:
                collectionView.dequeueConfiguredReusableCell(using: localCell, for: indexPath, item: item)
            case .searching, .noMatches, .empty, .archiveLoading:
                collectionView.dequeueConfiguredReusableCell(using: stateCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<SessionListSectionHeaderView>(
            elementKind: SessionListSectionHeaderView.elementKind
        ) { [weak self] view, _, indexPath in
            view.horizontalInset = SessionListSectionHeaderView.insetGroupedInset
            self?.configure(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
    }

    func applySnapshot(_ detail: DetailState, reconfigureAll: Bool) {
        guard let dataSource else { return }
        let data = viewData(detail)
        let connection = detail.connection

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var nextRows: [Item: SessionListRowContent] = [:]
        var nextLocals: [Item: LocalRow] = [:]
        var nextStates: [Item: StateRow] = [:]
        var nextHeaders: [Section: Header] = [:]
        let localsEnabled = !state.isImportingLocal

        func appendState(_ row: StateRow, item: Item, section: Section) {
            snapshot.appendSections([section])
            snapshot.appendItems([item], toSection: section)
            nextStates[item] = row
        }
        func append(_ items: [WorkspaceStoppedSessionGrouping.Item], to section: Section, archive: Bool) {
            var ids: [Item] = []
            ids.reserveCapacity(items.count)
            for item in items {
                switch item {
                case .entry(let entry):
                    let id = archive ? Item.archiveSession(entry.id) : Item.stoppedSession(entry.id)
                    // A diffable snapshot traps on a repeated item.
                    guard nextRows[id] == nil else { continue }
                    nextRows[id] = rowContent(for: entry, connection: connection)
                    ids.append(id)
                case .local(let local):
                    let id = archive ? Item.archiveLocal(local.path) : Item.local(local.path)
                    guard nextLocals[id] == nil else { continue }
                    nextLocals[id] = LocalRow(session: local, isEnabled: localsEnabled)
                    ids.append(id)
                }
            }
            snapshot.appendItems(ids, toSection: section)
        }
        func appendSessions(_ entries: [SessionListEntry], section: Section) {
            snapshot.appendSections([section])
            var ids: [Item] = []
            ids.reserveCapacity(entries.count)
            for entry in entries {
                let id = Item.session(entry.id)
                guard nextRows[id] == nil else { continue }
                nextRows[id] = rowContent(for: entry, connection: connection)
                ids.append(id)
            }
            snapshot.appendItems(ids, toSection: section)
        }

        if detail.hasSearchQuery {
            if searchStore.isSearching && data.searchMatches.isEmpty && data.localFiltered.isEmpty {
                appendState(.searching, item: .searching, section: .status)
            } else if data.searchMatches.isEmpty && data.localFiltered.isEmpty {
                let query = detail.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                appendState(.noMatches(query: query), item: .noMatches, section: .status)
            } else {
                if !data.searchMatches.isEmpty {
                    nextHeaders[.results] = .title(String(localized: "Results"))
                    appendSessions(data.searchMatches, section: .results)
                }
                if !data.localFiltered.isEmpty {
                    nextHeaders[.localResults] = .title(String(localized: "Local Sessions"))
                    snapshot.appendSections([.localResults])
                    append(data.localFiltered.map(WorkspaceStoppedSessionGrouping.Item.local), to: .localResults, archive: false)
                }
            }
        } else {
            if !data.yourTurn.isEmpty {
                nextHeaders[.yourTurn] = .title(SessionInboxSectionTitle.yourTurn)
                appendSessions(data.yourTurn, section: .yourTurn)
            }
            if !data.working.isEmpty {
                nextHeaders[.working] = .title(SessionInboxSectionTitle.working)
                appendSessions(data.working, section: .working)
            }
            let groups = WorkspaceStoppedSessionGrouping.groups(
                stoppedEntries: data.stopped,
                localSessions: data.localFiltered
            )
            for (index, group) in groups.enumerated() {
                let section = Section.stopped(group.id)
                let isExpanded = isGroupExpanded(group)
                let title = WorkspaceStoppedSessionGrouping.title(group.bucket)
                nextHeaders[section] = .group(GroupHeader(
                    title: index == 0 ? "Stopped · \(title)" : title,
                    detail: nil,
                    isExpanded: isExpanded,
                    accessibilityIdentifier: "workspace.stoppedGroup.\(group.id)",
                    toggle: .stopped(groupID: group.id, isExpanded: isExpanded)
                ))
                snapshot.appendSections([section])
                if isExpanded {
                    append(group.items, to: section, archive: false)
                }
            }
            for bucket in state.archiveBuckets {
                let section = Section.archive(bucket.id)
                let isExpanded = isArchiveBucketExpanded(bucket.id)
                nextHeaders[section] = .group(GroupHeader(
                    title: "Stopped · \(WorkspaceStoppedSessionGrouping.title(bucket))",
                    detail: "\(bucket.itemCount)",
                    isExpanded: isExpanded,
                    accessibilityIdentifier: nil,
                    toggle: .archive(bucket)
                ))
                snapshot.appendSections([section])
                guard isExpanded else { continue }
                if state.loadingArchiveBucketIDs.contains(bucket.id) {
                    let item = Item.archiveLoading(bucket.id)
                    snapshot.appendItems([item], toSection: section)
                    nextStates[item] = .archiveLoading
                } else {
                    append(
                        WorkspaceStoppedSessionGrouping.archiveItems(
                            entries: archiveEntries(for: bucket),
                            localSessions: state.archiveLocalSessionsByBucketID[bucket.id] ?? []
                        ),
                        to: section,
                        archive: true
                    )
                }
            }
            if data.isEmpty {
                appendState(.empty, item: .empty, section: .empty)
            }
        }

        let current = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { item in
            guard current.contains(item) else { return false }
            if reconfigureAll { return true }
            if let row = nextRows[item] { return rows[item] != row }
            if let local = nextLocals[item] { return localRows[item] != local }
            return stateRows[item] != nextStates[item]
        }
        let headersChanged = reconfigureAll || headers != nextHeaders
        rows = nextRows
        localRows = nextLocals
        stateRows = nextStates
        headers = nextHeaders
        snapshot.reconfigureItems(changed)

        let animated = hasAppliedSnapshot && view.window != nil
        hasAppliedSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            if headersChanged { self?.refreshVisibleHeaders() }
        }
    }

    private func rowBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = root.themeStore.backgroundColor
        return background
    }

    private func configure(_ cell: UICollectionViewListCell, row: StateRow) {
        let palette = root.themeStore.activeThemeID.palette
        cell.backgroundConfiguration = rowBackground()
        cell.automaticallyUpdatesBackgroundConfiguration = false
        switch row {
        case .searching:
            var content = UIContentUnavailableConfiguration.loading()
            content.text = String(localized: "Searching sessions…")
            cell.contentConfiguration = content
        case .noMatches(let query):
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "magnifyingglass")
            content.text = String(localized: "No Matching Sessions")
            content.secondaryText = String(localized: "No sessions match “\(query)”.")
            cell.contentConfiguration = content
        case .empty:
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "terminal")
            content.text = String(localized: "No Sessions")
            content.secondaryText = String(
                localized: "Tap Message to compose a Quick Session in this worktree."
            )
            cell.contentConfiguration = content
        case .archiveLoading:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Loading older sessions…")
            content.textProperties.color = UIColor(palette.comment)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
            return
        }
        cell.accessories = []
    }

    private func configure(_ view: SessionListSectionHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource?.sectionIdentifier(for: indexPath.section),
              let header = headers[section] else { return }
        let palette = root.themeStore.activeThemeID.palette
        switch header {
        case .title(let title):
            view.configure(title: title, palette: palette)
        case .group(let group):
            view.configure(
                title: group.title,
                detail: group.detail,
                isExpanded: group.isExpanded,
                accessibilityIdentifier: group.accessibilityIdentifier,
                palette: palette
            ) { [weak self] in
                self?.toggle(group.toggle)
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
        return rows[item]?.entry.session
    }

    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let session = session(at: indexPath) else { return nil }
        return SessionListRowMenus.trailingSwipe(
            for: session,
            actions: rowActions,
            palette: root.themeStore.activeThemeID.palette
        )
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        if rows[item] != nil { return true }
        return localRows[item]?.isEnabled == true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        if let session = rows[item]?.entry.session {
            rowActions.open(session)
        } else if let local = localRows[item], local.isEnabled {
            Task { await importAndResumeLocal(local.session) }
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
        return SessionListRowMenus.contextMenu(for: session, actions: rowActions)
    }
}
