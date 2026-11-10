import Foundation

extension APIClient {
    /// File bytes as Git stores them at `revision` (`HEAD`, a commit, or either
    /// with `^` for its parent), for the file a diff cannot show as text.
    func gitBlobURL(
        workspaceId: String,
        revision: String,
        path: String,
        worktreeId: String? = nil
    ) throws -> URL {
        try makeURL(
            pathSegments: ["workspaces", workspaceId, "git", "blob"],
            queryItems: [
                URLQueryItem(name: "rev", value: revision),
                URLQueryItem(name: "path", value: path),
            ] + workspaceWorktreeQueryItems(worktreeId)
        )
    }

    func getGitBlob(
        workspaceId: String,
        revision: String,
        path: String,
        worktreeId: String? = nil
    ) async throws -> Data {
        try await get(url: gitBlobURL(workspaceId: workspaceId, revision: revision, path: path, worktreeId: worktreeId))
    }

    /// A bearer-authenticated, range-capable source for AVPlayer. The server
    /// describes no media length for a blob, so there is no media-info URL.
    func makeGitBlobMediaSource(
        workspaceId: String,
        revision: String,
        path: String,
        worktreeId: String? = nil,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) throws -> AuthenticatedMediaSource {
        AuthenticatedMediaSource(
            url: try gitBlobURL(workspaceId: workspaceId, revision: revision, path: path, worktreeId: worktreeId),
            authorizationProvider: mediaAuthorizationProvider(),
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: environment.tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }
}
