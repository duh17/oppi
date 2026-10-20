import Foundation

/// Chooses the host origin vs the session origin for a session-touched file.
///
/// Sandbox workspaces always use the session origin. Guest paths like
/// `/workspace/<slug>/…` are absolute POSIX strings, so treating them as
/// host paths would send a host-origin read and 404.
enum SessionTouchedFileLoadRoute: Equatable {
    case hostFile(path: String)
    case sessionRaw(path: String)

    var requestPath: String {
        switch self {
        case let .hostFile(path), let .sessionRaw(path):
            return path
        }
    }

    static func resolve(
        path: String,
        workspaceRuntime: WorkspaceRuntime?,
        hostMount: String?
    ) -> Self {
        if workspaceRuntime == .sandbox {
            return .sessionRaw(path: path)
        }
        if MarkdownWikiLinkRewriter.resolvedHostPath(path) != nil {
            return .hostFile(path: path)
        }
        return .sessionRaw(path: path.workspaceRelativePath(hostMount: hostMount) ?? path)
    }

    static func navigationTitle(
        path: String,
        fileName: String,
        workspaceRuntime: WorkspaceRuntime?
    ) -> String {
        if workspaceRuntime == .sandbox {
            return fileName
        }
        if MarkdownWikiLinkRewriter.resolvedHostPath(path) != nil {
            return path
        }
        return fileName
    }
}

/// Session-origin markdown readers keep guest/worktree children on the session origin.
///
/// Sandbox and unknown runtime stay on the session origin even when wiki classification
/// labels an absolute guest path `hostFile`. Do not infer host ownership from a
/// leading `/` or missing workspace metadata. Confirmed host-workspace `/Users`
/// and `~/` links use the host origin.
enum SessionOriginLinkedFileRouting {
    static func routesThroughSessionRaw(
        kind: ResourceReferenceKind,
        workspaceRuntime: WorkspaceRuntime?,
        routesFileReferencesThroughSession: Bool
    ) -> Bool {
        guard routesFileReferencesThroughSession else { return false }
        if workspaceRuntime == .host {
            return kind != .hostFile
        }
        return true
    }
}

/// Reader content for a session-touched file.
///
/// The route-resolving providers come from `SessionTouchedFileOrigin`; this only
/// binds them to the source session as one ``MarkdownResourceAccess``.
enum SessionFileFullScreenContentBuilder {
    static func content(
        text: String,
        filePath: String,
        workspaceID: String?,
        serverBaseURL: URL?,
        fetchSessionFileData: ((String) async throws -> Data)?,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider? = nil,
        makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider? = nil,
        makeMarkdownUSDZFile: MarkdownUSDZFileProvider? = nil,
        makeTimedTextSidecar: TimedTextSidecarProvider? = nil,
        audioPlayer: AudioPlayerService? = nil,
        sessionID: String
    ) -> FullScreenCodeContent {
        .fromText(
            text,
            filePath: filePath,
            resourceAccess: MarkdownResourceAccess(
                identity: MarkdownResourceAccess.Identity(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    serverBaseURL: serverBaseURL
                ),
                fetchWorkspaceFile: fetchSessionFileData.map { fetch in
                    { _, path in try await fetch(path) }
                },
                fetchHostFile: fetchSessionFileData,
                makeMarkdownVideoSource: makeMarkdownVideoSource,
                makeMarkdownAudioSource: makeMarkdownAudioSource,
                makeMarkdownUSDZFile: makeMarkdownUSDZFile,
                makeTimedTextSidecar: makeTimedTextSidecar,
                audioPlayer: audioPlayer
            )
        )
    }
}

/// Where a session-touched file and the files its Markdown references are
/// read: the host for confirmed host paths, else the session's copy.
struct SessionTouchedFileOrigin: Equatable {
    let sessionId: String
    let workspaceRuntime: WorkspaceRuntime?
    let hostMount: String?

    func route(_ path: String) -> SessionTouchedFileLoadRoute {
        SessionTouchedFileLoadRoute.resolve(path: path, workspaceRuntime: workspaceRuntime, hostMount: hostMount)
    }

    func browse(api: APIClient, path: String) async throws -> Data {
        switch route(path) {
        case .hostFile(let hostPath):
            try await api.browseHostFile(path: hostPath)
        case .sessionRaw(let rawPath):
            try await api.getSessionFileData(sessionId: sessionId, path: rawPath)
        }
    }

    func mediaSource(
        api: APIClient,
        path: String,
        contentTypeHint: String?
    ) async throws -> AuthenticatedMediaSource {
        let route = route(path)
        let pathExtension = (route.requestPath as NSString).pathExtension
        switch route {
        case .hostFile(let hostPath):
            return try await api.makeHostFileMediaSource(
                path: hostPath,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: pathExtension
            )
        case .sessionRaw(let rawPath):
            return try await api.makeSessionFileMediaSource(
                sessionId: sessionId,
                path: rawPath,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: pathExtension
            )
        }
    }

    func loadTimedText(
        api: APIClient,
        workspaceId: String,
        mediaPath: String,
        kind: TimedText.MediaKind
    ) async -> TimedText.LoadResult {
        let mediaRoute: MarkdownVideoMediaSourceRoute = switch route(mediaPath) {
        case .hostFile:
            .host(path: mediaPath)
        case .sessionRaw(let rawPath):
            .session(workspaceID: workspaceId, sessionID: sessionId, path: rawPath)
        }
        return await TimedText.load(
            mediaPath: mediaRoute.path,
            kind: kind,
            locale: .current,
            access: TimedText.access(for: mediaRoute, api: api)
        )
    }

    /// Reader content whose images, media, 3D scenes, and captions resolve
    /// the way the file itself was read.
    func fullScreenContent(
        text: String,
        filePath: String,
        workspaceId: String,
        api: APIClient,
        audioPlayer: AudioPlayerService?
    ) -> FullScreenCodeContent {
        let origin = self
        return SessionFileFullScreenContentBuilder.content(
            text: text,
            filePath: filePath,
            workspaceID: workspaceId,
            serverBaseURL: api.baseURL,
            fetchSessionFileData: { path in try await origin.browse(api: api, path: path) },
            makeMarkdownVideoSource: { embed in
                try await origin.mediaSource(
                    api: api,
                    path: embed.filePath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: (embed.filePath as NSString).pathExtension)
                )
            },
            makeMarkdownAudioSource: { embed in
                try await origin.mediaSource(
                    api: api,
                    path: embed.filePath,
                    contentTypeHint: MediaMimeType.audioMimeType(forPathExtension: (embed.filePath as NSString).pathExtension)
                )
            },
            makeMarkdownUSDZFile: { embed in
                let data = try await origin.browse(api: api, path: embed.filePath)
                let key = USDZLocalFileStore.cacheKey(
                    kind: embed.reference.kind,
                    workspaceID: embed.reference.workspaceID ?? workspaceId,
                    sessionID: embed.reference.sourceSessionID ?? origin.sessionId,
                    worktreeID: nil,
                    path: embed.filePath
                )
                return try await USDZLocalFileStore.shared.store(key: key, data: data)
            },
            makeTimedTextSidecar: { mediaPath, kind, _ in
                await origin.loadTimedText(api: api, workspaceId: workspaceId, mediaPath: mediaPath, kind: kind)
            },
            audioPlayer: audioPlayer,
            sessionID: sessionId
        )
    }
}
