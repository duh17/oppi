import Foundation
import os

struct ShareQuickSessionWorkspace: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let server: PairedServer
}

struct ShareQuickSessionDraftAttachment: Equatable, Sendable {
    let name: String
    let mimeType: String
    let fileURL: URL
}

struct ShareQuickSessionSendResult: Equatable, Sendable {
    let sessionID: String
    let workspaceID: String
    let serverID: String
}

protocol ShareQuickSessionHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

extension URLSession: ShareQuickSessionHTTPTransport {}

enum ShareQuickSessionCredentialStore {
    /// The paired servers named by the app's shared id index, one Keychain
    /// query per id. The app owns the index; sharing never writes it.
    ///
    /// Throws `PairedServerKeychain.ReadFailed` when the device is locked or no
    /// record can be read, which is not "no paired servers". One unreadable
    /// record only drops that server, and so does one without an HTTPS endpoint.
    static func loadServers() throws -> [PairedServer] {
        let ids = SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey) ?? []
        return try PairedServerKeychain.records(PairedServer.self, ids: ids)
            .filter { endpoint(of: $0) != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The server's base URL when it is HTTPS. Sharing never sends over plain HTTP.
    static func endpoint(of server: PairedServer) -> URL? {
        guard let url = server.baseURL, ServerTLSTrustPolicy.requiresHTTPS(scheme: url.scheme) else {
            return nil
        }
        return url
    }

    /// Persist a refreshed device credential back to the shared keychain so a
    /// later share or relaunch starts from the replacement token, not the
    /// expired one. Merges the HTTP-scoped field against the LATEST stored
    /// record so a concurrent process cannot roll back or drop record fields.
    static func save(server: PairedServer, deviceCredential: DeviceCredential) {
        do {
            _ = try KeychainDeviceCredentialMerger.mergeRefresh(
                serverId: server.id,
                expectedDeviceId: deviceCredential.deviceId,
                accessToken: deviceCredential.accessToken,
                expiresAt: deviceCredential.expiresAt,
                refreshChallenge: deviceCredential.refreshChallenge
            )
        } catch {
            // Recoverable: the in-memory session still holds the fresh token;
            // the next share re-refreshes from the stale persisted credential.
            os.Logger(subsystem: "dev.chenda.Oppi.share", category: "CredentialStore")
                .error("Failed to persist refreshed device credential: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Device-auth challenge/refresh transport for the share extension. Credentials
/// are sent only in request bodies, never in URLs.
private struct ShareQuickSessionDeviceAuthTransport: DeviceAuthTransport {
    let baseURL: URL
    let transport: any ShareQuickSessionHTTPTransport

    func requestChallenge(deviceId: String) async throws -> DeviceAuthChallenge {
        struct Body: Encodable { let deviceId: String }
        let (data, response) = try await post(path: "auth/challenge", body: Body(deviceId: deviceId))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeviceAuthError.challengeUnavailable
        }
        guard let challenge = try? JSONDecoder().decode(DeviceAuthChallenge.self, from: data) else {
            throw DeviceAuthError.malformedResponse
        }
        return challenge
    }

    func refresh(
        deviceId: String,
        nonce: String,
        signature: String
    ) async throws -> DeviceAuthRefreshResult {
        struct Body: Encodable {
            let deviceId: String
            let nonce: String
            let signature: String
        }
        struct RefreshResponse: Decodable {
            let accessToken: String
            let expiresAt: Int
            let refreshChallenge: DeviceAuthChallenge?
        }
        struct ErrorResponse: Decodable { let error: String? }
        let (data, response) = try await post(
            path: "auth/refresh",
            body: Body(deviceId: deviceId, nonce: nonce, signature: signature)
        )
        guard let http = response as? HTTPURLResponse else {
            throw DeviceAuthError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "refresh_failed"
            throw DeviceAuthError.refreshRejected(code: code)
        }
        guard let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw DeviceAuthError.malformedResponse
        }
        return DeviceAuthRefreshResult(
            accessToken: decoded.accessToken,
            expiresAt: decoded.expiresAt,
            refreshChallenge: decoded.refreshChallenge
        )
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws -> (Data, URLResponse) {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.append(path: String(component))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await transport.data(for: request)
    }
}

actor ShareQuickSessionSender {
    private let transport: any ShareQuickSessionHTTPTransport
    private let deviceKeyProvider: () throws -> any DeviceKey
    private let persistCredential: @Sendable (PairedServer, DeviceCredential) -> Void
    /// One device-auth session per server, retained for the whole operation
    /// (including every attachment), so the refresh nonce/token are never
    /// recreated from a stale persisted snapshot.
    private var sessions: [String: DeviceAuthSession] = [:]

    init(
        transport: any ShareQuickSessionHTTPTransport,
        deviceKeyProvider: @escaping () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        persistCredential: @escaping @Sendable (PairedServer, DeviceCredential) -> Void = { _, _ in }
    ) {
        self.transport = transport
        self.deviceKeyProvider = deviceKeyProvider
        self.persistCredential = persistCredential
    }

    static func live(server: PairedServer) -> ShareQuickSessionSender {
        let configuration = URLSessionConfiguration.ephemeral
        // Idle-only: a shared screen recording can take minutes to send, and a
        // total-duration limit cut every upload over 30 seconds short.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = false
        let delegate = PinnedServerTrustDelegate(pinnedLeafFingerprint: server.tlsCertFingerprint)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return ShareQuickSessionSender(
            transport: session,
            persistCredential: { server, credential in
                ShareQuickSessionCredentialStore.save(server: server, deviceCredential: credential)
            }
        )
    }

    /// Build (once) and return the device-key auth session for a server, or nil
    /// for legacy/static-token servers. The device key load fails closed: it is
    /// never silently replaced by an empty static bearer.
    private func deviceSession(for server: PairedServer) throws -> DeviceAuthSession? {
        guard let credential = server.deviceCredential else { return nil }
        if let existing = sessions[server.id] { return existing }
        let key = try deviceKeyProvider()
        let session = DeviceAuthSession(
            credential: credential,
            key: key,
            transport: ShareQuickSessionDeviceAuthTransport(
                baseURL: try Self.baseURL(of: server),
                transport: transport
            ),
            onRefresh: { [persistCredential, server, credential] result in
                let updated = credential.updatingAccessToken(
                    result.accessToken,
                    expiresAt: Int64(result.expiresAt),
                    refreshChallenge: result.refreshChallenge
                )
                persistCredential(server, updated)
            }
        )
        sessions[server.id] = session
        return session
    }

    /// Resolve the bearer token for a server: the device-key access token when
    /// a device credential exists, otherwise the legacy/static token.
    private func resolveBearer(
        server: PairedServer,
        forceRefresh: Bool = false
    ) async throws -> String {
        guard let session = try deviceSession(for: server) else { return server.token }
        if forceRefresh {
            return try await session.refreshAccessToken()
        }
        let cached = await session.accessToken
        if cached.isEmpty, !server.token.isEmpty {
            return server.token
        }
        do {
            return DeviceAuthSession.resolvedToken(
                try await session.currentAccessToken(),
                fallback: server.token
            )
        } catch {
            if case DeviceAuthError.refreshRejected = error {
                throw error
            }
            if !server.token.isEmpty { return server.token }
            throw error
        }
    }

    func fetchWorkspaces(server: PairedServer) async throws -> [ShareQuickSessionWorkspace] {
        struct Response: Decodable {
            struct Workspace: Decodable {
                let id: String
                let name: String
            }
            let workspaces: [Workspace]
        }

        let data = try await request(server: server, method: "GET", path: ["workspaces"])
        return try JSONDecoder().decode(Response.self, from: data).workspaces.map {
            ShareQuickSessionWorkspace(id: $0.id, name: $0.name, server: server)
        }
    }

    /// The server's model catalog (`GET /models`): a share starts a session on the server's
    /// default model, whose provider this device must have allowed (`AISharingConsent`).
    func fetchModelCatalog(server: PairedServer) async throws -> [AISharingConsent.CatalogModel] {
        struct Response: Decodable { let models: [AISharingConsent.CatalogModel] }
        let data = try await request(server: server, method: "GET", path: ["models"])
        return try JSONDecoder().decode(Response.self, from: data).models
    }

    func send(
        payloadID: String,
        text: String,
        attachments: [ShareQuickSessionDraftAttachment],
        workspace: ShareQuickSessionWorkspace
    ) async throws -> ShareQuickSessionSendResult {
        let server = workspace.server
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty else {
            throw ShareQuickSessionSendError.emptyDraft
        }

        struct CreateBody: Encodable {
            let prompt: String?
            let launchIdempotencyKey: String
        }
        struct CreateResponse: Decodable {
            struct Session: Decodable { let id: String }
            let session: Session
        }

        let createBody = CreateBody(
            prompt: attachments.isEmpty ? trimmedText : nil,
            launchIdempotencyKey: payloadID
        )
        let createData = try await request(
            server: server,
            method: "POST",
            path: ["workspaces", workspace.id, "sessions"],
            jsonBody: createBody
        )
        let sessionID = try JSONDecoder().decode(CreateResponse.self, from: createData).session.id

        if !attachments.isEmpty {
            var uploaded: [UploadAttachment] = []
            for attachment in attachments {
                uploaded.append(try await upload(
                    attachment,
                    workspaceID: workspace.id,
                    sessionID: sessionID,
                    server: server
                ))
            }

            struct PromptBody: Encodable {
                let type = "prompt"
                let message: String
                let attachments: [UploadAttachment]
                let requestId: String
                let clientTurnId: String
            }
            _ = try await request(
                server: server,
                method: "POST",
                path: ["workspaces", workspace.id, "sessions", sessionID, "command"],
                jsonBody: PromptBody(
                    message: trimmedText,
                    attachments: uploaded,
                    requestId: payloadID,
                    clientTurnId: payloadID
                )
            )
        }

        return ShareQuickSessionSendResult(
            sessionID: sessionID,
            workspaceID: workspace.id,
            serverID: server.id
        )
    }

    private struct UploadAttachment: Codable, Sendable {
        let type: String
        let id: String
        let source: String
        let name: String
        let mimeType: String
        let sizeBytes: Int
        let sha256: String?
        let kind: String?
        let workspacePath: String?
    }

    private func upload(
        _ attachment: ShareQuickSessionDraftAttachment,
        workspaceID: String,
        sessionID: String,
        server: PairedServer
    ) async throws -> UploadAttachment {
        let values = try attachment.fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let sizeBytes = values.fileSize, sizeBytes >= 0 else {
            throw ShareQuickSessionSendError.invalidAttachment(attachment.name)
        }

        struct CreateUploadBody: Encodable {
            let name: String
            let mimeType: String
            let sizeBytes: Int
            let purpose = "chat_attachment"
        }
        struct CreateUploadResponse: Decodable {
            let uploadId: String
        }
        struct UploadResponse: Decodable { let attachment: UploadAttachment }

        // The server refuses a size it can't take (an owner's cap, or too little free
        // disk) with a message that says which.
        let createData = try await request(
            server: server,
            method: "POST",
            path: ["workspaces", workspaceID, "sessions", sessionID, "attachments"],
            jsonBody: CreateUploadBody(
                name: attachment.name,
                mimeType: attachment.mimeType,
                sizeBytes: sizeBytes
            )
        )
        let createResponse = try JSONDecoder().decode(CreateUploadResponse.self, from: createData)
        let uploadData = try await uploadFile(
            server: server,
            method: "PUT",
            path: [
                "workspaces", workspaceID, "sessions", sessionID,
                "attachments", createResponse.uploadId, "content",
            ],
            fileURL: attachment.fileURL,
            contentType: attachment.mimeType
        )
        return try JSONDecoder().decode(UploadResponse.self, from: uploadData).attachment
    }

    private func request<Body: Encodable>(
        server: PairedServer,
        method: String,
        path: [String],
        jsonBody: Body
    ) async throws -> Data {
        try await request(
            server: server,
            method: method,
            path: path,
            dataBody: try JSONEncoder().encode(jsonBody),
            contentType: "application/json"
        )
    }

    private func request(
        server: PairedServer,
        method: String,
        path: [String],
        dataBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        var url = try Self.baseURL(of: server)
        for component in path {
            url.append(path: component)
        }
        var bearer = try await resolveBearer(server: server)
        var result = try await performRequest(
            url: url,
            method: method,
            dataBody: dataBody,
            contentType: contentType,
            bearer: bearer
        )
        if server.deviceCredential != nil, (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            bearer = try await resolveBearer(server: server, forceRefresh: true)
            result = try await performRequest(
                url: url,
                method: method,
                dataBody: dataBody,
                contentType: contentType,
                bearer: bearer
            )
        }
        return try validatedData(result)
    }

    private static func baseURL(of server: PairedServer) throws -> URL {
        guard let url = ShareQuickSessionCredentialStore.endpoint(of: server) else {
            throw ShareQuickSessionSendError.insecureServer
        }
        return url
    }

    private func performRequest(
        url: URL,
        method: String,
        dataBody: Data?,
        contentType: String?,
        bearer: String
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = dataBody
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return try await transport.data(for: request)
    }

    private func uploadFile(
        server: PairedServer,
        method: String,
        path: [String],
        fileURL: URL,
        contentType: String
    ) async throws -> Data {
        var url = try Self.baseURL(of: server)
        for component in path {
            url.append(path: component)
        }
        var bearer = try await resolveBearer(server: server)
        var result = try await performUpload(
            url: url,
            method: method,
            fileURL: fileURL,
            contentType: contentType,
            bearer: bearer
        )
        if server.deviceCredential != nil, (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            bearer = try await resolveBearer(server: server, forceRefresh: true)
            result = try await performUpload(
                url: url,
                method: method,
                fileURL: fileURL,
                contentType: contentType,
                bearer: bearer
            )
        }
        return try validatedData(result)
    }

    private func performUpload(
        url: URL,
        method: String,
        fileURL: URL,
        contentType: String,
        bearer: String
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return try await transport.upload(for: request, fromFile: fileURL)
    }

    private func validatedData(_ result: (Data, URLResponse)) throws -> Data {
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw ShareQuickSessionSendError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorResponse: Decodable { let error: String? }
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ShareQuickSessionSendError.server(status: http.statusCode, message: message)
        }
        return data
    }
}

enum ShareQuickSessionSendError: LocalizedError {
    case emptyDraft
    case invalidAttachment(String)
    case invalidResponse
    case insecureServer
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyDraft:
            return "Add text or an attachment before sending."
        case .invalidAttachment(let name):
            return "\(name) is not a readable file."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .insecureServer:
            return "This server isn’t paired over HTTPS."
        case .server(_, let message):
            return message
        }
    }
}
