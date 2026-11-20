import Foundation

enum HostFileResolvedPathHeaders {
    static let resolvedPathField = "X-Oppi-Resolved-Path"

    static func resolvedPath(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let raw = http.value(forHTTPHeaderField: resolvedPathField)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return decode(raw)
    }

    /// Inverse of the server's `encodeURIComponent` header encoding, which
    /// keeps `/` literal so ASCII paths stay readable on the wire.
    static func decode(_ raw: String) -> String? {
        guard let decoded = raw.removingPercentEncoding, decoded.hasPrefix("/") else {
            return nil
        }
        return decoded
    }
}

/// The editor's read of a file that is not there yet: there is no ETag, and the
/// first save creates the file (`If-None-Match: *`).
let workspaceFileCreatableHeader = "X-Oppi-Creatable"

// MARK: - Current-file URLs

extension APIClient {
    /// What `currentFileVersion` reads: `size` in bytes, `modified` as the
    /// server's `Last-Modified`. Two reads of an unchanged file are equal.
    struct CurrentFileVersion: Sendable, Hashable {
        let size: Int
        let modified: String
    }

    /// Namespace a current-file path resolves in. It selects resolution only;
    /// pairing/auth is the host-file gate and sandbox paths stay confined.
    enum CurrentFileOrigin: Sendable, Hashable {
        /// Absolute or `~/` owner-host path; relative paths resolve from the
        /// declared control session's cwd when one is given.
        case host(controlSessionId: String?)
        case workspace(workspaceId: String, worktreeId: String?)
        /// Workspace session cwd; the server resolves the session by id.
        case session(sessionId: String)
        /// An editable Skill's own files, by Skill-relative path.
        case skill(skillId: String)
        /// Pi's own agent files (`SYSTEM.md`, `prompts/`), by agent-relative path.
        case pi
    }

    /// `/files/current` and its per-file companions, which take the same query.
    private enum CurrentFileRoute {
        case bytes, sidecars, mediaInfo

        var pathSegments: [String] {
            switch self {
            case .bytes: ["files", "current"]
            case .sidecars: ["files", "current", "sidecars"]
            case .mediaInfo: ["files", "current", "media-info"]
            }
        }
    }

    private func makeCurrentFileURL(
        _ origin: CurrentFileOrigin,
        path: String,
        route: CurrentFileRoute = .bytes
    ) throws -> URL {
        var queryItems: [URLQueryItem]
        switch origin {
        case .host(let controlSessionId):
            if let controlSessionId, !controlSessionId.isEmpty {
                queryItems = [
                    URLQueryItem(name: "origin", value: "session"),
                    URLQueryItem(name: "sessionId", value: controlSessionId),
                ]
            } else {
                queryItems = [URLQueryItem(name: "origin", value: "host")]
            }
        case .workspace(let workspaceId, let worktreeId):
            queryItems = [
                URLQueryItem(name: "origin", value: "workspace"),
                URLQueryItem(name: "workspaceId", value: workspaceId),
            ] + workspaceWorktreeQueryItems(worktreeId)
        case .session(let sessionId):
            queryItems = [
                URLQueryItem(name: "origin", value: "session"),
                URLQueryItem(name: "sessionId", value: sessionId),
            ]
        case .skill(let skillId):
            queryItems = [
                URLQueryItem(name: "origin", value: "skill"),
                URLQueryItem(name: "skillId", value: skillId),
            ]
        case .pi:
            queryItems = [URLQueryItem(name: "origin", value: "pi")]
        }
        queryItems.append(URLQueryItem(name: "path", value: path))
        return try makeURL(pathSegments: route.pathSegments, queryItems: queryItems)
    }

    private func makeWorkspaceContentsURL(
        workspaceId: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        directory: Bool = false
    ) throws -> URL {
        let normalizedPath = path == "/" ? "" : path
        let trailingSlash = directory || normalizedPath.hasSuffix("/")
        return try makeURL(
            pathSegments: ["workspaces", workspaceId, "contents"],
            appendedPath: normalizedPath,
            queryItems: queryItems,
            trailingSlash: trailingSlash
        )
    }

    private func makeHostContentsURL(path: String, queryItems: [URLQueryItem] = [], directory: Bool = false) throws -> URL {
        let normalizedPath = path == "/" ? "" : path
        let trailingSlash = directory || normalizedPath.hasSuffix("/")
        return try makeURL(
            pathSegments: ["host", "contents"],
            appendedPath: normalizedPath,
            queryItems: queryItems,
            trailingSlash: trailingSlash
        )
    }

