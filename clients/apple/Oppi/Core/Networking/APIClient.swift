import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "APIClient")

/// REST client for oppi server.
///
/// Handles session CRUD, health checks, and authentication.
/// All methods throw on network/server errors with descriptive messages.
actor APIClient {
    enum SessionTraceView: String, Sendable {
        case context
        case full
    }

    let baseURL: URL
    let token: String
    private let session: URLSession
    private let trustDelegate: PinnedServerTrustDelegate

    init(baseURL: URL, token: String, tlsCertFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        trustDelegate = PinnedServerTrustDelegate(pinnedLeafFingerprint: tlsCertFingerprint)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: config,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Test-only init with custom URLSessionConfiguration.
    init(
        baseURL: URL,
        token: String,
        configuration: URLSessionConfiguration,
        tlsCertFingerprint: String? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        trustDelegate = PinnedServerTrustDelegate(pinnedLeafFingerprint: tlsCertFingerprint)
        session = URLSession(
            configuration: configuration,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - Health & Auth

    /// Check server reachability.
    func health() async throws -> Bool {
        let (_, response) = try await request("GET", path: "/health")
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Exchange a one-time pairing token for a long-lived auth device token.
    func pairDevice(pairingToken: String, deviceName: String? = nil) async throws -> PairDeviceResponse {
        let body = PairDeviceRequest(pairingToken: pairingToken, deviceName: deviceName)
        let (data, response) = try await requestNoAuth("POST", path: "/pair", body: body)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(PairDeviceResponse.self, from: data)
    }

    /// Get authenticated user info.
    func me() async throws -> User {
        let data = try await get("/me")
        return try JSONDecoder().decode(User.self, from: data)
    }

    /// Fetch server metadata (version, uptime, stats) for the server detail view.
    func serverInfo() async throws -> ServerInfo {
        let data = try await get("/server/info")
        return try JSONDecoder().decode(ServerInfo.self, from: data)
    }

    /// Client timezone offset in minutes (e.g. PDT = -420).
    /// Sent to the server so daily/hourly buckets align with the user's local time.
    private static var tzOffsetMinutes: Int {
        TimeZone.current.secondsFromGMT() / 60
    }

    /// Fetch server stats for the given number of days.
    func fetchStats(range: Int = 7) async throws -> ServerStats {
        let tz = Self.tzOffsetMinutes
        let data = try await get("/server/stats?range=\(range)&tz=\(tz)")
        return try JSONDecoder().decode(ServerStats.self, from: data)
    }

    /// Fetch hourly breakdown for a specific day.
    func fetchDailyDetail(date: String) async throws -> DailyDetail {
        let tz = Self.tzOffsetMinutes
        let data = try await get("/server/stats/daily/\(date)?tz=\(tz)")
        return try JSONDecoder().decode(DailyDetail.self, from: data)
    }

    /// Fetch normalized Codex subscription usage windows from the server.
    func fetchCodexUsage() async throws -> CodexUsageInfo {
        let data = try await get("/server/codex-usage")
        return try JSONDecoder().decode(CodexUsageInfo.self, from: data)
    }

    struct RuntimeUpdateResult: Decodable, Sendable, Equatable {
        let ok: Bool
        let message: String
        let latestVersion: String?
        let pendingVersion: String?
        let restartRequired: Bool
        let error: String?
    }

    struct RuntimeUpdateResponse: Decodable, Sendable, Equatable {
        let ok: Bool
        let result: RuntimeUpdateResult
        let status: ServerInfo.RuntimeUpdateInfo
    }

    // MARK: - Server-managed agent config

    func getSubagentConfig() async throws -> SubagentConfig {
        let data = try await get("/server/subagents")
        return try JSONDecoder().decode(SubagentConfig.self, from: data)
    }

    func setSubagentConfig(_ config: SubagentConfig) async throws -> SubagentConfig {
        let (data, response) = try await request("PUT", path: "/server/subagents", body: config)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(SubagentConfig.self, from: data)
    }

    /// Trigger a server runtime update (`npm install -g <runtime>@latest`).
    ///
    /// Returns operation result plus the latest runtime update status snapshot.
    func updateRuntime() async throws -> RuntimeUpdateResponse {
        let data = try await post("/server/runtime/update", body: EmptyBody())
        return try JSONDecoder().decode(RuntimeUpdateResponse.self, from: data)
    }

    // MARK: - Sessions

    /// Full-text search across session content.
    func searchSessions(
        query: String,
        workspaceId: String? = nil,
        limit: Int = 20
    ) async throws -> SessionSearchResponse {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let workspaceId {
            items.append(URLQueryItem(name: "workspaceId", value: workspaceId))
        }
        var components = URLComponents()
        components.queryItems = items
        let qs = components.percentEncodedQuery ?? ""
        let data = try await get("/sessions/search?\(qs)")
        return try JSONDecoder().decode(SessionSearchResponse.self, from: data)
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Create a new session in a target workspace.
    ///
    /// If `workspaceId` is nil, the first available workspace is used.
    func createSession(
        name: String? = nil,
        model: String? = nil,
        workspaceId: String? = nil,
        ephemeral: Bool? = nil
    ) async throws -> Session {
        if let workspaceId, !workspaceId.isEmpty {
            return try await createWorkspaceSession(
                workspaceId: workspaceId,
                name: name,
                model: model,
                ephemeral: ephemeral
            ).session
        }

        let workspaces = try await listWorkspaces()
        guard let fallbackWorkspace = workspaces.first else {
            throw APIError.server(status: 404, message: "No workspaces available")
        }

        return try await createWorkspaceSession(
            workspaceId: fallbackWorkspace.id,
            name: name,
            model: model,
            ephemeral: ephemeral
        ).session
    }

    struct SequencedServerEvent: Sendable, Equatable {
        let seq: Int
        let message: ServerMessage
    }

    struct SessionEventsResponse: Sendable, Equatable {
        let events: [SequencedServerEvent]
        let currentSeq: Int
        let session: Session
        let catchUpComplete: Bool
    }

    /// Fetch sequenced durable session events after `since` for reconnect catch-up.
    ///
    /// Decodes the response in a single pass using `Decodable` — no intermediate
    /// `JSONValue` tree, no per-event re-encode/re-decode round-trip.
    func getSessionEvents(workspaceId: String, id: String, since: Int) async throws -> SessionEventsResponse {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(id)/events?since=\(since)")

        let payload = try JSONDecoder().decode(SessionEventsPayload.self, from: data)

        let events = payload.events.map {
            SequencedServerEvent(seq: $0.seq, message: $0.message)
        }

        return SessionEventsResponse(
            events: events,
            currentSeq: payload.currentSeq,
            session: payload.session,
            catchUpComplete: payload.catchUpComplete
        )
    }

    /// Wire format for `/workspaces/:workspaceId/sessions/:id/events` response.
    ///
    /// Each event object has `seq` alongside the `ServerMessage` fields:
    /// `{ "seq": 42, "type": "text_delta", "delta": "hello" }`.
    /// The wrapper decodes `seq` then delegates the rest to `ServerMessage.init(from:)`.
    private struct SessionEventsPayload: Decodable {
        let events: [SequencedEventEntry]
        let currentSeq: Int
        let catchUpComplete: Bool
        let session: Session
    }

    private struct SequencedEventEntry: Decodable {
        let seq: Int
        let message: ServerMessage

        private enum CodingKeys: String, CodingKey {
            case seq
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seq = try container.decode(Int.self, forKey: .seq)
            message = try ServerMessage(from: decoder)
        }
    }

    /// Get a session with trace events for either context or full timeline view.
    func getSession(
        workspaceId: String,
        id: String,
        traceView: SessionTraceView = .context
    ) async throws -> (session: Session, trace: [TraceEvent]) {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(id)?view=\(traceView.rawValue)")
        struct Response: Decodable { let session: Session; let trace: [TraceEvent] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.session, response.trace)
    }

    /// Stop a running session.
    func stopSession(workspaceId: String, id: String) async throws -> Session {
        let data = try await post("/workspaces/\(workspaceId)/sessions/\(id)/stop", body: EmptyBody())
        struct Response: Decodable { let session: Session? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let session = response.session { return session }
        return try await getSession(workspaceId: workspaceId, id: id).session
    }

    /// Delete a session permanently.
    func deleteSession(workspaceId: String, id: String) async throws {
        _ = try await request("DELETE", path: "/workspaces/\(workspaceId)/sessions/\(id)")
    }

    // MARK: - Permissions

    // periphery:ignore - used by APIClientTests via @testable import
    /// Resolve a pending permission request through REST.
    ///
    /// Used by action surfaces that may not have a live WebSocket (for example,
    /// Live Activity intents waking the app process).
    func respondToPermission(
        id: String,
        action: PermissionAction,
        scope: PermissionScope = .once,
        expiresInMs: Int? = nil
    ) async throws {
        struct Body: Encodable {
            let action: String
            let scope: String
            let expiresInMs: Int?
        }

        _ = try await post(
            "/permissions/\(id)/respond",
            body: Body(action: action.rawValue, scope: scope.rawValue, expiresInMs: expiresInMs)
        )
    }

    // MARK: - Models

    /// Fetch available models from the server.
    func listModels() async throws -> [ModelInfo] {
        let data = try await get("/models")
        struct Response: Decodable { let models: [ModelInfo] }
        return try JSONDecoder().decode(Response.self, from: data).models
    }

    // MARK: - Provider Auth

    /// List provider auth status (OAuth/API key) from the server.
    func listProviderAuthStatus() async throws -> [ProviderAuthProviderStatus] {
        let data = try await get("/provider-auth/status")
        struct Response: Decodable { let providers: [ProviderAuthProviderStatus] }
        return try JSONDecoder().decode(Response.self, from: data).providers
    }

    /// Start an OAuth/device-code flow for a provider.
    func startProviderAuthFlow(
        providerId: String,
        launchMode: ProviderAuthFlowSnapshot.LaunchMode = .serverBrowser
    ) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable {
            let providerId: String
            let launchMode: ProviderAuthFlowSnapshot.LaunchMode
        }

        let data = try await post(
            "/provider-auth/flows",
            body: Body(providerId: providerId, launchMode: launchMode)
        )
        struct Response: Decodable { let flow: ProviderAuthFlowSnapshot }
        return try JSONDecoder().decode(Response.self, from: data).flow
    }

    /// Fetch latest state for an in-flight provider auth flow.
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        let data = try await get("/provider-auth/flows/\(flowId)")
        struct Response: Decodable { let flow: ProviderAuthFlowSnapshot }
        return try JSONDecoder().decode(Response.self, from: data).flow
    }

    /// Submit response for a provider flow prompt.
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable { let value: String }
        let data = try await post(
            "/provider-auth/flows/\(flowId)/prompt-response",
            body: Body(value: value)
        )
        struct Response: Decodable { let flow: ProviderAuthFlowSnapshot }
        return try JSONDecoder().decode(Response.self, from: data).flow
    }

    /// Submit manually pasted callback URL/code for a provider flow.
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable { let input: String }
        let data = try await post(
            "/provider-auth/flows/\(flowId)/manual-code",
            body: Body(input: input)
        )
        struct Response: Decodable { let flow: ProviderAuthFlowSnapshot }
        return try JSONDecoder().decode(Response.self, from: data).flow
    }

    /// Cancel an in-flight provider auth flow.
    func cancelProviderAuthFlow(flowId: String, reason: String? = nil) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable { let reason: String? }
        let data = try await post(
            "/provider-auth/flows/\(flowId)/cancel",
            body: Body(reason: reason)
        )
        struct Response: Decodable { let flow: ProviderAuthFlowSnapshot }
        return try JSONDecoder().decode(Response.self, from: data).flow
    }

    /// Save an API key credential for a provider.
    func setProviderAPIKey(providerId: String, key: String) async throws {
        struct Body: Encodable {
            let providerId: String
            let key: String
        }
        _ = try await put(
            "/provider-auth/api-key",
            body: Body(providerId: providerId, key: key)
        )
    }

    /// Remove saved credential for a provider.
    func removeProviderCredential(providerId: String) async throws {
        let (data, response) = try await request("DELETE", path: "/provider-auth/\(providerId)")
        try checkStatus(response, data: data)
    }

    // MARK: - Auto-Title

    /// Server-side auto-title configuration.
    struct AutoTitleConfig: Codable, Sendable {
        var enabled: Bool
        var model: String?
    }

    /// Fetch the current auto-title configuration.
    func getAutoTitleConfig() async throws -> AutoTitleConfig {
        let data = try await get("/server/auto-title")
        return try JSONDecoder().decode(AutoTitleConfig.self, from: data)
    }

    /// Update the auto-title configuration.
    @discardableResult
    func setAutoTitleConfig(_ config: AutoTitleConfig) async throws -> AutoTitleConfig {
        let data = try await put("/server/auto-title", body: config)
        return try JSONDecoder().decode(AutoTitleConfig.self, from: data)
    }

    // MARK: - Themes

    /// List available custom themes on the server.
    func listThemes() async throws -> [RemoteThemeSummary] {
        let data = try await get("/themes")
        struct Response: Decodable { let themes: [RemoteThemeSummary] }
        return try JSONDecoder().decode(Response.self, from: data).themes
    }

    /// Fetch a full theme by name.
    func getTheme(name: String) async throws -> RemoteTheme {
        let data = try await get("/themes/\(name)")
        struct Response: Decodable { let theme: RemoteTheme }
        return try JSONDecoder().decode(Response.self, from: data).theme
    }

    // MARK: - Workspaces

    /// List all workspaces for the authenticated user.
    func listWorkspaces() async throws -> [Workspace] {
        let data = try await get("/workspaces")
        struct Response: Decodable { let workspaces: [Workspace] }
        return try JSONDecoder().decode(Response.self, from: data).workspaces
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Get a single workspace.
    func getWorkspace(id: String) async throws -> Workspace {
        let data = try await get("/workspaces/\(id)")
        struct Response: Decodable { let workspace: Workspace }
        return try JSONDecoder().decode(Response.self, from: data).workspace
    }

    /// Create a new workspace.
    func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> Workspace {
        let data = try await post("/workspaces", body: request)
        struct Response: Decodable { let workspace: Workspace }
        return try JSONDecoder().decode(Response.self, from: data).workspace
    }

    /// Update an existing workspace.
    func updateWorkspace(id: String, _ request: UpdateWorkspaceRequest) async throws -> Workspace {
        let data = try await put("/workspaces/\(id)", body: request.body)
        struct Response: Decodable { let workspace: Workspace }
        return try JSONDecoder().decode(Response.self, from: data).workspace
    }

    /// Fetch the current Pi base system prompt resolved for a workspace.
    func getWorkspaceBaseSystemPrompt(id: String) async throws -> String {
        let data = try await get("/workspaces/\(id)/system-prompt/base")
        struct Response: Decodable { let systemPrompt: String }
        return try JSONDecoder().decode(Response.self, from: data).systemPrompt
    }

    /// Delete a workspace.
    func deleteWorkspace(id: String) async throws {
        _ = try await request("DELETE", path: "/workspaces/\(id)")
    }

    /// Fetch workspace fork/session graph with optional branch entry tree.
    func getWorkspaceGraph(
        workspaceId: String,
        sessionId: String? = nil,
        includeEntryGraph: Bool = false,
        entrySessionId: String? = nil,
        includePaths: Bool = false
    ) async throws -> WorkspaceGraphResponse {
        var query: [String] = []

        if let sessionId, !sessionId.isEmpty {
            try query.append("sessionId=\(encodeQueryPath(sessionId))")
        }

        if includeEntryGraph {
            query.append("include=entry")
        }

        if let entrySessionId, !entrySessionId.isEmpty {
            try query.append("entrySessionId=\(encodeQueryPath(entrySessionId))")
        }

        if includePaths {
            query.append("includePaths=true")
        }

        let route = if query.isEmpty {
            "/workspaces/\(workspaceId)/graph"
        } else {
            "/workspaces/\(workspaceId)/graph?\(query.joined(separator: "&"))"
        }

        let data = try await get(route)
        return try JSONDecoder().decode(WorkspaceGraphResponse.self, from: data)
    }

    // MARK: - Git Commits

    /// Fetch paginated commit log for a workspace.
    func getCommitLog(workspaceId: String, offset: Int = 0, limit: Int = 20) async throws -> GitCommitLogResponse {
        let data = try await get("/workspaces/\(workspaceId)/git/commits?offset=\(offset)&limit=\(limit)")
        return try JSONDecoder().decode(GitCommitLogResponse.self, from: data)
    }

    /// Fetch detailed info for a single commit (metadata + changed files).
    func getCommitDetail(workspaceId: String, sha: String) async throws -> GitCommitDetail {
        let data = try await get("/workspaces/\(workspaceId)/git/commits/\(sha)")
        return try JSONDecoder().decode(GitCommitDetail.self, from: data)
    }

    /// Fetch diff for a specific file in a commit.
    func getCommitFileDiff(workspaceId: String, sha: String, path: String) async throws -> WorkspaceReviewDiffResponse {
        let encodedPath = try encodeQueryPath(path)
        let data = try await get("/workspaces/\(workspaceId)/git/commits/\(sha)/diff?path=\(encodedPath)")
        return try JSONDecoder().decode(WorkspaceReviewDiffResponse.self, from: data)
    }

    // MARK: - Git Status

    /// Fetch git status for a workspace's host directory.
    func getGitStatus(workspaceId: String) async throws -> GitStatus {
        let data = try await get("/workspaces/\(workspaceId)/git-status")
        return try JSONDecoder().decode(GitStatus.self, from: data)
    }

    /// Fetch a review diff for a single workspace file.
    func getWorkspaceReviewDiff(
        workspaceId: String,
        path: String
    ) async throws -> WorkspaceReviewDiffResponse {
        let encodedPath = try encodeQueryPath(path)
        let route = "/workspaces/\(workspaceId)/review/diff?path=\(encodedPath)"
        let data = try await get(route)
        return try JSONDecoder().decode(WorkspaceReviewDiffResponse.self, from: data)
    }

    func prepareWorkspaceReviewSelection(
        workspaceId: String,
        action: WorkspaceReviewSessionAction,
        paths: [String],
        selectedSessionId: String? = nil
    ) async throws -> WorkspaceReviewSelectionResponse {
        struct Body: Encodable {
            let action: WorkspaceReviewSessionAction
            let paths: [String]
            let selectedSessionId: String?
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/review/selection",
            body: Body(action: action, paths: paths, selectedSessionId: selectedSessionId)
        )
        return try JSONDecoder().decode(WorkspaceReviewSelectionResponse.self, from: data)
    }

    /// Create and seed a focused follow-up session from the workspace review selection.
    func createWorkspaceReviewSession(
        workspaceId: String,
        action: WorkspaceReviewSessionAction,
        paths: [String],
        selectedSessionId: String? = nil
    ) async throws -> WorkspaceReviewSessionResponse {
        struct Body: Encodable {
            let action: WorkspaceReviewSessionAction
            let paths: [String]
            let selectedSessionId: String?
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/review/session",
            body: Body(action: action, paths: paths, selectedSessionId: selectedSessionId)
        )
        return try JSONDecoder().decode(WorkspaceReviewSessionResponse.self, from: data)
    }

    func listReviewComments(
        workspaceId: String,
        sessionId: String? = nil,
        status: ReviewCommentStatus? = nil
    ) async throws -> [ReviewComment] {
        var query: [String] = []
        if let sessionId {
            try query.append("sessionId=\(encodeQueryPath(sessionId))")
        }
        if let status {
            query.append("status=\(status.rawValue)")
        }
        let suffix = query.isEmpty ? "" : "?\(query.joined(separator: "&"))"
        let data = try await get("/workspaces/\(workspaceId)/review/comments\(suffix)")
        return try JSONDecoder().decode(ReviewCommentsResponse.self, from: data).comments
    }

    func createReviewComment(
        workspaceId: String,
        sessionId: String?,
        body: String,
        reference: ReviewCommentReference
    ) async throws -> ReviewComment {
        struct Body: Encodable {
            let sessionId: String?
            let body: String
            let reference: ReviewCommentReference
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/review/comments",
            body: Body(sessionId: sessionId, body: body, reference: reference)
        )
        return try JSONDecoder().decode(ReviewCommentResponse.self, from: data).comment
    }

    func updateReviewComment(
        workspaceId: String,
        commentId: String,
        body: String? = nil,
        status: ReviewCommentStatus? = nil,
        severity: ReviewCommentSeverity? = nil
    ) async throws -> ReviewComment {
        struct Body: Encodable {
            let status: ReviewCommentStatus?
            let severity: ReviewCommentSeverity?
            let body: String?
        }

        let (data, response) = try await request(
            "PATCH",
            path: "/workspaces/\(workspaceId)/review/comments/\(commentId)",
            body: Body(status: status, severity: severity, body: body)
        )
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(ReviewCommentResponse.self, from: data).comment
    }

    func deleteReviewComment(workspaceId: String, commentId: String) async throws {
        let (data, response) = try await request(
            "DELETE",
            path: "/workspaces/\(workspaceId)/review/comments/\(commentId)"
        )
        try checkStatus(response, data: data)
    }

    func markReviewCommentsSent(
        workspaceId: String,
        ids: [String],
        sessionId: String? = nil
    ) async throws -> [ReviewComment] {
        struct Body: Encodable {
            let ids: [String]
            let sessionId: String?
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/review/comments/attach-to-turn",
            body: Body(ids: ids, sessionId: sessionId)
        )
        return try JSONDecoder().decode(ReviewCommentsResponse.self, from: data).comments
    }

    // MARK: - Safety Policy

    /// Get the global default fallback action when no rule matches.
    func getPolicyFallback() async throws -> PolicyFallbackDecision {
        let data = try await get("/policy/fallback")
        return try JSONDecoder().decode(PolicyFallbackResponse.self, from: data).fallback
    }

    /// Update the global default fallback action when no rule matches.
    func patchPolicyFallback(_ fallback: PolicyFallbackDecision) async throws -> PolicyFallbackDecision {
        struct Body: Encodable { let fallback: String }
        let (data, response) = try await request(
            "PATCH",
            path: "/policy/fallback",
            body: Body(fallback: fallback.rawValue)
        )
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(PolicyFallbackResponse.self, from: data).fallback
    }

    /// List effective learned/manual policy rules visible to the user.
    func listPolicyRules(workspaceId: String? = nil) async throws -> [PolicyRuleRecord] {
        var route = "/policy/rules"
        if let workspaceId {
            try route += "?workspaceId=\(encodeQueryPath(workspaceId))"
        }
        let data = try await get(route)
        struct Response: Decodable { let rules: [PolicyRuleRecord] }
        return try JSONDecoder().decode(Response.self, from: data).rules
    }

    /// Create a remembered policy rule.
    func createPolicyRule(request body: PolicyRuleCreateRequest) async throws -> PolicyRuleRecord {
        let (data, response) = try await request("POST", path: "/policy/rules", body: body)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(PolicyRuleMutationResponse.self, from: data).rule
    }

    /// Update an existing remembered policy rule.
    func patchPolicyRule(ruleId: String, request body: PolicyRulePatchRequest) async throws -> PolicyRuleRecord {
        let (data, response) = try await request("PATCH", path: "/policy/rules/\(ruleId)", body: body)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(PolicyRuleMutationResponse.self, from: data).rule
    }

    /// Delete a remembered policy rule by id.
    func deletePolicyRule(ruleId: String) async throws {
        let (data, response) = try await request("DELETE", path: "/policy/rules/\(ruleId)")
        try checkStatus(response, data: data)
    }

    /// Fetch recent policy audit decisions for the workspace/user.
    func listPolicyAudit(
        workspaceId: String? = nil,
        sessionId: String? = nil,
        limit: Int = 50,
        before: Date? = nil
    ) async throws -> [PolicyAuditEntry] {
        var query = ["limit=\(limit)"]
        if let workspaceId {
            try query.append("workspaceId=\(encodeQueryPath(workspaceId))")
        }
        if let sessionId {
            try query.append("sessionId=\(encodeQueryPath(sessionId))")
        }
        if let before {
            let ms = Int(before.timeIntervalSince1970 * 1000)
            query.append("before=\(ms)")
        }

        let route = "/policy/audit?\(query.joined(separator: "&"))"
        let data = try await get(route)
        struct Response: Decodable { let entries: [PolicyAuditEntry] }
        return try JSONDecoder().decode(Response.self, from: data).entries
    }

    // MARK: - Skills

    /// List available skills from the host's skill pool.
    func listSkills() async throws -> [SkillInfo] {
        let data = try await get("/skills")
        struct Response: Decodable { let skills: [SkillInfo] }
        return try JSONDecoder().decode(Response.self, from: data).skills
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Rescan host skills (e.g. after adding a new skill on the server).
    func rescanSkills() async throws -> [SkillInfo] {
        let data = try await post("/skills/rescan", body: EmptyBody())
        struct Response: Decodable { let skills: [SkillInfo] }
        return try JSONDecoder().decode(Response.self, from: data).skills
    }

    /// List available host extensions for the current workspace context.
    ///
    /// The server resolves extensions using pi's resource resolver, including
    /// auto-discovered dirs, settings paths, and installed package extensions.
    func listExtensions(cwd: String? = nil) async throws -> [ExtensionInfo] {
        var path = "/extensions"
        if let cwd, !cwd.isEmpty {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "cwd", value: cwd)]
            if let query = components.percentEncodedQuery {
                path += "?\(query)"
            }
        }

        let data = try await get(path)
        struct Response: Decodable { let extensions: [ExtensionInfo] }
        return try JSONDecoder().decode(Response.self, from: data).extensions
    }

    /// Discover project directories on the host.
    ///
    /// Scans default roots (`~/workspace`, `~/projects`, `~/src`, `~/code`, `~/Developer`)
    /// and returns directories that look like projects (have `.git`, manifest files, or `AGENTS.md`).
    func listDirectories() async throws -> [HostDirectory] {
        let data = try await get("/host/directories")
        struct Response: Decodable { let directories: [HostDirectory] }
        return try JSONDecoder().decode(Response.self, from: data).directories
    }

    /// Validate a manually entered host path.
    func getHostPathStatus(path: String) async throws -> HostPathStatus {
        let data = try await get(
            url: makeURL(
                pathSegments: ["host", "path", "status"],
                queryItems: [URLQueryItem(name: "path", value: path)]
            )
        )
        struct Response: Decodable { let status: HostPathStatus }
        return try JSONDecoder().decode(Response.self, from: data).status
    }

    /// Complete a manually entered host path using host directory names.
    func completeHostPath(prefix: String, limit: Int = 12) async throws -> [HostPathCompletion] {
        let data = try await get(
            url: makeURL(
                pathSegments: ["host", "path", "completions"],
                queryItems: [
                    URLQueryItem(name: "prefix", value: prefix),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
            )
        )
        struct Response: Decodable { let completions: [HostPathCompletion] }
        return try JSONDecoder().decode(Response.self, from: data).completions
    }

    /// Create a host directory after explicit user confirmation.
    func createHostPath(path: String) async throws -> HostPathCreateResult {
        struct Body: Encodable {
            let path: String
            let confirmed: Bool
        }
        let data = try await post(
            "/host/path/create",
            body: Body(path: path, confirmed: true)
        )
        return try JSONDecoder().decode(HostPathCreateResult.self, from: data)
    }

    /// Get full skill detail: metadata, SKILL.md content, and file tree.
    func getSkillDetail(name: String) async throws -> SkillDetail {
        let data = try await get("/skills/\(name)")
        return try JSONDecoder().decode(SkillDetail.self, from: data)
    }

    /// Get a single file's content from a skill directory.
    func getSkillFile(name: String, path: String) async throws -> String {
        let data = try await get(url: makeSkillFileURL(name: name, path: path))
        struct Response: Decodable { let content: String }
        return try JSONDecoder().decode(Response.self, from: data).content
    }

    // periphery:ignore - API surface for future skills editor UI
    /// Create or update a user skill via inline content.
    ///
    /// Calls `PUT /me/skills/:name` with SKILL.md content and optional extra files.
    /// Built-in skills cannot be overwritten.
    func putUserSkill(
        name: String,
        content: String?,
        files: [String: String]? = nil
    ) async throws {
        struct Body: Encodable {
            let content: String?
            let files: [String: String]?
        }
        _ = try await put("/me/skills/\(name)", body: Body(content: content, files: files))
    }

    // MARK: - Workspace-scoped Sessions (v2 API)

    struct WorkspaceSessionSummariesResponse: Decodable {
        let sessionSummaries: [SessionSummary]

        enum CodingKeys: String, CodingKey {
            case sessionSummaries = "sessions"
        }
    }

    struct WorkspaceAttentionResponse: Decodable, Sendable {
        struct Attention: Decodable, Sendable {
            let permissions: [PermissionRequest]
            let asks: [AskRequest]
        }

        let workspaceId: String
        let serverNow: Int64
        let attention: Attention
    }

    struct WorkspaceSessionListResponse: Decodable, Sendable {
        let workspace: Workspace
        let serverNow: Int64
        let sessionSummaries: [SessionSummary]
        let attention: WorkspaceAttentionResponse.Attention
        let importableSessions: [LocalSession]
        let archiveBuckets: [WorkspaceSessionArchiveBucket]

        enum CodingKeys: String, CodingKey {
            case workspace, serverNow, attention, importableSessions, archiveBuckets
            case sessionSummaries = "sessions"
        }
    }

    struct WorkspaceSessionListBucketResponse: Decodable, Sendable {
        let workspaceId: String
        let sinceMs: Int64
        let untilMs: Int64
        let sessionSummaries: [SessionSummary]
        let importableSessions: [LocalSession]

        enum CodingKeys: String, CodingKey {
            case workspaceId, sinceMs, untilMs, importableSessions
            case sessionSummaries = "sessions"
        }
    }

    struct WorkspaceSummariesResponse: Decodable, Sendable {
        let serverNow: Int64
        let summaries: [WorkspaceListSummary]
    }

    func listWorkspaceSummaries() async throws -> WorkspaceSummariesResponse {
        let data = try await get("/workspace-summaries")
        return try JSONDecoder().decode(WorkspaceSummariesResponse.self, from: data)
    }

    func getWorkspaceSessionList(
        workspaceId: String,
        since: Date,
        until: Date
    ) async throws -> WorkspaceSessionListResponse {
        let sinceMs = Int(since.timeIntervalSince1970 * 1000)
        let untilMs = Int(until.timeIntervalSince1970 * 1000)
        let data = try await get("/workspaces/\(workspaceId)/session-list?sinceMs=\(sinceMs)&untilMs=\(untilMs)")
        return try JSONDecoder().decode(WorkspaceSessionListResponse.self, from: data)
    }

    func getWorkspaceSessionListBucket(
        workspaceId: String,
        since: Date,
        until: Date
    ) async throws -> WorkspaceSessionListBucketResponse {
        let sinceMs = Int(since.timeIntervalSince1970 * 1000)
        let untilMs = Int(until.timeIntervalSince1970 * 1000)
        let data = try await get("/workspaces/\(workspaceId)/session-list-bucket?sinceMs=\(sinceMs)&untilMs=\(untilMs)")
        return try JSONDecoder().decode(WorkspaceSessionListBucketResponse.self, from: data)
    }

    /// List all workspace session summaries.
    func listAllWorkspaceSessionSummaries(workspaceId: String) async throws -> [SessionSummary] {
        let data = try await get("/workspaces/\(workspaceId)/sessions")
        return try JSONDecoder().decode(WorkspaceSessionSummariesResponse.self, from: data).sessionSummaries
    }

    /// List recent workspace session summaries for one workspace.
    func listRecentWorkspaceSessionSummaries(
        workspaceId: String,
        recentDays: Int = 3
    ) async throws -> [SessionSummary] {
        let data = try await get("/workspaces/\(workspaceId)/sessions?recentDays=\(recentDays)")
        return try JSONDecoder().decode(WorkspaceSessionSummariesResponse.self, from: data).sessionSummaries
    }

    /// List recent session summaries across all workspaces with one server request.
    func listRecentWorkspaceSessionSummaries(recentDays: Int = 3) async throws -> [SessionSummary] {
        let data = try await get("/workspace-session-summaries?recentDays=\(recentDays)")
        return try JSONDecoder().decode(WorkspaceSessionSummariesResponse.self, from: data).sessionSummaries
    }

    /// Bootstrap helper for flows that have an API client but no populated workspace store yet.
    func listSessionsFromWorkspaces(recentDays: Int = 3) async throws -> [Session] {
        let summaries = try await listRecentWorkspaceSessionSummaries(recentDays: recentDays)
        return summaries.map(\.session)
    }

    /// Create a new session in a specific workspace.
    /// Create a new session in a workspace.
    ///
    /// When `prompt` is provided, the server auto-resumes the session and delivers
    /// the first message — no WebSocket round-trip needed. The response includes
    /// `prompted: true` on success.
    func createWorkspaceSession(
        workspaceId: String,
        name: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        thinking: String? = nil,
        ephemeral: Bool? = nil,
        attachments: [ChatAttachmentRef]? = nil,
        images: [ImageAttachment]? = nil
    ) async throws -> CreateSessionResponse {
        struct ImageBody: Encodable {
            let type: String
            let data: String
            let mimeType: String
        }
        struct Body: Encodable {
            let name: String?
            let model: String?
            let prompt: String?
            let thinking: String?
            let ephemeral: Bool?
            let attachments: [ChatAttachmentRef]?
            let images: [ImageBody]?
        }
        let imagesBodies = images?.map { ImageBody(type: "image", data: $0.data, mimeType: $0.mimeType) }
        let data = try await post(
            "/workspaces/\(workspaceId)/sessions",
            body: Body(
                name: name,
                model: model,
                prompt: prompt,
                thinking: thinking,
                ephemeral: ephemeral,
                attachments: attachments,
                images: imagesBodies
            )
        )
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    /// Response from session creation. Includes `prompted` when a prompt was provided.
    struct CreateSessionResponse: Decodable, Sendable {
        let session: Session
        let prompted: Bool?
    }

    struct CreateUploadResponse: Decodable, Sendable {
        let uploadId: String
        let contentUrl: String
        let maxFileBytes: Int
        let expiresAt: Int
    }

    struct UploadContentResponse: Decodable, Sendable {
        let attachment: ChatAttachmentRef
    }

    struct UploadMetadataResponse: Decodable, Sendable {
        struct Upload: Decodable, Sendable {
            let id: String
            let status: String
            let name: String
            let mimeType: String
            let detectedMimeType: String?
            let sizeBytes: Int?
            let sha256: String?
            let kind: AttachmentKind?
            let createdAt: Int
            let expiresAt: Int
        }

        let upload: Upload
    }

    func createUpload(
        workspaceId: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        purpose: String = "chat_attachment"
    ) async throws -> CreateUploadResponse {
        struct Body: Encodable {
            let name: String
            let mimeType: String
            let sizeBytes: Int
            let purpose: String
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/uploads",
            body: Body(name: name, mimeType: mimeType, sizeBytes: sizeBytes, purpose: purpose)
        )
        return try JSONDecoder().decode(CreateUploadResponse.self, from: data)
    }

    func uploadAttachmentContent(
        workspaceId: String,
        uploadId: String,
        data body: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> ChatAttachmentRef {
        let (data, response) = try await request(
            "PUT",
            path: "/workspaces/\(workspaceId)/uploads/\(uploadId)/content",
            body: body,
            contentType: contentType
        )
        try checkStatus(response, data: data)
        let parsed = try JSONDecoder().decode(UploadContentResponse.self, from: data)
        return parsed.attachment
    }

    func getUploadMetadata(workspaceId: String, uploadId: String) async throws -> UploadMetadataResponse {
        let data = try await get("/workspaces/\(workspaceId)/uploads/\(uploadId)")
        return try JSONDecoder().decode(UploadMetadataResponse.self, from: data)
    }

    /// Create a session that resumes an existing local pi TUI session.
    func createWorkspaceSessionFromLocal(workspaceId: String, piSessionFile: String) async throws -> Session {
        struct Body: Encodable { let piSessionFile: String }
        let data = try await post("/workspaces/\(workspaceId)/sessions", body: Body(piSessionFile: piSessionFile))
        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Resume a stopped session in its workspace.
    func resumeWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        let data = try await post("/workspaces/\(workspaceId)/sessions/\(sessionId)/resume", body: EmptyBody())
        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Create a branched fork session from a source session entry.
    func forkWorkspaceSession(
        workspaceId: String,
        sessionId: String,
        entryId: String,
        name: String? = nil
    ) async throws -> Session {
        struct Body: Encodable {
            let entryId: String
            let name: String?
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/sessions/\(sessionId)/fork",
            body: Body(entryId: entryId, name: name)
        )

        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Stop a session via its workspace.
    func stopWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        try await stopSession(workspaceId: workspaceId, id: sessionId)
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Get session detail via workspace path.
    func getWorkspaceSession(
        workspaceId: String,
        sessionId: String,
        traceView: SessionTraceView = .context
    ) async throws -> (session: Session, trace: [TraceEvent]) {
        try await getSession(workspaceId: workspaceId, id: sessionId, traceView: traceView)
    }

    /// Delete a session via workspace path.
    func deleteWorkspaceSession(workspaceId: String, sessionId: String) async throws {
        try await deleteSession(workspaceId: workspaceId, id: sessionId)
    }

    // MARK: - Tool Output & Files

    /// Fetch the full tool output for a specific tool call ID from the session's JSONL trace.
    ///
    /// Used to lazy-load evicted tool output when the user expands an old tool call row.
    func getToolOutput(workspaceId: String, sessionId: String, toolCallId: String) async throws -> (output: String, isError: Bool) {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/tool-output/\(toolCallId)")
        struct Response: Decodable { let output: String; let isError: Bool }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.output, response.isError)
    }

    /// Fetch full tool output and return nil if it is empty/whitespace-only.
    func getNonEmptyToolOutput(workspaceId: String, sessionId: String, toolCallId: String) async throws -> String? {
        let (output, _) = try await getToolOutput(workspaceId: workspaceId, sessionId: sessionId, toolCallId: toolCallId)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : output
    }

    /// Fetch raw full (untruncated) tool output from the server temp-file side channel.
    ///
    /// Returns nil when the server no longer has the backing temp file (404).
    func getFullToolOutput(workspaceId: String, sessionId: String, toolCallId: String) async throws -> String? {
        do {
            let data = try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/tool-output/\(toolCallId)/full")
            struct Response: Decodable { let output: String }
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.output
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    /// Fetch full untruncated tool output and return nil if empty/whitespace-only.
    func getNonEmptyFullToolOutput(workspaceId: String, sessionId: String, toolCallId: String) async throws -> String? {
        guard let output = try await getFullToolOutput(workspaceId: workspaceId, sessionId: sessionId, toolCallId: toolCallId) else {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : output
    }

    /// Fetch a generated session attachment by id.
    ///
    /// Session attachments are server-owned artifacts (for example, voice_speak audio)
    /// stored in the Oppi data directory rather than the workspace checkout.
    func fetchSessionAttachment(workspaceId: String, sessionId: String, attachmentId: String) async throws -> Data {
        let url = try makeURL(pathSegments: ["workspaces", workspaceId, "sessions", sessionId, "attachments", attachmentId])
        return try await get(url: url)
    }

    /// Fetch a file from the session's working directory.
    ///
    /// Returns the raw file content as a string. Used when the user taps a file path
    /// in a tool call row to view the current file on disk.
    // periphery:ignore - used by APIClientTests + RemoteFileView (transitively unused)
    func getSessionFile(workspaceId: String, sessionId: String, path: String) async throws -> String {
        let data = try await get(url: makeSessionFileURL(workspaceId: workspaceId, sessionId: sessionId, route: "files", path: path))
        // File content is returned as raw bytes — decode as UTF-8 text
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.server(status: 422, message: "File is not text (binary content)")
        }
        return text
    }

    // periphery:ignore - used by RemoteFileView (transitively unused)
    /// Fetch raw file data from the session's working directory (for binary files like images).
    func getSessionFileData(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        return try await get(url: makeSessionFileURL(workspaceId: workspaceId, sessionId: sessionId, route: "files", path: path))
    }

    /// Fetch a workspace file by path (images, etc.) from the workspace file endpoint.
    ///
    /// Used by `MarkdownImageView` to load images referenced in markdown with relative paths.
    /// Returns raw `Data` so the caller can decode as `UIImage`.
    func fetchWorkspaceFile(workspaceID: String, path: String) async throws -> Data {
        return try await get(url: makeWorkspaceFileURL(workspaceId: workspaceID, path: path))
    }

    // MARK: - Workspace File Browser

    /// List entries in a workspace directory.
    ///
    /// Pass an empty string or "/" for the workspace root. Subdirectory paths
    /// should include a trailing slash (e.g. "src/").
    func listWorkspaceDirectory(workspaceId: String, path: String = "") async throws -> DirectoryListingResponse {
        let data = try await get(
            url: makeWorkspaceFileURL(
                workspaceId: workspaceId,
                path: path,
                directory: true
            )
        )
        return try JSONDecoder().decode(DirectoryListingResponse.self, from: data)
    }

    /// Fetch the complete file index for client-side fuzzy search.
    ///
    /// Returns all workspace-relative file paths in a single response.
    /// The client caches this and filters locally for instant search feedback.
    func fetchFileIndex(workspaceId: String) async throws -> FileIndexResponse {
        let data = try await get("/workspaces/\(workspaceId)/file-index")
        return try JSONDecoder().decode(FileIndexResponse.self, from: data)
    }

    /// Fetch a workspace file in browse mode (text/code files, not just images).
    ///
    /// Returns raw file content as `Data`. For text files, decode to String with UTF-8.
    func browseWorkspaceFile(workspaceId: String, path: String) async throws -> Data {
        return try await get(
            url: makeWorkspaceFileURL(
                workspaceId: workspaceId,
                path: path,
                queryItems: [URLQueryItem(name: "mode", value: "browse")]
            )
        )
    }

    /// Build an authenticated URL for streaming media via AVPlayer.
    ///
    /// Uses query-param token auth so AVPlayer can stream directly from the
    /// server without needing custom header injection. No data is downloaded
    /// by this method — AVPlayer handles progressive download and buffering.
    func browseFileStreamURL(workspaceId: String, path: String) throws -> URL {
        try makeWorkspaceFileURL(
            workspaceId: workspaceId,
            path: path,
            queryItems: [
                URLQueryItem(name: "mode", value: "browse"),
                URLQueryItem(name: "token", value: token),
            ]
        )
    }

    /// Fetch content of a file that was touched (written/edited) by a specific session.
    ///
    /// Works for both workspace-relative paths and absolute paths (e.g. ~/.agent/diagrams/).
    /// The server validates the path exists in the session's `changeStats.changedFiles`.
    func browseSessionTouchedFile(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        return try await get(url: makeSessionFileURL(workspaceId: workspaceId, sessionId: sessionId, route: "touched-file", path: path))
    }

    // MARK: - Device Token

    /// Register APNs device token with the server.
    func registerDeviceToken(_ token: String, tokenType: String = "apns") async throws {
        struct Body: Encodable { let deviceToken: String; let tokenType: String }
        _ = try await post("/me/device-token", body: Body(deviceToken: token, tokenType: tokenType))
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Unregister APNs device token.
    func unregisterDeviceToken(_ token: String) async throws {
        struct Body: Encodable { let deviceToken: String }
        let (data, response) = try await request("DELETE", path: "/me/device-token", body: Body(deviceToken: token))
        try checkStatus(response, data: data)
    }

    // MARK: - Diagnostics

    /// Upload raw MetricKit payloads for backend trend dashboards.
    func uploadMetricKitPayload(request body: MetricKitUploadRequest) async throws {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        _ = try await post("/telemetry/metrickit", body: body)
    }

    /// Upload chat performance metric samples for baseline tracking.
    /// Sorted-keys encoder for chat metric uploads.
    /// Produces deterministic tag JSON (e.g. `{"expanded":"0","tool":"edit"}`)
    /// regardless of dictionary insertion order, eliminating phantom cardinality.
    private static let chatMetricsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    func uploadChatMetrics(request body: ChatMetricUploadRequest) async throws {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        var req = try URLRequest(url: makeURL(path: "/telemetry/chat-metrics"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.chatMetricsEncoder.encode(body)
        logger.debug("POST /telemetry/chat-metrics")
        let (data, response) = try await session.data(for: req)
        try checkStatus(response, data: data)
    }

    // MARK: - Private

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await request("GET", path: path)
        try checkStatus(response, data: data)
        return data
    }

    private func get(url: URL) async throws -> Data {
        let (data, response) = try await request("GET", url: url)
        try checkStatus(response, data: data)
        return data
    }

    private func post<T: Encodable>(_ path: String, body: T) async throws -> Data {
        let (data, response) = try await request("POST", path: path, body: body)
        try checkStatus(response, data: data)
        return data
    }

    private func put<T: Encodable>(_ path: String, body: T) async throws -> Data {
        let (data, response) = try await request("PUT", path: path, body: body)
        try checkStatus(response, data: data)
        return data
    }

    private func request(_ method: String, path: String) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func request(_ method: String, url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("\(method) \(url.path)")
        return try await session.data(for: req)
    }

    private func request<T: Encodable>(_ method: String, path: String, body: T) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func request(_ method: String, path: String, body: Data, contentType: String) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func requestNoAuth<T: Encodable>(_ method: String, path: String, body: T) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        logger.debug("\(method) \(path) [no-auth]")
        return try await session.data(for: req)
    }

    private func encodeQueryPath(_ path: String) throws -> String {
        try percentEncodeQueryComponent(path)
    }

    private func percentEncodeQueryComponent(_ component: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw APIError.server(status: 400, message: "Invalid query value")
        }
        return encoded
    }

    private func makePercentEncodedQuery(_ queryItems: [URLQueryItem]) throws -> String? {
        guard !queryItems.isEmpty else { return nil }

        let parts = try queryItems.map { item in
            let name = try percentEncodeQueryComponent(item.name)
            guard let value = item.value else { return name }
            return "\(name)=\(try percentEncodeQueryComponent(value))"
        }
        return parts.joined(separator: "&")
    }

    private func percentEncodePathSegment(_ segment: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        return encoded
    }

    private func makeWorkspaceFileURL(
        workspaceId: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        directory: Bool = false
    ) throws -> URL {
        let normalizedPath = path == "/" ? "" : path
        let trailingSlash = directory || normalizedPath.hasSuffix("/")
        return try makeURL(
            pathSegments: ["workspaces", workspaceId, "files"],
            appendedPath: normalizedPath,
            queryItems: queryItems,
            trailingSlash: trailingSlash
        )
    }

    private func makeSessionFileURL(
        workspaceId: String,
        sessionId: String,
        route: String,
        path: String
    ) throws -> URL {
        try makeURL(
            pathSegments: ["workspaces", workspaceId, "sessions", sessionId, route],
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    private func makeSkillFileURL(name: String, path: String) throws -> URL {
        try makeURL(
            pathSegments: ["skills", name, "file"],
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    private func makeURL(
        pathSegments: [String],
        appendedPath: String? = nil,
        queryItems: [URLQueryItem] = [],
        trailingSlash: Bool = false
    ) throws -> URL {
        let encodedSegments = try pathSegments.map(percentEncodePathSegment)
        let normalizedAppendedPath = appendedPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let appendedSegments = try normalizedAppendedPath.isEmpty
            ? []
            : normalizedAppendedPath.split(separator: "/", omittingEmptySubsequences: true).map {
                try percentEncodePathSegment(String($0))
            }
        let combined = encodedSegments + appendedSegments
        var percentEncodedPath = "/\(combined.joined(separator: "/"))"
        if trailingSlash {
            percentEncodedPath += "/"
        }
        return try makeURL(percentEncodedPath: percentEncodedPath, queryItems: queryItems)
    }

    private func makeURL(percentEncodedPath: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }

        let normalizedBasePath: String = {
            if components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" { return "" }
            if components.percentEncodedPath.hasSuffix("/") { return String(components.percentEncodedPath.dropLast()) }
            return components.percentEncodedPath
        }()

        let normalizedRequestPath = percentEncodedPath.hasPrefix("/") ? percentEncodedPath : "/\(percentEncodedPath)"
        components.percentEncodedPath = normalizedBasePath + normalizedRequestPath
        components.percentEncodedQuery = try makePercentEncodedQuery(queryItems)

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        return url
    }

    /// Build a request URL from an API path that may include a query string.
    ///
    /// `URL.appendingPathComponent` encodes `?` as a literal path character,
    /// which breaks routes like `/workspaces/:workspaceId/sessions/:id/files?path=...`
    /// and yields 404.
    private func makeURL(path: String) throws -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let rawQuery = parts.count > 1 ? String(parts[1]) : nil

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }

        let normalizedBasePath: String = {
            if components.path.isEmpty || components.path == "/" { return "" }
            if components.path.hasSuffix("/") { return String(components.path.dropLast()) }
            return components.path
        }()

        let normalizedRequestPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        components.path = normalizedBasePath + normalizedRequestPath
        components.percentEncodedQuery = rawQuery

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        return url
    }

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Try to extract server error message
            if let parsed = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw APIError.server(status: http.statusCode, message: parsed.error)
            }
            throw APIError.server(status: http.statusCode, message: body)
        }
    }

    private struct EmptyBody: Encodable {}
    private struct ServerError: Decodable { let error: String }
}
