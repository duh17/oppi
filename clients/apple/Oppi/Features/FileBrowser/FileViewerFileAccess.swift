import Foundation

/// How one file viewer reads its file and the files a Markdown reader
/// references: the file's origin (workspace checkout, session copy, or host)
/// and the identity that routes relative resources.
@MainActor
struct FileViewerFileAccess {
    let source: FileBrowserContentSource
    let serverId: String?
    let workspaceId: String
    let worktreeId: String?
    let sessionId: String?
    let controlSessionId: String?
    let workspaceRuntime: WorkspaceRuntime?

    func browseFile(api: APIClient, path: String) async throws -> Data {
        switch source {
        case .hostFile:
            return try await api.browseHostFile(
                path: path,
                controlSessionId: controlSessionId
            )
        case .sessionFile(let sessionId):
            return try await api.getSessionFileData(
                sessionId: sessionId,
                path: path
            )
        case .workspaceFile:
            return try await api.browseWorkspaceFile(
                workspaceId: workspaceId,
                path: path,
                worktreeId: worktreeId
            )
        }
    }

    func mediaSource(
        api: APIClient,
        path: String,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) async throws -> AuthenticatedMediaSource {
        switch source {
        case .hostFile:
            return try await api.makeHostFileMediaSource(
                path: path,
                controlSessionId: controlSessionId,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: sourceFileExtension
            )
        case .sessionFile(let sessionId):
            return try await api.makeSessionFileMediaSource(
                sessionId: sessionId,
                path: path,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: sourceFileExtension
            )
        case .workspaceFile:
            return try await api.makeWorkspaceMediaSource(
                workspaceId: workspaceId,
                path: path,
                worktreeId: worktreeId,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: sourceFileExtension
            )
        }
    }

    func loadTimedText(
        api: APIClient,
        path: String,
        kind: TimedText.MediaKind
    ) async -> TimedText.LoadResult {
        let route: MarkdownVideoMediaSourceRoute = switch source {
        case .hostFile:
            .host(path: path)
        case .sessionFile(let sessionId):
            .session(workspaceID: workspaceId, sessionID: sessionId, path: path)
        case .workspaceFile:
            .workspace(workspaceID: workspaceId, path: path, worktreeID: worktreeId)
        }
        return await TimedText.load(
            mediaPath: path,
            kind: kind,
            locale: .current,
            access: TimedText.access(for: route, api: api, controlSessionId: controlSessionId)
        )
    }

    /// Reader content with this file's origin, so relative images, media, 3D
    /// scenes, and captions resolve where the file lives. `sourcePath` is the
    /// resolved host path when the server reported one.
    func fullScreenContent(
        text: String,
        sourcePath: String,
        api: APIClient?,
        audioPlayer: AudioPlayerService?
    ) -> FullScreenCodeContent {
        guard let api else {
            return .fromText(text, filePath: sourcePath)
        }
        let access = self
        return .fromText(
            text,
            filePath: sourcePath,
            resourceAccess: MarkdownResourceAccess(
                identity: MarkdownResourceAccess.Identity(
                    serverID: serverId,
                    workspaceID: workspaceId,
                    worktreeId: worktreeId,
                    sessionID: sessionId,
                    workspaceRuntime: workspaceRuntime,
                    serverBaseURL: api.baseURL,
                    routesFileReferencesThroughSession: source.routesFileReferencesThroughSession
                ),
                fetchWorkspaceFile: { wsID, filePath in
                    switch access.source {
                    case .hostFile:
                        return try await api.browseHostFile(
                            path: filePath,
                            controlSessionId: access.controlSessionId
                        )
                    case .sessionFile(let sourceSessionId):
                        return try await api.getSessionFileData(
                            sessionId: sourceSessionId,
                            path: filePath
                        )
                    case .workspaceFile:
                        return try await api.browseWorkspaceFile(
                            workspaceId: wsID.isEmpty ? access.workspaceId : wsID,
                            path: filePath,
                            worktreeId: access.worktreeId
                        )
                    }
                },
                fetchSessionFile: { _, sourceSessionID, path in
                    try await api.getSessionFileData(
                        sessionId: sourceSessionID,
                        path: path
                    )
                },
                fetchHostFile: { path in
                    if case .sessionFile = access.source {
                        return try await access.browseFile(api: api, path: path)
                    }
                    let route = MarkdownVideoMediaSourceRoute.resolve(
                        filePath: path,
                        kind: .hostFile,
                        referenceWorkspaceID: access.workspaceId,
                        workspaceID: access.workspaceId,
                        sessionID: access.sessionId,
                        worktreeID: access.worktreeId,
                        workspaceRuntime: access.workspaceRuntime
                    )
                    switch route {
                    case .host(let hostPath):
                        return try await api.browseHostFile(
                            path: hostPath,
                            controlSessionId: access.controlSessionId
                        )
                    case .session(_, let sessionID, let sessionPath):
                        return try await api.getSessionFileData(
                            sessionId: sessionID,
                            path: sessionPath
                        )
                    case .workspace(let workspaceID, let workspacePath, let worktreeID):
                        return try await api.fetchWorkspaceFile(
                            workspaceID: workspaceID,
                            path: workspacePath,
                            worktreeId: worktreeID
                        )
                    case nil:
                        throw CocoaError(.fileNoSuchFile)
                    }
                },
                makeMarkdownVideoSource: { embed in
                    try await access.markdownMediaSource(
                        api: api, path: embed.filePath, reference: embed.reference,
                        mimeType: MediaMimeType.videoMimeType(forPathExtension:)
                    )
                },
                makeMarkdownAudioSource: { embed in
                    try await access.markdownMediaSource(
                        api: api, path: embed.filePath, reference: embed.reference,
                        mimeType: MediaMimeType.audioMimeType(forPathExtension:)
                    )
                },
                makeMarkdownUSDZFile: { embed in
                    try await access.markdownUSDZFile(api: api, embed: embed)
                },
                makeTimedTextSidecar: { mediaPath, kind, reference in
                    if case .sessionFile = access.source {
                        return await access.loadTimedText(api: api, path: mediaPath, kind: kind)
                    }
                    return await TimedText.load(
                        mediaPath: mediaPath,
                        kind: kind,
                        fileKind: reference.kind,
                        workspaceID: reference.workspaceID ?? access.workspaceId,
                        sessionID: access.sessionId,
                        worktreeID: access.worktreeId,
                        workspaceRuntime: access.workspaceRuntime,
                        api: api
                    )
                },
                audioPlayer: audioPlayer
            )
        )
    }

