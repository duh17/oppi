import Foundation

/// Immutable Markdown origin, retained across metadata lookup and playback.
struct MacMarkdownAudioRequest: Hashable, Sendable {
    let embed: MarkdownAudioEmbed
    let worktreeId: String?
}

enum MacMarkdownAudioSource {
    enum Unavailable: Error { case source }
    struct Resolved: Sendable {
        let media: MacAuthenticatedMediaSource
        let filePlan: FileViewerPlan
    }
    typealias WorkspaceLookup = @Sendable (String) async throws -> Workspace?
    typealias SessionLookup = @Sendable (String) async throws -> Session?

    static func resolve(
        _ request: MacMarkdownAudioRequest,
        token: String,
        socketPath: String,
        session: SessionLookup = { _ in nil },
        workspace: WorkspaceLookup
    ) async throws -> Resolved {
        let reference = request.embed.reference
        let path = request.embed.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, reference.sourceServerID == nil,
              reference.lineAnchor == nil, FileType.detect(from: path).previewCategory == .audio,
              !path.contains("\0"), !path.hasPrefix("//") else { throw Unavailable.source }

        var useHost = reference.kind == .hostFile
        if useHost {
            guard MarkdownWikiLinkRewriter.resolvedHostPath(path) == path else { throw Unavailable.source }
        } else {
            guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains(":"),
                  !path.contains("?"), !path.contains("#"),
                  !path.split(separator: "/").contains("..") else { throw Unavailable.source }
        }

        var workspaceID = nonEmpty(reference.workspaceID)
        var worktreeId = request.worktreeId
        if workspaceID == nil, let sessionID = nonEmpty(reference.sourceSessionID) {
            // Absent workspace metadata does not declare a control session.
            // Recover immutable source scope from the existing session endpoint,
            // or refuse the read; never upgrade missing context to host authority.
            guard let context = try await session(sessionID), context.id == sessionID else { throw Unavailable.source }
            try Task.checkCancellation()
            workspaceID = nonEmpty(context.workspaceId)
            worktreeId = context.worktreeId
            guard workspaceID != nil || context.control != nil else { throw Unavailable.source }
        }
        if useHost, let workspaceID {
            // A POSIX filename from a sandbox is not authority to read the
            // identically named owner file. Missing catalog context fails closed.
            guard let context = try await workspace(workspaceID), context.id == workspaceID,
                  let runtime = context.runtime else { throw Unavailable.source }
            useHost = runtime == .host
        }
        try Task.checkCancellation()

        let requestPath: String
        if useHost {
            var components = URLComponents()
            components.path = "/files/raw"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let encoded = components.string else { throw Unavailable.source }
            requestPath = encoded.replacingOccurrences(of: "+", with: "%2B")
        } else {
            guard let workspaceID else { throw Unavailable.source }
            let prefix: [String]
            if let sessionID = nonEmpty(reference.sourceSessionID) {
                prefix = ["workspaces", workspaceID, "sessions", sessionID, "raw"]
            } else {
                prefix = ["workspaces", workspaceID, "raw"]
            }
            // Match APIClient.makeSessionRawURL/makeWorkspaceRawURL: encode the
            // complete file path as one segment, preserving a guest leading '/'.
            // Server resolveWorkspaceUserPath owns sandbox guest→host mapping.
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/%+?#&")
            let segments = (prefix + [path]).compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
            guard segments.count == prefix.count + 1 else { throw Unavailable.source }
            let route = "/" + segments.joined(separator: "/")
            requestPath = reference.sourceSessionID.flatMap(nonEmpty) == nil
                ? MacUnixSocketMediaPath.appendWorktreeQuery(route, worktreeId: worktreeId)
                    .replacingOccurrences(of: "+", with: "%2B")
                : route
        }
        let ext = (path as NSString).pathExtension
        let media = MacOwnerMediaSource.make(
            requestPath: requestPath, socketPath: socketPath, token: token,
            contentTypeHint: MacMediaMimeType.hint(forPathExtension: ext), sourceFileExtension: ext
        )
        let filePlan: FileViewerPlan = useHost ? .hostFile(path: path) : .workspaceFile(
            workspaceID: workspaceID ?? "", path: path, worktreeId: worktreeId
        )
        return Resolved(media: media, filePlan: filePlan)
    }

    static func local(_ request: MacMarkdownAudioRequest) async throws -> Resolved {
        guard let token = MacAPIClient.readOwnerToken(), !token.isEmpty else { throw Unavailable.source }
        let socketPath = MacLocalAPISocket.path(dataDir: NSString("~/.config/oppi").expandingTildeInPath)
        let client = MacWorkspaceClient(socketPath: socketPath, token: token)
        return try await resolve(
            request, token: token, socketPath: socketPath,
            session: { try await client.getSessionRecord(sessionId: $0) },
            workspace: { workspaceID in
                try await client.listWorkspaceCatalog().workspaces.first { $0.id == workspaceID }
            }
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
