import Foundation
import UIKit

// Resource, session-file, and file-link opens. The resolution rules are the
// ones the timeline and extension surfaces always used; the owner adds App
// Lock, launch, and server readiness before any of it runs.

/// A `[[link]]` that matched more than one resource; the user picks one.
struct PendingResourceReferenceChoice {
    let reference: ResourceReference
    let matches: [ResourceReferenceMatch]
}

/// A `file://` link inside a workspace, resolved when it opens.
struct FileLinkPayload: Equatable, Sendable {
    let workspaceID: String
    let filePath: String
    let originalURL: URL
}

/// Resolves a `file://` payload to the workspace (and server) that owns it.
enum FileLinkOpenPolicy {
    enum Kind: Equatable {
        case workspaceFile
        case hostFile
    }

    struct ResolvedLink: Equatable {
        let serverId: String
        let kind: Kind
        let path: String

        var relativePath: String { path }

        var fileName: String {
            (path as NSString).lastPathComponent
        }
    }

    static func resolve(
        payload: FileLinkPayload,
        workspacesByServer: [String: [Workspace]]
    ) -> ResolvedLink? {
        for (serverId, workspaces) in workspacesByServer {
            guard let workspace = workspaces.first(where: { $0.id == payload.workspaceID }) else {
                continue
            }
            if let relativePath = payload.filePath.workspaceRelativePath(hostMount: workspace.hostMount) {
                return ResolvedLink(
                    serverId: serverId,
                    kind: .workspaceFile,
                    path: relativePath
                )
            }
            return ResolvedLink(
                serverId: serverId,
                kind: .hostFile,
                path: payload.filePath
            )
        }
        return nil
    }
}

extension AppOpener {
    // MARK: - Root prompts

    /// The user picked one of several `[[link]]` matches.
    func startOpeningResourceReferenceMatch(_ match: ResourceReferenceMatch) {
        guard let reference = pendingResourceReferenceChoice?.reference else { return }
        pendingResourceReferenceChoice = nil
        generation &+= 1
        let generation = generation
        currentTask?.cancel()
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.openResourceReferenceMatch(
                match,
                reference: reference,
                generation: generation
            )
            // An unreachable choice parks like an unreachable single match:
            // the next foreground resolves the link again.
            self.finish(.resourceReference(reference), outcome: outcome, generation: generation)
        }
    }

    func cancelResourceReferenceRequest() {
        // A newer open already ended this choice; a late Cancel from its
        // sheet must not cancel that open.
        guard pendingResourceReferenceChoice != nil else { return }
        generation &+= 1
        currentTask?.cancel()
        currentTask = nil
        pendingResourceReferenceChoice = nil
    }

    // MARK: - Session files

    nonisolated static func sessionFileTarget(
        for reference: ResourceReference
    ) -> WorkspaceLinkedFileNavTarget? {
        guard let serverID = reference.sourceServerID,
              let workspaceID = reference.workspaceID,
              let sessionID = reference.sourceSessionID,
              let path = reference.fileCandidatePath,
              !serverID.isEmpty,
              !workspaceID.isEmpty,
              !sessionID.isEmpty,
              !path.isEmpty else {
            return nil
        }
        return .sessionFile(
            serverId: serverID,
            workspaceId: workspaceID,
            sessionId: sessionID,
            path: path,
            lineAnchor: reference.lineAnchor,
            headingAnchor: reference.headingAnchor,
            sourceSessionId: sessionID
        )
    }

    func openSessionFileReference(
        _ reference: ResourceReference,
        generation: UInt64
    ) async -> AppOpenOutcome {
        guard let target = Self.sessionFileTarget(for: reference) else {
            toast("Could not open this session file")
            return .finished
        }
        guard await scopedLock.authorize(
            WorkspaceLinkedFileViewController.lockTarget(for: target)
        ), isCurrent(generation) else {
            return .finished
        }
        let switched = await openServer(target.serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            toastUnreachableIfFirstAttempt(target.serverId)
            return .unreachable
        }
        await dismissCoveringDocumentOverlayThenNavigateIfCurrent(generation: generation) { [weak self] in
            self?.openLinkedFile(target, reference: reference)
        }
        return .finished
    }

