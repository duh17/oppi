import Foundation
import Testing
@testable import Oppi

@Suite("Pending attachment uploader", .serialized)
struct PendingAttachmentUploaderTests {
    @Test func alreadyUploadedAttachmentPassesThroughWithoutNetworkUpload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        let client = APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "test-token",
            configuration: configuration
        )
        defer { TestURLProtocol.handler = nil }
        var requestCount = 0
        TestURLProtocol.handler = { _ in
            requestCount += 1
            return try Self.response(status: 500, json: "{}")
        }
        let reference = ChatAttachmentRef(
            type: "attachment",
            id: "att-existing",
            source: .upload,
            name: "notes.txt",
            mimeType: "text/plain",
            sizeBytes: 5,
            sha256: nil,
            kind: .text,
            workspacePath: ".pi/attachments/session/notes.txt"
        )

        let uploaded = try await PendingAttachmentUploader.upload(
            [.uploaded(reference)],
            api: client,
            scope: .workspace("ws-1"),
            sessionId: "session-1"
        )

        #expect(uploaded == [reference])
        #expect(requestCount == 0)
    }

    @Test func uploadsLocalFileIntoExistingAgentSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        let client = APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "test-token",
            configuration: configuration
        )
        defer { TestURLProtocol.handler = nil }

        var requestCount = 0
        TestURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/workspaces/ws-1/sessions/session-1/attachments")
                return try Self.response(
                    status: 201,
                    json: """
                    {"uploadId":"upload-1","contentUrl":"/content","maxFileBytes":1024,"expiresAt":999999}
                    """
                )
            }

            #expect(request.httpMethod == "PUT")
            #expect(
                request.url?.path
                    == "/workspaces/ws-1/sessions/session-1/attachments/upload-1/content"
            )
            return try Self.response(
                json: """
                {"attachment":{"type":"attachment","id":"upload-1","source":"upload","name":"notes.txt","mimeType":"text/plain","sizeBytes":5,"kind":"text"}}
                """
            )
        }

        let uploaded = try await PendingAttachmentUploader.upload(
            [.localFile(name: "notes.txt", data: Data("hello".utf8), mimeType: "text/plain")],
            api: client,
            scope: .workspace("ws-1"),
            sessionId: "session-1"
        )

        #expect(uploaded.map(\.id) == ["upload-1"])
        #expect(requestCount == 2)
    }

    @Test func uploadsFileBackedVideoWithoutLoadingClipData() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        let client = APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "test-token",
            configuration: configuration
        )
        defer { TestURLProtocol.handler = nil }

        let videoURL = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        let videoBytes = Data(repeating: 0x44, count: 128)
        try videoBytes.write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let attachment = PendingAttachment.localFile(
            name: "clip.mp4",
            fileURL: videoURL,
            mimeType: "video/mp4",
            sizeBytes: videoBytes.count
        )
        #expect(attachment.localFileData == nil)

        var requestCount = 0
        TestURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/workspaces/ws-1/sessions/session-1/attachments")
                return try Self.response(
                    status: 201,
                    json: """
                    {"uploadId":"upload-video","contentUrl":"/content","maxFileBytes":1024,"expiresAt":999999}
                    """
                )
            }

            #expect(request.httpMethod == "PUT")
            #expect(
                request.url?.path
                    == "/workspaces/ws-1/sessions/session-1/attachments/upload-video/content"
            )
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
            return try Self.response(
                json: """
                {"attachment":{"type":"attachment","id":"upload-video","source":"upload","name":"clip.mp4","mimeType":"video/mp4","sizeBytes":128,"kind":"video"}}
                """
            )
        }

        let uploaded = try await PendingAttachmentUploader.upload(
            [attachment],
            api: client,
            scope: .workspace("ws-1"),
            sessionId: "session-1"
        )

        #expect(uploaded.map(\.id) == ["upload-video"])
        #expect(requestCount == 2)
        #expect(attachment.localFileData == nil)
    }

    @Test @MainActor func retriesDroppedConnectionAsFreshUploadFromTheFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        let client = APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "test-token",
            configuration: configuration
        )
        defer { TestURLProtocol.handler = nil }
        let videoURL = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        try Data(repeating: 0x44, count: 256).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        var created = 0
        var puts: [String] = []
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST" {
                created += 1
                return try Self.response(
                    status: 201,
                    json: #"{"uploadId":"upload-\#(created)","contentUrl":"/content","expiresAt":999999}"#
                )
            }
            puts.append(path)
            if path.contains("/upload-1/") {
                throw URLError(.networkConnectionLost)
            }
            return try Self.response(
                json: """
                {"attachment":{"type":"attachment","id":"upload-2","source":"upload","name":"clip.mp4","mimeType":"video/mp4","sizeBytes":256,"kind":"video"}}
                """
            )
        }

        var phases: [AttachmentUploadProgress.Phase] = []
        let uploaded = try await PendingAttachmentUploader.upload(
            [.localFile(name: "clip.mp4", fileURL: videoURL, mimeType: "video/mp4")],
            api: client,
            scope: .workspace("ws-1"),
            sessionId: "session-1",
            onProgress: { phases.append($0.phase) }
        )

        #expect(uploaded.map(\.id) == ["upload-2"])
        // The cut upload is not resumed: the retry is a new upload of the whole file.
        #expect(created == 2)
        #expect(puts == [
            "/workspaces/ws-1/sessions/session-1/attachments/upload-1/content",
            "/workspaces/ws-1/sessions/session-1/attachments/upload-2/content",
        ])
        #expect(phases.contains(.retrying(
            attempt: 2,
            maxAttempts: PendingAttachmentUploader.maxAttempts,
            reason: "the connection dropped"
        )))
        #expect(phases.last == .uploaded)
    }

    @Test @MainActor func failsWithTheServersReasonWithoutRetryingARefusal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        let client = APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "test-token",
            configuration: configuration
        )
        defer { TestURLProtocol.handler = nil }
        let message = "Not enough free disk space on the server for this 1.2 GB upload: 3.0 GB free, "
            + "and uploads always leave 2.0 GB free."
        var requestCount = 0
        TestURLProtocol.handler = { _ in
            requestCount += 1
            return try Self.response(status: 507, json: #"{"error":"\#(message)"}"#)
        }

        var last: AttachmentUploadProgress?
        do {
            _ = try await PendingAttachmentUploader.upload(
                [.localFile(name: "notes.txt", data: Data("hello".utf8), mimeType: "text/plain")],
                api: client,
                scope: .workspace("ws-1"),
                sessionId: "session-1",
                onProgress: { last = $0 }
            )
            Issue.record("Expected the upload to fail")
        } catch let error as AttachmentUploadError {
            #expect(error.name == "notes.txt")
            #expect(error.reason == message)
            #expect(error.attempts == 1)
            #expect(error.localizedDescription == "Couldn't upload notes.txt: \(message)")
        }
        #expect(requestCount == 1)
        #expect(last?.phase == .failed(message))
    }

    private static func response(
        status: Int = 200,
        json: String
    ) throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://localhost:7749")!
        return (
            Data(json.utf8),
            (try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )))
        )
    }
}