    private static func listingCursorQueryItems(_ after: String?) -> [URLQueryItem] {
        after.map { [URLQueryItem(name: "after", value: $0)] } ?? []
    }
}

// MARK: - File reads and the file browser

extension APIClient {
    /// Fetch raw data for a workspace file or an external path reported by the session.
    func getSessionFileData(sessionId: String, path: String) async throws -> Data {
        try await get(url: makeCurrentFileURL(.session(sessionId: sessionId), path: path))
    }

    /// Fetch a workspace file by path (images, etc.) through the workspace-origin current-file read.
    ///
    /// Used by `MarkdownImageView` to load images referenced in markdown with relative paths.
    /// Returns raw `Data` so the caller can decode as `UIImage`.
    func fetchWorkspaceFile(workspaceID: String, path: String, worktreeId: String? = nil) async throws -> Data {
        try await browseWorkspaceFile(workspaceId: workspaceID, path: path, worktreeId: worktreeId)
    }

    /// List entries in a workspace directory.
    ///
    /// Pass an empty string or "/" for the workspace root. Subdirectory paths
    /// should include a trailing slash (e.g. "src/").
    ///
    /// One page of up to 1000 entries: pass the previous page's `next` as
    /// `after` for the one after it (`DirectoryListingResponse.next`).
    func listWorkspaceDirectory(
        workspaceId: String,
        path: String = "",
        worktreeId: String? = nil,
        after: String? = nil
    ) async throws -> DirectoryListingResponse {
        try await get(
            url: makeWorkspaceContentsURL(
                workspaceId: workspaceId,
                path: path,
                queryItems: workspaceWorktreeQueryItems(worktreeId) + Self.listingCursorQueryItems(after),
                directory: true
            ),
            as: DirectoryListingResponse.self
        )
    }

    /// List entries in the connected server's home directory, one page at a
    /// time like `listWorkspaceDirectory`.
    ///
    /// Pass an empty string or "/" for `~`. Subdirectory paths are
    /// home-relative and should include a trailing slash (e.g. "Documents/").
    func listHostDirectory(path: String = "", after: String? = nil) async throws -> DirectoryListingResponse {
        try await get(
            url: makeHostContentsURL(path: path, queryItems: Self.listingCursorQueryItems(after), directory: true),
            as: DirectoryListingResponse.self
        )
    }

    /// Fetch the complete file index for client-side fuzzy search.
    ///
    /// Returns all workspace-relative file paths in a single response.
    /// The client caches this and filters locally for instant search feedback.
    func fetchFileIndex(workspaceId: String, worktreeId: String? = nil) async throws -> FileIndexResponse {
        try await get(
            url: makeURL(
                pathSegments: ["workspaces", workspaceId, "paths"],
                queryItems: workspaceWorktreeQueryItems(worktreeId)
            ),
            as: FileIndexResponse.self
        )
    }

    /// Fetch a workspace file in browse mode (text/code files, not just images).
    ///
    /// Returns raw file content as `Data`. For text files, decode to String with UTF-8.
    func browseWorkspaceFile(workspaceId: String, path: String, worktreeId: String? = nil) async throws -> Data {
        try await get(url: makeCurrentFileURL(.workspace(workspaceId: workspaceId, worktreeId: worktreeId), path: path))
    }