// MARK: - Resource references

    func handleResourceReference(
        _ reference: ResourceReference,
        generation: UInt64
    ) async -> AppOpenOutcome {
#if DEBUG
        if let handler = _resourceReferenceHandlerForTesting, handler(reference) {
            return .finished
        }
#endif
        guard !ResourceReferenceSelfLinkPolicy.isCurrentSession(reference) else {
            return .finished
        }
        let sessionMatches = reference.lineAnchor == nil
            ? knownSessionMatches(for: reference.target)
            : []
        let fileLookup: ResourceReferenceFileLookup
        do {
            fileLookup = try await currentFileMatches(for: reference)
        } catch is CancellationError {
            // A superseded tap is dropped rather than surfaced as "right now".
            return .finished
        } catch {
            // Host-file lookup never throws; unexpected workspace throws stay
            // "right now" instead of looking like a true unresolved file.
            fileLookup = .unavailable
        }
        guard isCurrent(generation) else { return .finished }

        switch ResourceReferenceCandidateCollector.resolve(
            reference,
            sessionMatches: sessionMatches,
            fileLookup: fileLookup
        ) {
        case .unavailable:
            toast("Could not resolve [[\(reference.target)]] right now")
        case .authorizationFailed:
            toast("Could not authorize host file [[\(reference.target)]]")
        case .resolution(.unresolved(let target)):
            // No file by that name: a folder opens in the File Browser.
            if let folder = await folderTarget(for: reference) {
                guard isCurrent(generation) else { return .finished }
                return await openFolder(folder, generation: generation)
            }
            guard isCurrent(generation) else { return .finished }
            toast("Could not resolve [[\(target)]]")
        case .resolution(.resolved(let match)):
            return await openResourceReferenceMatch(
                match,
                reference: reference,
                generation: generation
            )
        case .resolution(.ambiguous(let matches)):
            guard isCurrent(generation) else { return .finished }
            pendingResourceReferenceChoice = PendingResourceReferenceChoice(
                reference: reference,
                matches: matches
            )
        }
        return .finished
    }

    func knownSessionMatches(for target: String) -> [ResourceReferenceMatch] {
        coordinator.connections.flatMap { serverID, connection in
            connection.sessionStore.sessions.compactMap { session in
                guard session.id == target else { return nil }
                let workspaceName = session.workspaceId.flatMap { workspaceID in
                    connection.workspaceStore.workspaces.first { $0.id == workspaceID }?.name
                }
                return .session(SessionResourceReference(
                    serverID: serverID,
                    sessionID: session.id,
                    workspaceID: session.workspaceId,
                    displayName: session.displayTitle,
                    workspaceName: workspaceName,
                    serverName: resourceReferenceServerName(serverID)
                ))
            }
        }
    }

    func currentFileMatches(
        for reference: ResourceReference
    ) async throws -> ResourceReferenceFileLookup {
        switch ResourceReferenceFileLookupPolicy.kind(for: reference) {
        case .hostFile:
            return await currentHostFileMatches(for: reference)
        case .workspaceFile:
            return try await currentWorkspaceFileMatches(for: reference)
        }
    }

    func currentHostFileMatches(
        for reference: ResourceReference
    ) async -> ResourceReferenceFileLookup {
        guard let fileCandidatePath = reference.fileCandidatePath else {
            return .notApplicable
        }

        let scopes: [(serverID: String, connection: ServerConnection)]
        if let sourceServerID = reference.sourceServerID {
            guard let connection = sourceConnection(of: reference) else {
                return .unavailable
            }
            scopes = [(sourceServerID, connection)]
        } else {
            scopes = coordinator.connections.map { ($0.key, $0.value) }
            guard !scopes.isEmpty else { return .unavailable }
        }

        var matches: [ResourceReferenceMatch] = []
        for scope in scopes {
            guard let apiClient = scope.connection.apiClient else { return .unavailable }
            do {
                let resolvedPath = try await apiClient.resolveHostFile(path: fileCandidatePath)
                try Task.checkCancellation()
                if let resolvedPath {
                    matches.append(.hostFile(HostFileResourceReference(
                        serverID: scope.serverID,
                        path: resolvedPath,
                        serverName: resourceReferenceServerName(scope.serverID)
                    )))
                }
            } catch let APIError.server(status, _) where status == 404 {
                continue
            } catch let APIError.server(status, _) where status == 401 || status == 403 {
                return .authorizationFailed
            } catch let APIError.codedServer(status, _, _) where status == 401 || status == 403 {
                return .authorizationFailed
            } catch {
                return .unavailable
            }
        }
        return .complete(matches)
    }

    func currentWorkspaceFileMatches(
        for reference: ResourceReference
    ) async throws -> ResourceReferenceFileLookup {
        guard reference.kind == .workspaceFile,
              let workspaceID = reference.workspaceID,
              let fileCandidatePath = reference.fileCandidatePath else {
            return .notApplicable
        }

        let scopes: [(serverID: String, connection: ServerConnection, workspace: Workspace)]
        if let sourceServerID = reference.sourceServerID {
            guard let connection = sourceConnection(of: reference),
                  let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
                return .unavailable
            }
            scopes = [(sourceServerID, connection, workspace)]
        } else {
            scopes = coordinator.connections.compactMap { serverID, connection in
                guard let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == workspaceID }) else {
                    return nil
                }
                return (serverID, connection, workspace)
            }
            guard !scopes.isEmpty else { return .unavailable }
        }

        var matches: [ResourceReferenceMatch] = []
        for scope in scopes {
            guard let apiClient = scope.connection.apiClient else { return .unavailable }

            // Resolve the source session's checkout. A missing or foreign
            // source session means the checkout is unknown: list the main
            // checkout (nil) instead of failing closed, because a gitignored
            // workspace file (for example `.pi/skills/...`) may exist only on
            // the main checkout.
            let sourceSessionResolved: Bool
            let sourceSessionWorktreeID: String?
            if let sourceSessionID = reference.sourceSessionID,
               let sourceSession = scope.connection.sessionStore.session(id: sourceSessionID),
               sourceSession.workspaceId == workspaceID {
                sourceSessionResolved = true
                sourceSessionWorktreeID = sourceSession.worktreeId
            } else {
                sourceSessionResolved = false
                sourceSessionWorktreeID = nil
            }
            let firstWorktreeID = WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
                sourceSessionResolved: sourceSessionResolved,
                sourceSessionWorktreeID: sourceSessionWorktreeID
            )

            var outcome = try await exactFileListingResult(
                fileCandidatePath,
                workspaceID: workspaceID,
                worktreeID: firstWorktreeID,
                apiClient: apiClient
            )
            let effectiveWorktreeID = WorkspaceWikiLinkFileLookupPolicy.resolvedCheckout(
                sourceSessionResolved: sourceSessionResolved,
                sourceSessionWorktreeID: sourceSessionWorktreeID,
                firstOutcome: outcome
            )

            // A git-ignored workspace file (for example `.pi/skills/...`) is
            // not checked out into a fresh worktree. If the worktree lookup is
            // a deterministic absence, retry the same workspace-relative path
            // against the main checkout before declaring the link unresolvable.
            // The server's realpath sandbox still bounds both lookups.
            if effectiveWorktreeID != firstWorktreeID {
                outcome = try await exactFileListingResult(
                    fileCandidatePath,
                    workspaceID: workspaceID,
                    worktreeID: effectiveWorktreeID,
                    apiClient: apiClient
                )
            }

            switch outcome {
            case .present:
                matches.append(.workspaceFile(WorkspaceFileResourceReference(
                    serverID: scope.serverID,
                    workspaceID: workspaceID,
                    worktreeID: effectiveWorktreeID,
                    path: fileCandidatePath,
                    workspaceName: scope.workspace.name,
                    serverName: resourceReferenceServerName(scope.serverID)
                )))
            case .absent:
                break
            case .truncated, .unavailable:
                return .unavailable
            }
        }

        return .complete(matches)
    }

    func exactFileListingResult(
        _ filePath: String,
        workspaceID: String,
        worktreeID: String?,
        apiClient: APIClient
    ) async throws -> ExactFileListingOutcome {
        let fileName = (filePath as NSString).lastPathComponent
        let parent = (filePath as NSString).deletingLastPathComponent
        let directoryPath = parent.isEmpty || parent == "." ? "" : parent + "/"

        // Page through the folder until the name turns up or the pages end.
        var after: String?
        repeat {
            let listing: DirectoryListingResponse
            do {
                listing = try await apiClient.listWorkspaceDirectory(
                    workspaceId: workspaceID,
                    path: directoryPath,
                    worktreeId: worktreeID,
                    after: after
                )
            } catch {
                // A superseded tap must stay silent: propagate cancellation instead
                // of turning it into a transient "right now" failure.
                try Task.checkCancellation()
                return WorkspaceWikiLinkFileLookupPolicy.isDeterministicAbsence(error)
                    ? .absent
                    : .unavailable
            }

            try Task.checkCancellation()
            switch ResourceFileCandidatePolicy.directoryResult(
                fileName: fileName,
                entries: listing.entries,
                truncated: listing.truncated
            ) {
            case .some(true):
                return .present
            case .some(false):
                return .absent
            case .none:
                // More pages follow; a server that does not page cannot say.
                guard let next = listing.next else { return .truncated }
                after = next
            }
        } while true
    }

    func openResourceReferenceMatch(
        _ match: ResourceReferenceMatch,
        reference: ResourceReference,
        generation: UInt64
    ) async -> AppOpenOutcome {
        switch match {
        case .session(let session):
            guard !ResourceReferenceSelfLinkPolicy.isCurrentSession(reference) else {
                return .finished
            }
            guard let connection = coordinator.connection(for: session.serverID) else {
                guard isCurrent(generation) else { return .finished }
                toast("Could not open session \(session.sessionID)")
                return .finished
            }
            guard await scopedLock.authorize(
                scopedLock.sessionTarget(serverId: session.serverID, sessionId: session.sessionID)
            ), isCurrent(generation) else { return .finished }
            let previousServerId = windowServerId
            let switched = await openServer(session.serverID, generation: generation)
            guard isCurrent(generation) else { return .finished }
            guard switched else {
                toastUnreachableIfFirstAttempt(session.serverID)
                return .unreachable
            }
            // A `[[session]]` match opens like a timeline session link.
            return await openPreparedSession(
                serverId: session.serverID,
                sessionId: session.sessionID,
                workspaceIdHint: nil,
                connection: connection,
                origin: .link,
                previousServerId: previousServerId,
                generation: generation
            )

        case .workspaceFile(let file):
            guard let connection = coordinator.connection(for: file.serverID),
                  connection.workspaceStore.workspaces.contains(where: { $0.id == file.workspaceID }) else {
                guard isCurrent(generation) else { return .finished }
                toast("Could not open file \(file.path)")
                return .finished
            }
            guard await scopedLock.authorize(
                .workspace(serverId: file.serverID, workspaceId: file.workspaceID)
            ), isCurrent(generation) else { return .finished }
            let switched = await openServer(file.serverID, generation: generation)
            guard isCurrent(generation) else { return .finished }
            guard switched else {
                toastUnreachableIfFirstAttempt(file.serverID)
                return .unreachable
            }

            await dismissCoveringDocumentOverlayThenNavigateIfCurrent(generation: generation) { [weak self] in
                self?.openLinkedFile(Self.linkedFileTarget(file, reference: reference), reference: reference)
            }
            return .finished

        case .hostFile(let file):
            guard coordinator.connection(for: file.serverID) != nil else {
                guard isCurrent(generation) else { return .finished }
                toast("Could not open file \(file.path)")
                return .finished
            }
            guard await scopedLock.authorize(.server(file.serverID)),
                  isCurrent(generation) else { return .finished }
            let switched = await openServer(file.serverID, generation: generation)
            guard isCurrent(generation) else { return .finished }
            guard switched else {
                toastUnreachableIfFirstAttempt(file.serverID)
                return .unreachable
            }

            await dismissCoveringDocumentOverlayThenNavigateIfCurrent(generation: generation) { [weak self] in
                self?.openLinkedFile(Self.linkedFileTarget(file, reference: reference), reference: reference)
            }
            return .finished
        }
    }

    /// The file a `[[path]]` match opens, at the reference's anchors.
    nonisolated static func linkedFileTarget(
        _ file: WorkspaceFileResourceReference,
        reference: ResourceReference
    ) -> WorkspaceLinkedFileNavTarget {
        .workspaceFile(
            serverId: file.serverID,
            workspaceId: file.workspaceID,
            worktreeId: file.worktreeID,
            path: file.path,
            lineAnchor: reference.lineAnchor,
            headingAnchor: reference.headingAnchor,
            sourceSessionId: reference.sourceSessionID
        )
    }

    /// The host file a `[[/path]]` match opens; it keeps no workspace of its own.
    nonisolated static func linkedFileTarget(
        _ file: HostFileResourceReference,
        reference: ResourceReference
    ) -> WorkspaceLinkedFileNavTarget {
        .hostFile(
            serverId: file.serverID,
            workspaceId: reference.workspaceID ?? "",
            path: file.path,
            lineAnchor: reference.lineAnchor,
            headingAnchor: reference.headingAnchor,
            sourceSessionId: reference.sourceSessionID
        )
    }

    // MARK: - Opening in a pane

    /// Whether a link names a file, folder or web page an item menu can open
    /// in a pane (`PaneOpenMenu`): a `[[path]]`, a session's file, a
    /// `file://` link, an `oppi://file` or `oppi://files` link, or an
    /// http(s) page.
    nonisolated static func opensInPane(_ request: AppOpenRequest) -> Bool {
        switch request {
        case .resourceReference(let reference):
            return reference.fileCandidatePath?.isEmpty == false
        case .sessionFile, .fileLink, .webLink:
            return true
        case .pane(let link, _):
            switch link.route {
            case .file, .files: return true
            default: return false
            }
        default:
            return false
        }
    }

    /// What a link opens as in a pane, found as a tap finds it: a `[[path]]`
    /// resolves against its checkout (a file, else a folder; an ambiguous
    /// one is left to the tap's chooser), and a web page opens on the
    /// window's server unless it turned Web Pages in Panes off. Nil when it
    /// names nothing this device can open in a pane.
    func paneContent(for request: AppOpenRequest) async -> PaneOpenContent? {
        switch request {
        case .resourceReference(let reference):
            guard let lookup = try? await currentFileMatches(for: reference) else { return nil }
            switch ResourceReferenceCandidateCollector.resolve(reference, sessionMatches: [], fileLookup: lookup) {
            case .resolution(.resolved(.workspaceFile(let file))):
                return PaneOpenContent(file: Self.linkedFileTarget(file, reference: reference))
            case .resolution(.resolved(.hostFile(let file))):
                return PaneOpenContent(file: Self.linkedFileTarget(file, reference: reference))
            case .resolution(.unresolved):
                return await folderTarget(for: reference).map { PaneOpenContent(folder: $0) }
            default:
                return nil
            }
        case .webLink(let url):
            guard let serverId = windowServerId, coordinator.server(serverId, offers: .browserPane) else { return nil }
            return PaneOpenContent(entry: PaneStackEntry(serverId: serverId, route: .browser(url)))
        case .sessionFile(let reference):
            return Self.sessionFileTarget(for: reference).map { PaneOpenContent(file: $0) }
        case .fileLink(let payload):
            return resolveFileLink(payload).map { PaneOpenContent(file: $0) }
        case .pane(let link, let sourceServerID):
            guard Self.opensInPane(request), let serverId = link.server ?? sourceServerID ?? windowServerId else { return nil }
            return PaneOpenContent(entry: PaneStackEntry(serverId: serverId, route: link.route))
        default:
            return nil
        }
    }

    /// Tells a mounted source chat to freeze its scroll anchor before the open
    /// replaces the visible screen.
    func postWorkspaceLinkedFileWillOpen(reference: ResourceReference) {
        guard let sourceSessionID = reference.sourceSessionID,
              let sourceServerID = reference.sourceServerID else {
            return
        }
        // Session IDs are only unique within one server. Keep this
        // pre-navigation capture scoped so another server's chat cannot freeze
        // its viewport when IDs happen to collide.
        NotificationCenter.default.post(
            name: .workspaceLinkedFileWillOpen,
            object: sourceSessionID,
            userInfo: [Notification.Name.workspaceLinkedFileSourceServerIDKey: sourceServerID]
        )
    }

    /// Closes a document viewer covering this opener's window, then runs
    /// `navigate` unless a newer open has taken over.
    func dismissCoveringDocumentOverlayThenNavigateIfCurrent(
        generation: UInt64,
        navigate: @escaping @MainActor () -> Void = {}
    ) async {
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            from: navigation.window?.rootViewController,
            shouldNavigate: { [weak self] in self?.isCurrent(generation) ?? false },
            navigate: navigate
        )
    }

    // MARK: - File links

    func handleFileLink(
        _ payload: FileLinkPayload,
        generation: UInt64
    ) async -> AppOpenOutcome {
        guard let target = resolveFileLink(payload) else {
            toast("Could not open this file link")
            return .finished
        }
        guard await scopedLock.authorize(
            WorkspaceLinkedFileViewController.lockTarget(for: target)
        ), isCurrent(generation) else { return .finished }
        let switched = await openServer(target.serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            toastUnreachableIfFirstAttempt(target.serverId)
            return .unreachable
        }

        await dismissCoveringDocumentOverlayThenNavigateIfCurrent(generation: generation) { [weak self] in
            self?.openSideContent(PaneOpenContent(file: target), kind: .file)
        }
        return .finished
    }

    // MARK: - Folders

    /// The connection of the server a reference came from: its files and
    /// folders resolve there, never on the window's server.
    private func sourceConnection(of reference: ResourceReference) -> ServerConnection? {
        reference.sourceServerID.flatMap { coordinator.connection(for: $0) }
    }

    /// The folder a `[[path]]` or `[label](path/)` names when no file does: a
    /// folder in the reference's workspace checkout, or one in the host's
    /// home (`~/…`, the only host folders the File Browser reads). Nil when
    /// the server lists no folder there.
    func folderTarget(for reference: ResourceReference) async -> FileBrowserNavTarget? {
        guard let path = reference.fileCandidatePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              let serverID = reference.sourceServerID,
              let connection = sourceConnection(of: reference), let api = connection.apiClient else { return nil }
        switch ResourceReferenceFileLookupPolicy.kind(for: reference) {
        case .hostFile:
            guard path == "~" || path.hasPrefix("~/") else { return nil }
            let folder = FileBrowserHostHomePath.directoryPath(rawPath: path)
            guard (try? await api.listHostDirectory(path: folder)) != nil else { return nil }
            return FileBrowserNavTarget(serverId: serverID, scope: .hostHome, path: folder)
        case .workspaceFile:
            guard let workspaceID = reference.workspaceID else { return nil }
            // The source session's checkout, as its files resolve.
            let worktreeID = reference.sourceSessionID
                .flatMap { connection.sessionStore.session(id: $0) }
                .flatMap { $0.workspaceId == workspaceID ? $0.worktreeId : nil }
            let folder = path.hasSuffix("/") ? path : path + "/"
            guard (try? await api.listWorkspaceDirectory(workspaceId: workspaceID, path: folder, worktreeId: worktreeID)) != nil
            else { return nil }
            return FileBrowserNavTarget(serverId: serverID, workspaceId: workspaceID, worktreeId: worktreeID, path: folder)
        }
    }

    /// Opens a linked folder in the File Browser, beside the focused pane
    /// where there is room, once its lock allows.
    func openFolder(_ target: FileBrowserNavTarget, generation: UInt64) async -> AppOpenOutcome {
        let content = PaneOpenContent(folder: target)
        guard await scopedLock.authorize(content.lockTarget), isCurrent(generation) else { return .finished }
        let switched = await openServer(target.serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            toastUnreachableIfFirstAttempt(target.serverId)
            return .unreachable
        }
        await dismissCoveringDocumentOverlayThenNavigateIfCurrent(generation: generation) { [weak self] in
            self?.openSideContent(content, kind: .folder)
        }
        return .finished
    }

    func resolveFileLink(
        _ payload: FileLinkPayload
    ) -> WorkspaceLinkedFileNavTarget? {
        let workspacesByServer = Dictionary(
            uniqueKeysWithValues: coordinator.connections.map { serverId, connection in
                (serverId, connection.workspaceStore.workspaces)
            }
        )
        guard let resolution = FileLinkOpenPolicy.resolve(
            payload: payload,
            workspacesByServer: workspacesByServer
        ) else {
            return nil
        }
        let kind: WorkspaceLinkedFileKind
        switch resolution.kind {
        case .workspaceFile:
            kind = .workspaceFile(path: resolution.path, fileName: resolution.fileName)
        case .hostFile:
            kind = .hostFile(path: resolution.path, fileName: resolution.fileName)
        }
        return WorkspaceLinkedFileNavTarget(serverId: resolution.serverId, workspaceId: payload.workspaceID, kind: kind)
    }
}
