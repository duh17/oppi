import Foundation
import Testing
@testable import Oppi

@Suite("Voice control API client", .serialized)
struct VoiceControlAPIClientTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func cleanup() {
        TestURLProtocol.handler = nil
    }

    private func mockResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private func requestBodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }

    @Test func createPostsPurposeCheckedVoiceControlSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/voice-control-sessions")
            let body = try JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            #expect(body?["purpose"] as? String == "voice-control")
            #expect(body?["name"] as? String == "Voice Control")
            return mockResponse(status: 201, json: """
            {"session":{"id":"voice-1","name":"Voice Control","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"voice":{"purpose":"voice-control"}}}
            """)
        }

        let response = try await client.createVoiceControlSession()
        #expect(response.session.id == "voice-1")
        #expect(response.session.voice?.purpose == "voice-control")
        #expect(response.session.workspaceId == nil)
        #expect(response.session.control == nil)
    }

    @Test func resumePostsPurposeCheckedVoiceControlSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/voice-control-sessions/voice-1/resume")
            let body = try JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            #expect(body?["purpose"] as? String == "voice-control")
            #expect(body?["name"] == nil)
            return mockResponse(json: """
            {"session":{"id":"voice-1","name":"Voice Control","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"voice":{"purpose":"voice-control"}}}
            """)
        }

        let response = try await client.resumeVoiceControlSession(id: "voice-1")
        #expect(response.session.id == "voice-1")
        #expect(response.session.voice?.purpose == "voice-control")
    }
}