    /// Exact-path existence check for an owner host file. 404 is unresolved.
    /// A 200 response yields the server's canonical realpath when present.
    func resolveHostFile(path: String) async throws -> String? {
        let url = try makeCurrentFileURL(.host(controlSessionId: nil), path: path)
        do {
            let (_, response) = try await request("HEAD", url: url)
            try checkStatus(response, data: Data())
            return HostFileResolvedPathHeaders.resolvedPath(from: response) ?? path
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    /// Fetch an authenticated owner-host file through the host-origin current-file read.
    func browseHostFile(
        path: String,
        controlSessionId: String? = nil
    ) async throws -> Data {
        try await browseHostFileContent(path: path, controlSessionId: controlSessionId).data
    }

    /// Keep the server's canonical path with the bytes from the same GET.
    /// Relative control files need it as the base for child Markdown links.
    func browseHostFileContent(
        path: String,
        controlSessionId: String? = nil
    ) async throws -> (data: Data, resolvedPath: String?) {
        let (data, response) = try await request(
            "GET", url: makeCurrentFileURL(.host(controlSessionId: controlSessionId), path: path)
        )
        try checkStatus(response, data: data)
        return (data, HostFileResolvedPathHeaders.resolvedPath(from: response))
    }

    /// A file's size and modification time, read without its bytes (a
    /// `HEAD` of the current-file read); nil when the file is not there.
    func currentFileVersion(_ origin: CurrentFileOrigin, path: String) async throws -> CurrentFileVersion? {
        do {
            let (_, response) = try await request("HEAD", url: makeCurrentFileURL(origin, path: path))
            try checkStatus(response, data: Data())
            guard let http = response as? HTTPURLResponse,
                  let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) else { return nil }
            return CurrentFileVersion(size: size, modified: http.value(forHTTPHeaderField: "Last-Modified") ?? "")
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    /// A file's bytes through the current-file read of `origin`.
    func currentFile(_ origin: CurrentFileOrigin, path: String) async throws -> Data {
        try await get(url: makeCurrentFileURL(origin, path: path))
    }

    /// Same-stem timed-text sidecar names beside an existing media file.
    func listCurrentFileSidecars(_ origin: CurrentFileOrigin, mediaPath: String) async throws -> [String] {
        struct Response: Decodable { let names: [String] }
        return try await get(url: makeCurrentFileURL(origin, path: mediaPath, route: .sidecars), as: Response.self).names
    }
}

// MARK: - File Editing

extension APIClient {
    /// Editing capability for this server and owner. Nil means read-only:
    /// workspace files need `workspaceFileEditing`, Skill files `skillFileEditing`,
    /// Pi's own agent files `piFileEditing`, host files `fileEditOrigins`.
    func fileEditingCapability(
        for owner: WorkspaceFileEditIdentity.Owner
    ) -> ServerInfo.WorkspaceFileEditingCapability? {
        let capability: ServerInfo.WorkspaceFileEditingCapability? = switch owner {
        case .workspace: workspaceFileEditing
        case .skill: skillFileEditing
        case .pi: piFileEditing
        case .host: fileEditOrigins
        // A record's prompt is edited through its own route, which every server of
        // this version answers; it has no file-editing capability to check.
        case .agent, .schedule: nil
        }
        guard let capability, capability.version >= 1, capability.maxBytes > 0 else { return nil }
        return capability
    }

    /// The editor's read: the exact bytes with their strong ETag, or — for a file
    /// the server offers to create — an empty base with no tag. Only on servers
    /// that advertise editing for the identity's owner.
    func readFileForEditing(_ identity: WorkspaceFileEditIdentity) async throws -> WorkspaceFileDiskSnapshot {
        guard identity.owner.isFile, fileEditingCapability(for: identity.owner) != nil else {
            throw CocoaError(.featureUnsupported)
        }
        let url = try makeFileEditURL(identity)
        // A host file is tagged only on a read that asks for its owner.
        let (data, response) = try await performAuthorized {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            req.httpMethod = "GET"
            req.setValue("1", forHTTPHeaderField: fileEditResolveHeader)
            return req
        }
        try checkStatus(response, data: data)
        let http = response as? HTTPURLResponse
        // The server names a file it would let the editor create; the body is
        // empty and there is no version to overwrite.
        let creatable = http?.value(forHTTPHeaderField: workspaceFileCreatableHeader) != nil
        let etag = creatable ? nil : http?.value(forHTTPHeaderField: "ETag")
        return WorkspaceFileDiskSnapshot(bytes: data, etag: etag, creatable: creatable)
    }

    func readFileForEditingOutcome(_ identity: WorkspaceFileEditIdentity) async -> WorkspaceFileReadOutcome {
        do {
            let snapshot = try await readFileForEditing(identity)
            return snapshot.creatable ? .creatable : .snapshot(snapshot)
        } catch let APIError.server(status, _) where status == 404 {
            return .missing
        } catch let APIError.codedServer(status, _, _) where status == 404 {
            return .missing
        } catch {
            return .failed
        }
    }

    /// Who edits the file a reader read at `location`, and that read's bytes and
    /// tag: one `GET /files/current` with `X-Oppi-Edit-Resolve`, through the
    /// origin the reader used. The server follows the path to its canonical file
    /// and names the origin that owns it, so a chat link, an Org `file:` link,
    /// and the workspace tree all edit one file the same way. A read through a
    /// sandbox session stays inside its sandbox. A failed read is `.unresolved`.
    func resolveFileForEditing(_ location: FileEditLocation) async -> FileEditResolution {
        do {
            let url = try makeCurrentFileURL(location.origin, path: location.path)
            let (data, response) = try await performAuthorized {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                req.setValue("1", forHTTPHeaderField: fileEditResolveHeader)
                return req
            }
            guard let http = response as? HTTPURLResponse else { return .unresolved }
            return FileEditResolution(response: http, body: data, serverId: location.serverId)
        } catch {
            return .unresolved
        }
    }

    /// Guarded write of one text file. The only file-write URL this client builds:
    /// `PUT /files/current` with `origin=workspace`, `origin=skill`, `origin=pi`,
    /// or `origin=host`, raw bytes, and one precondition — the version it
    /// overwrites, or `If-None-Match: *` for a file it read as absent.
    func writeEditedFile(
        _ identity: WorkspaceFileEditIdentity,
        bytes: Data,
        condition: WorkspaceFileWriteCondition
    ) async -> WorkspaceFileWriteOutcome {
        guard identity.owner.isFile, fileEditingCapability(for: identity.owner) != nil else {
            return .rejected(status: 0, message: "Editing is not available on this server")
        }
        if case .version(let tag) = condition, tag.isEmpty || tag == "*" {
            return .rejected(status: 0, message: "Editing is not available on this server")
        }
        let data: Data
        let response: URLResponse
        do {
            let url = try makeFileEditURL(identity)
            (data, response) = try await performAuthorized {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                req.httpMethod = "PUT"
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                switch condition {
                case .version(let tag):
                    req.setValue(tag, forHTTPHeaderField: "If-Match")
                case .absent:
                    req.setValue("*", forHTTPHeaderField: "If-None-Match")
                }
                req.httpBody = bytes
                return req
            }
        } catch {
            return WorkspaceFileWriteFailureClassifier.outcome(for: error)
        }
        guard let http = response as? HTTPURLResponse else { return .unknown }
        switch http.statusCode {
        case 200:
            struct Body: Decodable { let etag: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: data), !body.etag.isEmpty else {
                return .unknown
            }
            return .saved(etag: body.etag)
        case 412:
            return .stale
        case 404:
            return .missing
        default:
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            return .rejected(status: http.statusCode, message: message)
        }
    }

    private func makeFileEditURL(_ identity: WorkspaceFileEditIdentity) throws -> URL {
        let origin: CurrentFileOrigin = switch identity.owner {
        case .workspace(let workspaceId, let worktreeId): .workspace(workspaceId: workspaceId, worktreeId: worktreeId)
        case .skill(let skillId): .skill(skillId: skillId)
        case .pi: .pi
        case .host: .host(controlSessionId: nil)
        case .agent, .schedule: throw CocoaError(.featureUnsupported)
        }
        return try makeCurrentFileURL(origin, path: identity.path)
    }
}

// MARK: - Media sources

extension APIClient {
    func makeHostFileMediaSource(
        path: String,
        controlSessionId: String? = nil,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        try makeCurrentFileMediaSource(
            .host(controlSessionId: controlSessionId),
            path: path,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    /// Build a bearer-authenticated media source for AVPlayer resource loading.
    ///
    /// AVPlayer receives a local `oppi-media://` asset URL. The resource loader
    /// translates byte-range requests to the workspace-origin current-file URL with the normal
    /// `Authorization: Bearer ...` header.
    func makeWorkspaceMediaSource(
        workspaceId: String,
        path: String,
        worktreeId: String? = nil,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        try makeCurrentFileMediaSource(
            .workspace(workspaceId: workspaceId, worktreeId: worktreeId),
            path: path,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    /// Build a bearer-authenticated, range-capable media source for a file
    /// addressable through the owning session's session-origin current-file read.
    func makeSessionFileMediaSource(
        sessionId: String,
        path: String,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        try makeCurrentFileMediaSource(
            .session(sessionId: sessionId),
            path: path,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    private func makeCurrentFileMediaSource(
        _ origin: CurrentFileOrigin,
        path: String,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) throws -> AuthenticatedMediaSource {
        AuthenticatedMediaSource(
            url: try makeCurrentFileURL(origin, path: path),
            authorizationProvider: mediaAuthorizationProvider(),
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: environment.tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension,
            mediaInfoURL: try makeCurrentFileURL(origin, path: path, route: .mediaInfo)
        )
    }

    /// Build a bearer-authenticated media source for a session attachment.
    func makeSessionAttachmentMediaSource(
        scope: SessionRouteScope?,
        sessionId: String,
        attachmentId: String,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        let pathSegments = scope == .control
            ? ["control-sessions", sessionId, "attachments", attachmentId]
            : ["sessions", sessionId, "attachments", attachmentId]
        return AuthenticatedMediaSource(
            url: try makeURL(pathSegments: pathSegments),
            authorizationProvider: mediaAuthorizationProvider(),
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: environment.tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }
}
