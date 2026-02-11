import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "APIClient")

/// REST client for pi-remote server.
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

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Test-only init with custom URLSessionConfiguration.
    init(baseURL: URL, token: String, configuration: URLSessionConfiguration) {
        self.baseURL = baseURL
        self.token = token
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Health & Auth

    /// Check server reachability.
    func health() async throws -> Bool {
        let (_, response) = try await request("GET", path: "/health")
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Get authenticated user info.
    func me() async throws -> User {
        let data = try await get("/me")
        return try JSONDecoder().decode(User.self, from: data)
    }

    /// Fetch server-authored security posture for trust + transport checks.
    func securityProfile() async throws -> ServerSecurityProfile {
        let data = try await get("/security/profile")
        return try JSONDecoder().decode(ServerSecurityProfile.self, from: data)
    }

    /// Update server security posture.
    ///
    /// This modifies global server policy settings and returns the updated profile.
    func updateSecurityProfile(
        profile: String,
        requireTlsOutsideTailnet: Bool,
        allowInsecureHttpInTailnet: Bool,
        requirePinnedServerIdentity: Bool,
        inviteMaxAgeSeconds: Int
    ) async throws -> ServerSecurityProfile {
        let body = UpdateSecurityProfileRequest(
            profile: profile,
            requireTlsOutsideTailnet: requireTlsOutsideTailnet,
            allowInsecureHttpInTailnet: allowInsecureHttpInTailnet,
            requirePinnedServerIdentity: requirePinnedServerIdentity,
            invite: InviteUpdate(maxAgeSeconds: inviteMaxAgeSeconds)
        )
        let data = try await put("/security/profile", body: body)
        return try JSONDecoder().decode(ServerSecurityProfile.self, from: data)
    }

    // MARK: - Sessions

    /// List all sessions for the authenticated user by aggregating
    /// workspace-scoped session lists.
    func listSessions() async throws -> [Session] {
        let workspaces = try await listWorkspaces()
        var sessions: [Session] = []
        sessions.reserveCapacity(workspaces.count * 2)

        for workspace in workspaces {
            let workspaceSessions = try await listWorkspaceSessions(workspaceId: workspace.id)
            sessions.append(contentsOf: workspaceSessions)
        }

        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Create a new session in a target workspace.
    ///
    /// If `workspaceId` is nil, the first available workspace is used.
    func createSession(name: String? = nil, model: String? = nil, workspaceId: String? = nil) async throws -> Session {
        if let workspaceId, !workspaceId.isEmpty {
            return try await createWorkspaceSession(workspaceId: workspaceId, name: name, model: model)
        }

        let workspaces = try await listWorkspaces()
        guard let fallbackWorkspace = workspaces.first else {
            throw APIError.server(status: 404, message: "No workspaces available")
        }

        return try await createWorkspaceSession(
            workspaceId: fallbackWorkspace.id,
            name: name,
            model: model
        )
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

    // MARK: - Models

    /// Fetch available models from the server.
    func listModels() async throws -> [ModelInfo] {
        let data = try await get("/models")
        struct Response: Decodable { let models: [ModelInfo] }
        return try JSONDecoder().decode(Response.self, from: data).models
    }

    // MARK: - Workspaces

    /// List all workspaces for the authenticated user.
    func listWorkspaces() async throws -> [Workspace] {
        let data = try await get("/workspaces")
        struct Response: Decodable { let workspaces: [Workspace] }
        return try JSONDecoder().decode(Response.self, from: data).workspaces
    }

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
        let data = try await put("/workspaces/\(id)", body: request)
        struct Response: Decodable { let workspace: Workspace }
        return try JSONDecoder().decode(Response.self, from: data).workspace
    }

    /// Delete a workspace.
    func deleteWorkspace(id: String) async throws {
        _ = try await request("DELETE", path: "/workspaces/\(id)")
    }

    // MARK: - Safety Policy

    /// Fetch a human-readable policy profile for a workspace.
    func getPolicyProfile(workspaceId: String? = nil) async throws -> PolicyProfile {
        var route = "/policy/profile"
        if let workspaceId {
            route += "?workspaceId=\(try encodeQueryPath(workspaceId))"
        }
        let data = try await get(route)
        struct Response: Decodable { let profile: PolicyProfile }
        return try JSONDecoder().decode(Response.self, from: data).profile
    }

    /// List effective learned/manual policy rules visible to the user.
    func listPolicyRules(workspaceId: String? = nil) async throws -> [PolicyRuleRecord] {
        var route = "/policy/rules"
        if let workspaceId {
            route += "?workspaceId=\(try encodeQueryPath(workspaceId))"
        }
        let data = try await get(route)
        struct Response: Decodable { let rules: [PolicyRuleRecord] }
        return try JSONDecoder().decode(Response.self, from: data).rules
    }

    /// Fetch recent policy audit decisions for the workspace/user.
    func listPolicyAudit(
        workspaceId: String? = nil,
        sessionId: String? = nil,
        limit: Int = 50,
        before: Date? = nil
    ) async throws -> [PolicyAuditEntry] {
        var query: [String] = ["limit=\(limit)"]
        if let workspaceId {
            query.append("workspaceId=\(try encodeQueryPath(workspaceId))")
        }
        if let sessionId {
            query.append("sessionId=\(try encodeQueryPath(sessionId))")
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

    /// Rescan host skills (e.g. after adding a new skill on the server).
    func rescanSkills() async throws -> [SkillInfo] {
        let data = try await post("/skills/rescan", body: EmptyBody())
        struct Response: Decodable { let skills: [SkillInfo] }
        return try JSONDecoder().decode(Response.self, from: data).skills
    }

    /// List available host extensions from ~/.pi/agent/extensions.
    func listExtensions() async throws -> [ExtensionInfo] {
        let data = try await get("/extensions")
        struct Response: Decodable { let extensions: [ExtensionInfo] }
        return try JSONDecoder().decode(Response.self, from: data).extensions
    }

    /// Get full skill detail: metadata, SKILL.md content, and file tree.
    func getSkillDetail(name: String) async throws -> SkillDetail {
        let data = try await get("/skills/\(name)")
        return try JSONDecoder().decode(SkillDetail.self, from: data)
    }

    /// Get a single file's content from a skill directory.
    func getSkillFile(name: String, path: String) async throws -> String {
        let data = try await get("/skills/\(name)/file?path=\(try encodeQueryPath(path))")
        struct Response: Decodable { let content: String }
        return try JSONDecoder().decode(Response.self, from: data).content
    }

    // MARK: - Workspace-scoped Sessions (v2 API)

    /// List sessions for a specific workspace.
    func listWorkspaceSessions(workspaceId: String) async throws -> [Session] {
        let data = try await get("/workspaces/\(workspaceId)/sessions")
        struct Response: Decodable { let sessions: [Session] }
        return try JSONDecoder().decode(Response.self, from: data).sessions
    }

    /// Create a new session in a specific workspace.
    func createWorkspaceSession(workspaceId: String, name: String? = nil, model: String? = nil) async throws -> Session {
        struct Body: Encodable { let name: String?; let model: String? }
        let data = try await post("/workspaces/\(workspaceId)/sessions", body: Body(name: name, model: model))
        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Resume a stopped session in its workspace.
    func resumeWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        let data = try await post("/workspaces/\(workspaceId)/sessions/\(sessionId)/resume", body: EmptyBody())
        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Stop a session via its workspace.
    func stopWorkspaceSession(workspaceId: String, sessionId: String) async throws -> Session {
        try await stopSession(workspaceId: workspaceId, id: sessionId)
    }

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

    struct SessionOverallDiffResponse: Decodable, Sendable, Equatable {
        struct DiffLine: Decodable, Sendable, Equatable {
            enum Kind: String, Decodable, Sendable {
                case context
                case added
                case removed
            }

            let kind: Kind
            let text: String
        }

        let path: String
        let revisionCount: Int
        let baselineText: String
        let currentText: String
        let diffLines: [DiffLine]
        let addedLines: Int
        let removedLines: Int
        let cacheKey: String
    }

    func getSessionOverallDiff(
        sessionId: String,
        workspaceId: String,
        path: String
    ) async throws -> SessionOverallDiffResponse {
        let encodedPath = try encodeQueryPath(path)
        let route = "/workspaces/\(workspaceId)/sessions/\(sessionId)/overall-diff?path=\(encodedPath)"
        let data = try await get(route)
        return try JSONDecoder().decode(SessionOverallDiffResponse.self, from: data)
    }

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

    /// Fetch a file from the session's working directory.
    ///
    /// Returns the raw file content as a string. Used when the user taps a file path
    /// in a tool call row to view the current file on disk.
    func getSessionFile(workspaceId: String, sessionId: String, path: String) async throws -> String {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/files?path=\(try encodeQueryPath(path))")
        // File content is returned as raw bytes — decode as UTF-8 text
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.server(status: 422, message: "File is not text (binary content)")
        }
        return text
    }

    /// Fetch raw file data from the session's working directory (for binary files like images).
    func getSessionFileData(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        return try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/files?path=\(try encodeQueryPath(path))")
    }

    // MARK: - Device Token

    /// Register APNs device token with the server.
    func registerDeviceToken(_ token: String, tokenType: String = "apns") async throws {
        struct Body: Encodable { let deviceToken: String; let tokenType: String }
        _ = try await post("/me/device-token", body: Body(deviceToken: token, tokenType: tokenType))
    }

    /// Unregister APNs device token.
    func unregisterDeviceToken(_ token: String) async throws {
        struct Body: Encodable { let deviceToken: String }
        let (data, response) = try await request("DELETE", path: "/me/device-token", body: Body(deviceToken: token))
        try checkStatus(response, data: data)
    }

    // MARK: - Diagnostics

    /// Upload in-app client logs for a specific session (dev/debug triage).
    func uploadClientLogs(workspaceId: String, sessionId: String, request body: ClientLogUploadRequest) async throws {
        _ = try await post("/workspaces/\(workspaceId)/sessions/\(sessionId)/client-logs", body: body)
    }

    // MARK: - Private

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await request("GET", path: path)
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
        var req = URLRequest(url: try makeURL(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func request<T: Encodable>(_ method: String, path: String, body: T) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: try makeURL(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func encodeQueryPath(_ path: String) throws -> String {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        return encoded
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
        guard (200...299).contains(http.statusCode) else {
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

// MARK: - Security Request Types

private struct InviteUpdate: Encodable {
    let maxAgeSeconds: Int
}

private struct UpdateSecurityProfileRequest: Encodable {
    let profile: String
    let requireTlsOutsideTailnet: Bool
    let allowInsecureHttpInTailnet: Bool
    let requirePinnedServerIdentity: Bool
    let invite: InviteUpdate
}

// MARK: - Workspace Request Types

struct CreateWorkspaceRequest: Encodable {
    let name: String
    var description: String?
    var icon: String?
    let skills: [String]
    var runtime: String?
    var policyPreset: String?
    var systemPrompt: String?
    var hostMount: String?
    var memoryEnabled: Bool?
    var memoryNamespace: String?
    var extensionMode: String?
    var extensions: [String]?
    var defaultModel: String?
}

struct UpdateWorkspaceRequest: Encodable {
    var name: String?
    var description: String?
    var icon: String?
    var skills: [String]?
    var runtime: String?
    var policyPreset: String?
    var systemPrompt: String?
    var hostMount: String?
    var memoryEnabled: Bool?
    var memoryNamespace: String?
    var extensionMode: String?
    var extensions: [String]?
    var defaultModel: String?
}

// MARK: - Policy Models

struct PolicyProfile: Decodable, Sendable {
    let workspaceId: String?
    let workspaceName: String?
    let runtime: String
    let policyPreset: String
    let supervisionLevel: String
    let summary: String
    let generatedAt: Date
    let alwaysBlocked: [PolicyProfileItem]
    let needsApproval: [PolicyProfileItem]
    let usuallyAllowed: [String]

    enum CodingKeys: String, CodingKey {
        case workspaceId, workspaceName, runtime, policyPreset, supervisionLevel
        case summary, generatedAt, alwaysBlocked, needsApproval, usuallyAllowed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
        runtime = try c.decode(String.self, forKey: .runtime)
        policyPreset = try c.decode(String.self, forKey: .policyPreset)
        supervisionLevel = try c.decode(String.self, forKey: .supervisionLevel)
        summary = try c.decode(String.self, forKey: .summary)
        let generatedAtMs = try c.decode(Double.self, forKey: .generatedAt)
        generatedAt = Date(timeIntervalSince1970: generatedAtMs / 1000)
        alwaysBlocked = try c.decode([PolicyProfileItem].self, forKey: .alwaysBlocked)
        needsApproval = try c.decode([PolicyProfileItem].self, forKey: .needsApproval)
        usuallyAllowed = try c.decode([String].self, forKey: .usuallyAllowed)
    }
}

struct PolicyProfileItem: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String?
    let risk: RiskLevel
    let example: String?
}

struct PolicyRuleRecord: Decodable, Identifiable, Sendable {
    struct Match: Decodable, Sendable {
        let executable: String?
        let domain: String?
        let pathPattern: String?
        let commandPattern: String?
    }

    let id: String
    let effect: String
    let tool: String?
    let match: Match?
    let scope: String
    let workspaceId: String?
    let sessionId: String?
    let source: String
    let description: String
    let risk: RiskLevel
    let createdAt: Date
    let createdBy: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, effect, tool, match, scope, workspaceId, sessionId, source
        case description, risk, createdAt, createdBy, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        effect = try c.decode(String.self, forKey: .effect)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        match = try c.decodeIfPresent(Match.self, forKey: .match)
        scope = try c.decode(String.self, forKey: .scope)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        source = try c.decode(String.self, forKey: .source)
        description = try c.decode(String.self, forKey: .description)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        let createdAtMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        if let expiresMs = try c.decodeIfPresent(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: expiresMs / 1000)
        } else {
            expiresAt = nil
        }
    }
}

struct PolicyAuditUserChoice: Decodable, Sendable {
    let action: String
    let scope: String
    let learnedRuleId: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case action, scope, learnedRuleId, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        scope = try c.decode(String.self, forKey: .scope)
        learnedRuleId = try c.decodeIfPresent(String.self, forKey: .learnedRuleId)
        if let expiresAtMs = try c.decodeIfPresent(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
        } else {
            expiresAt = nil
        }
    }
}

struct PolicyAuditEntry: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let sessionId: String
    let workspaceId: String
    let userId: String
    let tool: String
    let displaySummary: String
    let risk: RiskLevel
    let decision: String
    let resolvedBy: String
    let layer: String
    let ruleId: String?
    let ruleSummary: String?
    let userChoice: PolicyAuditUserChoice?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, sessionId, workspaceId, userId, tool, displaySummary
        case risk, decision, resolvedBy, layer, ruleId, ruleSummary, userChoice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let timestampMs = try c.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: timestampMs / 1000)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        userId = try c.decode(String.self, forKey: .userId)
        tool = try c.decode(String.self, forKey: .tool)
        displaySummary = try c.decode(String.self, forKey: .displaySummary)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        decision = try c.decode(String.self, forKey: .decision)
        resolvedBy = try c.decode(String.self, forKey: .resolvedBy)
        layer = try c.decode(String.self, forKey: .layer)
        ruleId = try c.decodeIfPresent(String.self, forKey: .ruleId)
        ruleSummary = try c.decodeIfPresent(String.self, forKey: .ruleSummary)
        userChoice = try c.decodeIfPresent(PolicyAuditUserChoice.self, forKey: .userChoice)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .server(let status, let message): return "Server error (\(status)): \(message)"
        }
    }
}
