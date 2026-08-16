import CryptoKit
import Foundation
import os
import Security

struct ShareQuickSessionServer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let baseURL: URL
    let token: String
    let deviceCredential: DeviceCredential?
    let tlsCertFingerprint: String?
    let sortOrder: Int

    init?(
        id: String,
        name: String,
        baseURL: URL?,
        token: String,
        deviceCredential: DeviceCredential? = nil,
        tlsCertFingerprint: String?,
        sortOrder: Int
    ) {
        guard let baseURL else { return nil }
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
        self.deviceCredential = deviceCredential
        self.tlsCertFingerprint = tlsCertFingerprint
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, scheme, token, deviceCredential, tlsCertFingerprint, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        token = try container.decode(String.self, forKey: .token)
        deviceCredential = try container.decodeIfPresent(DeviceCredential.self, forKey: .deviceCredential)
        tlsCertFingerprint = try container.decodeIfPresent(String.self, forKey: .tlsCertFingerprint)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0

        let host = try container.decode(String.self, forKey: .host)
        let port = try container.decode(Int.self, forKey: .port)
        let scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? "https"
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "Paired server has an invalid endpoint"
            )
        }
        baseURL = url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(deviceCredential, forKey: .deviceCredential)
        try container.encodeIfPresent(tlsCertFingerprint, forKey: .tlsCertFingerprint)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(baseURL.host, forKey: .host)
        try container.encode(baseURL.port, forKey: .port)
        try container.encode(baseURL.scheme, forKey: .scheme)
    }

    /// Replace the device credential, clearing the static token so it is never
    /// used after the short-lived access token has been issued.
    func withDeviceCredential(_ credential: DeviceCredential) -> ShareQuickSessionServer {
        guard let updated = ShareQuickSessionServer(
            id: id,
            name: name,
            baseURL: baseURL,
            token: "",
            deviceCredential: credential,
            tlsCertFingerprint: tlsCertFingerprint,
            sortOrder: sortOrder
        ) else {
            // The failable init only fails on a nil baseURL; this instance's
            // baseURL is a stored non-optional URL.
            return self
        }
        return updated
    }
}

