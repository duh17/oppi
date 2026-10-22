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
        let workspace: Workspace
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
                    workspace: workspace,
                    kind: .workspaceFile,
                    path: relativePath
                )
            }
            return ResolvedLink(
                serverId: serverId,
                workspace: workspace,
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
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            shouldNavigate: { [weak self] in self?.isCurrent(generation) ?? false }
        ) { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .workspaceLinkedFileWillOpen,
                object: target.sourceSessionId,
                userInfo: [Notification.Name.workspaceLinkedFileSourceServerIDKey: target.serverId]
            )
            navigation.openReferencedWorkspaceLinkedFile(
                target,
                sourceSession: target.sourceSessionId.map {
                    WorkspaceSessionNavTarget(
                        serverId: target.serverId,
                        sessionId: $0,
                        workspaceId: target.workspaceId
                    )
                }
            )
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
            guard let connection = coordinator.connection(for: sourceServerID) else {
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
            guard let connection = coordinator.connection(for: sourceServerID),
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

        let listing: DirectoryListingResponse
        do {
            listing = try await apiClient.listWorkspaceDirectory(
                workspaceId: workspaceID,
                path: directoryPath,
                worktreeId: worktreeID
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
            return .truncated
        }
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
            let previousServerId = coordinator.activeServerId
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
                origin: .inAppHyperlink,
                previousServerId: previousServerId,
                generation: generation
            )

        case .workspaceFile(let file):
            guard let connection = coordinator.connection(for: file.serverID),
                  let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == file.workspaceID }) else {
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
                guard let self else { return }
                postWorkspaceLinkedFileWillOpen(reference: reference)
                navigation.openReferencedWorkspaceLinkedFile(
                    .workspaceFile(
                        serverId: file.serverID,
                        workspaceId: file.workspaceID,
                        worktreeId: file.worktreeID,
                        path: file.path,
                        lineAnchor: reference.lineAnchor,
                        sourceSessionId: reference.sourceSessionID
                    ),
                    workspace: WorkspaceNavTarget(serverId: file.serverID, workspace: workspace),
                    sourceSession: reference.sourceSessionID.flatMap { sourceSessionID in
                        reference.sourceServerID.map { sourceServerID in
                            WorkspaceSessionNavTarget(
                                serverId: sourceServerID,
                                sessionId: sourceSessionID
                            )
                        }
                    }
                )
            }
            return .finished

        case .hostFile(let file):
            guard let connection = coordinator.connection(for: file.serverID) else {
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
                guard let self else { return }
                postWorkspaceLinkedFileWillOpen(reference: reference)
                // Host files stay on the current stack. Do not select another
                // workspace or pretend the file lives in this checkout.
                navigation.openReferencedWorkspaceLinkedFile(
                    .hostFile(
                        serverId: file.serverID,
                        workspaceId: reference.workspaceID ?? "",
                        path: file.path,
                        lineAnchor: reference.lineAnchor,
                        sourceSessionId: reference.sourceSessionID
                    ),
                    sourceSession: reference.sourceSessionID.flatMap { sourceSessionID in
                        reference.sourceServerID.map { sourceServerID in
                            WorkspaceSessionNavTarget(
                                serverId: sourceServerID,
                                sessionId: sourceSessionID
                            )
                        }
                    }
                )
            }
            return .finished
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

    func dismissCoveringDocumentOverlayThenNavigateIfCurrent(
        generation: UInt64,
        navigate: @escaping @MainActor () -> Void
    ) async {
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            shouldNavigate: { [weak self] in self?.isCurrent(generation) ?? false },
            navigate: navigate
        )
    }

    // MARK: - File links

    func handleFileLink(
        _ payload: FileLinkPayload,
        generation: UInt64
    ) async -> AppOpenOutcome {
        guard let resolution = resolveFileLink(payload) else {
            toast("Could not open this file link")
            return .finished
        }
        guard await scopedLock.authorize(
            WorkspaceLinkedFileViewController.lockTarget(for: resolution.target)
        ), isCurrent(generation) else { return .finished }
        let switched = await openServer(resolution.target.serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            toastUnreachableIfFirstAttempt(resolution.target.serverId)
            return .unreachable
        }

        let workspace: WorkspaceNavTarget?
        if case .workspaceFile = resolution.target.kind {
            workspace = WorkspaceNavTarget(
                serverId: resolution.target.serverId,
                workspace: resolution.workspace
            )
        } else {
            workspace = nil
        }
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            shouldNavigate: { [weak self] in self?.isCurrent(generation) ?? false }
        ) { [weak self] in
            self?.navigation.openWorkspaceLinkedFile(resolution.target, workspace: workspace)
        }
        return .finished
    }

    func resolveFileLink(
        _ payload: FileLinkPayload
    ) -> (target: WorkspaceLinkedFileNavTarget, workspace: Workspace)? {
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
        return (
            target: WorkspaceLinkedFileNavTarget(
                serverId: resolution.serverId,
                workspaceId: payload.workspaceID,
                kind: kind
            ),
            workspace: resolution.workspace
        )
    }
}
