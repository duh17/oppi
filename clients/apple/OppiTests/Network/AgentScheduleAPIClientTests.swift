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
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","prompt":"Run QA","agentId":"agent-1","model":"openai/gpt-5.5","worktreeId":"wt-1","name":"QA run"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let schedule = try await client.getAgentSchedule("sch-1")

        #expect(schedule.name == "Daily QA")
        #expect(schedule.trigger.displaySummary.contains("0 9 * * *"))
        guard case .newSession(let workspaceId, let prompt, let agentId, let model, let worktreeId, let name) = schedule.action else {
            Issue.record("Expected new-session action")
            return
        }
        #expect(workspaceId == "ws-1")
        #expect(prompt == "Run QA")
        #expect(agentId == "agent-1")
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
            {"run":{"id":"run-1","scheduleId":"sch-1","kind":"manual","slotKey":"manual:ios","idempotencyKey":"schedule:sch-1:manual:ios","status":"completed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":2000,"sessionId":"sess-1","promptDispatch":"delivered"}}
            """)
        }

        let run = try await client.runAgentSchedule("sch-1")

        #expect(run.id == "run-1")
        #expect(run.sessionId == "sess-1")
        #expect(run.status == .completed)
    }

    @Test func controlSessionCreateUsesDeclaredMetadataAndPrompt() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/control-sessions")
            let body = try JSONDecoder().decode(APIClient.CreateControlSessionRequest.self, from: requestBodyData(request))
            #expect(body.domain == .agents)
            #expect(body.intent == .revise)
            #expect(body.targetId == "agent-1")
            #expect(body.targetName == "Reviewer")
            #expect(body.prompt.contains("--definition-json"))
            return mockResponse(status: 201, json: """
            {"session":{"id":"control-1","name":"Oppi Control","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"revise","targetId":"agent-1","targetName":"Reviewer"}},"prompted":true}
            """)
        }

        let response = try await client.createControlSession(.init(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Reviewer",
            name: "Revise Reviewer",
            prompt: ControlSessionStarterPrompt.make(
                domain: .agents,
                intent: .revise,
                targetId: "agent-1",
                targetName: "Reviewer"
            )
        ))

        #expect(response.session.control?.domain == .agents)
        #expect(response.session.workspaceId == nil)
        #expect(response.prompted == true)
    }

    @Test func focusedControlOperationsUseControlRouteFamily() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/control-sessions/control-1/trace-outline")
            return mockResponse(json: "{}")
        }
        _ = try? await client.getSessionTraceOutline(scope: .control, sessionId: "control-1")

        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/control-sessions/control-1/events")
            #expect(request.url?.query == "since=9")
            return mockResponse(json: "{}")
        }
        _ = try? await client.getSessionEvents(scope: .control, id: "control-1", since: 9)

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/control-sessions/control-1/command")
            return mockResponse(json: "{}")
        }
        try await client.sendSessionCommand(
            scope: .control,
            sessionId: "control-1",
            message: .stop()
        )

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/control-sessions/control-1")
            return mockResponse(json: "{}")
        }
        try await client.deleteSession(scope: .control, sessionId: "control-1")
    }
}

@Suite("Control session starter prompts")
struct ControlSessionStarterPromptTests {
    @Test func revisionPromptIsDeterministicAndUsesCanonicalDefinitionInput() {
        let first = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .revise,
            targetId: "schedule-7",
            targetName: "Nightly review"
        )
        let second = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .revise,
            targetId: "schedule-7",
            targetName: "Nightly review"
        )

        #expect(first == second)
        #expect(first.contains("Canonical target ID: schedule-7"))
        #expect(first.contains("Canonical target name: Nightly review"))
        #expect(first.contains("--definition-json"))
        #expect(first.contains("Do not use filesystem tools or temporary files"))
        #expect(first.contains("wait for explicit approval"))
    }
}
