import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "APIClient")

/// REST client for pi-remote server.
///
/// Handles session CRUD, health checks, and authentication.
/// All methods throw on network/server errors with descriptive messages.
actor APIClient {
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

    // MARK: - Sessions

    /// List all sessions for the authenticated user.
    func listSessions() async throws -> [Session] {
        let data = try await get("/sessions")
        struct Response: Decodable { let sessions: [Session] }
        return try JSONDecoder().decode(Response.self, from: data).sessions
    }

    /// Create a new session, optionally tied to a workspace.
    func createSession(name: String? = nil, model: String? = nil, workspaceId: String? = nil) async throws -> Session {
        struct Body: Encodable { let name: String?; let model: String?; let workspaceId: String? }
        let data = try await post("/sessions", body: Body(name: name, model: model, workspaceId: workspaceId))
        struct Response: Decodable { let session: Session }
        return try JSONDecoder().decode(Response.self, from: data).session
    }

    /// Get a session with its resolved context (compaction-aware, same view as pi TUI).
    func getSession(id: String) async throws -> (session: Session, trace: [TraceEvent]) {
        let data = try await get("/sessions/\(id)")
        struct Response: Decodable { let session: Session; let trace: [TraceEvent] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.session, response.trace)
    }

    /// Stop a running session.
    func stopSession(id: String) async throws -> Session {
        let data = try await post("/sessions/\(id)/stop", body: EmptyBody())
        struct Response: Decodable { let session: Session? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let session = response.session { return session }
        return try await getSession(id: id).session
    }

    /// Delete a session permanently.
    func deleteSession(id: String) async throws {
        _ = try await request("DELETE", path: "/sessions/\(id)")
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

    /// Get full skill detail: metadata, SKILL.md content, and file tree.
    func getSkillDetail(name: String) async throws -> SkillDetail {
        let data = try await get("/skills/\(name)")
        return try JSONDecoder().decode(SkillDetail.self, from: data)
    }

    /// Get a single file's content from a skill directory.
    func getSkillFile(name: String, path: String) async throws -> String {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        let data = try await get("/skills/\(name)/file?path=\(encoded)")
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
        let data = try await post("/workspaces/\(workspaceId)/sessions/\(sessionId)/stop", body: EmptyBody())
        struct Response: Decodable { let session: Session? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let session = response.session { return session }
        return try await getSession(id: sessionId).session
    }

    /// Get session detail via workspace path.
    func getWorkspaceSession(workspaceId: String, sessionId: String) async throws -> (session: Session, trace: [TraceEvent]) {
        let data = try await get("/workspaces/\(workspaceId)/sessions/\(sessionId)")
        struct Response: Decodable { let session: Session; let trace: [TraceEvent] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.session, response.trace)
    }

    /// Delete a session via workspace path.
    func deleteWorkspaceSession(workspaceId: String, sessionId: String) async throws {
        _ = try await request("DELETE", path: "/workspaces/\(workspaceId)/sessions/\(sessionId)")
    }

    // MARK: - Tool Output & Files

    /// Fetch the full tool output for a specific tool call ID from the session's JSONL trace.
    ///
    /// Used to lazy-load evicted tool output when the user expands an old tool call row.
    func getToolOutput(sessionId: String, toolCallId: String) async throws -> (output: String, isError: Bool) {
        let data = try await get("/sessions/\(sessionId)/tool-output/\(toolCallId)")
        struct Response: Decodable { let output: String; let isError: Bool }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.output, response.isError)
    }

    /// Fetch a file from the session's working directory.
    ///
    /// Returns the raw file content as a string. Used when the user taps a file path
    /// in a tool call row to view the current file on disk.
    func getSessionFile(sessionId: String, path: String) async throws -> String {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        let data = try await get("/sessions/\(sessionId)/files?path=\(encoded)")
        // File content is returned as raw bytes — decode as UTF-8 text
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.server(status: 422, message: "File is not text (binary content)")
        }
        return text
    }

    /// Fetch raw file data from the session's working directory (for binary files like images).
    func getSessionFileData(sessionId: String, path: String) async throws -> Data {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        return try await get("/sessions/\(sessionId)/files?path=\(encoded)")
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
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
    }

    private func request<T: Encodable>(_ method: String, path: String, body: T) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        logger.debug("\(method) \(path)")
        return try await session.data(for: req)
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
    var defaultModel: String?
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
