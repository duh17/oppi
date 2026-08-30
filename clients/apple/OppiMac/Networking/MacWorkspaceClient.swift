import Foundation
import OSLog

private let workspaceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacWorkspaceClient"
)

/// Local-first workspace/session snapshot client for the Mac shell.
///
/// Authenticated calls use the owner Unix socket with `sk_`. They must not send
/// the owner token over HTTPS. Selected-session live streams use the owner Unix-socket WebSocket upgrade.
actor MacWorkspaceClient {
    struct WorkspaceCatalog: Sendable, Equatable {
        let workspaces: [Workspace]
        let summaries: [String: WorkspaceListSummary]
    }

    struct WorkspaceSessionList: Sendable, Equatable {
        let workspaceId: String
        let serverNow: Int64
        let active: [SessionSummary]
        let stopped: [SessionSummary]
        let importableSessions: [LocalSession]

        var allSummaries: [SessionSummary] { active + stopped }

        var hasVisibleSessions: Bool {
            !active.isEmpty || !stopped.isEmpty || !importableSessions.isEmpty
        }
    }

    struct SessionTracePage: Decodable, Sendable {
        let session: Session
        let trace: [TraceEvent]
        let page: TracePageMetadata
        let metrics: TracePageMetrics?
    }

    struct SessionTraceOutline: Decodable, Sendable {
        let session: Session
        let outline: SessionOutlineSnapshot
    }

    struct SessionCatchUp: Sendable {
        struct Event: Sendable {
            let seq: Int
            let message: ServerMessage
        }

        let events: [Event]
        let currentSeq: Int
        let runtimeEpoch: String?
        let session: Session
        let catchUpComplete: Bool
    }

    struct CreateSessionResponse: Decodable, Sendable {
        let session: Session
        let prompted: Bool?
    }

    struct CreateControlSessionRequest: Encodable, Sendable {
        let domain: ControlSessionDomain
        let intent: ControlSessionIntent
        let targetId: String?
        let targetName: String?
        let name: String?
        let model: String?
        let thinking: ThinkingLevel?
        let prompt: String?
        let launchIdempotencyKey: String?

        init(
            domain: ControlSessionDomain,
            intent: ControlSessionIntent,
            targetId: String? = nil,
            targetName: String? = nil,
            name: String? = nil,
            model: String? = nil,
            thinking: ThinkingLevel? = nil,
            prompt: String? = nil,
            launchIdempotencyKey: String? = nil
        ) {
            self.domain = domain
            self.intent = intent
            self.targetId = targetId
            self.targetName = targetName
            self.name = name
            self.model = model
            self.thinking = thinking
            self.prompt = prompt
            self.launchIdempotencyKey = launchIdempotencyKey
        }

        private enum CodingKeys: String, CodingKey {
            case domain, intent, targetId, targetName, name, model, thinking, prompt, launchIdempotencyKey
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(domain, forKey: .domain)
            try container.encode(intent, forKey: .intent)
            try container.encodeIfPresent(targetId, forKey: .targetId)
            try container.encodeIfPresent(targetName, forKey: .targetName)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(thinking, forKey: .thinking)
            try container.encodeIfPresent(prompt, forKey: .prompt)
            try container.encodeIfPresent(launchIdempotencyKey, forKey: .launchIdempotencyKey)
        }
    }

    struct StopSessionResponse: Decodable, Sendable {
        let session: Session?
    }

    struct WorkspaceResponse: Decodable, Sendable {
        let workspace: Workspace
    }

    struct CreateUploadResponse: Decodable, Sendable, Equatable {
        let uploadId: String
        let contentUrl: String
        let maxFileBytes: Int
        let expiresAt: Int
    }

    struct UploadContentResponse: Decodable, Sendable, Equatable {
        let attachment: ChatAttachmentRef
    }

    let socketPath: String
    private let token: String
    private let transport: any MacLocalHTTPPerforming

    func ownerToken() -> String { token }

    init(
        socketPath: String,
        token: String,
        timeoutIntervalForRequest: TimeInterval = 10,
        transport: (any MacLocalHTTPPerforming)? = nil
    ) {
        self.socketPath = socketPath
        self.token = token
        self.transport = transport ?? MacUnixSocketHTTPClient(
            socketPath: socketPath,
            timeout: timeoutIntervalForRequest
        )
    }

    nonisolated static func localOwner(
        dataDir: String = NSString("~/.config/oppi").expandingTildeInPath
    ) -> MacWorkspaceClient? {
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return nil }
        return MacWorkspaceClient(
            socketPath: MacLocalAPISocket.path(dataDir: dataDir),
            token: token
        )
    }

    func listWorkspaceCatalog() async throws -> WorkspaceCatalog {
        let data = try await get("/workspaces")
        return try Self.decodeWorkspaceCatalog(data)
    }

    /// List git checkouts available inside a workspace. Does not create worktrees.
    func listWorkspaceWorktrees(workspaceId: String) async throws -> [WorkspaceWorktree] {
        let data = try await get("/workspaces/\(workspaceId)/worktrees")
        return try Self.decodeWorkspaceWorktrees(data)
    }

    func listModels() async throws -> [ModelInfo] {
        let data = try await get("/models")
        return try Self.decodeModels(data)
    }

    func listAgents(includeArchived: Bool = false) async throws -> [AgentDefinitionSummary] {
        let data = try await get(
            url: try makeURL(
                path: "/agents",
                queryItems: includeArchived ? [URLQueryItem(name: "includeArchived", value: "true")] : []
            )
        )
        return try JSONDecoder().decode(AgentListResponse.self, from: data).agents
    }

    func getAgent(_ agentId: String) async throws -> StoredAgentDefinition {
        let data = try await get(url: try makeURL(pathSegments: ["agents", agentId]))
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func createAgent(_ definition: AgentDefinition) async throws -> StoredAgentDefinition {
        let data = try await post(path: "/agents", body: definition)
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func updateAgent(agentId: String, definition: AgentDefinition) async throws -> StoredAgentDefinition {
        struct UpdateBody: Encodable {
            let definition: AgentDefinition

            enum CodingKeys: String, CodingKey {
                case name, icon, description, instructions, resources, sessionDefaults, launchConstraints
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(definition.name, forKey: .name)
                try container.encode(definition.icon, forKey: .icon)
                try encodeNullable(definition.description, to: &container, forKey: .description)
                try encodeNullable(definition.instructions, to: &container, forKey: .instructions)
                try encodeNullable(definition.resources, to: &container, forKey: .resources)
                try encodeNullable(definition.sessionDefaults, to: &container, forKey: .sessionDefaults)
                try container.encodeIfPresent(definition.launchConstraints, forKey: .launchConstraints)
            }

            func encodeNullable<T: Encodable>(
                _ value: T?,
                to container: inout KeyedEncodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) throws {
                if let value {
                    try container.encode(value, forKey: key)
                } else {
                    try container.encodeNil(forKey: key)
                }
            }
        }

        let data = try await patch(
            url: try makeURL(pathSegments: ["agents", agentId]),
            body: UpdateBody(definition: definition)
        )
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func archiveAgent(agentId: String) async throws -> StoredAgentDefinition {
        let data = try await send(
            method: "DELETE",
            url: try makeURL(pathSegments: ["agents", agentId])
        )
        return try JSONDecoder().decode(AgentResponse.self, from: data).agent
    }

    func listAgentSchedules() async throws -> [AgentScheduleSummary] {
        let data = try await get("/schedules")
        return try JSONDecoder().decode(AgentScheduleListResponse.self, from: data).schedules
    }

    func getAgentSchedule(_ scheduleId: String) async throws -> AgentSchedule {
        let data = try await get(url: try makeURL(pathSegments: ["schedules", scheduleId]))
        return try JSONDecoder().decode(AgentScheduleResponse.self, from: data).schedule
    }

    func createAgentSchedule(
        name: String,
        trigger: AgentScheduleTrigger,
        action: AgentScheduleAction
    ) async throws -> AgentScheduleSummary {
        struct Body: Encodable {
            let name: String
            let trigger: AgentScheduleTrigger
            let action: AgentScheduleAction
        }
        let data = try await post(
            path: "/schedules",
            body: Body(name: name, trigger: trigger, action: action)
        )
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
    }

    func updateAgentSchedule(
        scheduleId: String,
        name: String,
        trigger: AgentScheduleTrigger,
        action: AgentScheduleAction
    ) async throws -> AgentScheduleSummary {
        struct Body: Encodable {
            let name: String
            let trigger: AgentScheduleTrigger
            let action: AgentScheduleAction
        }
        let data = try await patch(
            url: try makeURL(pathSegments: ["schedules", scheduleId]),
            body: Body(name: name, trigger: trigger, action: action)
        )
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
    }

    func setAgentScheduleStatus(
        scheduleId: String,
        status: AgentScheduleStatus
    ) async throws -> AgentScheduleSummary {
        let action: String
        switch status {
        case .active: action = "resume"
        case .paused: action = "pause"
        case .archived: action = "archive"
        }
        let data = try await post(
            url: try makeURL(pathSegments: ["schedules", scheduleId, action]),
            body: EmptyBody()
        )
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
    }

    func restoreAgentSchedule(_ scheduleId: String) async throws -> AgentScheduleSummary {
        let data = try await post(
            url: try makeURL(pathSegments: ["schedules", scheduleId, "restore"]),
            body: EmptyBody()
        )
        return try JSONDecoder().decode(AgentScheduleSummaryResponse.self, from: data).schedule
    }

    func listServerSkills() async throws -> [ServerSkillSummary] {
        let data = try await get(url: try makeURL(pathSegments: ["server", "resources", "skills"]))
        return try JSONDecoder().decode(ServerSkillsCatalog.self, from: data).skills
    }

    func getServerSkill(id: String) async throws -> ServerSkillDetail {
        let data = try await get(url: try makeURL(pathSegments: ["server", "resources", "skills", id]))
        return try JSONDecoder().decode(ServerSkillDetail.self, from: data)
    }

    func setServerSkillEnabled(id: String, enabled: Bool) async throws -> ServerSkillSummary {
        let data = try await put(
            url: try makeURL(pathSegments: ["server", "resources", "skills", id, "enabled"]),
            body: ResourceEnabledBody(enabled: enabled)
        )
        return try JSONDecoder().decode(ServerSkillSummary.self, from: data)
    }

    func listServerExtensions() async throws -> ServerExtensionCatalog {
        let data = try await get(url: try makeURL(pathSegments: ["server", "resources", "extensions"]))
        return try JSONDecoder().decode(ServerExtensionCatalog.self, from: data)
    }

    func getServerExtension(id: String) async throws -> ServerExtensionDetail {
        let data = try await get(url: try makeURL(pathSegments: ["server", "resources", "extensions", id]))
        return try JSONDecoder().decode(ServerExtensionDetail.self, from: data)
    }

    func setServerExtensionEnabled(id: String, enabled: Bool) async throws -> ServerExtensionSummary {
        let data = try await put(
            url: try makeURL(pathSegments: ["server", "resources", "extensions", id, "enabled"]),
            body: ResourceEnabledBody(enabled: enabled)
        )
        return try JSONDecoder().decode(ServerExtensionSummary.self, from: data)
    }

    func listWorkspaceDirectory(
        workspaceId: String,
        path: String = "",
        worktreeId: String? = nil
    ) async throws -> DirectoryListingResponse {
        var queryItems: [URLQueryItem] = []
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let data = try await get(
            url: try makeURL(
                pathSegments: ["workspaces", workspaceId, "contents"],
                appendedPath: path == "/" ? "" : path,
                queryItems: queryItems,
                trailingSlash: true
            )
        )
        return try Self.decodeDirectoryListing(data)
    }

    func fetchFileIndex(workspaceId: String) async throws -> FileIndexResponse {
        let data = try await get("/workspaces/\(workspaceId)/paths")
        return try Self.decodeFileIndex(data)
    }

    func listSessionChanges(workspaceId: String, sessionId: String) async throws -> SessionChangesResponse {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/changes")
        return try Self.decodeSessionChanges(data)
    }

    func getSessionDiff(workspaceId: String, sessionId: String, path: String) async throws -> WorkspaceReviewDiffResponse {
        let data = try await get(
            url: try makeURL(
                path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/diff",
                queryItems: [URLQueryItem(name: "path", value: path)]
            )
        )
        return try Self.decodeSessionDiff(data)
    }

    func getGitStatus(workspaceId: String, worktreeId: String? = nil) async throws -> GitStatus {
        var queryItems: [URLQueryItem] = []
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let data = try await get(
            url: try makeURL(
                path: "/workspaces/\(workspaceId)/git/status",
                queryItems: queryItems
            )
        )
        return try Self.decodeGitStatus(data)
    }

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
        let data = try await get(
            url: try makeURL(
                path: "/workspaces/\(workspaceId)/git/diff",
                queryItems: queryItems
            )
        )
        return try Self.decodeWorkspaceReviewDiff(data)
    }

    func getSessionRawFileData(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        try await get(
            url: try makeURL(
                pathSegments: ["workspaces", workspaceId, "sessions", sessionId, "raw", path]
            )
        )
    }

    /// Fetch workspace file bytes. Omitting `worktreeId` matches the server's
    /// main-checkout default. `main` is omitted so raw URLs keep that identity.
    func getWorkspaceRawFileData(
        workspaceId: String,
        path: String,
        worktreeId: String? = nil
    ) async throws -> Data {
        var queryItems: [URLQueryItem] = []
        if let worktreeId = FileViewerPlan.normalizedWorktreeId(worktreeId) {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        return try await get(
            url: try makeURL(
                pathSegments: ["workspaces", workspaceId, "raw"],
                appendedPath: path,
                queryItems: queryItems
            )
        )
    }

    /// Fetch untruncated tool output from the server temp-file side channel.
    ///
    /// Returns nil when the server no longer has the backing file (404).
    func getFullToolOutput(
        workspaceId: String,
        sessionId: String,
        toolCallId: String
    ) async throws -> String? {
        try await getFullToolOutput(
            scope: .workspace(workspaceId),
            sessionId: sessionId,
            toolCallId: toolCallId
        )
    }

    func getFullToolOutput(
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String
    ) async throws -> String? {
        do {
            let data = try await get(
                url: try makeURL(
                    path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/tool-output/\(toolCallId)",
                    queryItems: [URLQueryItem(name: "full", value: "true")]
                )
            )
            return try Self.decodeFullToolOutput(data)
        } catch let MacWorkspaceClientError.server(status, _) where status == 404 {
            return nil
        }
    }

    static func decodeFullToolOutput(_ data: Data) throws -> String {
        struct Response: Decodable {
            let output: String
        }
        return try JSONDecoder().decode(Response.self, from: data).output
    }

    func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> Workspace {
        let data = try await post(path: "/workspaces", body: request)
        return try JSONDecoder().decode(WorkspaceResponse.self, from: data).workspace
    }

    func updateWorkspace(id: String, request: UpdateWorkspaceRequest) async throws -> Workspace {
        let data = try await put(path: "/workspaces/\(id)", body: request.body)
        return try JSONDecoder().decode(WorkspaceResponse.self, from: data).workspace
    }

    func deleteWorkspace(id: String) async throws {
        _ = try await request(method: "DELETE", path: "/workspaces/\(id)")
    }

    /// Recent session summaries across workspaces. Same `/sessions/recent`
    /// payload as iOS (`{ "sessions": [SessionSummary] }`).
    func listRecentSessions(recentDays: Int = 3) async throws -> [SessionSummary] {
        let data = try await get(
            url: try makeURL(
                path: "/sessions/recent",
                queryItems: [URLQueryItem(name: "recentDays", value: String(recentDays))]
            )
        )
        return try Self.decodeRecentSessions(data)
    }

    /// Generic session metadata for deep links whose row is outside the recent snapshot.
    func getSessionRecord(sessionId: String) async throws -> Session {
        struct Response: Decodable {
            let session: Session
        }
        let data = try await get(url: try makeURL(pathSegments: ["sessions", sessionId]))
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Full-text search across session content. Same `/sessions/search` as iOS.
    func searchSessions(
        query: String,
        workspaceId: String? = nil,
        limit: Int = 20
    ) async throws -> SessionSearchResponse {
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let workspaceId {
            queryItems.append(URLQueryItem(name: "workspaceId", value: workspaceId))
        }
        let data = try await get(
            url: try makeURL(path: "/sessions/search", queryItems: queryItems)
        )
        return try JSONDecoder().decode(SessionSearchResponse.self, from: data)
    }

    /// Omitting `worktreeId` matches the server's main-only default.
    /// There is no all-worktrees collection mode.
    func getWorkspaceSessions(
        workspaceId: String,
        since: Date,
        until: Date,
        worktreeId: String? = nil
    ) async throws -> WorkspaceSessionList {
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        var queryItems = [
            URLQueryItem(name: "status", value: "active,stopped"),
            URLQueryItem(name: "sinceMs", value: String(sinceMs)),
            URLQueryItem(name: "untilMs", value: String(untilMs)),
        ]
        if let worktreeId, !worktreeId.isEmpty {
            queryItems.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        let data = try await get(
            url: try makeURL(path: "/workspaces/\(workspaceId)/sessions", queryItems: queryItems)
        )
        return try Self.decodeWorkspaceSessionList(data)
    }

    func getWorkspaceSessionTracePage(
        workspaceId: String,
        sessionId: String,
        targetEvents: Int = 120,
        previewBytes: Int = 8_192,
        cursor: String? = nil,
        aroundEntryId: String? = nil
    ) async throws -> SessionTracePage {
        try await getSessionTracePage(
            scope: .workspace(workspaceId),
            sessionId: sessionId,
            targetEvents: targetEvents,
            previewBytes: previewBytes,
            cursor: cursor,
            aroundEntryId: aroundEntryId
        )
    }

    func getSessionTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        targetEvents: Int = 120,
        previewBytes: Int = 8_192,
        cursor: String? = nil,
        aroundEntryId: String? = nil
    ) async throws -> SessionTracePage {
        var queryItems = [
            URLQueryItem(name: "presentation", value: "mobile"),
            URLQueryItem(name: "targetEvents", value: String(targetEvents)),
            URLQueryItem(name: "previewBytes", value: String(previewBytes)),
        ]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let aroundEntryId {
            queryItems.append(URLQueryItem(name: "aroundEntryId", value: aroundEntryId))
        }
        let data = try await get(
            url: try makeURL(
                path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/trace-page",
                queryItems: queryItems
            )
        )
        return try JSONDecoder().decode(
            SessionTracePage.self,
            from: JSONUnpairedSurrogateRepair.repairing(data)
        )
    }

    func getWorkspaceSessionTraceOutline(
        workspaceId: String,
        sessionId: String
    ) async throws -> SessionOutlineSnapshot {
        try await getSessionTraceOutline(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func getSessionTraceOutline(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> SessionOutlineSnapshot {
        let data = try await get(
            url: try makeURL(
                path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/trace-outline"
            )
        )
        return try JSONDecoder().decode(
            SessionTraceOutline.self,
            from: JSONUnpairedSurrogateRepair.repairing(data)
        ).outline
    }

    func getWorkspaceSessionEvents(
        workspaceId: String,
        sessionId: String,
        since: Int
    ) async throws -> SessionCatchUp {
        try await getSessionEvents(scope: .workspace(workspaceId), sessionId: sessionId, since: since)
    }

    func getSessionEvents(
        scope: SessionRouteScope,
        sessionId: String,
        since: Int
    ) async throws -> SessionCatchUp {
        let data = try await get(
            url: try makeURL(
                path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/events",
                queryItems: [URLQueryItem(name: "since", value: String(since))]
            )
        )
        return try Self.decodeSessionCatchUp(data)
    }

    func createControlSession(_ request: CreateControlSessionRequest) async throws -> CreateSessionResponse {
        let data = try await post(path: "/control-sessions", body: request)
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    func createWorkspaceSession(
        workspaceId: String,
        name: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        ephemeral: Bool? = nil,
        worktreeId: String? = nil
    ) async throws -> CreateSessionResponse {
        struct Body: Encodable {
            let name: String?
            let model: String?
            let prompt: String?
            let ephemeral: Bool?
            let worktreeId: String?
        }
        let data = try await post(
            path: "/workspaces/\(workspaceId)/sessions",
            body: Body(
                name: name,
                model: model,
                prompt: prompt,
                ephemeral: ephemeral,
                worktreeId: worktreeId
            )
        )
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    /// Resume a local pi TUI session into this workspace.
    func createWorkspaceSessionFromLocal(
        workspaceId: String,
        piSessionFile: String,
        worktreeId: String? = nil
    ) async throws -> CreateSessionResponse {
        struct Body: Encodable {
            let piSessionFile: String
            let worktreeId: String?
        }
        let data = try await post(
            path: "/workspaces/\(workspaceId)/sessions",
            body: Body(piSessionFile: piSessionFile, worktreeId: worktreeId)
        )
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    func stopWorkspaceSession(
        workspaceId: String,
        sessionId: String
    ) async throws -> StopSessionResponse {
        try await stopSession(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func stopSession(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> StopSessionResponse {
        let data = try await post(
            path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/stop",
            body: EmptyBody()
        )
        return try JSONDecoder().decode(StopSessionResponse.self, from: data)
    }

    func resumeSession(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> Session {
        struct Response: Decodable {
            let session: Session
        }
        let data = try await post(
            path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/resume",
            body: EmptyBody()
        )
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    func deleteWorkspaceSession(
        workspaceId: String,
        sessionId: String
    ) async throws {
        try await deleteSession(scope: .workspace(workspaceId), sessionId: sessionId)
    }

    func deleteSession(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws {
        _ = try await request(
            method: "DELETE",
            path: Self.focusedSessionPath(scope: scope, sessionId: sessionId)
        )
    }

    static func focusedSessionPath(scope: SessionRouteScope, sessionId: String) -> String {
        switch scope {
        case .workspace(let workspaceId):
            "/workspaces/\(workspaceId)/sessions/\(sessionId)"
        case .control:
            "/control-sessions/\(sessionId)"
        }
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
            scope: .workspace(workspaceId),
            sessionId: sessionId,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            purpose: purpose
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
        struct Body: Encodable {
            let name: String
            let mimeType: String
            let sizeBytes: Int
            let purpose: String
        }
        let data = try await post(
            path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/attachments",
            body: Body(name: name, mimeType: mimeType, sizeBytes: sizeBytes, purpose: purpose)
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
            scope: .workspace(workspaceId),
            sessionId: sessionId,
            attachmentId: attachmentId,
            data: body,
            contentType: contentType
        )
    }

    func uploadSessionAttachmentContent(
        scope: SessionRouteScope,
        sessionId: String,
        attachmentId: String,
        data body: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> ChatAttachmentRef {
        let data = try await putRaw(
            path: "\(Self.focusedSessionPath(scope: scope, sessionId: sessionId))/attachments/\(attachmentId)/content",
            body: body,
            contentType: contentType
        )
        return try JSONDecoder().decode(UploadContentResponse.self, from: data).attachment
    }

    static func decodeWorkspaceWorktrees(_ data: Data) throws -> [WorkspaceWorktree] {
        struct Response: Decodable {
            let worktrees: [WorkspaceWorktree]
        }
        return try JSONDecoder().decode(Response.self, from: data).worktrees
    }

    static func decodeWorkspaceCatalog(_ data: Data) throws -> WorkspaceCatalog {
        struct Response: Decodable {
            let workspaces: [Workspace]
            let summaries: [WorkspaceListSummary]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let summaries = Dictionary(
            uniqueKeysWithValues: (response.summaries ?? []).map { ($0.workspaceId, $0) }
        )
        return WorkspaceCatalog(workspaces: response.workspaces, summaries: summaries)
    }

    static func decodeModels(_ data: Data) throws -> [ModelInfo] {
        struct Response: Decodable {
            let models: [ModelInfo]
        }
        return try JSONDecoder().decode(Response.self, from: data).models
    }

    static func decodeDirectoryListing(_ data: Data) throws -> DirectoryListingResponse {
        try JSONDecoder().decode(DirectoryListingResponse.self, from: data)
    }

    static func decodeFileIndex(_ data: Data) throws -> FileIndexResponse {
        try JSONDecoder().decode(FileIndexResponse.self, from: data)
    }

    static func decodeSessionChanges(_ data: Data) throws -> SessionChangesResponse {
        try JSONDecoder().decode(SessionChangesResponse.self, from: data)
    }

    static func decodeSessionDiff(_ data: Data) throws -> WorkspaceReviewDiffResponse {
        try JSONDecoder().decode(WorkspaceReviewDiffResponse.self, from: data)
    }

    static func decodeGitStatus(_ data: Data) throws -> GitStatus {
        try JSONDecoder().decode(GitStatus.self, from: data)
    }

    static func decodeWorkspaceReviewDiff(_ data: Data) throws -> WorkspaceReviewDiffResponse {
        try decodeSessionDiff(data)
    }

    static func decodeSessionCatchUp(_ data: Data) throws -> SessionCatchUp {
        let payload = try JSONDecoder().decode(SessionCatchUpPayload.self, from: data)
        return SessionCatchUp(
            events: payload.events.map { SessionCatchUp.Event(seq: $0.seq, message: $0.message) },
            currentSeq: payload.currentSeq,
            runtimeEpoch: payload.runtimeEpoch,
            session: payload.session,
            catchUpComplete: payload.catchUpComplete
        )
    }

    static func decodeRecentSessions(_ data: Data) throws -> [SessionSummary] {
        struct Response: Decodable {
            let sessionSummaries: [SessionSummary]

            enum CodingKeys: String, CodingKey {
                case sessionSummaries = "sessions"
            }
        }
        return try JSONDecoder().decode(Response.self, from: data).sessionSummaries
    }

    static func decodeWorkspaceSessionList(_ data: Data) throws -> WorkspaceSessionList {
        let response = try JSONDecoder().decode(WorkspaceSessionCollectionResponse.self, from: data)
        return WorkspaceSessionList(
            workspaceId: response.workspaceId,
            serverNow: response.serverNow,
            active: response.active.compactMap(\.sessionSummary),
            stopped: response.stopped.compactMap(\.sessionSummary),
            importableSessions: response.stopped.compactMap(\.localSession)
        )
    }

    private func get(_ path: String) async throws -> Data {
        try await get(url: makeURL(path: path))
    }

    private func get(url: URL) async throws -> Data {
        try await send(method: "GET", url: url)
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws -> Data {
        try await post(url: try makeURL(path: path), body: body)
    }

    private func post<Body: Encodable>(url: URL, body: Body) async throws -> Data {
        try await send(
            method: "POST",
            url: url,
            body: try JSONEncoder().encode(body),
            contentType: "application/json"
        )
    }

    private func put<Body: Encodable>(path: String, body: Body) async throws -> Data {
        try await put(url: try makeURL(path: path), body: body)
    }

    private func put<Body: Encodable>(url: URL, body: Body) async throws -> Data {
        try await send(
            method: "PUT",
            url: url,
            body: try JSONEncoder().encode(body),
            contentType: "application/json"
        )
    }

    private func patch<Body: Encodable>(url: URL, body: Body) async throws -> Data {
        try await send(
            method: "PATCH",
            url: url,
            body: try JSONEncoder().encode(body),
            contentType: "application/json"
        )
    }

    private func putRaw(path: String, body: Data, contentType: String) async throws -> Data {
        try await send(method: "PUT", url: try makeURL(path: path), body: body, contentType: contentType)
    }

    private func request(method: String, path: String) async throws -> Data {
        try await send(method: method, url: try makeURL(path: path))
    }

    private func send(method: String, url: URL, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        let path = requestTarget(from: url)
        workspaceLogger.debug("\(method) \(path)")
        let response = try await transport.perform(
            macLocalAuthenticatedRequest(
                method: method,
                path: path,
                token: token,
                body: body,
                contentType: contentType
            )
        )
        try checkStatus(response)
        return response.body
    }

    private func requestTarget(from url: URL) -> String {
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true), !query.isEmpty {
            target += "?\(query)"
        }
        return target
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        var components = try localhostComponents()
        let normalizedBasePath: String = {
            if components.path.isEmpty || components.path == "/" { return "" }
            if components.path.hasSuffix("/") { return String(components.path.dropLast()) }
            return components.path
        }()
        components.path = normalizedBasePath + (path.hasPrefix("/") ? path : "/\(path)")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw MacWorkspaceClientError.invalidURL }
        return url
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
        var path = "/\((encodedSegments + appendedSegments).joined(separator: "/"))"
        if trailingSlash { path += "/" }
        return try makeURL(percentEncodedPath: path, queryItems: queryItems)
    }

    private func makeURL(percentEncodedPath: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = try localhostComponents()
        let normalizedBasePath: String = {
            if components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" { return "" }
            if components.percentEncodedPath.hasSuffix("/") { return String(components.percentEncodedPath.dropLast()) }
            return components.percentEncodedPath
        }()
        components.percentEncodedPath = normalizedBasePath + (percentEncodedPath.hasPrefix("/") ? percentEncodedPath : "/\(percentEncodedPath)")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw MacWorkspaceClientError.invalidURL }
        return url
    }

    private func localhostComponents() throws -> URLComponents {
        guard let components = URLComponents(string: "http://localhost") else {
            throw MacWorkspaceClientError.invalidURL
        }
        return components
    }

    private func percentEncodePathSegment(_ segment: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw MacWorkspaceClientError.invalidURL
        }
        return encoded
    }

    private func checkStatus(_ response: MacLocalHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw MacWorkspaceClientError.server(status: response.statusCode, message: body)
        }
    }
}

extension MacWorkspaceClient: SessionSearching {}

private struct EmptyBody: Encodable, Sendable {}

private struct ResourceEnabledBody: Encodable, Sendable {
    let enabled: Bool
}

private struct SessionCatchUpPayload: Decodable {
    let events: [SequencedCatchUpEvent]
    let currentSeq: Int
    let runtimeEpoch: String?
    let catchUpComplete: Bool
    let session: Session
}

private struct SequencedCatchUpEvent: Decodable {
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

private struct WorkspaceSessionManagedRow: Decodable, Sendable, Equatable {
    let summary: SessionSummary

    init(from decoder: Decoder) throws {
        summary = try SessionSummary(from: decoder)
    }
}

private enum WorkspaceSessionListRow: Decodable, Sendable, Equatable {
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

    var sessionSummary: SessionSummary? {
        if case .session(let row) = self { return row.summary }
        return nil
    }

    var localSession: LocalSession? {
        if case .tui(let session) = self { return session }
        return nil
    }
}

private struct WorkspaceSessionCollectionResponse: Decodable, Sendable, Equatable {
    let workspaceId: String
    let serverNow: Int64
    let active: [WorkspaceSessionListRow]
    let stopped: [WorkspaceSessionListRow]

    enum CodingKeys: String, CodingKey {
        case workspaceId, serverNow, active, stopped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        serverNow = try container.decode(Int64.self, forKey: .serverNow)
        active = try container.decodeIfPresent([WorkspaceSessionListRow].self, forKey: .active) ?? []
        stopped = try container.decodeIfPresent([WorkspaceSessionListRow].self, forKey: .stopped) ?? []
    }
}

enum MacWorkspaceClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .invalidResponse:
            return "Server returned an invalid response."
        case .server(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Server request failed with status \(status)."
            }
            return "Server request failed with status \(status): \(trimmed)"
        }
    }
}
