import Foundation
import Security
import Testing
@testable import Oppi

@Suite("Share Quick Session sender", .serialized)
struct ShareQuickSessionSenderTests {
    @Test func repairsMissingDefaultsIndexFromSharedKeychain() throws {
        let serverID = "share-discovery-\(UUID().uuidString)"
        let server = try #require(ShareQuickSessionServer(
            id: serverID,
            name: "Discovered Mac",
            baseURL: URL(string: "https://mac.example:7749"),
            token: "device-token",
            tlsCertFingerprint: nil,
            sortOrder: 7
        ))
        let account = "\(SharedConstants.serverAccountPrefix)\(serverID)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = try JSONEncoder().encode(server)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let originalIDs = SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.pairedServerIdsKey)
        defer {
            SecItemDelete(query as CFDictionary)
            if let originalIDs {
                SharedConstants.sharedDefaults.set(originalIDs, forKey: SharedConstants.pairedServerIdsKey)
            } else {
                SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.pairedServerIdsKey)
            }
        }
        #expect(SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess)

        let loaded = ShareQuickSessionCredentialStore.loadServers()

        #expect(loaded.contains(server))
        #expect(
            SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey)?
                .contains(serverID) == true
        )
    }

    @Test func fetchesWorkspacesWithPairedServerCredentials() async throws {
        let transport = ShareSenderStubTransport(responses: [
            .json(200, #"{"workspaces":[{"id":"ws-1","name":"Oppi"}]}"#),
        ])
        let sender = ShareQuickSessionSender(transport: transport)
        let server = try #require(ShareQuickSessionServer(
            id: "server-1",
            name: "Mac",
            baseURL: URL(string: "https://mac.example:7749"),
            token: "device-token",
            tlsCertFingerprint: nil,
            sortOrder: 0
        ))

        let workspaces = try await sender.fetchWorkspaces(server: server)

        #expect(workspaces == [ShareQuickSessionWorkspace(id: "ws-1", name: "Oppi", server: server)])
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/workspaces")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
    }

    @Test func sendsTextInIdempotentSessionCreationRequest() async throws {
        let transport = ShareSenderStubTransport(responses: [
            .json(201, #"{"session":{"id":"session-1"},"prompted":true}"#),
        ])
        let sender = ShareQuickSessionSender(transport: transport)
        let server = try #require(ShareQuickSessionServer(
            id: "server-1",
            name: "Mac",
            baseURL: URL(string: "https://mac.example:7749"),
            token: "device-token",
            tlsCertFingerprint: nil,
            sortOrder: 0
        ))
        let workspace = ShareQuickSessionWorkspace(id: "ws-1", name: "Oppi", server: server)

        let result = try await sender.send(
            payloadID: "share-123",
            text: "Review this URL",
            attachments: [],
            workspace: workspace
        )

        #expect(result == ShareQuickSessionSendResult(sessionID: "session-1", workspaceID: "ws-1", serverID: "server-1"))
        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["prompt"] as? String == "Review this URL")
        #expect(json["launchIdempotencyKey"] as? String == "share-123")
    }

    @Test func uploadsAttachmentsBeforeDispatchingPrompt() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("shared file".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transport = ShareSenderStubTransport(responses: [
            .json(201, #"{"session":{"id":"session-2"}}"#),
            .json(201, #"{"uploadId":"upload-1","contentUrl":"/content","maxFileBytes":1000,"expiresAt":0}"#),
            .json(200, #"{"attachment":{"type":"file","id":"upload-1","source":"upload","name":"notes.txt","mimeType":"text/plain","sizeBytes":11,"sha256":null,"kind":"text","workspacePath":null}}"#),
            .json(200, #"{"messages":[]}"#),
        ])
        let sender = ShareQuickSessionSender(transport: transport)
        let server = try #require(ShareQuickSessionServer(
            id: "server-1",
            name: "Mac",
            baseURL: URL(string: "https://mac.example:7749"),
            token: "device-token",
            tlsCertFingerprint: nil,
            sortOrder: 0
        ))
        let workspace = ShareQuickSessionWorkspace(id: "ws-1", name: "Oppi", server: server)
        let attachment = ShareQuickSessionDraftAttachment(
            name: "notes.txt",
            mimeType: "text/plain",
            fileURL: fileURL
        )

        _ = try await sender.send(
            payloadID: "share-with-file",
            text: "Summarize",
            attachments: [attachment],
            workspace: workspace
        )

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "PUT", "POST"])
        #expect(requests[1].url?.path == "/workspaces/ws-1/sessions/session-2/attachments")
        #expect(requests[2].httpBody == nil)
        #expect(await transport.uploadedFileURLs == [fileURL])
        let commandBody = try #require(requests[3].httpBody)
        let command = try #require(JSONSerialization.jsonObject(with: commandBody) as? [String: Any])
        #expect(command["type"] as? String == "prompt")
        #expect(command["message"] as? String == "Summarize")
        #expect(command["clientTurnId"] as? String == "share-with-file")
        #expect((command["attachments"] as? [[String: Any]])?.first?["id"] as? String == "upload-1")
    }

    @Test func mapsServerSizeRejectionWithoutUploadingBytes() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("too large".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = ShareSenderStubTransport(responses: [
            .json(201, #"{"session":{"id":"session-3"}}"#),
            .json(413, #"{"error":"Upload exceeds max file size"}"#),
        ])
        let sender = ShareQuickSessionSender(transport: transport)
        let server = try #require(ShareQuickSessionServer(
            id: "server-1",
            name: "Mac",
            baseURL: URL(string: "https://mac.example:7749"),
            token: "device-token",
            tlsCertFingerprint: nil,
            sortOrder: 0
        ))
        let workspace = ShareQuickSessionWorkspace(id: "ws-1", name: "Oppi", server: server)

        do {
            _ = try await sender.send(
                payloadID: "share-server-rejected",
                text: "Review",
                attachments: [ShareQuickSessionDraftAttachment(
                    name: "large.txt",
                    mimeType: "text/plain",
                    fileURL: fileURL
                )],
                workspace: workspace
            )
            Issue.record("Expected server size rejection")
        } catch ShareQuickSessionSendError.attachmentTooLarge(let name, let maxFileBytes) {
            #expect(name == "large.txt")
            #expect(maxFileBytes == nil)
        }
        #expect(await transport.uploadedFileURLs.isEmpty)
        #expect(await transport.requests.map(\.httpMethod) == ["POST", "POST"])
    }

    @Test func rejectsOversizedAttachmentBeforeUploadingBytes() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("too large".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transport = ShareSenderStubTransport(responses: [
            .json(201, #"{"session":{"id":"session-3"}}"#),
            .json(201, #"{"uploadId":"upload-2","contentUrl":"/content","maxFileBytes":4,"expiresAt":0}"#),
        ])
        let sender = ShareQuickSessionSender(transport: transport)
        let server = try #require(ShareQuickSessionServer(
            id: "server-1",
            name: "Mac",
            baseURL: URL(string: "https://mac.example:7749"),
            token: "device-token",
            tlsCertFingerprint: nil,
            sortOrder: 0
        ))
        let workspace = ShareQuickSessionWorkspace(id: "ws-1", name: "Oppi", server: server)

        do {
            _ = try await sender.send(
                payloadID: "share-too-large",
                text: "Review",
                attachments: [ShareQuickSessionDraftAttachment(
                    name: "large.txt",
                    mimeType: "text/plain",
                    fileURL: fileURL
                )],
                workspace: workspace
            )
            Issue.record("Expected oversized attachment to fail")
        } catch ShareQuickSessionSendError.attachmentTooLarge(let name, let maxFileBytes) {
            #expect(name == "large.txt")
            #expect(maxFileBytes == 4)
        }

        #expect(await transport.uploadedFileURLs.isEmpty)
        #expect(await transport.requests.map(\.httpMethod) == ["POST", "POST"])
    }
}

private actor ShareSenderStubTransport: ShareQuickSessionHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let data: Data

        static func json(_ status: Int, _ value: String) -> Self {
            Self(status: status, data: Data(value.utf8))
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []
    private(set) var uploadedFileURLs: [URL] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return nextResponse(for: request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        requests.append(request)
        uploadedFileURLs.append(fileURL)
        return nextResponse(for: request)
    }

    private func nextResponse(for request: URLRequest) -> (Data, URLResponse) {
        let response = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.example")!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response.data, http)
    }
}
