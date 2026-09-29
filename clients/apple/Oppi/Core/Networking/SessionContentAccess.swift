import Foundation

/// iOS owner of session-scoped content access: attachments, session files,
/// host files, Markdown media/sidecar resources, and tool-output capabilities for
/// assistant and tool rows.
///
/// `ServerConnection` stays authoritative for API-client installation,
/// authentication, and lifecycle. This adapter only reads the *current* client
/// and metadata through narrow capabilities each time an operation starts or
/// resumes, so cached rows can request content before the client or workspace
/// catalog is ready without pinning a stale client, runtime, or worktree.
///
/// Every content fetch (attachments, session files, host files, Markdown media) waits a
/// bounded time for readiness (`readinessAttempts` polls spaced `readinessPoll` apart),
/// honors task cancellation, and then resolves the origin (workspace, session, host, or
/// stored attachment) from the caller's bound source identity plus current metadata.
/// `toolOutputAccess` and `sessionFileReader` do not wait: they resolve synchronously from
/// the current client and return nil when the client or route scope/workspace is missing.
@MainActor
final class SessionContentAccess {
    static let readinessAttempts = 50
    static let defaultReadinessPoll: Duration = .milliseconds(100)

    private let currentAPIClient: @MainActor () -> APIClient?
    private let currentServerId: @MainActor () -> String?
    private let sessionStore: SessionStore
    private let workspaceStore: WorkspaceStore
    private let readinessPoll: Duration

    init(
        apiClient: @escaping @MainActor () -> APIClient?,
        serverId: @escaping @MainActor () -> String?,
        sessionStore: SessionStore,
        workspaceStore: WorkspaceStore,
        readinessPoll: Duration = SessionContentAccess.defaultReadinessPoll
    ) {
        self.currentAPIClient = apiClient
        self.currentServerId = serverId
        self.sessionStore = sessionStore
        self.workspaceStore = workspaceStore
        self.readinessPoll = readinessPoll
    }

    // MARK: - Stored session attachments

    func fetchSessionAttachment(
        sessionId: String,
        attachmentId: String,
        routeScope: SessionRouteScope? = nil
    ) async throws -> Data {
        let apiClient = try await waitForAPIClient()
        return try await apiClient.fetchSessionAttachment(
            scope: routeScope,
            sessionId: sessionId,
            attachmentId: attachmentId
        )
    }

