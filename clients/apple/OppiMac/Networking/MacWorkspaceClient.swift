import Foundation
import OSLog

private let workspaceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacWorkspaceClient"
)

/// Local-first workspace/session snapshot client for the Mac shell.
///
/// This adapter returns shared `OppiCore` DTOs from existing server routes. It is
/// intentionally smaller than the iOS `APIClient`; live selected-session streams
/// and command routing come in later slices.
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
    }

    struct SessionTracePage: Decodable, Sendable {
        let session: Session
        let trace: [TraceEvent]
        let page: TracePageMetadata
        let metrics: TracePageMetrics?
    }

    struct CreateSessionResponse: Decodable, Sendable {
        let session: Session
        let prompted: Bool?
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

    let baseURL: URL
    private let token: String
    private let session: URLSession

    init(
        baseURL: URL,
        token: String,
        timeoutIntervalForRequest: TimeInterval = 10,
        timeoutIntervalForResource: TimeInterval = 15
    ) {
        self.baseURL = baseURL
        self.token = token

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutIntervalForRequest
        config.timeoutIntervalForResource = timeoutIntervalForResource
        session = URLSession(
            configuration: config,
            delegate: LocalServerTrustDelegate(),
            delegateQueue: nil
        )
    }

    func listWorkspaceCatalog() async throws -> WorkspaceCatalog {
        let data = try await get("/workspaces")
        return try Self.decodeWorkspaceCatalog(data)
    }

    func listModels() async throws -> [ModelInfo] {
        let data = try await get("/models")
        return try Self.decodeModels(data)
    }

    func listWorkspaceDirectory(workspaceId: String, path: String = "") async throws -> DirectoryListingResponse {
        let data = try await get(
            url: try makeURL(
                pathSegments: ["workspaces", workspaceId, "contents"],
                appendedPath: path == "/" ? "" : path,
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

    func getSessionRawFileData(workspaceId: String, sessionId: String, path: String) async throws -> Data {
        try await get(
            url: try makeURL(
                pathSegments: ["workspaces", workspaceId, "sessions", sessionId, "raw", path]
            )
        )
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

    func getWorkspaceSessions(
        workspaceId: String,
        since: Date,
        until: Date
    ) async throws -> WorkspaceSessionList {
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        let queryItems = [
            URLQueryItem(name: "status", value: "active,stopped"),
            URLQueryItem(name: "sinceMs", value: String(sinceMs)),
            URLQueryItem(name: "untilMs", value: String(untilMs)),
        ]
        let data = try await get(
            url: try makeURL(path: "/workspaces/\(workspaceId)/sessions", queryItems: queryItems)
        )
        return try Self.decodeWorkspaceSessionList(data)
    }

    func getWorkspaceSessionTracePage(
        workspaceId: String,
        sessionId: String,
        targetEvents: Int = 120,
        previewBytes: Int = 8_192
    ) async throws -> SessionTracePage {
        let queryItems = [
            URLQueryItem(name: "targetEvents", value: String(targetEvents)),
            URLQueryItem(name: "previewBytes", value: String(previewBytes)),
        ]
        let data = try await get(
            url: try makeURL(
                path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/trace-page",
                queryItems: queryItems
            )
        )
        return try JSONDecoder().decode(SessionTracePage.self, from: data)
    }

    func createWorkspaceSession(
        workspaceId: String,
        name: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        ephemeral: Bool? = nil
    ) async throws -> CreateSessionResponse {
        struct Body: Encodable {
            let name: String?
            let model: String?
            let prompt: String?
            let ephemeral: Bool?
        }
        let data = try await post(
            path: "/workspaces/\(workspaceId)/sessions",
            body: Body(name: name, model: model, prompt: prompt, ephemeral: ephemeral)
        )
        return try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    func stopWorkspaceSession(
        workspaceId: String,
        sessionId: String
    ) async throws -> StopSessionResponse {
        let data = try await post(
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/stop",
            body: EmptyBody()
        )
        return try JSONDecoder().decode(StopSessionResponse.self, from: data)
    }

    func deleteWorkspaceSession(
        workspaceId: String,
        sessionId: String
    ) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)"
        )
    }

    @discardableResult
    func sendWorkspaceSessionCommand(
        workspaceId: String,
        sessionId: String,
        message: ClientMessage
    ) async throws -> [ServerMessage] {
        let data = try await post(
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/command",
            body: message
        )
        return try Self.decodeSessionCommandResponse(data)
    }

    func createSessionAttachmentUpload(
        workspaceId: String,
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
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/attachments",
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
        let data = try await putRaw(
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/attachments/\(attachmentId)/content",
            body: body,
            contentType: contentType
        )
        return try JSONDecoder().decode(UploadContentResponse.self, from: data).attachment
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

    static func decodeSessionCommandResponse(_ data: Data) throws -> [ServerMessage] {
        struct Response: Decodable {
            let messages: [ServerMessage]
        }
        return try JSONDecoder().decode(Response.self, from: data).messages
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        workspaceLogger.debug("GET \(url.path)")

        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws -> Data {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await data(for: request, logPath: path)
    }

    private func put<Body: Encodable>(path: String, body: Body) async throws -> Data {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await data(for: request, logPath: path)
    }

    private func putRaw(path: String, body: Data, contentType: String) async throws -> Data {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await data(for: request, logPath: path)
    }

    private func request(method: String, path: String) async throws -> Data {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = method
        return try await data(for: request, logPath: path)
    }

    private func data(for request: URLRequest, logPath: String) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        workspaceLogger.debug("\(request.httpMethod ?? "GET") \(logPath)")

        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MacWorkspaceClientError.invalidURL
        }
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
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MacWorkspaceClientError.invalidURL
        }
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

    private func percentEncodePathSegment(_ segment: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw MacWorkspaceClientError.invalidURL
        }
        return encoded
    }

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MacWorkspaceClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MacWorkspaceClientError.server(status: http.statusCode, message: body)
        }
    }
}

private struct EmptyBody: Encodable, Sendable {}

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
