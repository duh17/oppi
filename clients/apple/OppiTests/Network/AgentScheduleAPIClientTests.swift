import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping non_optional_string_data_conversion

@Suite("Agent and schedule API client", .serialized)
struct AgentScheduleAPIClientTests {
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

    @Test func agentCreatePostsDefinitionAndDecodesStoredAgent() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/agents")
            let body = try JSONDecoder().decode(AgentDefinition.self, from: requestBodyData(request))
            #expect(body.name == "Reviewer")
            #expect(body.instructions?.mode == .append)
            #expect(body.sessionDefaults?.thinkingLevel == .medium)
            return mockResponse(status: 201, json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":1,"definition":{"name":"Reviewer","instructions":{"mode":"append","text":"Review changes."},"sessionDefaults":{"thinkingLevel":"medium"}},"createdAt":1000,"updatedAt":1000}}
            """)
        }

        let agent = try await client.createAgent(
            AgentDefinition(
                name: "Reviewer",
                instructions: AgentInstructions(text: "Review changes."),
                sessionDefaults: AgentSessionDefaults(thinkingLevel: .medium)
            )
        )

        #expect(agent.id == "agent-1")
        #expect(agent.definition.instructions?.text == "Review changes.")
        #expect(agent.createdAt == Date(timeIntervalSince1970: 1))
    }

    @Test func agentUpdateSendsNullsForClearedOptionalFields() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let json = try JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            #expect(json?["name"] as? String == "Reviewer")
            #expect(json?["description"] is NSNull)
            #expect(json?["instructions"] is NSNull)
            #expect(json?["resources"] is NSNull)
            #expect(json?["sessionDefaults"] is NSNull)
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":2,"definition":{"name":"Reviewer"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let agent = try await client.updateAgent(
            agentId: "agent-1",
            definition: AgentDefinition(name: "Reviewer")
        )

        #expect(agent.version == 2)
        #expect(agent.definition.description == nil)
    }

    @Test func scheduleDetailDecodesFullPromptAndAction() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/schedules/sch-1")
            return mockResponse(json: """
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","prompt":"Run QA","model":"openai/gpt-5.5","worktreeId":"wt-1","name":"QA run"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let schedule = try await client.getAgentSchedule("sch-1")

        #expect(schedule.name == "Daily QA")
        #expect(schedule.trigger.displaySummary.contains("0 9 * * *"))
        guard case .newSession(let workspaceId, let prompt, let model, let worktreeId, let name, _) = schedule.action else {
            Issue.record("Expected new-session action")
            return
        }
        #expect(workspaceId == "ws-1")
        #expect(prompt == "Run QA")
        #expect(model == "openai/gpt-5.5")
        #expect(worktreeId == "wt-1")
        #expect(name == "QA run")
    }

    @Test func scheduleRunNowPostsRequestIdAndDecodesRun() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/schedules/sch-1/run")
            let body = try JSONDecoder().decode([String: String].self, from: requestBodyData(request))
            #expect(body["requestId"]?.hasPrefix("ios-manual-") == true)
            return mockResponse(status: 201, json: """
            {"run":{"id":"run-1","scheduleId":"sch-1","kind":"manual","slotKey":"manual:ios","idempotencyKey":"schedule:sch-1:manual:ios","status":"completed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"approvalRefCount":0,"createdAt":1000,"updatedAt":2000,"sessionId":"sess-1","promptDispatch":"delivered"}}
            """)
        }

        let run = try await client.runAgentSchedule("sch-1")

        #expect(run.id == "run-1")
        #expect(run.sessionId == "sess-1")
        #expect(run.status == .completed)
    }
}
