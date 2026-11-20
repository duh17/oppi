import Foundation

// MARK: - Workspaces

extension APIClient {
    struct WorkspaceCatalogResponse: Decodable, Sendable {
        let serverNow: Int64?
        let workspaces: [Workspace]
        let summaries: [WorkspaceListSummary]?
    }

    /// List workspace cards, including optional list summaries for catalog/home UI.
    func listWorkspaceCatalog(includeGitSummary: Bool = true) async throws -> WorkspaceCatalogResponse {
        let query = includeGitSummary ? "?includeGitSummary=true" : ""
        return try await get("/workspaces\(query)", as: WorkspaceCatalogResponse.self)
    }

    /// List all workspaces for the authenticated user.
    func listWorkspaces() async throws -> [Workspace] {
        try await listWorkspaceCatalog(includeGitSummary: false).workspaces
    }

    /// List git worktrees/checkouts available inside a workspace.
    func listWorkspaceWorktrees(workspaceId: String) async throws -> [WorkspaceWorktree] {
        struct Response: Decodable { let worktrees: [WorkspaceWorktree] }
        return try await get("/workspaces/\(workspaceId)/worktrees", as: Response.self).worktrees
    }

    /// Create a new workspace.
    func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> Workspace {
        struct Response: Decodable { let workspace: Workspace }
        return try await post("/workspaces", body: request, as: Response.self).workspace
    }

    /// Update an existing workspace.
    func updateWorkspace(id: String, _ request: UpdateWorkspaceRequest) async throws -> Workspace {
        struct Response: Decodable { let workspace: Workspace }
        return try await put("/workspaces/\(id)", body: request.body, as: Response.self).workspace
    }

    /// Delete a workspace.
    func deleteWorkspace(id: String) async throws {
        _ = try await delete("/workspaces/\(id)")
    }

    /// Discover project directories on the host.
    ///
    /// Scans default roots (`~/workspace`, `~/projects`, `~/src`, `~/code`, `~/Developer`)
    /// and returns directories that look like projects (have `.git`, manifest files, or `AGENTS.md`).
    func listDirectories() async throws -> [HostDirectory] {
        struct Response: Decodable { let directories: [HostDirectory] }
        return try await get("/host/directories", as: Response.self).directories
    }

    /// Validate a manually entered host path.
    func getHostPathStatus(path: String) async throws -> HostPathStatus {
        struct Response: Decodable { let status: HostPathStatus }
        return try await get(
            url: makeURL(
                pathSegments: ["host", "path", "status"],
                queryItems: [URLQueryItem(name: "path", value: path)]
            ),
            as: Response.self
        ).status
    }

