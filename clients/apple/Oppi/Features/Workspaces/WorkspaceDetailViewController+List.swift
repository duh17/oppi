import UIKit

/// What the list shows: the rows read from the stores, the snapshot the
/// `SessionListCollection` applies, and the local and state rows it draws.
extension WorkspaceDetailViewController {
    private func viewData(_ detail: DetailState) -> ViewData {
        let startNs = SessionListPerf.timestampNs()
        let sessions = detail.sessions
        let localFiltered = filteredLocalSessions(query: detail.search.searchText, hasQuery: detail.hasSearchQuery)

        if let matches = searchStore.sessionListMatches(
            localSessions: sessions,
            query: detail.search.searchText,
            serverId: serverId
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

        // Same sections, order, and recent stopped days as All Sessions; older history follows as server sections.
        let attention = { (session: Session) in
            SessionListAttentionCounts(askCount: detail.connection.sessionListAskCount(for: session.id))
        }
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

    /// This list's sessions as thread rows. Threads are built over every loaded session
    /// so a thread keeps members from other workspaces and worktrees; a session whose
    /// root is elsewhere links to it.
    private func entries(for listed: [Session], connection: ServerConnection) -> [SessionListEntry] {
        SessionListEntries.threads(listed: listed, loaded: connection.sessionStore.listProjectionSessions)
    }

    /// An older-history bucket threads only within itself, so a thread never claims recent
    /// sessions that already have their own rows above.
    private func archiveEntries(for bucket: WorkspaceSessionArchiveBucket) -> [SessionListEntry] {
        let sessions = state.archiveStoppedSessionsByBucketID[bucket.id] ?? []
        return SessionListEntries.threads(listed: sessions, loaded: sessions)
    }

    private func rowContent(for entry: SessionListEntry, connection: ServerConnection) -> SessionListRowContent {
        let rowStartNs = SessionListPerf.timestampNs()
        let content = SessionListRowContent.make(
            entry: entry,
            connection: connection,
            // A session of an open thread that runs in another workspace names it on its row.
            workspaceContext: foreignWorkspaceName(for: entry.session, connection: connection),
            foreignWorkspaceName: { foreignWorkspaceName(for: $0, connection: connection) },
            searchSnippet: searchStore.snippetsBySessionId[entry.session.id],
            lockTarget: rowActions.lockTarget,
            callBadge: root.liveVoiceCalls.rowBadge(serverId: serverId, sessionId: entry.session.id)
        )
        SessionListPerf.recordRowCompute(
            durationMs: Int((SessionListPerf.timestampNs() &- rowStartNs) / 1_000_000),
            rowCount: 1,
            workspaceId: workspaceId
        )
        return content
    }

    /// Workspace name for a session that runs in another workspace; this list's own workspace is implied.
    private func foreignWorkspaceName(for session: Session, connection: ServerConnection) -> String? {
        guard let id = session.workspaceId, id != workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == id }?.name ?? session.workspaceName
    }

    private func isGroupExpanded(_ groupID: String, day: Date, now: Date, calendar: Calendar) -> Bool {
        if state.expandedStoppedGroupIDs.contains(groupID) { return true }
        if state.collapsedStoppedGroupIDs.contains(groupID) { return false }
        return SessionInboxStoppedDayPolicy.isExpandedByDefault(day: day, now: now, calendar: calendar)
    }

    private func isArchiveBucketExpanded(_ bucketId: String) -> Bool {
        state.expandedStoppedGroupIDs.contains(bucketId)
    }

    func toggle(_ toggle: GroupToggle) {
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

    func applySnapshot(_ detail: DetailState) {
        let data = viewData(detail)
        let connection = detail.connection
        let localsEnabled = !state.isImportingLocal
        var next = List.Snapshot()

        func append(_ items: [WorkspaceStoppedSessionGrouping.Item], to section: Section, archive: Bool) {
            next.append(openingThreads(items, connection: connection), to: section) { item -> Item in
                switch item {
                case .entry(let entry): return archive ? .archiveSession(entry.id) : .stoppedSession(entry.id)
                case .local(let local): return archive ? .archiveLocal(local.path) : .local(local.path)
                }
            } cell: { item in
                switch item {
                case .entry(let entry): List.Snapshot.Cell.entry(entry) { rowContent(for: $0, connection: connection) }
                case .local(let local): .row(.local(local, isEnabled: localsEnabled))
                }
            }
        }
        func appendSessions(_ entries: [SessionListEntry], to section: Section, title: String) {
            next.appendSection(section, header: .title(title))
            let rows = openingThreads(entries, connection: connection)
            next.append(sessions: rows, to: section, item: Item.session) { rowContent(for: $0, connection: connection) }
        }

        if detail.hasSearchQuery {
            if searchStore.isSearching && data.searchMatches.isEmpty && data.localFiltered.isEmpty {
                next.appendSection(.status, item: .searching, row: .searching)
            } else if data.searchMatches.isEmpty && data.localFiltered.isEmpty {
                let query = detail.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                next.appendSection(.status, item: .noMatches, row: .noMatches(query: query))
            } else {
                if !data.searchMatches.isEmpty {
                    appendSessions(data.searchMatches, to: .results, title: String(localized: "Results"))
                }
                if !data.localFiltered.isEmpty {
                    next.appendSection(.localResults, header: .title(String(localized: "Local Sessions")))
                    append(data.localFiltered.map(WorkspaceStoppedSessionGrouping.Item.local), to: .localResults, archive: false)
                }
            }
        } else {
            if !data.yourTurn.isEmpty {
                appendSessions(data.yourTurn, to: .yourTurn, title: SessionInboxSectionTitle.yourTurn)
            }
            if !data.working.isEmpty {
                appendSessions(data.working, to: .working, title: SessionInboxSectionTitle.working)
            }
            let now = Date()
            let calendar = Calendar.current
            let groups = WorkspaceStoppedSessionGrouping.groups(
                stoppedEntries: data.stopped,
                localSessions: data.localFiltered,
                rangeStart: recentRangeStart(now: now, calendar: calendar),
                calendar: calendar
            )
            for (index, group) in groups.enumerated() {
                let groupID = WorkspaceStoppedSessionGrouping.groupID(for: group.day)
                let section = Section.stopped(groupID)
                let isExpanded = isGroupExpanded(groupID, day: group.day, now: now, calendar: calendar)
                let title = SessionInboxStoppedDayPolicy.title(for: group.day, now: now, calendar: calendar)
                next.appendSection(section, header: .group(
                    title: index == 0 ? "Stopped · \(title)" : title,
                    isExpanded: isExpanded,
                    accessibilityIdentifier: "workspace.stoppedGroup.\(groupID)",
                    toggle: .stopped(groupID: groupID, isExpanded: isExpanded)
                ))
                if isExpanded {
                    append(group.items, to: section, archive: false)
                }
            }
            for bucket in state.archiveBuckets {
                let section = Section.archive(bucket.id)
                let isExpanded = isArchiveBucketExpanded(bucket.id)
                next.appendSection(section, header: .group(
                    title: "Stopped · \(WorkspaceStoppedSessionGrouping.title(bucket, now: now, calendar: calendar))",
                    detail: "\(bucket.itemCount)",
                    isExpanded: isExpanded,
                    accessibilityIdentifier: nil,
                    toggle: .archive(bucket)
                ))
                guard isExpanded else { continue }
                if state.loadingArchiveBucketIDs.contains(bucket.id) {
                    next.append([bucket.id], to: section, item: Item.archiveLoading) { _ in .row(.archiveLoading) }
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
                next.appendSection(.empty, item: .empty, row: .empty)
            }
        }
        list.apply(next)
    }

    /// Stopped-section items with each open thread's child rows listed after its root.
    private func openingThreads(
        _ items: [WorkspaceStoppedSessionGrouping.Item],
        connection: ServerConnection
    ) -> [WorkspaceStoppedSessionGrouping.Item] {
        items.flatMap { item -> [WorkspaceStoppedSessionGrouping.Item] in
            guard case .entry(let entry) = item else { return [item] }
            return openingThreads([entry], connection: connection).map { .entry($0) }
        }
    }

    private func openingThreads(_ entries: [SessionListEntry], connection: ServerConnection) -> [SessionListEntry] {
        let attention: (Session) -> SessionListAttentionCounts = {
            SessionListAttentionCounts(askCount: connection.sessionListAskCount(for: $0.id))
        }
        // A thread's fold is settled the first time it lists open, and kept, so a member starting or
        // stopping never unfolds the stopped rows under the person's hand.
        let expanded = SessionListEntries.expanded(
            entries, expandedRoots: state.expandedThreadRoots, stoppedFolds: state.threadStoppedFolds, attention: attention
        )
        if expanded.folds != state.threadStoppedFolds { state.threadStoppedFolds = expanded.folds }
        return expanded.rows
    }

    /// A state row, or a local session that imports and resumes on a tap.
    func configure(_ cell: UICollectionViewListCell, row: Row) {
        let palette = root.themeStore.activeThemeID.palette
        switch row {
        case .searching:
            cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(
                .loading(String(localized: "Searching sessions…")),
                palette: palette
            )
        case .noMatches(let query):
            cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(
                .noResults(query: query),
                palette: palette
            )
        case .empty:
            cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(
                .empty(
                    title: String(localized: "No Sessions"),
                    systemImage: "terminal",
                    message: String(localized: "Tap Message to compose a Quick Session in this worktree.")
                ),
                palette: palette
            )
        case .archiveLoading:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Loading older sessions…")
            content.textProperties.color = palette.ui.comment
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
        case .local(let local, let isEnabled):
            cell.contentConfiguration = LocalSessionRowConfiguration(
                session: local,
                isEnabled: isEnabled,
                themeID: root.themeStore.activeThemeID
            ) { [weak self] in
                Task { await self?.importAndResumeLocal(local) }
            }
        }
    }
}