    private func markdownUSDZFile(
        api: APIClient,
        embed: MarkdownUSDZEmbed
    ) async throws -> USDZLocalFileStore.Handle {
        let path = embed.filePath
        let data: Data
        if case .sessionFile = source {
            data = try await browseFile(api: api, path: path)
        } else {
            guard let route = MarkdownVideoMediaSourceRoute.resolve(
                embed: embed,
                workspaceID: workspaceId,
                sessionID: sessionId,
                worktreeID: worktreeId,
                workspaceRuntime: workspaceRuntime
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            switch route {
            case .host(let hostPath):
                data = try await api.browseHostFile(
                    path: hostPath,
                    controlSessionId: controlSessionId
                )
            case .session(_, let sessionID, let sessionPath):
                data = try await api.getSessionFileData(
                    sessionId: sessionID,
                    path: sessionPath
                )
            case .workspace(let workspaceID, let workspacePath, let worktreeID):
                data = try await api.fetchWorkspaceFile(
                    workspaceID: workspaceID,
                    path: workspacePath,
                    worktreeId: worktreeID
                )
            }
        }
        let key = USDZLocalFileStore.cacheKey(
            kind: embed.reference.kind,
            workspaceID: embed.reference.workspaceID ?? workspaceId,
            sessionID: embed.reference.sourceSessionID ?? sessionId,
            worktreeID: worktreeId,
            path: path
        )
        return try await USDZLocalFileStore.shared.store(key: key, data: data)
    }

    private func markdownMediaSource(
        api: APIClient,
        path: String,
        reference: ResourceReference,
        mimeType: (String?) -> String?
    ) async throws -> AuthenticatedMediaSource {
        // Exact session readers keep their captured origin even without runtime metadata.
        if case .sessionFile = source {
            let pathExtension = (path as NSString).pathExtension
            return try await mediaSource(
                api: api, path: path,
                contentTypeHint: mimeType(pathExtension),
                sourceFileExtension: pathExtension
            )
        }
        guard let route = MarkdownVideoMediaSourceRoute.resolve(
            filePath: path,
            kind: reference.kind,
            referenceWorkspaceID: reference.workspaceID,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: worktreeId,
            workspaceRuntime: workspaceRuntime
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let pathExtension = (route.path as NSString).pathExtension
        let contentType = mimeType(pathExtension)
        switch route {
        case .host(let path):
            return try await api.makeHostFileMediaSource(
                path: path,
                controlSessionId: controlSessionId,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        case .session(_, let sessionID, let path):
            return try await api.makeSessionFileMediaSource(
                sessionId: sessionID,
                path: path,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        case .workspace(let workspaceID, let path, let worktreeID):
            return try await api.makeWorkspaceMediaSource(
                workspaceId: workspaceID,
                path: path,
                worktreeId: worktreeID,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        }
    }
}