    /// Complete a manually entered host path using host directory names.
    func completeHostPath(prefix: String, limit: Int = 12) async throws -> [HostPathCompletion] {
        struct Response: Decodable { let completions: [HostPathCompletion] }
        return try await get(
            url: makeURL(
                pathSegments: ["host", "path", "completions"],
                queryItems: [
                    URLQueryItem(name: "prefix", value: prefix),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
            ),
            as: Response.self
        ).completions
    }

    /// Create a host directory after explicit user confirmation.
    func createHostPath(path: String) async throws -> HostPathCreateResult {
        struct Body: Encodable {
            let path: String
            let confirmed: Bool
        }
        return try await post("/host/path/create", body: Body(path: path, confirmed: true), as: HostPathCreateResult.self)
    }
}

// MARK: - Git

extension APIClient {
    /// Fetch a page of a checkout's commit graph: HEAD and every local branch,
    /// with the repository's worktrees on the first page.
    func getGitGraph(
        workspaceId: String,
        worktreeId: String?,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> CommitGraphResponse {
        var queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let query = try makePercentEncodedQuery(queryItems).map { "?\($0)" } ?? ""
        return try await get("/workspaces/\(workspaceId)/git/graph\(query)", as: CommitGraphResponse.self)
    }

    /// Fetch detailed info for a single commit (metadata + changed files).
    func getCommitDetail(workspaceId: String, sha: String) async throws -> GitCommitDetail {
        try await get("/workspaces/\(workspaceId)/git/commits/\(sha)", as: GitCommitDetail.self)
    }

    /// Fetch diff for a specific file in a commit.
    func getCommitFileDiff(workspaceId: String, sha: String, path: String) async throws -> WorkspaceReviewDiffResponse {
        let encodedPath = try encodeQueryPath(path)
        return try await get(
            "/workspaces/\(workspaceId)/git/commits/\(sha)/diff?path=\(encodedPath)",
            as: WorkspaceReviewDiffResponse.self
        )
    }

    /// Fetch the lightweight Git state used by workspace catalog rows.
    func getWorkspaceGitSummary(workspaceId: String) async throws -> WorkspaceGitSummary {
        try await get("/workspaces/\(workspaceId)/git/summary", as: WorkspaceGitSummary.self)
    }

    /// Fetch git status for a workspace checkout.
    func getGitStatus(workspaceId: String, worktreeId: String? = nil) async throws -> GitStatus {
        var queryItems: [URLQueryItem] = []
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let query = try makePercentEncodedQuery(queryItems).map { "?\($0)" } ?? ""
        return try await get("/workspaces/\(workspaceId)/git/status\(query)", as: GitStatus.self)
    }

    /// Fetch a review diff for a single workspace file.
    func getWorkspaceReviewDiff(
        workspaceId: String,
        path: String,
        selectedSessionId: String? = nil,
        worktreeId: String? = nil
    ) async throws -> WorkspaceReviewDiffResponse {
        var queryItems = [URLQueryItem(name: "path", value: path)]
        if let selectedSessionId, !selectedSessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "selectedSessionId", value: selectedSessionId))
        }
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let query = try makePercentEncodedQuery(queryItems) ?? ""
        return try await get("/workspaces/\(workspaceId)/git/diff?\(query)", as: WorkspaceReviewDiffResponse.self)
    }

    func getWorkspaceQuickActions(
        workspaceId: String,
        selectedSessionId: String? = nil,
        worktreeId: String? = nil
    ) async throws -> WorkspaceQuickActionsResponse {
        var queryItems: [URLQueryItem] = []
        if let selectedSessionId, !selectedSessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "selectedSessionId", value: selectedSessionId))
        }
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let query = try makePercentEncodedQuery(queryItems).map { "?\($0)" } ?? ""
        return try await get("/workspaces/\(workspaceId)/quick-actions\(query)", as: WorkspaceQuickActionsResponse.self)
    }

    /// The selected files and template both quick-action routes take.
    private struct QuickActionSelectionBody: Encodable {
        let paths: [String]
        let selectedSessionId: String?
        let worktreeId: String?
        let commitSha: String?
        let promptTemplateName: String
    }

    func prepareWorkspaceQuickActionSelection(
        workspaceId: String,
        paths: [String],
        selectedSessionId: String? = nil,
        worktreeId: String? = nil,
        commitSha: String? = nil,
        promptTemplateName: String
    ) async throws -> WorkspaceQuickActionSelectionResponse {
        try await post(
            "/workspaces/\(workspaceId)/quick-actions/selection",
            body: QuickActionSelectionBody(
                paths: paths,
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId,
                commitSha: commitSha,
                promptTemplateName: promptTemplateName
            ),
            as: WorkspaceQuickActionSelectionResponse.self
        )
    }

    /// Create and seed a focused follow-up session from a selected-files quick action.
    func createWorkspaceQuickActionSession(
        workspaceId: String,
        paths: [String],
        selectedSessionId: String? = nil,
        worktreeId: String? = nil,
        commitSha: String? = nil,
        promptTemplateName: String
    ) async throws -> WorkspaceQuickActionSessionResponse {
        try await post(
            "/workspaces/\(workspaceId)/quick-actions/session",
            body: QuickActionSelectionBody(
                paths: paths,
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId,
                commitSha: commitSha,
                promptTemplateName: promptTemplateName
            ),
            as: WorkspaceQuickActionSessionResponse.self
        )
    }
}