    func makeSessionAttachmentMediaSource(
        sessionId: String,
        attachmentId: String,
        contentTypeHint: String?,
        sourceFileExtension: String?,
        routeScope: SessionRouteScope? = nil
    ) async throws -> AuthenticatedMediaSource {
        let apiClient = try await waitForAPIClient()
        return try await apiClient.makeSessionAttachmentMediaSource(
            scope: routeScope,
            sessionId: sessionId,
            attachmentId: attachmentId,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    // MARK: - Tool output

    /// Tool-output capabilities for `sessionId`, bound to the current API client and the
    /// caller's route scope. Nil when either is missing right now: unlike the operations
    /// above, this does not wait for readiness, so a timeline built before the client
    /// exists simply has no tool-output fetch, sidecar, or copy.
    func toolOutputAccess(
        sessionId: String,
        routeScope: SessionRouteScope?
    ) -> SessionToolOutputAccess? {
        guard let apiClient = currentAPIClient(), let routeScope else { return nil }
        return SessionToolOutputAccess(apiClient: apiClient, scope: routeScope, sessionId: sessionId)
    }

    // MARK: - Session files

    /// Session-file reader for user-message image pills, bound to the current API client
    /// and the caller's workspace and session. Nil when either is missing right now: like
    /// `toolOutputAccess`, this does not wait for readiness, so a row built before the
    /// client or workspace exists simply has no reader.
    func sessionFileReader(
        workspaceId: String?,
        sessionId: String
    ) -> ((_ path: String) async throws -> Data)? {
        guard let apiClient = currentAPIClient(), let workspaceId else { return nil }
        return { path in
            try await apiClient.getSessionFileData(
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: path
            )
        }
    }

    func fetchSessionFileData(
        workspaceId: String?,
        sessionId: String,
        path: String
    ) async throws -> Data {
        let context = try await waitForSessionFileContext(
            workspaceId: workspaceId,
            sessionId: sessionId
        )
        return try await context.apiClient.getSessionFileData(
            workspaceId: context.workspaceId,
            sessionId: sessionId,
            path: path
        )
    }

    func makeSessionFileMediaSource(
        workspaceId: String?,
        sessionId: String,
        path: String,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) async throws -> AuthenticatedMediaSource {
        let context = try await waitForSessionFileContext(
            workspaceId: workspaceId,
            sessionId: sessionId
        )
        return try await context.apiClient.makeSessionFileMediaSource(
            workspaceId: context.workspaceId,
            sessionId: sessionId,
            path: path,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    // MARK: - Markdown resources (host / session / workspace origins)

    func makeMarkdownVideoMediaSource(
        embed: MarkdownVideoEmbed,
        workspaceId: String?,
        sessionId: String?,
        worktreeId: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) async throws -> AuthenticatedMediaSource {
        let apiClient = try await waitForAPIClient()
        let scope = resolveMarkdownScope(
            workspaceId: workspaceId,
            sessionId: sessionId,
            worktreeId: worktreeId,
            capturedRuntime: workspaceRuntime
        )
        guard let route = MarkdownVideoMediaSourceRoute.resolve(
            embed: embed,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: scope.worktreeId,
            workspaceRuntime: scope.runtime
        ) else {
            throw APIError.server(status: 404, message: "Video source is unavailable")
        }
        let pathExtension = (embed.filePath as NSString).pathExtension
        return try await makeMediaSource(
            route: route,
            apiClient: apiClient,
            contentType: MediaMimeType.videoMimeType(forPathExtension: pathExtension),
            pathExtension: pathExtension
        )
    }

    func makeMarkdownAudioMediaSource(
        embed: MarkdownAudioEmbed,
        workspaceId: String?,
        sessionId: String?,
        worktreeId: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) async throws -> AuthenticatedMediaSource {
        let apiClient = try await waitForAPIClient()
        let scope = resolveMarkdownScope(
            workspaceId: workspaceId,
            sessionId: sessionId,
            worktreeId: worktreeId,
            capturedRuntime: workspaceRuntime
        )
        guard let route = MarkdownVideoMediaSourceRoute.resolve(
            embed: embed,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: scope.worktreeId,
            workspaceRuntime: scope.runtime
        ) else {
            throw APIError.server(status: 404, message: "Audio source is unavailable")
        }
        let pathExtension = (embed.filePath as NSString).pathExtension
        return try await makeMediaSource(
            route: route,
            apiClient: apiClient,
            contentType: MediaMimeType.audioMimeType(forPathExtension: pathExtension),
            pathExtension: pathExtension
        )
    }

    func makeMarkdownUSDZFile(
        embed: MarkdownUSDZEmbed,
        workspaceId: String?,
        sessionId: String?,
        worktreeId: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) async throws -> USDZLocalFileStore.Handle {
        let apiClient = try await waitForAPIClient()
        let scope = resolveMarkdownScope(
            workspaceId: workspaceId,
            sessionId: sessionId,
            worktreeId: worktreeId,
            capturedRuntime: workspaceRuntime
        )
        guard let route = MarkdownVideoMediaSourceRoute.resolve(
            embed: embed,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: scope.worktreeId,
            workspaceRuntime: scope.runtime
        ) else {
            throw APIError.server(status: 404, message: "USDZ source is unavailable")
        }
        let data = try await fetchData(route: route, apiClient: apiClient)
        let key = USDZLocalFileStore.cacheKey(
            kind: embed.reference.kind,
            workspaceID: embed.reference.workspaceID ?? workspaceId,
            sessionID: embed.reference.sourceSessionID ?? sessionId,
            worktreeID: scope.worktreeId,
            path: route.path
        )
        return try await USDZLocalFileStore.shared.store(key: key, data: data)
    }

    func loadTimedTextSidecar(
        mediaPath: String,
        kind: TimedText.MediaKind,
        reference: ResourceReference,
        workspaceId: String?,
        sessionId: String?,
        worktreeId: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) async -> TimedText.LoadResult {
        let apiClient: APIClient
        do {
            apiClient = try await waitForAPIClient()
        } catch {
            return .empty
        }
        let scope = resolveMarkdownScope(
            workspaceId: workspaceId,
            sessionId: sessionId,
            worktreeId: worktreeId,
            capturedRuntime: workspaceRuntime
        )
        return await TimedText.load(
            mediaPath: mediaPath,
            kind: kind,
            fileKind: reference.kind,
            workspaceID: reference.workspaceID ?? workspaceId,
            sessionID: sessionId,
            worktreeID: scope.worktreeId,
            workspaceRuntime: scope.runtime,
            api: apiClient
        )
    }

    func fetchHostFile(
        path: String,
        workspaceId: String?,
        sessionId: String?,
        worktreeId: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) async throws -> Data {
        let apiClient = try await waitForAPIClient()
        let scope = resolveMarkdownScope(
            workspaceId: workspaceId,
            sessionId: sessionId,
            worktreeId: worktreeId,
            capturedRuntime: workspaceRuntime
        )
        guard let route = MarkdownVideoMediaSourceRoute.resolveHostFile(
            path: path,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: scope.worktreeId,
            capturedRuntime: workspaceRuntime,
            currentRuntime: scope.currentRuntime
        ) else {
            throw APIError.server(status: 404, message: "Host image is unavailable")
        }
        return try await fetchData(route: route, apiClient: apiClient)
    }

    // MARK: - Markdown resource access (timeline rows)

    /// The source a row's providers are bound to. Captured by value so a provider never
    /// consults whichever session is active when it runs.
    private struct BoundSource: Sendable {
        let workspaceID: String?
        let sessionID: String
        let worktreeId: String?
        let runtime: WorkspaceRuntime?
    }

    /// Builds the ``MarkdownResourceAccess`` an assistant or tool row hands to its Markdown
    /// renderers and, through them, to the full-screen reader.
    ///
    /// `serverID`, `workspaceID`, and `sessionID` are the row's bound source. The rest follows
    /// the split row construction has always used:
    ///
    /// - Captured at construction: the source session's checkout (with a fetch-time lookup only
    ///   when that captured worktree is nil), the source workspace's runtime (a fallback only),
    ///   the client's base URL, and the client that `fetchWorkspaceFile` reads through. Without
    ///   a client the base URL and that provider stay unset, and the timeline builds a fresh
    ///   value once one exists.
    /// - Resolved when a provider runs: the client and the current catalog runtime, with this
    ///   adapter's bounded waits and cancellation. The workspace is never re-derived from the
    ///   session. A row built from cached data can therefore start loading before the client
    ///   exists.
    ///
    /// `includesInlineMedia == false` leaves the video, audio, USDZ, and sidecar providers unset:
    /// expanded tool Markdown renders file reads only.
    func markdownResourceAccess(
        serverID: String?,
        workspaceID: String?,
        sessionID: String,
        audioPlayer: AudioPlayerService?,
        includesInlineMedia: Bool
    ) -> MarkdownResourceAccess {
        let client = currentAPIClient()
        let sourceSession = sessionStore.session(id: sessionID)
        let source = BoundSource(
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: MarkdownVideoWorkspaceContext.firstCheckout(
                session: sourceSession,
                workspaceId: workspaceID
            ),
            runtime: boundWorkspaceRuntime(workspaceID: workspaceID, serverID: serverID)
        )

        // Missing or foreign source session lists main (nil), matching
        // WorkspaceWikiLinkFileLookupPolicy.
        let readWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? =
            client.map { client in
                { [sourceSession] requestedWorkspaceID, path in
                    let sourceSessionResolved = sourceSession?.workspaceId == requestedWorkspaceID
                    return try await WorkspaceMarkdownImageFileLookup.fetch(
                        workspaceID: requestedWorkspaceID,
                        path: path,
                        sourceSessionResolved: sourceSessionResolved,
                        sourceSessionWorktreeID: sourceSessionResolved ? sourceSession?.worktreeId : nil,
                        fetchWorkspaceFile: { @Sendable workspaceID, path, worktreeId in
                            try await client.fetchWorkspaceFile(
                                workspaceID: workspaceID,
                                path: path,
                                worktreeId: worktreeId
                            )
                        }
                    )
                }
            }
        let readHostFile: (_ path: String) async throws -> Data = { [source] path in
            try await self.fetchHostFile(
                path: path,
                workspaceId: source.workspaceID,
                sessionId: source.sessionID,
                worktreeId: source.worktreeId,
                workspaceRuntime: source.runtime
            )
        }
        let identity = MarkdownResourceAccess.Identity(
            serverID: serverID,
            workspaceID: workspaceID,
            worktreeId: source.worktreeId,
            sessionID: sessionID,
            serverBaseURL: client?.baseURL
        )
        guard includesInlineMedia else {
            return MarkdownResourceAccess(
                identity: identity,
                fetchWorkspaceFile: readWorkspaceFile,
                fetchHostFile: readHostFile,
                audioPlayer: audioPlayer
            )
        }
        return MarkdownResourceAccess(
            identity: identity,
            fetchWorkspaceFile: readWorkspaceFile,
            fetchHostFile: readHostFile,
            makeMarkdownVideoSource: { [source] embed in
                try await self.makeMarkdownVideoMediaSource(
                    embed: embed,
                    workspaceId: source.workspaceID,
                    sessionId: source.sessionID,
                    worktreeId: source.worktreeId,
                    workspaceRuntime: source.runtime
                )
            },
            makeMarkdownAudioSource: { [source] embed in
                try await self.makeMarkdownAudioMediaSource(
                    embed: embed,
                    workspaceId: source.workspaceID,
                    sessionId: source.sessionID,
                    worktreeId: source.worktreeId,
                    workspaceRuntime: source.runtime
                )
            },
            makeMarkdownUSDZFile: { [source] embed in
                try await self.makeMarkdownUSDZFile(
                    embed: embed,
                    workspaceId: source.workspaceID,
                    sessionId: source.sessionID,
                    worktreeId: source.worktreeId,
                    workspaceRuntime: source.runtime
                )
            },
            makeTimedTextSidecar: { [source] mediaPath, kind, reference in
                await self.loadTimedTextSidecar(
                    mediaPath: mediaPath,
                    kind: kind,
                    reference: reference,
                    workspaceId: source.workspaceID,
                    sessionId: source.sessionID,
                    worktreeId: source.worktreeId,
                    workspaceRuntime: source.runtime
                )
            },
            audioPlayer: audioPlayer
        )
    }

    /// The runtime of the row's own workspace, looked up in the row's own server partition
    /// (or the flat catalog when the row has no server). A fetch-time lookup of the current
    /// catalog wins over this snapshot; the snapshot only covers a catalog that no longer
    /// lists the workspace.
    private func boundWorkspaceRuntime(workspaceID: String?, serverID: String?) -> WorkspaceRuntime? {
        guard let workspaceID else { return nil }
        if let serverID {
            return workspaceStore.workspacesByServer[serverID]?
                .first(where: { $0.id == workspaceID })?.runtime
        }
        return workspaceStore.workspaces.first(where: { $0.id == workspaceID })?.runtime
    }

    // MARK: - Routing helpers

    /// Runtime/worktree metadata is read after the client is ready: cache-first
    /// rows may hold a nil runtime snapshot, and the current catalog wins.
    private func resolveMarkdownScope(
        workspaceId: String?,
        sessionId: String?,
        worktreeId: String?,
        capturedRuntime: WorkspaceRuntime?
    ) -> (currentRuntime: WorkspaceRuntime?, runtime: WorkspaceRuntime?, worktreeId: String?) {
        let currentRuntime = MarkdownVideoWorkspaceContext.runtime(
            workspaceId: workspaceId,
            serverId: currentServerId(),
            workspacesByServer: workspaceStore.workspacesByServer,
            workspaces: workspaceStore.workspaces
        )
        let session = sessionId.flatMap { sessionStore.session(id: $0) }
        let resolvedWorktree = worktreeId ?? MarkdownVideoWorkspaceContext.firstCheckout(
            session: session,
            workspaceId: workspaceId
        )
        return (
            currentRuntime,
            MarkdownVideoWorkspaceContext.resolvedRuntime(
                captured: capturedRuntime,
                current: currentRuntime
            ),
            resolvedWorktree
        )
    }

    private func makeMediaSource(
        route: MarkdownVideoMediaSourceRoute,
        apiClient: APIClient,
        contentType: String?,
        pathExtension: String
    ) async throws -> AuthenticatedMediaSource {
        switch route {
        case .host(let path):
            return try await apiClient.makeHostFileMediaSource(
                path: path,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        case .session(let workspaceID, let sessionID, let path):
            return try await apiClient.makeSessionFileMediaSource(
                workspaceId: workspaceID,
                sessionId: sessionID,
                path: path,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        case .workspace(let workspaceID, let path, let worktreeID):
            return try await apiClient.makeWorkspaceMediaSource(
                workspaceId: workspaceID,
                path: path,
                worktreeId: worktreeID,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        }
    }

    private func fetchData(
        route: MarkdownVideoMediaSourceRoute,
        apiClient: APIClient
    ) async throws -> Data {
        switch route {
        case .host(let path):
            return try await apiClient.browseHostFile(path: path)
        case .session(let workspaceID, let sessionID, let path):
            return try await apiClient.getSessionFileData(
                workspaceId: workspaceID,
                sessionId: sessionID,
                path: path
            )
        case .workspace(let workspaceID, let path, let worktreeID):
            return try await apiClient.fetchWorkspaceFile(
                workspaceID: workspaceID,
                path: path,
                worktreeId: worktreeID
            )
        }
    }

    // MARK: - Readiness

    private func waitForAPIClient() async throws -> APIClient {
        for _ in 0..<Self.readinessAttempts {
            if let apiClient = currentAPIClient() {
                return apiClient
            }
            try Task.checkCancellation()
            try await Task.sleep(for: readinessPoll)
        }

        throw APIError.server(status: 503, message: "Server client is not ready")
    }

    private func waitForSessionFileContext(
        workspaceId: String?,
        sessionId: String
    ) async throws -> (apiClient: APIClient, workspaceId: String) {
        for _ in 0..<Self.readinessAttempts {
            let resolvedWorkspaceId = Self.normalizedWorkspaceId(workspaceId)
                ?? Self.normalizedWorkspaceId(sessionStore.workspaceId(for: sessionId))
            if let apiClient = currentAPIClient(), let resolvedWorkspaceId {
                return (apiClient, resolvedWorkspaceId)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: readinessPoll)
        }

        throw APIError.server(status: 503, message: "Session file client is not ready")
    }

    private static func normalizedWorkspaceId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

// MARK: - Route policy

enum MarkdownVideoWorkspaceContext {
    /// Cache-first rows may snapshot a nil runtime before the catalog arrives.
    /// Fetch-time lookup always prefers the current store value.
    static func resolvedRuntime(
        captured: WorkspaceRuntime?,
        current: WorkspaceRuntime?
    ) -> WorkspaceRuntime? {
        current ?? captured
    }

    static func runtime(
        workspaceId: String?,
        serverId: String?,
        workspacesByServer: [String: [Workspace]],
        workspaces: [Workspace]
    ) -> WorkspaceRuntime? {
        guard let workspaceId, !workspaceId.isEmpty else { return nil }
        if let serverId,
           let match = workspacesByServer[serverId]?.first(where: { $0.id == workspaceId }) {
            return match.runtime
        }
        return workspaces.first(where: { $0.id == workspaceId })?.runtime
    }

    static func firstCheckout(session: Session?, workspaceId: String?) -> String? {
        let sourceSessionResolved = session?.workspaceId == workspaceId
        return WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: sourceSessionResolved,
            sourceSessionWorktreeID: sourceSessionResolved ? session?.worktreeId : nil
        )
    }
}

enum MarkdownVideoMediaSourceRoute: Equatable {
    case host(path: String)
    case session(workspaceID: String, sessionID: String, path: String)
    case workspace(workspaceID: String, path: String, worktreeID: String?)

    var path: String {
        switch self {
        case .host(let path), .session(_, _, let path), .workspace(_, let path, _):
            return path
        }
    }

    static func resolve(
        embed: MarkdownVideoEmbed,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) -> Self? {
        resolve(
            filePath: embed.filePath,
            kind: embed.reference.kind,
            referenceWorkspaceID: embed.reference.workspaceID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeID: worktreeID,
            workspaceRuntime: workspaceRuntime
        )
    }

    static func resolve(
        embed: MarkdownAudioEmbed,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) -> Self? {
        resolve(
            filePath: embed.filePath,
            kind: embed.reference.kind,
            referenceWorkspaceID: embed.reference.workspaceID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeID: worktreeID,
            workspaceRuntime: workspaceRuntime
        )
    }

    static func resolve(
        embed: MarkdownUSDZEmbed,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) -> Self? {
        resolve(
            filePath: embed.filePath,
            kind: embed.reference.kind,
            referenceWorkspaceID: embed.reference.workspaceID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeID: worktreeID,
            workspaceRuntime: workspaceRuntime
        )
    }

    static func resolve(
        filePath: String,
        kind: ResourceReferenceKind,
        referenceWorkspaceID: String?,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) -> Self? {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        switch kind {
        case .hostFile:
            if workspaceRuntime == .sandbox {
                let workspace = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let session = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let workspace, !workspace.isEmpty,
                   let session, !session.isEmpty {
                    return .session(workspaceID: workspace, sessionID: session, path: path)
                }
                if let workspace, !workspace.isEmpty {
                    // Guest POSIX paths are not owner-host files. Prefer the
                    // workspace origin over the host origin.
                    return .workspace(
                        workspaceID: workspace,
                        path: path,
                        worktreeID: worktreeID
                    )
                }
                return nil
            }
            return .host(path: path)
        case .workspaceFile:
            let workspace = (referenceWorkspaceID ?? workspaceID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let workspace, !workspace.isEmpty else { return nil }
            if let session = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !session.isEmpty {
                return .session(workspaceID: workspace, sessionID: session, path: path)
            }
            return .workspace(
                workspaceID: workspace,
                path: path,
                worktreeID: worktreeID
            )
        }
    }

    /// Absolute / `~/` / `file://` markdown images use the same host-file
    /// route as AV. Unknown catalog runtime is treated as owner-host read;
    /// only a known sandbox workspace remaps away from the host origin.
    static func resolveHostFile(
        path: String,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        capturedRuntime: WorkspaceRuntime?,
        currentRuntime: WorkspaceRuntime?
    ) -> Self? {
        resolve(
            filePath: path,
            kind: .hostFile,
            referenceWorkspaceID: workspaceID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeID: worktreeID,
            workspaceRuntime: MarkdownVideoWorkspaceContext.resolvedRuntime(
                captured: capturedRuntime,
                current: currentRuntime
            )
        )
    }
}
