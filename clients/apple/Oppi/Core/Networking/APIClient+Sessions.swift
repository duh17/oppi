import Foundation

struct CreateWorkspaceSessionConflict: Error, Sendable {
    let sessionId: String
    let message: String
}

private struct SessionCommandRejectedError: LocalizedError {
    let message: String

    var errorDescription: String? {
        UserFacingErrorText.normalize(message)
    }
}

// MARK: - Sessions

extension APIClient {
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
        return try await get("/sessions/search?\(qs)", as: SessionSearchResponse.self)
    }

    struct SequencedServerEvent: Sendable, Equatable {
        let seq: Int
        let message: ServerMessage
    }

    struct SessionEventsResponse: Sendable, Equatable {
        let events: [SequencedServerEvent]
        let currentSeq: Int
        let runtimeEpoch: String?
        let session: Session
        let catchUpComplete: Bool
        /// False when the session exists but has no live event ring.
        let live: Bool

        init(
            events: [SequencedServerEvent],
            currentSeq: Int,
            runtimeEpoch: String? = nil,
            session: Session,
            catchUpComplete: Bool,
            live: Bool = true
        ) {
            self.events = events
            self.currentSeq = currentSeq
            self.runtimeEpoch = runtimeEpoch
            self.session = session
            self.catchUpComplete = catchUpComplete
            self.live = live
        }
    }

    func focusedSessionPath(scope: SessionRouteScope, sessionId: String) -> String {
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
    func getSessionEvents(scope: SessionRouteScope, id: String, since: Int) async throws -> SessionEventsResponse {
        let payload = try await get(
            "\(focusedSessionPath(scope: scope, sessionId: id))/events?since=\(since)",
            as: SessionEventsPayload.self
        )

        let events = payload.events.map {
            SequencedServerEvent(seq: $0.seq, message: $0.message)
        }

        return SessionEventsResponse(
            events: events,
            currentSeq: payload.currentSeq,
            runtimeEpoch: payload.runtimeEpoch,
            session: payload.session,
            catchUpComplete: payload.catchUpComplete,
            live: payload.live
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
        let runtimeEpoch: String?
        let catchUpComplete: Bool
        let session: Session
        /// This server always sends `live`. A missing field is a decode failure, not a live ring.
        let live: Bool
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

    /// Fetches a session together with its trace. The trace read is the expensive part of
    /// the route, so `traceView` has no default: a caller that needs only the session
    /// record uses `getSessionRecord(sessionId:)`.
    func getSession(
        scope: SessionRouteScope,
        sessionId: String,
        traceView: SessionTraceView
    ) async throws -> (session: Session, trace: [TraceEvent]) {
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))?view=\(traceView.rawValue)")
        struct Response: Decodable { let session: Session; let trace: [TraceEvent] }
        let response = try JSONDecoder().decode(
            Response.self,
            from: JSONUnpairedSurrogateRepair.repairing(data)
        )
        return (response.session, response.trace)
    }

    /// Generic session metadata without a workspace or control route scope.
    func getSessionRecord(sessionId: String) async throws -> Session {
        struct Response: Decodable { let session: Session }
        return try await get("/sessions/\(sessionId)", as: Response.self).session
    }

    struct SessionDialogsResponse: Decodable, Sendable, Equatable {
        let dialogs: [ExtensionUIRequest.DialogSnapshot]
        let serverNow: Int64?
    }

    /// Pending user-reply dialogs for one session (`GET /sessions/:id/dialogs`).
    func getSessionDialogs(sessionId: String) async throws -> SessionDialogsResponse {
        try await get("/sessions/\(sessionId)/dialogs", as: SessionDialogsResponse.self)
    }

    /// Get a paged session trace for timeline history.
    func getSessionTracePage(
        scope: SessionRouteScope,
        sessionId: String,
        cursor: String? = nil,
        targetEvents: Int? = nil,
        previewBytes: Int? = nil
    ) async throws -> SessionTracePageResponse {
        var items = [URLQueryItem(name: "presentation", value: "mobile")]
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let targetEvents {
            items.append(URLQueryItem(name: "targetEvents", value: String(targetEvents)))
        }
        if let previewBytes {
            items.append(URLQueryItem(name: "previewBytes", value: String(previewBytes)))
        }
        var components = URLComponents()
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let data = try await get("\(focusedSessionPath(scope: scope, sessionId: sessionId))/trace-page\(query)")
        return try JSONDecoder().decode(
            SessionTracePageResponse.self,
            from: JSONUnpairedSurrogateRepair.repairing(data)
        )
    }

    func getSessionTraceOutline(
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> SessionTraceOutlineResponse {
        try await get(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/trace-outline",
            as: SessionTraceOutlineResponse.self
        )
    }

    /// Stop a running session.
    func stopSession(scope: SessionRouteScope, sessionId: String) async throws -> Session {
        struct Response: Decodable { let session: Session? }
        let response = try await post(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/stop",
            body: EmptyBody(),
            as: Response.self
        )
        if let session = response.session { return session }
        return try await getSessionRecord(sessionId: sessionId)
    }

    /// Delete a session permanently.
    func deleteSession(scope: SessionRouteScope, sessionId: String) async throws {
        _ = try await delete(focusedSessionPath(scope: scope, sessionId: sessionId))
    }

    /// Send a session command over HTTP when no focused session WebSocket is available.
    func sendSessionCommand(
        scope: SessionRouteScope,
        sessionId: String,
        message: ClientMessage
    ) async throws {
        struct Response: Decodable {
            let messages: [ServerMessage]
        }

        let response = try await post(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/command",
            body: message,
            as: Response.self
        )
        for case .commandResult(_, _, false, _, let error) in response.messages {
            throw SessionCommandRejectedError(message: error ?? "Session command failed")
        }
    }

    /// Respond to an extension UI request in another session without focusing its stream.
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
}

// MARK: - Workspace-scoped Sessions

extension APIClient {
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

    enum WorkspaceSessionListRow: Decodable, Sendable, Equatable {
        case session(SessionSummary)
        case tui(LocalSession)

        private enum CodingKeys: String, CodingKey {
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decodeIfPresent(String.self, forKey: .source) == "tui" {
                self = .tui(try LocalSession(from: decoder))
            } else {
                self = .session(try SessionSummary(from: decoder))
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
                if case .session(let summary) = row { return summary }
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

    /// Assembled on device from the sessions, session-buckets, and attention routes; never decoded.
    struct WorkspaceSessionListResponse: Sendable {
        let workspace: Workspace
        let serverNow: Int64
        let sessionSummaries: [SessionSummary]
        let attention: WorkspaceAttentionResponse.Attention
        let importableSessions: [LocalSession]
        let archiveBuckets: [WorkspaceSessionArchiveBucket]
    }

    /// Assembled on device from one sessions route response; never decoded.
    struct WorkspaceSessionListBucketResponse: Sendable {
        let workspaceId: String
        let sinceMs: Int64
        let untilMs: Int64
        let sessionSummaries: [SessionSummary]
        let importableSessions: [LocalSession]
    }

    func getWorkspaceAttention(workspaceId: String) async throws -> WorkspaceAttentionResponse {
        try await get("/workspaces/\(workspaceId)/attention", as: WorkspaceAttentionResponse.self)
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
        let sections = try await get(
            "/workspaces/\(workspaceId)/sessions?\(query)",
            as: WorkspaceSessionCollectionResponse.self
        )
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
        try await get(
            "/sessions/recent?recentDays=\(recentDays)",
            as: WorkspaceSessionSummariesResponse.self
        ).sessionSummaries
    }

    /// Bootstrap helper for flows that have an API client but no populated workspace store yet.
    func listSessionsFromWorkspaces(recentDays: Int = 3) async throws -> [Session] {
        let summaries = try await listRecentWorkspaceSessionSummaries(recentDays: recentDays)
        return summaries.map(\.session)
    }

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
        attachments: [ChatAttachmentRef]? = nil,
        launchIdempotencyKey: String? = nil,
        engine: SessionEngine = .classic
    ) async throws -> CreateSessionResponse {
        struct Body: Encodable {
            let name: String?
            let model: String?
            let prompt: String?
            let thinking: String?
            let ephemeral: Bool?
            let worktreeId: String?
            let attachments: [ChatAttachmentRef]?
            let launchIdempotencyKey: String?
            /// Omitted for classic, the server default.
            let engine: SessionEngine?
        }
        let (data, response) = try await request(
            "POST",
            path: "/workspaces/\(workspaceId)/sessions",
            body: Body(
                name: name,
                model: model,
                prompt: prompt,
                thinking: thinking,
                ephemeral: ephemeral,
                worktreeId: worktreeId,
                attachments: attachments,
                launchIdempotencyKey: launchIdempotencyKey,
                engine: engine == .durable ? engine : nil
            )
        )
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            struct ConflictBody: Decodable {
                let error: String?
                let sessionId: String?
            }
            if let conflict = try? JSONDecoder().decode(ConflictBody.self, from: data),
               let sessionId = conflict.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionId.isEmpty {
                throw CreateWorkspaceSessionConflict(
                    sessionId: sessionId,
                    message: conflict.error ?? "Conflict"
                )
            }
        }
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    /// Body of `POST /control-sessions`. The prompt carries the target, request,
    /// and staged review comments; the server delivers it once per launch key.
    struct CreateControlSessionRequest: Codable, Sendable {
        let prompt: String
        /// Staged comments the server renders before `prompt` for the model only.
        let context: [PromptContextItem]?
        let name: String?
        let model: String?
        let thinking: ThinkingLevel?
        let launchIdempotencyKey: String?

        init(
            prompt: String,
            context: [PromptContextItem]? = nil,
            name: String? = nil,
            model: String? = nil,
            thinking: ThinkingLevel? = nil,
            launchIdempotencyKey: String? = nil
        ) {
            self.prompt = prompt
            self.context = context
            self.name = name
            self.model = model
            self.thinking = thinking
            self.launchIdempotencyKey = launchIdempotencyKey
        }
    }

    func createControlSession(_ request: CreateControlSessionRequest) async throws -> CreateSessionResponse {
        try await post("/control-sessions", body: request, as: CreateSessionResponse.self)
    }

    /// Response from session creation. Includes `prompted` when a prompt was provided.
    struct CreateSessionResponse: Decodable, Sendable {
        let session: Session
        let prompted: Bool?
    }

    struct CreateUploadResponse: Decodable, Sendable {
        let uploadId: String
        let contentUrl: String
        let expiresAt: Int
    }

    private struct UploadCreateBody: Encodable {
        let name: String
        let mimeType: String
        let sizeBytes: Int
        let purpose: String
    }

    func createSessionAttachmentUpload(
        scope: SessionRouteScope,
        sessionId: String,
        name: String,
        mimeType: String,
        sizeBytes: Int,
        purpose: String = "chat_attachment"
    ) async throws -> CreateUploadResponse {
        try await post(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/attachments",
            body: UploadCreateBody(name: name, mimeType: mimeType, sizeBytes: sizeBytes, purpose: purpose),
            as: CreateUploadResponse.self
        )
    }

    func uploadSessionAttachmentContent(
        scope: SessionRouteScope,
        sessionId: String,
        attachmentId: String,
        data body: Data,
        contentType: String = "application/octet-stream",
        progress: AttachmentUploadTransport.Progress? = nil
    ) async throws -> ChatAttachmentRef {
        try await putAttachmentContent(
            path: "\(focusedSessionPath(scope: scope, sessionId: sessionId))/attachments/\(attachmentId)/content",
            body: .data(body),
            contentType: contentType,
            progress: progress
        )
    }

    /// Streams the file from disk; `progress` reports the upload task's sent bytes.
    func uploadSessionAttachmentContent(
        scope: SessionRouteScope,
        sessionId: String,
        attachmentId: String,
        fileURL: URL,
        contentType: String = "application/octet-stream",
        progress: AttachmentUploadTransport.Progress? = nil
    ) async throws -> ChatAttachmentRef {
        try await putAttachmentContent(
            path: "\(focusedSessionPath(scope: scope, sessionId: sessionId))/attachments/\(attachmentId)/content",
            body: .file(fileURL),
            contentType: contentType,
            progress: progress
        )
    }

    /// Create a session that resumes an existing local pi TUI session.
    func createWorkspaceSessionFromLocal(
        workspaceId: String,
        piSessionFile: String,
        worktreeId: String? = nil
    ) async throws -> Session {
        struct Body: Encodable { let piSessionFile: String; let worktreeId: String? }
        struct Response: Decodable { let session: Session }
        return try await post(
            "/workspaces/\(workspaceId)/sessions",
            body: Body(piSessionFile: piSessionFile, worktreeId: worktreeId),
            as: Response.self
        ).session
    }

    /// Resume a stopped session.
    func resumeSession(scope: SessionRouteScope, sessionId: String) async throws -> Session {
        struct Response: Decodable { let session: Session }
        return try await post(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/resume",
            body: EmptyBody(),
            as: Response.self
        ).session
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
        struct Response: Decodable { let session: Session }
        return try await post(
            "/workspaces/\(workspaceId)/sessions/\(sessionId)/fork",
            body: Body(entryId: entryId, name: name),
            as: Response.self
        ).session
    }

    /// Read-only disclosure of a generated input's advertised output, not its model prompt.
    func getInputCardOutput(scope: SessionRouteScope, sessionId: String, entryId: String) async throws -> String {
        let encoded = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? entryId
        struct Response: Decodable { let output: String }
        return try await get(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/input-card-output/\(encoded)",
            as: Response.self
        ).output
    }

    /// The viewer's read of a session's internal URL (`proc://bash-3`), its
    /// output after UTF-16 offset `from` when the viewer already holds that much.
    func getInternalURLView(
        scope: SessionRouteScope,
        sessionId: String,
        url: String,
        from: Int?
    ) async throws -> InternalURLView {
        var query = [URLQueryItem(name: "url", value: url)]
        if let from { query.append(URLQueryItem(name: "from", value: String(from))) }
        return try await get(
            url: makeURL(
                pathSegments: internalURLPathSegments(scope: scope, sessionId: sessionId),
                queryItems: query
            ),
            as: InternalURLView.self
        )
    }

    /// Stops what a session's internal URL names (`InternalURLView.stoppable`).
    func stopInternalURL(scope: SessionRouteScope, sessionId: String, url: String) async throws {
        let (data, response) = try await request(
            "POST",
            url: makeURL(
                pathSegments: internalURLPathSegments(scope: scope, sessionId: sessionId) + ["stop"],
                queryItems: [URLQueryItem(name: "url", value: url)]
            ),
            body: EmptyBody()
        )
        try checkStatus(response, data: data)
    }

    private func internalURLPathSegments(scope: SessionRouteScope, sessionId: String) -> [String] {
        switch scope {
        case .workspace(let workspaceId): ["workspaces", workspaceId, "sessions", sessionId, "internal-url"]
        case .control: ["control-sessions", sessionId, "internal-url"]
        }
    }

    /// List files touched (written/edited) by a specific session.
    func listSessionChanges(workspaceId: String, sessionId: String) async throws -> SessionChangesResponse {
        try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)/changes", as: SessionChangesResponse.self)
    }

    /// Fetch a session-derived diff for a touched file.
    func getSessionDiff(
        workspaceId: String,
        sessionId: String,
        path: String
    ) async throws -> WorkspaceReviewDiffResponse {
        let encodedPath = try encodeQueryPath(path)
        return try await get(
            "/workspaces/\(workspaceId)/sessions/\(sessionId)/diff?path=\(encodedPath)",
            as: WorkspaceReviewDiffResponse.self
        )
    }
}
