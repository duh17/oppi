import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "APIClient")

/// REST client for oppi server.
///
/// Handles session CRUD, health checks, and authentication.
/// All methods throw on network/server errors with descriptive messages.
actor APIClient: ClientLogUploading {
    enum SessionTraceView: String, Sendable {
        case context
        case full
    }

    struct SessionTracePageResponse: Decodable, Sendable {
        let session: Session
        let trace: [TraceEvent]
        let page: TracePageMetadata
        let metrics: TracePageMetrics
    }

    struct SessionTraceOutlineResponse: Decodable, Sendable {
        let session: Session
        let outline: SessionOutlineSnapshot
    }

    let baseURL: URL
    let token: String
    let environment: OppiClientEnvironment
    private let tlsCertFingerprint: String?
    private let session: URLSession
    private let trustDelegate: PinnedServerTrustDelegate

    init(environment: OppiClientEnvironment) {
        self.environment = environment
        self.baseURL = environment.baseURL
        self.token = environment.bearerToken
        self.tlsCertFingerprint = environment.pinnedCertificateFingerprint
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: environment.pinnedCertificateFingerprint,
            expectedServerName: environment.tlsServerName
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: config,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    init(baseURL: URL, token: String, tlsCertFingerprint: String? = nil) {
        let environment = OppiClientEnvironment(
            baseURL: baseURL,
            bearerToken: token,
            pinnedCertificateFingerprint: tlsCertFingerprint
        )
        self.environment = environment
        self.baseURL = environment.baseURL
        self.token = environment.bearerToken
        self.tlsCertFingerprint = environment.pinnedCertificateFingerprint
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: environment.pinnedCertificateFingerprint,
            expectedServerName: environment.tlsServerName
        )

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
        environment: OppiClientEnvironment,
        configuration: URLSessionConfiguration
    ) {
        self.environment = environment
        self.baseURL = environment.baseURL
        self.token = environment.bearerToken
        self.tlsCertFingerprint = environment.pinnedCertificateFingerprint
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: environment.pinnedCertificateFingerprint,
            expectedServerName: environment.tlsServerName
        )
        session = URLSession(
            configuration: configuration,
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
        let environment = OppiClientEnvironment(
            baseURL: baseURL,
            bearerToken: token,
            pinnedCertificateFingerprint: tlsCertFingerprint
        )
        self.environment = environment
        self.baseURL = environment.baseURL
        self.token = environment.bearerToken
        self.tlsCertFingerprint = environment.pinnedCertificateFingerprint
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: environment.pinnedCertificateFingerprint,
            expectedServerName: environment.tlsServerName
        )
        session = URLSession(
            configuration: configuration,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - Health & Auth

    /// Check server reachability.
    func health() async throws -> Bool {
        try await performHealth(timeoutInterval: nil)
    }

    func health(timeoutInterval: TimeInterval) async throws -> Bool {
        try await performHealth(timeoutInterval: timeoutInterval)
    }

    private func performHealth(timeoutInterval: TimeInterval?) async throws -> Bool {
        var request = try URLRequest(url: makeURL(path: "/health"))
        request.httpMethod = "GET"
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        ServerAuthorization.apply(token: token, to: &request)
        let (_, response) = try await session.data(for: request)
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

    private func focusedSessionPath(scope: SessionRouteScope, sessionId: String) -> String {
        switch scope {
        case .workspace(let workspaceId):
            return "/workspaces/\(workspaceId)/sessions/\(sessionId)"
        case .control:
            return "/control-sessions/\(sessionId)"
        }
    }

    /// Fetch sequenced durable session events after `since` for reconnect catch-up.
    ///
    /// Decodes the response in a single pass using `Decodable` — no intermediate
    /// `JSONValue` tree, no per-event re-encode/re-decode round-trip.
    func getSessionEvents(workspaceId: String, id: String, since: Int) async throws -> SessionEventsResponse {
        try await getSessionEvents(scope: .workspace(workspaceId), id: id, since: since)
    }

    func getSessionEvents(scope: SessionRouteScope, id: String, since: Int) async throws -> SessionEventsResponse {
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: id))/events?since=\(since)")

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

    /// Get a workspace session with trace events for either context or full timeline view.
    func getWorkspaceSession(
        workspaceId: String,
        sessionId: String,
        traceView: SessionTraceView = .context
    ) async throws -> (session: Session, trace: [TraceEvent]) {
        try await getSession(scope: .workspace(workspaceId), sessionId: sessionId, traceView: traceView)
    }

    func getSession(
        scope: SessionRouteScope,
        sessionId: String,
        traceView: SessionTraceView = .context
    ) async throws -> (session: Session, trace: [TraceEvent]) {
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))?view=\(traceView.rawValue)")
        struct Response: Decodable { let session: Session; let trace: [TraceEvent] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.session, response.trace)
    }

    /// Get a paged workspace session trace for timeline history.
    func getWorkspaceSessionTracePage(
        workspaceId: String,
        sessionId: String,
        cursor: String? = nil,
        aroundEntryId: String? = nil,
        previewBytes: Int? = nil
    ) async throws -> SessionTracePageResponse {
        try await getSessionTracePage(
            scope: .workspace(workspaceId),
            sessionId: sessionId,
            cursor: cursor,
            aroundEntryId: aroundEntryId,
            previewBytes: previewBytes
        )
    }

    func getSessionTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        cursor: String? = nil,
        aroundEntryId: String? = nil,
        previewBytes: Int? = nil
    ) async throws -> SessionTracePageResponse {
        var items: [URLQueryItem] = []
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let aroundEntryId {
            items.append(URLQueryItem(name: "aroundEntryId", value: aroundEntryId))
        }
        if let previewBytes {
            items.append(URLQueryItem(name: "previewBytes", value: String(previewBytes)))
        }
        var components = URLComponents()
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))/trace-page\(query)")
        return try JSONDecoder().decode(SessionTracePageResponse.self, from: data)
    }

    /// Get a lightweight workspace session outline without full trace payloads.
    func getWorkspaceSessionTraceOutline(
        workspaceId: String,
        sessionId: String
    ) async throws -> SessionTraceOutlineResponse {
        try await getSessionTraceOutline(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func getSessionTraceOutline(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> SessionTraceOutlineResponse {
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))/trace-outline")
        return try JSONDecoder().decode(SessionTraceOutlineResponse.self, from: data)
    }

    /// Stop a running workspace session.
    func stopWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        try await stopSession(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func stopSession(scope: SessionRouteScope, sessionId: String) async throws -> Session {
        let data = try await post("\(focusedSessionPath(scope: scope, sessionId: sessionId))/stop", body: EmptyBody())
        struct Response: Decodable { let session: Session? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let session = response.session { return session }
        return try await getSession(scope: scope, sessionId: sessionId).session
    }

    /// Delete a workspace session permanently.
    func deleteWorkspaceSession(workspaceId: String, sessionId: String) async throws {
        try await deleteSession(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func deleteSession(scope: SessionRouteScope, sessionId: String) async throws {
        _ = try await request("DELETE", path: focusedSessionPath(scope: scope, sessionId: sessionId))
    }

    /// Send a session command over HTTP when no focused session WebSocket is available.
    func sendWorkspaceSessionCommand(
        workspaceId: String,
        sessionId: String,
        message: ClientMessage
    ) async throws {
        try await sendSessionCommand(scope: .workspace(workspaceId), sessionId: sessionId, message: message)
    }

    func sendSessionCommand(
        scope: SessionRouteScope,
        sessionId: String,
        message: ClientMessage
    ) async throws {
        _ = try await post(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/command",
            body: message
        )
    }

    /// Respond to an extension UI request in another session without focusing its stream.
    func sendExtensionUIResponse(
        workspaceId: String,
        sessionId: String,
        id: String,
        payload: ExtensionUIResponsePayload,
        requestId: String? = nil
    ) async throws {
        try await sendExtensionUIResponse(
            scope: .workspace(workspaceId),
            sessionId: sessionId,
            id: id,
            payload: payload,
            requestId: requestId
        )
    }

    func sendExtensionUIResponse(
        scope: SessionRouteScope,
        sessionId: String,
        id: String,
        payload: ExtensionUIResponsePayload,
        requestId: String? = nil
    ) async throws {
        try await sendSessionCommand(
            scope: scope,
            sessionId: sessionId,
            message: .extensionUIResponse(
                id: id,
                value: payload.value,
                confirmed: payload.confirmed,
                cancelled: payload.cancelled,
                requestId: requestId
            )
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

    struct WorkspaceCatalogResponse: Decodable, Sendable {
        let serverNow: Int64?
        let workspaces: [Workspace]
        let summaries: [WorkspaceListSummary]?
    }

    /// List workspace cards, including optional list summaries for catalog/home UI.
    func listWorkspaceCatalog(includeGitSummary: Bool = true) async throws -> WorkspaceCatalogResponse {
        let query = includeGitSummary ? "?includeGitSummary=true" : ""
        let data = try await get("/workspaces\(query)")
        return try JSONDecoder().decode(WorkspaceCatalogResponse.self, from: data)
    }

    /// List all workspaces for the authenticated user.
    func listWorkspaces() async throws -> [Workspace] {
        try await listWorkspaceCatalog(includeGitSummary: false).workspaces
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Get a single workspace.
    func getWorkspace(id: String) async throws -> Workspace {
        let data = try await get("/workspaces/\(id)")
        struct Response: Decodable { let workspace: Workspace }
        return try JSONDecoder().decode(Response.self, from: data).workspace
    }

    /// List git worktrees/checkouts available inside a workspace.
    func listWorkspaceWorktrees(workspaceId: String) async throws -> [WorkspaceWorktree] {
        let data = try await get("/workspaces/\(workspaceId)/worktrees")
        struct Response: Decodable { let worktrees: [WorkspaceWorktree] }
        return try JSONDecoder().decode(Response.self, from: data).worktrees
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

    /// Delete a workspace.
    func deleteWorkspace(id: String) async throws {
        _ = try await request("DELETE", path: "/workspaces/\(id)")
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

    /// Fetch the lightweight Git state used by workspace catalog rows.
    func getWorkspaceGitSummary(workspaceId: String) async throws -> WorkspaceGitSummary {
        let data = try await get("/workspaces/\(workspaceId)/git/summary")
        return try JSONDecoder().decode(WorkspaceGitSummary.self, from: data)
    }

    /// Fetch git status for a workspace checkout.
    func getGitStatus(workspaceId: String, worktreeId: String? = nil) async throws -> GitStatus {
        var queryItems: [URLQueryItem] = []
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let query = try makePercentEncodedQuery(queryItems).map { "?\($0)" } ?? ""
        let data = try await get("/workspaces/\(workspaceId)/git/status\(query)")
        return try JSONDecoder().decode(GitStatus.self, from: data)
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
        let route = "/workspaces/\(workspaceId)/git/diff?\(query)"
        let data = try await get(route)
        return try JSONDecoder().decode(WorkspaceReviewDiffResponse.self, from: data)
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
        let data = try await get("/workspaces/\(workspaceId)/quick-actions\(query)")
        return try JSONDecoder().decode(WorkspaceQuickActionsResponse.self, from: data)
    }

    func prepareWorkspaceQuickActionSelection(
        workspaceId: String,
        paths: [String],
        selectedSessionId: String? = nil,
        worktreeId: String? = nil,
        commitSha: String? = nil,
        promptTemplateName: String
    ) async throws -> WorkspaceQuickActionSelectionResponse {
        struct Body: Encodable {
            let paths: [String]
            let selectedSessionId: String?
            let worktreeId: String?
            let commitSha: String?
            let promptTemplateName: String
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/quick-actions/selection",
            body: Body(
                paths: paths,
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId,
                commitSha: commitSha,
                promptTemplateName: promptTemplateName
            )
        )
        return try JSONDecoder().decode(WorkspaceQuickActionSelectionResponse.self, from: data)
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
        struct Body: Encodable {
            let paths: [String]
            let selectedSessionId: String?
            let worktreeId: String?
            let commitSha: String?
            let promptTemplateName: String
        }

        let data = try await post(
            "/workspaces/\(workspaceId)/quick-actions/session",
            body: Body(
                paths: paths,
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId,
                commitSha: commitSha,
                promptTemplateName: promptTemplateName
            )
        )
        return try JSONDecoder().decode(WorkspaceQuickActionSessionResponse.self, from: data)
    }

    // MARK: - Skills

    /// List available skills from Pi resource discovery.
    func listSkills(cwd: String? = nil) async throws -> [SkillInfo] {
        var queryItems: [URLQueryItem] = []
        if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        let data = try await get(
            url: try makeURL(pathSegments: ["skills"], queryItems: queryItems)
        )
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

    /// Enable or disable a Pi resource by writing Pi user/project settings for the cwd.
    func setPiResourceEnabled(type: String, path: String, cwd: String? = nil, enabled: Bool) async throws {
        struct Body: Encodable {
            let type: String
            let path: String
            let cwd: String?
            let enabled: Bool
        }

        _ = try await post(
            "/pi/resources/enabled",
            body: Body(type: type, path: path, cwd: cwd, enabled: enabled)
        )
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
    func getSkillDetail(name: String, cwd: String? = nil) async throws -> SkillDetail {
        var queryItems: [URLQueryItem] = []
        if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        let data = try await get(
            url: try makeURL(pathSegments: ["skills", name], queryItems: queryItems)
        )
        return try JSONDecoder().decode(SkillDetail.self, from: data)
    }

    /// Get a single file's content from a skill directory.
    func getSkillFile(name: String, path: String, cwd: String? = nil) async throws -> String {
        let data = try await get(url: makeSkillFileURL(name: name, path: path, cwd: cwd))
        struct Response: Decodable { let content: String }
        return try JSONDecoder().decode(Response.self, from: data).content
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
            let asks: [AskRequest]
        }

        let workspaceId: String
        let serverNow: Int64
        let attention: Attention
    }

    struct WorkspaceSessionManagedRow: Decodable, Sendable, Equatable {
        let summary: SessionSummary
        let pendingAskCount: Int
        let hasPendingAskCount: Bool

        private enum CodingKeys: String, CodingKey {
            case pendingAskCount
        }

        init(from decoder: Decoder) throws {
            summary = try SessionSummary(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedPendingAskCount = try container.decodeIfPresent(Int.self, forKey: .pendingAskCount)
            pendingAskCount = decodedPendingAskCount ?? 0
            hasPendingAskCount = decodedPendingAskCount != nil
        }
    }

    enum WorkspaceSessionListRow: Decodable, Sendable, Equatable {
        case session(WorkspaceSessionManagedRow)
        case tui(LocalSession)

        private enum CodingKeys: String, CodingKey {
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decodeIfPresent(String.self, forKey: .source) == "tui" {
                self = .tui(try LocalSession(from: decoder))
            } else {
                self = .session(try WorkspaceSessionManagedRow(from: decoder))
            }
        }
    }

    struct WorkspaceSessionCollectionResponse: Decodable, Sendable, Equatable {
        let workspaceId: String
        let sinceMs: Int64?
        let untilMs: Int64?
        let serverNow: Int64
        let active: [WorkspaceSessionListRow]
        let stopped: [WorkspaceSessionListRow]

        var sessionSummaries: [SessionSummary] {
            (active + stopped).compactMap { row in
                if case .session(let row) = row { return row.summary }
                return nil
            }
        }

        var importableSessions: [LocalSession] {
            stopped.compactMap { row in
                if case .tui(let session) = row { return session }
                return nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case workspaceId, sinceMs, untilMs, serverNow, active, stopped
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspaceId = try c.decode(String.self, forKey: .workspaceId)
            sinceMs = try c.decodeIfPresent(Int64.self, forKey: .sinceMs)
            untilMs = try c.decodeIfPresent(Int64.self, forKey: .untilMs)
            serverNow = try c.decode(Int64.self, forKey: .serverNow)
            active = try c.decodeIfPresent([WorkspaceSessionListRow].self, forKey: .active) ?? []
            stopped = try c.decodeIfPresent([WorkspaceSessionListRow].self, forKey: .stopped) ?? []
        }
    }

    struct WorkspaceSessionBucketsResponse: Decodable, Sendable {
        let workspaceId: String
        let status: String
        let beforeMs: Int64
        let serverNow: Int64
        let buckets: [WorkspaceSessionArchiveBucket]
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

    func getWorkspaceAttention(workspaceId: String) async throws -> WorkspaceAttentionResponse {
        let data = try await get("/workspaces/\(workspaceId)/attention")
        return try JSONDecoder().decode(WorkspaceAttentionResponse.self, from: data)
    }

    func getWorkspaceSessionList(
        workspace: Workspace,
        since: Date,
        until: Date,
        worktreeId: String? = nil
    ) async throws -> WorkspaceSessionListResponse {
        let workspaceId = workspace.id
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        var sessionQueryItems = [
            URLQueryItem(name: "status", value: "active,stopped"),
            URLQueryItem(name: "sinceMs", value: String(sinceMs)),
            URLQueryItem(name: "untilMs", value: String(untilMs)),
        ]
        var bucketQueryItems = [
            URLQueryItem(name: "status", value: "stopped"),
            URLQueryItem(name: "beforeMs", value: String(sinceMs)),
        ]
        if let worktreeId, !worktreeId.isEmpty {
            sessionQueryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
            bucketQueryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let sessionsQuery = try makePercentEncodedQuery(sessionQueryItems) ?? ""
        let bucketsQuery = try makePercentEncodedQuery(bucketQueryItems) ?? ""

        async let sectionsData = get("/workspaces/\(workspaceId)/sessions?\(sessionsQuery)")
        async let bucketsData = get("/workspaces/\(workspaceId)/session-buckets?\(bucketsQuery)")
        async let attention = getWorkspaceAttention(workspaceId: workspaceId)

        let resolvedSectionsData = try await sectionsData
        let resolvedBucketsData = try await bucketsData
        let resolvedAttention = try await attention

        let sections = try JSONDecoder().decode(WorkspaceSessionCollectionResponse.self, from: resolvedSectionsData)
        let buckets = try JSONDecoder().decode(WorkspaceSessionBucketsResponse.self, from: resolvedBucketsData)

        return WorkspaceSessionListResponse(
            workspace: workspace,
            serverNow: sections.serverNow,
            sessionSummaries: sections.sessionSummaries,
            attention: resolvedAttention.attention,
            importableSessions: sections.importableSessions,
            archiveBuckets: buckets.buckets
        )
    }

    func getWorkspaceSessionListBucket(
        workspaceId: String,
        since: Date,
        until: Date,
        worktreeId: String? = nil
    ) async throws -> WorkspaceSessionListBucketResponse {
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        var queryItems = [
            URLQueryItem(name: "status", value: "stopped"),
            URLQueryItem(name: "sinceMs", value: String(sinceMs)),
            URLQueryItem(name: "untilMs", value: String(untilMs)),
        ]
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let query = try makePercentEncodedQuery(queryItems) ?? ""
        let data = try await get("/workspaces/\(workspaceId)/sessions?\(query)")
        let sections = try JSONDecoder().decode(WorkspaceSessionCollectionResponse.self, from: data)
        return WorkspaceSessionListBucketResponse(
            workspaceId: workspaceId,
            sinceMs: sinceMs,
            untilMs: untilMs,
            sessionSummaries: sections.sessionSummaries,
            importableSessions: sections.importableSessions
        )
    }

    /// List recent session summaries across all workspaces with one server request.
    func listRecentWorkspaceSessionSummaries(recentDays: Int = 3) async throws -> [SessionSummary] {
        let data = try await get("/sessions/recent?recentDays=\(recentDays)")
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
        worktreeId: String? = nil,
        attachments: [ChatAttachmentRef]? = nil
    ) async throws -> CreateSessionResponse {
        struct Body: Encodable {
            let name: String?
            let model: String?
            let prompt: String?
            let thinking: String?
            let ephemeral: Bool?
            let worktreeId: String?
            let attachments: [ChatAttachmentRef]?
        }
        let data = try await post(
            "/workspaces/\(workspaceId)/sessions",
            body: Body(
                name: name,
                model: model,
                prompt: prompt,
                thinking: thinking,
                ephemeral: ephemeral,
                worktreeId: worktreeId,
                attachments: attachments
            )
        )
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    struct CreateControlSessionRequest: Codable, Sendable {
        let domain: ControlSessionDomain
        let intent: ControlSessionIntent
        let targetId: String?
        let targetName: String?
        let name: String?
        let model: String?
        let thinking: ThinkingLevel?
        let prompt: String

        init(
            domain: ControlSessionDomain,
            intent: ControlSessionIntent,
            targetId: String?,
            targetName: String?,
            name: String?,
            model: String? = nil,
            thinking: ThinkingLevel? = nil,
            prompt: String
        ) {
            self.domain = domain
            self.intent = intent
            self.targetId = targetId
            self.targetName = targetName
            self.name = name
            self.model = model
            self.thinking = thinking
            self.prompt = prompt
        }
    }

    func createControlSession(_ request: CreateControlSessionRequest) async throws -> CreateSessionResponse {
        let data = try await post("/control-sessions", body: request)
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

    private struct UploadCreateBody: Encodable {
        let name: String
        let mimeType: String
        let sizeBytes: Int
        let purpose: String
    }

    func createSessionAttachmentUpload(
        workspaceId: String,
        sessionId: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        purpose: String = "chat_attachment"
    ) async throws -> CreateUploadResponse {
        try await createSessionAttachmentUpload(
            scope: .workspace(workspaceId), sessionId: sessionId, name: name,
            mimeType: mimeType, sizeBytes: sizeBytes, purpose: purpose
        )
    }

    func createSessionAttachmentUpload(
        scope: SessionRouteScope,
        sessionId: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        purpose: String = "chat_attachment"
    ) async throws -> CreateUploadResponse {
        let data = try await post(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/attachments",
            body: UploadCreateBody(name: name, mimeType: mimeType, sizeBytes: sizeBytes, purpose: purpose)
        )
        return try JSONDecoder().decode(CreateUploadResponse.self, from: data)
    }

    func uploadSessionAttachmentContent(
        workspaceId: String,
        sessionId: String,
        attachmentId: String,
        data body: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> ChatAttachmentRef {
        try await uploadSessionAttachmentContent(
            scope: .workspace(workspaceId), sessionId: sessionId,
            attachmentId: attachmentId, data: body, contentType: contentType
        )
    }

    func uploadSessionAttachmentContent(
        scope: SessionRouteScope,
        sessionId: String,
        attachmentId: String,
        data body: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> ChatAttachmentRef {
        try await putAttachmentContent(
            path: "\(focusedSessionPath(scope: scope, sessionId: sessionId))/attachments/\(attachmentId)/content",
            data: body,
            contentType: contentType
        )
    }

    private func putAttachmentContent(
        path: String,
        data body: Data,
        contentType: String
    ) async throws -> ChatAttachmentRef {
        let (data, response) = try await request(
            "PUT",
            path: path,
            body: body,
            contentType: contentType
        )
        try checkStatus(response, data: data)
        let parsed = try JSONDecoder().decode(UploadContentResponse.self, from: data)
        return parsed.attachment
    }

    /// Create a session that resumes an existing local pi TUI session.
    func createWorkspaceSessionFromLocal(
        workspaceId: String,
        piSessionFile: String,
        worktreeId: String? = nil
    ) async throws -> Session {
        struct Body: Encodable { let piSessionFile: String; let worktreeId: String? }
        let data = try await post(
            "/workspaces/\(workspaceId)/sessions",
            body: Body(piSessionFile: piSessionFile, worktreeId: worktreeId)
        )
        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Resume a stopped session in its workspace.
    func resumeWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        try await resumeSession(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func resumeSession(scope: SessionRouteScope, sessionId: String) async throws -> Session {
        let data = try await post("\(focusedSessionPath(scope: scope, sessionId: sessionId))/resume", body: EmptyBody())
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

    // MARK: - Tool Output & Files

    /// Fetch the full tool output for a specific tool call ID from the session's JSONL trace.
    ///
    /// Used to lazy-load evicted tool output when the user expands an old tool call row.
    private func getToolOutput(workspaceId: String, sessionId: String, toolCallId: String) async throws -> (output: String, isError: Bool) {
        try await getToolOutput(scope: .workspace(workspaceId), sessionId: sessionId, toolCallId: toolCallId)
    }

    private func getToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> (output: String, isError: Bool) {
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))/tool-output/\(toolCallId)")
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

    func getNonEmptyToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> String? {
        let (output, _) = try await getToolOutput(scope: scope, sessionId: sessionId, toolCallId: toolCallId)
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : output
    }

    /// Fetch raw full (untruncated) tool output from the server temp-file side channel.
    ///
    /// Returns nil when the server no longer has the backing temp file (404).
    private func getFullToolOutput(workspaceId: String, sessionId: String, toolCallId: String) async throws -> String? {
        try await getFullToolOutput(scope: .workspace(workspaceId), sessionId: sessionId, toolCallId: toolCallId)
    }

    private func getFullToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> String? {
        do {
            let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))/tool-output/\(toolCallId)?full=true")
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

    func getNonEmptyFullToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> String? {
        guard let output = try await getFullToolOutput(scope: scope, sessionId: sessionId, toolCallId: toolCallId) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : output
    }

    /// Fetch a generated session attachment by id.
    ///
    /// Session attachments are server-owned artifacts (for example, voice_speak audio)
    /// stored in the Oppi data directory rather than the workspace checkout.
    func fetchSessionAttachment(sessionId: String, attachmentId: String) async throws -> Data {
        try await fetchSessionAttachment(scope: nil, sessionId: sessionId, attachmentId: attachmentId)
    }

    func fetchSessionAttachment(
        scope: SessionRouteScope?,
        sessionId: String,
        attachmentId: String
    ) async throws -> Data {
        let pathSegments: [String]
        if scope == .control {
            pathSegments = ["control-sessions", sessionId, "attachments", attachmentId]
        } else {
            pathSegments = ["sessions", sessionId, "attachments", attachmentId]
        }
        let url = try makeURL(pathSegments: pathSegments)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        logger.debug("GET \(url.path)")

        let (data, response) = try await session.data(for: req)
        try checkStatus(response, data: data)
        try checkCompleteSessionAttachmentResponse(response, data: data)
        return data
    }

    /// Fetch a workspace file or an external path reported by the session.
    ///
    /// Returns the raw file content as a string. Used when the user taps a file path
    /// in a tool call row to view the current file on disk.
    // periphery:ignore - used by APIClientTests + RemoteFileView (transitively unused)
    func getSessionFile(workspaceId: String, sessionId: String, path: String) async throws -> String {
        let data = try await get(url: makeSessionRawURL(workspaceId: workspaceId, sessionId: sessionId, path: path))
        // File content is returned as raw bytes — decode as UTF-8 text
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.server(status: 422, message: "File is not text (binary content)")
        }
        return text
    }

    /// Fetch raw data for a workspace file or an external path reported by the session.
    func getSessionFileData(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        return try await get(url: makeSessionRawURL(workspaceId: workspaceId, sessionId: sessionId, path: path))
    }

    /// Fetch a workspace file by path (images, etc.) from the workspace raw endpoint.
    ///
    /// Used by `MarkdownImageView` to load images referenced in markdown with relative paths.
    /// Returns raw `Data` so the caller can decode as `UIImage`.
    func fetchWorkspaceFile(workspaceID: String, path: String, worktreeId: String? = nil) async throws -> Data {
        return try await get(
            url: makeWorkspaceRawURL(
                workspaceId: workspaceID,
                path: path,
                queryItems: workspaceWorktreeQueryItems(worktreeId)
            )
        )
    }

    // MARK: - Workspace File Browser

    /// List entries in a workspace directory.
    ///
    /// Pass an empty string or "/" for the workspace root. Subdirectory paths
    /// should include a trailing slash (e.g. "src/").
    func listWorkspaceDirectory(
        workspaceId: String,
        path: String = "",
        worktreeId: String? = nil
    ) async throws -> DirectoryListingResponse {
        let data = try await get(
            url: makeWorkspaceContentsURL(
                workspaceId: workspaceId,
                path: path,
                queryItems: workspaceWorktreeQueryItems(worktreeId),
                directory: true
            )
        )
        return try JSONDecoder().decode(DirectoryListingResponse.self, from: data)
    }

    /// Fetch the complete file index for client-side fuzzy search.
    ///
    /// Returns all workspace-relative file paths in a single response.
    /// The client caches this and filters locally for instant search feedback.
    func fetchFileIndex(workspaceId: String, worktreeId: String? = nil) async throws -> FileIndexResponse {
        let data = try await get(
            url: makeURL(
                pathSegments: ["workspaces", workspaceId, "paths"],
                queryItems: workspaceWorktreeQueryItems(worktreeId)
            )
        )
        return try JSONDecoder().decode(FileIndexResponse.self, from: data)
    }

    /// Fetch a workspace file in browse mode (text/code files, not just images).
    ///
    /// Returns raw file content as `Data`. For text files, decode to String with UTF-8.
    func browseWorkspaceFile(workspaceId: String, path: String, worktreeId: String? = nil) async throws -> Data {
        return try await get(
            url: makeWorkspaceRawURL(
                workspaceId: workspaceId,
                path: path,
                queryItems: workspaceWorktreeQueryItems(worktreeId)
            )
        )
    }

    /// Build a bearer-authenticated media source for AVPlayer resource loading.
    ///
    /// AVPlayer receives a local `oppi-media://` asset URL. The resource loader
    /// translates byte-range requests to this raw endpoint with the normal
    /// `Authorization: Bearer ...` header.
    func makeWorkspaceMediaSource(
        workspaceId: String,
        path: String,
        worktreeId: String? = nil,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        AuthenticatedMediaSource(
            url: try makeWorkspaceRawURL(
                workspaceId: workspaceId,
                path: path,
                queryItems: workspaceWorktreeQueryItems(worktreeId)
            ),
            authorizationHeaderValue: ServerAuthorization.headerValue(token: token),
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: environment.tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    /// Build a bearer-authenticated, range-capable media source for a file
    /// addressable through the owning session's raw-file capability.
    func makeSessionFileMediaSource(
        workspaceId: String,
        sessionId: String,
        path: String,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        AuthenticatedMediaSource(
            url: try makeSessionRawURL(workspaceId: workspaceId, sessionId: sessionId, path: path),
            authorizationHeaderValue: ServerAuthorization.headerValue(token: token),
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: environment.tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    /// Build a bearer-authenticated media source for a session attachment.
    func makeSessionAttachmentMediaSource(
        sessionId: String,
        attachmentId: String,
        contentTypeHint: String? = nil,
        sourceFileExtension: String? = nil
    ) throws -> AuthenticatedMediaSource {
        try makeSessionAttachmentMediaSource(
            scope: nil,
            sessionId: sessionId,
            attachmentId: attachmentId,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

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
            authorizationHeaderValue: ServerAuthorization.headerValue(token: token),
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: environment.tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    /// List files touched (written/edited) by a specific session.
    func listSessionChanges(workspaceId: String, sessionId: String) async throws -> SessionChangesResponse {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/changes")
        return try JSONDecoder().decode(SessionChangesResponse.self, from: data)
    }

    /// Fetch a session-derived diff for a touched file.
    func getSessionDiff(
        workspaceId: String,
        sessionId: String,
        path: String
    ) async throws -> WorkspaceReviewDiffResponse {
        let encodedPath = try encodeQueryPath(path)
        let route = "/workspaces/\(workspaceId)/sessions/\(sessionId)/diff?path=\(encodedPath)"
        let data = try await get(route)
        return try JSONDecoder().decode(WorkspaceReviewDiffResponse.self, from: data)
    }

    /// Fetch content of a file reported by a specific session.
    ///
    /// Relative paths resolve against the session workspace or worktree. The server also accepts
    /// exact external paths present in that session's changed-file metadata or tool arguments.
    func browseSessionTouchedFile(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        return try await get(url: makeSessionRawURL(workspaceId: workspaceId, sessionId: sessionId, path: path))
    }

    // MARK: - Device Token

    /// Register APNs device token with the server.
    func registerDeviceToken(_ token: String, tokenType: String = "apns") async throws {
        struct Body: Encodable { let deviceToken: String; let tokenType: String }
        _ = try await post("/me/device-token", body: Body(deviceToken: token, tokenType: tokenType))
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
        _ = try await post(
            "/telemetry/chat-metrics",
            body: body,
            encoder: Self.chatMetricsEncoder
        )
    }

    func uploadClientLogs(request body: ClientLogUploadRequest) async throws {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        _ = try await post(
            "/telemetry/client-logs",
            body: body,
            encoder: Self.chatMetricsEncoder
        )
    }

    // MARK: - Private

    func get(_ path: String) async throws -> Data {
        let (data, response) = try await request("GET", path: path)
        try checkStatus(response, data: data)
        return data
    }

    private func get(url: URL) async throws -> Data {
        let (data, response) = try await request("GET", url: url)
        try checkStatus(response, data: data)
        return data
    }

    func post<T: Encodable>(
        _ path: String,
        body: T,
        encoder: JSONEncoder? = nil
    ) async throws -> Data {
        let (data, response) = try await request("POST", path: path, body: body, encoder: encoder)
        try checkStatus(response, data: data)
        return data
    }

    private func put<T: Encodable>(_ path: String, body: T) async throws -> Data {
        let (data, response) = try await request("PUT", path: path, body: body)
        try checkStatus(response, data: data)
        return data
    }

    func request(_ method: String, path: String) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        ServerAuthorization.apply(token: token, to: &req)
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func request(_ method: String, url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        ServerAuthorization.apply(token: token, to: &req)
        logger.debug("\(method) \(url.path)")
        return try await session.data(for: req)
    }

    func request<T: Encodable>(
        _ method: String,
        path: String,
        body: T,
        encoder: JSONEncoder? = nil
    ) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        ServerAuthorization.apply(token: token, to: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try (encoder ?? JSONEncoder()).encode(body)
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    func request(_ method: String, path: String, body: Data, contentType: String) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        ServerAuthorization.apply(token: token, to: &req)
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

    func percentEncodePathSegment(_ segment: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        return encoded
    }

    private func workspaceWorktreeQueryItems(_ worktreeId: String?) -> [URLQueryItem] {
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }
        return [URLQueryItem(name: "worktreeId", value: trimmed)]
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

    private func makeWorkspaceRawURL(
        workspaceId: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        try makeURL(
            pathSegments: ["workspaces", workspaceId, "raw", path],
            queryItems: queryItems
        )
    }

    private func makeSessionRawURL(
        workspaceId: String,
        sessionId: String,
        path: String
    ) throws -> URL {
        try makeURL(
            pathSegments: ["workspaces", workspaceId, "sessions", sessionId, "raw", path]
        )
    }

    private func makeSkillFileURL(name: String, path: String, cwd: String? = nil) throws -> URL {
        var queryItems = [URLQueryItem(name: "path", value: path)]
        if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        return try makeURL(
            pathSegments: ["skills", name, "file"],
            queryItems: queryItems
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
    /// which breaks routes with query strings and yields 404.
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

    func checkStatus(_ response: URLResponse, data: Data) throws {
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

    private func checkCompleteSessionAttachmentResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.statusCode != 206 else {
            throw APIError.server(status: http.statusCode, message: "Attachment response was partial")
        }
        guard let contentLengthValue = http.value(forHTTPHeaderField: "Content-Length"),
              let expectedBytes = Int(contentLengthValue),
              expectedBytes >= 0 else {
            return
        }
        guard data.count == expectedBytes else {
            throw APIError.server(
                status: http.statusCode,
                message: "Attachment download was incomplete (\(data.count)/\(expectedBytes) bytes)"
            )
        }
    }

    private struct EmptyBody: Encodable {}
    private struct ServerError: Decodable { let error: String }
}
