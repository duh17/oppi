import Foundation

/// The app's side of `PaneRoute`: which shell screens have a link, which
/// screen a linked entry opens as, and what the app knows of an entry's
/// server and content now, for `PaneLeafState.resolve`.
@MainActor
enum PaneEntries {
    // MARK: Shell routes to entries

    /// The primary leaf's stack for these screens above its root: the session
    /// list (of the workspace when the first screen is one), then each
    /// screen, with `.local` for a screen that has no link.
    static func primaryStack(_ elements: [WorkspaceStackRouteElement], rootServerId: String) -> [PaneStackEntry] {
        var elements = elements[...]
        var root = PaneStackEntry(serverId: rootServerId, route: .sessions(workspace: nil))
        if case .workspace(let target)? = elements.first {
            root = PaneStackEntry(serverId: target.serverId, route: .sessions(workspace: target.workspace.id))
            elements = elements.dropFirst()
        }
        return [root] + elements.map { element in
            entry(for: element) ?? PaneStackEntry(serverId: rootServerId, route: .local(PaneLocalToken(raw: "screen")))
        }
    }

    /// The entry a screen shows; nil for a screen with no link (settings,
    /// readers, a worktree's or the host's file browser, which links do not
    /// name yet), and for a file whose lock or path comes from where it was
    /// opened: a host file, or a file opened from a chat other than its own
    /// session's copy. A link cannot carry that origin yet, and restoring
    /// without it would show the file under a weaker lock.
    static func entry(for element: WorkspaceStackRouteElement) -> PaneStackEntry? {
        switch element {
        case .workspace(let target):
            return PaneStackEntry(serverId: target.serverId, route: .sessions(workspace: target.workspace.id))
        case .session(let target):
            return PaneStackEntry(serverId: target.serverId, route: .session(target.sessionId))
        case .fileBrowser(let target):
            guard case .workspace(let workspaceId, nil) = target.scope else { return nil }
            return PaneStackEntry(
                serverId: target.serverId,
                route: .files(workspace: workspaceId, path: target.path.isEmpty ? nil : target.path)
            )
        case .linkedFile(let target):
            guard target.controlSessionId == nil else { return nil }
            let line = target.lineAnchor?.range.lowerBound
            switch target.kind {
            case .workspaceFile(let path, _):
                guard target.sourceSessionId == nil else { return nil }
                return PaneStackEntry(
                    serverId: target.serverId,
                    route: .file(.workspace(id: target.workspaceId, worktree: target.worktreeId), path: path, line: line)
                )
            case .sessionFile(let path, _, let sessionId):
                guard target.sourceSessionId == nil || target.sourceSessionId == sessionId else { return nil }
                return PaneStackEntry(serverId: target.serverId, route: .file(.session(sessionId), path: path, line: line))
            case .hostFile:
                return nil
            }
        case .paneEntry(let entry):
            return entry
        case .chatReader, .workspaceConfiguration, .utility, .serverDetails, .modelProviders,
             .serverResourceDetail, .serverSkillBrowser, .serverSkillFile:
            return nil
        }
    }

    // MARK: Entries to shell routes

    /// The connection an entry reads: its own server's, never the window's.
    private static func connection(_ serverId: String, _ coordinator: ConnectionCoordinator) -> ServerConnection? {
        coordinator.connection(for: serverId)
    }