struct ShareQuickSessionWorkspace: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let server: ShareQuickSessionServer
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
    static func loadServers() -> [ShareQuickSessionServer] {
        let defaults = SharedConstants.sharedDefaults
        let ids = defaults.stringArray(forKey: SharedConstants.pairedServerIdsKey) ?? []
        var serversByID: [String: ShareQuickSessionServer] = [:]
        for id in ids {
            if let server = loadServer(id: id) {
                serversByID[server.id] = server
            }
        }

        // The defaults index can be missing or stale after an upgrade. Discover
        // only within the shared access group; app-only legacy credentials are
        // migrated by KeychainService when the main app loads them.
        for server in discoverSharedServers() {
            serversByID[server.id] = server
        }
        let sortedServers = serversByID.values.sorted { $0.sortOrder < $1.sortOrder }
        let repairedIDs = sortedServers.map(\.id)
        if repairedIDs != ids {
            defaults.set(repairedIDs, forKey: SharedConstants.pairedServerIdsKey)
        }
        return sortedServers
    }

    private static func loadServer(id: String) -> ShareQuickSessionServer? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: "\(SharedConstants.serverAccountPrefix)\(id)",
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ShareQuickSessionServer.self, from: data)
    }

    private static func discoverSharedServers() -> [ShareQuickSessionServer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(SharedConstants.serverAccountPrefix),
                  let data = item[kSecValueData as String] as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(ShareQuickSessionServer.self, from: data)
        }
    }

    /// Persist a refreshed device credential back to the shared keychain so a
    /// later share or relaunch starts from the replacement token, not the
    /// expired one. Merges the HTTP-scoped field against the LATEST stored
    /// record so a concurrent process cannot roll back or drop record fields.
    static func save(server: ShareQuickSessionServer, deviceCredential: DeviceCredential) {
        do {
            try KeychainDeviceCredentialMerger.mergeRefresh(
                serverId: server.id,
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
    private let persistCredential: @Sendable (ShareQuickSessionServer, DeviceCredential) -> Void
    /// One device-auth session per server, retained for the whole operation
    /// (including every attachment), so the refresh nonce/token are never
    /// recreated from a stale persisted snapshot.
    private var sessions: [String: DeviceAuthSession] = [:]

    init(
        transport: any ShareQuickSessionHTTPTransport,
        deviceKeyProvider: @escaping () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        persistCredential: @escaping @Sendable (ShareQuickSessionServer, DeviceCredential) -> Void = { _, _ in }
    ) {
        self.transport = transport
        self.deviceKeyProvider = deviceKeyProvider
        self.persistCredential = persistCredential
    }

    static func live(server: ShareQuickSessionServer) -> ShareQuickSessionSender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        let delegate = ShareQuickSessionTrustDelegate(
            pinnedLeafFingerprint: server.tlsCertFingerprint
        )
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
    private func deviceSession(for server: ShareQuickSessionServer) throws -> DeviceAuthSession? {
        guard let credential = server.deviceCredential else { return nil }
        if let existing = sessions[server.id] { return existing }
        let key = try deviceKeyProvider()
        let session = DeviceAuthSession(
            credential: credential,
            key: key,
            transport: ShareQuickSessionDeviceAuthTransport(
                baseURL: server.baseURL,
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
        server: ShareQuickSessionServer,
        forceRefresh: Bool = false
    ) async throws -> String {
        guard let session = try deviceSession(for: server) else { return server.token }
        return forceRefresh
            ? try await session.refreshAccessToken()
            : try await session.currentAccessToken()
    }

    func fetchWorkspaces(server: ShareQuickSessionServer) async throws -> [ShareQuickSessionWorkspace] {
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
        server: ShareQuickSessionServer
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
            let maxFileBytes: Int
        }
        struct UploadResponse: Decodable { let attachment: UploadAttachment }

        let createData: Data
        do {
            createData = try await request(
                server: server,
                method: "POST",
                path: ["workspaces", workspaceID, "sessions", sessionID, "attachments"],
                jsonBody: CreateUploadBody(
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    sizeBytes: sizeBytes
                )
            )
        } catch ShareQuickSessionSendError.server(let status, _) where status == 413 {
            throw ShareQuickSessionSendError.attachmentTooLarge(
                name: attachment.name,
                maxFileBytes: nil
            )
        }
        let createResponse = try JSONDecoder().decode(CreateUploadResponse.self, from: createData)
        guard sizeBytes <= createResponse.maxFileBytes else {
            throw ShareQuickSessionSendError.attachmentTooLarge(
                name: attachment.name,
                maxFileBytes: createResponse.maxFileBytes
            )
        }
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
        server: ShareQuickSessionServer,
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
        server: ShareQuickSessionServer,
        method: String,
        path: [String],
        dataBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        var url = server.baseURL
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
        server: ShareQuickSessionServer,
        method: String,
        path: [String],
        fileURL: URL,
        contentType: String
    ) async throws -> Data {
        var url = server.baseURL
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
    case attachmentTooLarge(name: String, maxFileBytes: Int?)
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyDraft:
            return "Add text or an attachment before sending."
        case .invalidAttachment(let name):
            return "\(name) is not a readable file."
        case .attachmentTooLarge(let name, let maxFileBytes):
            if let maxFileBytes {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(maxFileBytes), countStyle: .file)
                return "\(name) is larger than the server’s \(limit) upload limit."
            }
            return "\(name) exceeds the server’s upload limit."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .server(_, let message):
            return message
        }
    }
}

private final class ShareQuickSessionTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinnedLeafFingerprint: String?

    init(pinnedLeafFingerprint: String?) {
        self.pinnedLeafFingerprint = pinnedLeafFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let pinnedLeafFingerprint, !pinnedLeafFingerprint.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let digest = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        let encodedDigest = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fingerprint = "sha256:\(encodedDigest)"
        let host = challenge.protectionSpace.host.lowercased()
        if fingerprint == pinnedLeafFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if host.hasSuffix(".ts.net") || host.hasSuffix(".beta.tailscale.net") {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
