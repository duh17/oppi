import Foundation
import Testing
@testable import Oppi

@Suite("Pending attachment uploader", .serialized)
struct PendingAttachmentUploaderTests {
    @Test func uploadsLocalFileIntoExistingAgentSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
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
                return Self.response(
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
            return Self.response(
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

    private static func response(
        status: Int = 200,
        json: String
    ) -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://localhost:7749")!
        return (
            Data(json.utf8),
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}