    /// Workspace `id` on `serverId`, and the host that server is reached at
    /// (a terminal leaf's SSH host).
    static func workspace(
        _ id: String, serverId: String, coordinator: ConnectionCoordinator
    ) -> (workspace: Workspace, host: String)? {
        guard let connection = connection(serverId, coordinator),
              let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == id }) else { return nil }
        return (workspace, connection.credentials?.host ?? coordinator.serverStore.server(for: serverId)?.host ?? "")
    }

    /// The screen `entry` opens as when its content is known; nil while it
    /// is not (or for a route the primary leaf has no screen for yet).
    static func element(for entry: PaneStackEntry, coordinator: ConnectionCoordinator) -> WorkspaceStackRouteElement? {
        guard let connection = connection(entry.serverId, coordinator) else { return nil }
        let serverId = entry.serverId
        func workspace(_ id: String) -> Workspace? {
            connection.workspaceStore.workspaces.first { $0.id == id }
        }
        func anchor(_ line: Int?) -> SourceLineAnchor? {
            line.flatMap { SourceLineAnchor(startLine: $0, endLine: $0) }
        }
        switch entry.route {
        case .sessions(let workspaceId?):
            return workspace(workspaceId).map { .workspace(WorkspaceNavTarget(serverId: serverId, workspace: $0)) }
        case .session(let id):
            guard let session = connection.sessionStore.session(id: id) else { return nil }
            return .session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: id, workspaceId: session.workspaceId))
        case .file(.workspace(let workspaceId, let worktree), let path, let line):
            guard workspace(workspaceId) != nil else { return nil }
            return .linkedFile(.workspaceFile(
                serverId: serverId, workspaceId: workspaceId, worktreeId: worktree, path: path, lineAnchor: anchor(line)
            ))
        case .file(.session(let sessionId), let path, let line):
            guard let workspaceId = connection.sessionStore.session(id: sessionId)?.workspaceId else { return nil }
            return .linkedFile(.sessionFile(
                serverId: serverId, workspaceId: workspaceId, sessionId: sessionId, path: path,
                lineAnchor: anchor(line), sourceSessionId: sessionId
            ))
        case .file(.host, let path, let line):
            // A host file has no workspace; the linked file reads it on its server.
            return .linkedFile(.hostFile(serverId: serverId, workspaceId: "", path: path, lineAnchor: anchor(line)))
        case .files(let workspaceId, let path):
            guard workspace(workspaceId) != nil else { return nil }
            return .fileBrowser(FileBrowserNavTarget(
                serverId: serverId,
                scope: .workspace(workspaceId: workspaceId, worktreeId: nil),
                path: path ?? ""
            ))
        case .sessions(nil), .thread, .git, .commit, .panel, .browser, .local, .unsupported:
            return nil
        }
    }

    // MARK: What the app knows

    /// The entry's server as its connection reports it.
    static func connectionStatus(serverId: String, coordinator: ConnectionCoordinator) -> PaneConnectionStatus {
        guard let server = coordinator.serverStore.server(for: serverId) else { return .removed }
        // The badge the server switcher shows, so a pane and the switcher agree.
        switch HostSwitcherBadgeState.make(for: server, coordinator: coordinator) {
        case .connected: return .connected
        case .connecting, .recovering: return .connecting
        case .disconnected, .syncFailed:
            return .unreachable(connection(serverId, coordinator)?.unreachableRemedy ?? .retry)
        }
    }

    /// Whether the entry's content exists, from the local stores and, for a
    /// session the stores do not hold, the server's answer to a lookup
    /// (`lookedUp`). A workspace is absent only once its server's list came
    /// back without it.
    static func presence(
        of entry: PaneStackEntry,
        coordinator: ConnectionCoordinator,
        lookedUp: PaneContentPresence
    ) -> PaneContentPresence {
        if element(for: entry, coordinator: coordinator) != nil { return .present }
        guard let connection = connection(entry.serverId, coordinator) else { return .unknown }
        switch entry.route {
        case .panel(let sessionId, _):
            // A panel opens beside its chat, so it is there when its session is.
            return connection.sessionStore.session(id: sessionId) != nil ? .present : lookedUp
        case .session, .file(.session, _, _):
            return lookedUp
        case .sessions(let workspaceId?), .files(let workspaceId, _), .file(.workspace(let workspaceId, _), _, _):
            let synced = connection.workspaceStore.lastSuccessfulSyncAt != nil
            let known = connection.workspaceStore.workspaces.contains { $0.id == workspaceId }
            return synced && !known ? .absent : .unknown
        default:
            return .unknown
        }
    }

    static func state(
        of entry: PaneStackEntry,
        coordinator: ConnectionCoordinator,
        lookedUp: PaneContentPresence = .unknown
    ) -> PaneLeafState {
        PaneLeafState.resolve(
            route: entry.route,
            connection: connectionStatus(serverId: entry.serverId, coordinator: coordinator),
            presence: presence(of: entry, coordinator: coordinator, lookedUp: lookedUp),
            isLocked: ScopedLockService.shared.isLocked(lockTarget(entry))
        )
    }

    /// The scoped lock that holds the entry's content; Unlock asks for it.
    static func lockTarget(_ entry: PaneStackEntry) -> ScopedLockTarget {
        let locks = ScopedLockService.shared
        switch entry.route {
        case .session(let id), .file(.session(let id), _, _), .panel(let id, _):
            return locks.sessionTarget(serverId: entry.serverId, sessionId: id)
        case .sessions(let workspaceId?), .files(let workspaceId, _), .file(.workspace(let workspaceId, _), _, _):
            return .workspace(serverId: entry.serverId, workspaceId: workspaceId)
        default:
            return .server(entry.serverId)
        }
    }
}
