import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
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

    @Test func agentListDecodesSavedIconSummary() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/agents")
            return mockResponse(json: """
            {"agents":[{"id":"agent-1","name":"Sensei","icon":{"kind":"emoji","value":"🧘"},"launchConstraints":{"allowedWorkspaceIds":["research"],"requiredRuntime":"sandbox"},"status":"active","version":2,"createdAt":1000,"updatedAt":2000}]}
            """)
        }

        let agents = try await client.listAgents()

        #expect(agents.count == 1)
        #expect(agents.first?.icon == .emoji("🧘"))
        #expect(agents.first?.launchConstraints?.allowedWorkspaceIds == ["research"])
        #expect(agents.first?.launchConstraints?.requiredRuntime == .sandbox)
    }

    @Test func agentCreatePostsDefinitionAndDecodesStoredAgent() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/agents")
            let body = try JSONDecoder().decode(AgentDefinition.self, from: requestBodyData(request))
            #expect(body.name == "Reviewer")
            #expect(body.icon == .defaultValue)
            #expect(body.instructions?.mode == .append)
            #expect(body.sessionDefaults?.thinkingLevel == .medium)
            return mockResponse(status: 201, json: """
            {"agent":{"id":"agent-1","name":"Reviewer","icon":{"kind":"emoji","value":"🧘"},"status":"active","version":1,"definition":{"name":"Reviewer","icon":{"kind":"emoji","value":"🧘"},"instructions":{"mode":"append","text":"Review changes."},"sessionDefaults":{"thinkingLevel":"medium"}},"createdAt":1000,"updatedAt":1000}}
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
        #expect(agent.icon == .emoji("🧘"))
        #expect(agent.definition.icon == .emoji("🧘"))
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
            let icon = json?["icon"] as? [String: Any]
            #expect(icon?["kind"] as? String == "default")
            #expect(json?["description"] is NSNull)
            #expect(json?["instructions"] is NSNull)
            #expect(json?["resources"] is NSNull)
            #expect(json?["sessionDefaults"] is NSNull)
            #expect(json?["launchConstraints"] == nil)
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

    @Test func agentUpdateSendsReplacePromptModelAndThinkingDefaults() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let data = requestBodyData(request)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(json.keys) == ["name", "description", "instructions", "resources", "sessionDefaults"])
            let definition = try JSONDecoder().decode(AgentDefinition.self, from: data)
            #expect(definition.instructions?.mode == .replace)
            #expect(definition.instructions?.text == "Use only these instructions.")
            #expect(definition.sessionDefaults?.model == "openai/gpt-5.6")
            #expect(definition.sessionDefaults?.thinkingLevel == .max)
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":3,"definition":{"name":"Reviewer","instructions":{"mode":"replace","text":"Use only these instructions."},"sessionDefaults":{"model":"openai/gpt-5.6","thinkingLevel":"max"}},"createdAt":1000,"updatedAt":3000}}
            """)
        }

        let updated = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Reviewer",
            description: nil,
            instructions: AgentInstructions(
                mode: .replace,
                text: "Use only these instructions."
            ),
            model: "openai/gpt-5.6",
            thinkingLevel: .max,
            skillPaths: nil,
            extensionIds: nil
        )

        #expect(updated.definition.instructions?.mode == .replace)
        #expect(updated.definition.sessionDefaults?.thinkingLevel == .max)
    }

    @Test func nativeAgentUpdatePreservesInheritVersusExactEmptyResources() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            let resources = try #require(json["resources"] as? [String: Any])
            #expect(resources["skillPaths"] is NSNull)
            #expect(resources["extensionIds"] as? [String] == [])
            #expect(resources["promptTemplateIds"] is NSNull)
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":4,"definition":{"name":"Reviewer","resources":{"extensionIds":[]}},"createdAt":1000,"updatedAt":4000}}
            """)
        }

        let updated = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Reviewer",
            description: nil,
            instructions: nil,
            model: nil,
            thinkingLevel: nil,
            skillPaths: nil,
            extensionIds: []
        )

        #expect(updated.definition.resources?.skillPaths == nil)
        #expect(updated.definition.resources?.extensionIds?.isEmpty == true)
        #expect(updated.definition.resources?.isEmpty == false)
    }

    @Test func nativeAgentUpdateAddsAndClearsLaunchConstraintsExplicitly() async throws {
        let client = makeClient()
        defer { cleanup() }

        var requestCount = 0
        TestURLProtocol.handler = { request in
            requestCount += 1
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            if requestCount == 1 {
                let constraints = try #require(json["launchConstraints"] as? [String: Any])
                #expect(constraints["allowedWorkspaceIds"] as? [String] == ["research"])
                #expect(constraints["requiredRuntime"] as? String == "sandbox")
            } else {
                #expect(json["launchConstraints"] is NSNull)
            }
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Research Scout","status":"active","version":\(requestCount + 1),"definition":{"name":"Research Scout"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        _ = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Research Scout",
            description: nil,
            instructions: nil,
            model: nil,
            thinkingLevel: nil,
            skillPaths: nil,
            extensionIds: nil,
            launchConstraints: AgentLaunchConstraints(
                allowedWorkspaceIds: ["research"],
                requiredRuntime: .sandbox
            )
        )
        _ = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Research Scout",
            description: nil,
            instructions: nil,
            model: nil,
            thinkingLevel: nil,
            skillPaths: nil,
            extensionIds: nil,
            launchConstraints: nil,
            previouslyHadLaunchConstraints: true
        )
    }

    @Test func nativeDefaultAgentUpdateOmitsForbiddenResourcesOnCanonicalRoute() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/oppi-default-agent")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(json["resources"] == nil)
            #expect(json["launchConstraints"] == nil)
            #expect(json["name"] as? String == "Home Agent")
            #expect(json["description"] is NSNull)
            #expect(json["instructions"] is NSNull)
            #expect(json["sessionDefaults"] is [String: Any])
            return mockResponse(json: """
            {"agent":{"id":"oppi-default-agent","name":"Home Agent","status":"active","version":2,"definition":{"name":"Home Agent","resources":{"noContextFiles":true}},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let updated = try await client.updateAgentNative(
            agentId: "oppi-default-agent",
            name: "Home Agent",
            description: nil,
            instructions: nil,
            model: "openai/gpt-5.6",
            thinkingLevel: .high,
            skillPaths: nil,
            extensionIds: nil
        )

        #expect(updated.id == "oppi-default-agent")
        #expect(updated.definition.resources?.noContextFiles == true)
    }

    @Test func agentLaunchDecodesActionableConfigurationFailure() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/agents/research-scout/sessions")
            return mockResponse(status: 422, json: """
            {
              "error":"Research Scout can’t start in Oppi. Edit Research Scout → Resources → Extensions.",
              "code":"agent_tools_unavailable",
              "sessionId":"failed-1",
              "receipt":{"accepted":false,"retryable":false,"reason":"agent_tools_unavailable","sessionId":"failed-1","promptDispatch":"not_sent"},
              "recovery":{"actions":["edit_agent","choose_workspace"],"agentId":"research-scout","workspaceId":"oppi","missingTools":["research_web_search"]}
            }
            """)
        }

        do {
            _ = try await client.launchAgentSession(
                agentId: "research-scout",
                prompt: "Research this",
                workspaceId: "oppi"
            )
            Issue.record("Expected an actionable Agent launch failure")
        } catch let failure as AgentLaunchFailureResponse {
            #expect(failure.code == "agent_tools_unavailable")
            #expect(failure.receipt.accepted == false)
            #expect(failure.recovery.actions == [.editAgent, .chooseWorkspace])
            #expect(failure.recovery.missingTools == ["research_web_search"])
        }
    }

    @Test func agentIconUpdateSendsOnlyIconForSetAndClear() async throws {
        let client = makeClient()
        defer { cleanup() }

        var expectedKind = "emoji"
        var requestCount = 0
        TestURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(Set(json.keys) == ["icon"])
            let icon = try #require(json["icon"] as? [String: Any])
            #expect(icon["kind"] as? String == expectedKind)
            if expectedKind == "emoji" {
                #expect(icon["value"] as? String == "🧘")
            }
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":\(requestCount + 1),"definition":{"name":"Reviewer"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        _ = try await client.updateAgentIcon(agentId: "agent-1", icon: .emoji("🧘"))
        expectedKind = "default"
        _ = try await client.updateAgentIcon(agentId: "agent-1", icon: .defaultValue)

        #expect(requestCount == 2)
    }

    @Test func iconAssetUploadSendsAuthenticatedDeclaredHEIFBody() async throws {
        let client = makeClient()
        defer { cleanup() }
        let body = Data([0, 1, 2, 3])
        let assetId = "ia_" + String(repeating: "A", count: 43)

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/icon-assets")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/heic")
            #expect(requestBodyData(request) == body)
            return mockResponse(status: 201, json: """
            {"asset":{"assetId":"\(assetId)","sha256":"abc","sizeBytes":4,"contentType":"image/heic","createdAt":1000}}
            """)
        }

        let asset = try await client.uploadIconAsset(data: body, contentType: "image/heic")

        #expect(asset.assetId == assetId)
        #expect(asset.sizeBytes == body.count)
    }

    @Test func iconAssetFetchUsesAuthenticatedOpaqueAssetRoute() async throws {
        let client = makeClient()
        defer { cleanup() }
        let assetId = "ia_" + String(repeating: "A", count: 43)
        let expected = Data([4, 5, 6])

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/icon-assets/\(assetId)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            return (expected, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/heic"]
            )!)
        }

        #expect(try await client.fetchIconAsset(assetId: assetId) == expected)
    }

    @Test func scheduleDetailDecodesFullPromptAndAction() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/schedules/sch-1")
            return mockResponse(json: """
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","prompt":"Run QA","agentId":"agent-1","model":"openai/gpt-5.5","thinkingLevel":"high","worktreeId":"wt-1","name":"QA run"},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        let schedule = try await client.getAgentSchedule("sch-1")

        #expect(schedule.name == "Daily QA")
        #expect(schedule.trigger.displaySummary.contains("0 9 * * *"))
        guard case .newSession(
            let workspaceId,
            let prompt,
            let agentId,
            let model,
            let thinkingLevel,
            let worktreeId,
            let name
        ) = schedule.action else {
            Issue.record("Expected new-session action")
            return
        }
        #expect(workspaceId == "ws-1")
        #expect(prompt == "Run QA")
        #expect(agentId == "agent-1")
        #expect(model == "openai/gpt-5.5")
        #expect(thinkingLevel == .high)
        #expect(worktreeId == "wt-1")
        #expect(name == "QA run")
    }

    @Test func scheduleUpdateEncodesThinkingOverride() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/schedules/sch-1")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            let action = try #require(json["action"] as? [String: Any])
            #expect(action["thinkingLevel"] as? String == "max")
            #expect(action["agentId"] is NSNull)
            #expect(action["model"] is NSNull)
            #expect(action["name"] is NSNull)
            #expect(action["worktreeId"] == nil)
            return mockResponse(json: """
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":2000}}
            """)
        }

        _ = try await client.updateAgentScheduleNative(
            scheduleId: "sch-1",
            name: "Daily QA",
            trigger: .cron(expression: "0 9 * * *", timeZone: "UTC"),
            action: .newSession(
                workspaceId: "ws-1",
                prompt: "Run QA",
                agentId: nil,
                model: nil,
                thinkingLevel: .max,
                worktreeId: nil,
                name: nil
            )
        )
    }

    @Test func scheduleRestorePostsActionAndDecodesActiveSchedule() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/schedules/sch-1/restore")
            return mockResponse(json: """
            {"schedule":{"id":"sch-1","name":"Daily QA","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"America/Los_Angeles"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":3000}}
            """)
        }

        let schedule = try await client.restoreAgentSchedule("sch-1")

        #expect(schedule.status == .active)
        #expect(schedule.archivedAt == nil)
    }

    @Test func scheduleRunHistoryIsNewestFirstEvenWhenServerOrderIsOldestFirst() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/schedules/sch-1/runs")
            #expect(request.url?.query == "limit=20&order=desc")
            return mockResponse(json: """
            {"runs":[
              {"id":"run-old","scheduleId":"sch-1","kind":"due","slotKey":"old","idempotencyKey":"old","status":"completed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":1000},
              {"id":"run-new","scheduleId":"sch-1","kind":"manual","slotKey":"new","idempotencyKey":"new","status":"completed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":3000,"updatedAt":3000},
              {"id":"run-middle","scheduleId":"sch-1","kind":"due","slotKey":"middle","idempotencyKey":"middle","status":"failed","action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":2000,"updatedAt":2000}
            ]}
            """)
        }

        let runs = try await client.listAgentScheduleRuns(scheduleId: "sch-1")

        #expect(runs.map(\.id) == ["run-new", "run-middle", "run-old"])
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
            #expect(body.model == "anthropic/claude-opus-4-8")
            #expect(body.thinking == .high)
            #expect(body.prompt?.contains("--definition-json") == true)
            #expect(body.launchIdempotencyKey == "control-revision-request-1")
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
            model: "anthropic/claude-opus-4-8",
            thinking: .high,
            prompt: ControlSessionStarterPrompt.make(
                domain: .agents,
                intent: .revise,
                targetId: "agent-1",
                targetName: "Reviewer"
            ),
            launchIdempotencyKey: "control-revision-request-1"
        ))

        #expect(response.session.control?.domain == .agents)
        #expect(response.session.workspaceId == nil)
        #expect(response.prompted == true)
    }

    @Test func controlSessionCreateCanPersistBeforeStarterPromptDelivery() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(json["prompt"] == nil)
            #expect(json["launchIdempotencyKey"] as? String == "control-create-request-1")
            return mockResponse(status: 201, json: """
            {"session":{"id":"control-1","name":"Oppi Control","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"revise","targetId":"agent-1"}}}
            """)
        }

        let response = try await client.createControlSession(.init(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Reviewer",
            name: "Revise Reviewer",
            launchIdempotencyKey: "control-create-request-1"
        ))

        #expect(response.session.id == "control-1")
        #expect(response.prompted == nil)
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
            return mockResponse(json: """
            {"messages":[{"type":"command_result","command":"stop","success":true}]}
            """)
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

    @Test func failedHTTPControlCommandThrowsInsteadOfClaimingPromptDelivery() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/control-sessions/control-1/command")
            return mockResponse(json: """
            {"messages":[{"type":"command_result","command":"prompt","requestId":"request-1","success":false,"error":"Starter prompt was rejected"}]}
            """)
        }

        do {
            try await client.sendSessionCommand(
                scope: .control,
                sessionId: "control-1",
                message: .prompt(message: "Start", requestId: "request-1")
            )
            Issue.record("A failed command_result must throw")
        } catch {
            #expect(error.localizedDescription == "Starter prompt was rejected")
        }
    }

    @Test func agentResourceCatalogStateDistinguishesUnloadedFailureEmptyAndContent() {
        #expect(AgentResourceCatalogState.resolve(
            hasLoaded: false,
            isSyncing: true,
            lastSyncFailed: false,
            hasRows: false
        ) == .loading)
        #expect(AgentResourceCatalogState.resolve(
            hasLoaded: false,
            isSyncing: false,
            lastSyncFailed: false,
            hasRows: false
        ) == .neverLoaded)
        #expect(AgentResourceCatalogState.resolve(
            hasLoaded: false,
            isSyncing: false,
            lastSyncFailed: true,
            hasRows: false
        ) == .failed)
        #expect(AgentResourceCatalogState.resolve(
            hasLoaded: true,
            isSyncing: false,
            lastSyncFailed: false,
            hasRows: false
        ) == .empty)
        #expect(AgentResourceCatalogState.resolve(
            hasLoaded: true,
            isSyncing: false,
            lastSyncFailed: false,
            hasRows: true
        ) == .content)
        #expect(AgentResourceCatalogState.isExactSelectionSaveAllowed(
            initialSelectionWasInherited: true,
            catalogState: .failed
        ) == false)
        #expect(AgentResourceCatalogState.isExactSelectionSaveAllowed(
            initialSelectionWasInherited: true,
            catalogState: .empty
        ))
        #expect(AgentResourceCatalogState.isExactSelectionSaveAllowed(
            initialSelectionWasInherited: false,
            catalogState: .failed
        ))
    }
}

private actor IconAssetFetchCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor IconAssetFetchGate {
    private var continuations: [CheckedContinuation<Data, Never>] = []

    func wait() async -> Data {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open(with data: Data) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: data) }
    }
}

private actor IconAssetCompletionState {
    private(set) var wasCancelled = false

    func markCancelled() {
        wasCancelled = true
    }
}

private actor IconAssetResultGate {
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var requested: [String] = []

    func wait(for assetId: String) async throws -> Data {
        requested.append(assetId)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[assetId] = continuation
        }
    }

    func requestedIDs() -> [String] {
        requested
    }

    func succeed(_ assetId: String, data: Data) {
        continuations.removeValue(forKey: assetId)?.resume(returning: data)
    }

    func fail(_ assetId: String) {
        continuations.removeValue(forKey: assetId)?.resume(
            throwing: APIError.server(status: 500, message: "injected failure")
        )
    }
}

private enum HEIFFixtureError: Error {
    case context
    case destination
    case finalize
}

/// Runtime-generated with Core Graphics + ImageIO so production decoder tests
/// have deterministic provenance and do not embed an opaque binary fixture.
private func imageIOHEIFFixture(
    width: Int,
    height: Int,
    visible: Bool
) throws -> Data {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let context = pixels.withUnsafeMutableBytes({ storage in
        CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }) else { throw HEIFFixtureError.context }
    if visible {
        context.setFillColor(UIColor.systemPink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    guard let image = context.makeImage() else { throw HEIFFixtureError.context }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.heic.identifier as CFString,
        1,
        nil
    ) else { throw HEIFFixtureError.destination }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw HEIFFixtureError.finalize }
    return output as Data
}

@Suite("Icon asset cache")
@MainActor
struct IconAssetCacheTests {
    private func decodedImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    @Test func serverConnectionOwnsACacheForItsConfiguredAPIClient() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: configuration
        )
        let connection = ServerConnection()

        connection.setAPIClientForTesting(client)

        #expect(connection.iconAssetCache != nil)
    }

    @Test func decodedCacheCostUsesRasterBytesAndSaturatesOverflow() {
        #expect(IconAssetCache.decodedByteCost(bytesPerRow: 256, height: 128) == 32_768)
        #expect(IconAssetCache.decodedByteCost(bytesPerRow: .max, height: 2) == .max)
        #expect(IconAssetCache.decodedByteCost(bytesPerRow: 0, height: 128) == 0)
    }

    @Test func reusesDecodedAssetForTheSameIDAndSize() async throws {
        let counter = IconAssetFetchCounter()
        let cache = IconAssetCache(
            fetch: { _ in
                await counter.increment()
                return Data([1, 2, 3])
            },
            decode: { _, _ in (decodedImage(), NSObject()) }
        )

        let first = try await cache.image(assetId: "ia_test", size: 32)
        let second = try await cache.image(assetId: "ia_test", size: 32)

        #expect(await counter.value() == 1)
        #expect(first === second)
    }

    @Test func cancellationStopsAnAbandonedFetchBeforeDecode() async {
        let cache = IconAssetCache(
            fetch: { _ in
                try await Task.sleep(for: .seconds(30))
                return Data([1])
            },
            decode: { _, _ in
                Issue.record("Cancelled fetch must not decode")
                return (decodedImage(), NSObject())
            }
        )

        let task = Task { try await cache.image(assetId: "ia_slow", size: 32) }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func concurrentMissesCoalesceAndOneConsumerCanCancelIndependently() async throws {
        let counter = IconAssetFetchCounter()
        let gate = IconAssetFetchGate()
        let firstCompletion = IconAssetCompletionState()
        let cache = IconAssetCache(
            fetch: { _ in
                await counter.increment()
                return await gate.wait()
            },
            decode: { _, _ in (decodedImage(), NSObject()) }
        )

        let first = Task {
            do {
                _ = try await cache.image(assetId: "ia_shared", size: 32)
            } catch is CancellationError {
                await firstCompletion.markCancelled()
            }
        }
        let second = Task { try await cache.image(assetId: "ia_shared", size: 32) }
        for _ in 0..<20 {
            if await counter.value() > 0 { break }
            await Task.yield()
        }

        #expect(await counter.value() == 1)
        first.cancel()
        for _ in 0..<20 {
            if await firstCompletion.wasCancelled { break }
            await Task.yield()
        }
        #expect(await firstCompletion.wasCancelled)

        await gate.open(with: Data([1, 2, 3]))
        _ = try await second.value
        _ = await first.result
        #expect(await counter.value() == 1)
    }

    @Test func rapidAssetReplacementCannotClearTheNewerResultWithAStaleFailure() async throws {
        let gate = IconAssetResultGate()
        let firstID = "ia_" + String(repeating: "A", count: 43)
        let secondID = "ia_" + String(repeating: "B", count: 43)
        let secondImage = decodedImage()
        let cache = IconAssetCache(
            fetch: { try await gate.wait(for: $0) },
            decode: { data, _ in
                #expect(data == Data([2]))
                return (secondImage, NSObject())
            }
        )
        let firstIdentity = IconAssetViewLoadIdentity(
            key: IconAssetLoadKey(assetId: firstID, cache: cache),
            requestID: UUID()
        )
        var currentIdentity = firstIdentity
        var loadedImage: UIImage?

        let first = Task { @MainActor in
            await loadIconAssetForView(
                assetId: firstID,
                size: 32,
                cache: cache,
                identity: firstIdentity,
                currentIdentity: { currentIdentity },
                assign: { loadedImage = $0 }
            )
        }
        for _ in 0..<50 where await gate.requestedIDs().isEmpty { await Task.yield() }

        let secondIdentity = IconAssetViewLoadIdentity(
            key: IconAssetLoadKey(assetId: secondID, cache: cache),
            requestID: UUID()
        )
        currentIdentity = secondIdentity
        let second = Task { @MainActor in
            await loadIconAssetForView(
                assetId: secondID,
                size: 32,
                cache: cache,
                identity: secondIdentity,
                currentIdentity: { currentIdentity },
                assign: { loadedImage = $0 }
            )
        }
        for _ in 0..<50 where !(await gate.requestedIDs()).contains(secondID) { await Task.yield() }
        await gate.succeed(secondID, data: Data([2]))
        await second.value
        #expect(loadedImage === secondImage)

        await gate.fail(firstID)
        await first.value
        #expect(loadedImage === secondImage)
    }

    @Test func serverCacheReplacementCannotAssignTheOldCachesResult() async throws {
        let assetID = "ia_" + String(repeating: "C", count: 43)
        let oldGate = IconAssetResultGate()
        let newGate = IconAssetResultGate()
        let oldImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        let newImage = decodedImage()
        let oldCache = IconAssetCache(
            fetch: { try await oldGate.wait(for: $0) },
            decode: { _, _ in (oldImage, NSObject()) }
        )
        let newCache = IconAssetCache(
            fetch: { try await newGate.wait(for: $0) },
            decode: { _, _ in (newImage, NSObject()) }
        )
        let oldIdentity = IconAssetViewLoadIdentity(
            key: IconAssetLoadKey(assetId: assetID, cache: oldCache),
            requestID: UUID()
        )
        var currentIdentity = oldIdentity
        var loadedImage: UIImage?

        let oldRequest = Task { @MainActor in
            await loadIconAssetForView(
                assetId: assetID,
                size: 32,
                cache: oldCache,
                identity: oldIdentity,
                currentIdentity: { currentIdentity },
                assign: { loadedImage = $0 }
            )
        }
        for _ in 0..<50 where await oldGate.requestedIDs().isEmpty { await Task.yield() }

        let newIdentity = IconAssetViewLoadIdentity(
            key: IconAssetLoadKey(assetId: assetID, cache: newCache),
            requestID: UUID()
        )
        currentIdentity = newIdentity
        let newRequest = Task { @MainActor in
            await loadIconAssetForView(
                assetId: assetID,
                size: 32,
                cache: newCache,
                identity: newIdentity,
                currentIdentity: { currentIdentity },
                assign: { loadedImage = $0 }
            )
        }
        for _ in 0..<50 where await newGate.requestedIDs().isEmpty { await Task.yield() }
        await newGate.succeed(assetID, data: Data([2]))
        await newRequest.value
        #expect(loadedImage === newImage)

        await oldGate.succeed(assetID, data: Data([1]))
        await oldRequest.value
        #expect(loadedImage === newImage)
        #expect(loadedImage !== oldImage)
    }

    @Test func productionRemoteDecoderAcceptsVisibleGeneratedHEIF() throws {
        let data = try imageIOHEIFFixture(width: 64, height: 64, visible: true)
        let decoded = try IconAssetCache.decodeRemoteHEIF(data: data, size: 32)

        #expect(decoded.image.size.width > 0)
        #expect(decoded.image.size.height > 0)
    }

    @Test func productionRemoteDecoderRejectsTransparentBlankHEIF() throws {
        let data = try imageIOHEIFFixture(width: 64, height: 64, visible: false)

        #expect(throws: Error.self) {
            _ = try IconAssetCache.decodeRemoteHEIF(data: data, size: 32)
        }
    }

    @Test func productionRemoteDecoderRejectsInvalidRenderSizes() throws {
        let data = try imageIOHEIFFixture(width: 64, height: 64, visible: true)

        for size in [CGFloat.zero, -1, 513, .infinity, .nan] {
            #expect(throws: Error.self) {
                _ = try IconAssetCache.decodeRemoteHEIF(data: data, size: size)
            }
        }
    }

    @Test func productionRemoteDecoderRejectsOversizedDimensions() throws {
        let data = try imageIOHEIFFixture(width: 4_097, height: 1, visible: true)

        #expect(throws: Error.self) {
            _ = try IconAssetCache.decodeRemoteHEIF(data: data, size: 32)
        }
    }

    @Test func productionRemoteDecoderRejectsMalformedAndTruncatedHEIF() throws {
        let valid = try imageIOHEIFFixture(width: 64, height: 64, visible: true)
        for data in [Data([1, 2, 3, 4]), Data(valid.prefix(valid.count / 2))] {
            #expect(throws: Error.self) {
                _ = try IconAssetCache.decodeRemoteHEIF(data: data, size: 32)
            }
        }
    }

    @Test func emptyAndOversizedResponsesFailBeforeDecode() async {
        for data in [Data(), Data(repeating: 0, count: 2 * 1024 * 1024 + 1)] {
            let cache = IconAssetCache(
                fetch: { _ in data },
                decode: { _, _ in
                    Issue.record("Invalid bytes must not decode")
                    return (decodedImage(), NSObject())
                }
            )

            do {
                _ = try await cache.image(assetId: "ia_invalid", size: 32)
                Issue.record("Expected invalid asset data to fail")
            } catch let APIError.server(status, _) {
                #expect(status == 422)
            } catch {
                Issue.record("Expected APIError.server, got \(error)")
            }
        }
    }
}

@Suite("Agent icon presentation")
struct AgentIconPresentationTests {
    @Test func classifiesTrimmedEmojiAndSymbolCandidatesDeterministically() {
        #expect(AgentIconValue.classify("  🧘  ") == .emoji("🧘"))
        #expect(AgentIconValue.classify(" checkmark.shield\n") == .symbolCandidate("checkmark.shield"))
        #expect(AgentIconValue.classify("🧘🧘") == .invalid(.multipleEmoji))
        #expect(AgentIconValue.classify(String(repeating: "a", count: 129)) == .invalid(.tooLong))
        #expect(AgentIconValue.classify("😀" + String(repeating: "‍😀", count: 64)) == .invalid(.tooLong))
        #expect(AgentIconValue.classify("not/a/symbol") == .invalid(.malformed))
    }

    @Test func scaledIconContentNeverExceedsItsLayoutBox() {
        let size = AgentIconSizingPolicy.contentSize(
            baseSize: 20,
            scaledSize: 40,
            frameSize: 24
        )

        #expect(size <= 24)
        #expect(size == 18.72)
    }

    @Test func ordinaryAndAgentSessionIdentityUseTheCorrectPresentation() {
        #expect(AssistantIdentityPresentation.resolve(agentId: nil, agentIcon: .emoji("🧘")) == .globalAvatar)
        #expect(AssistantIdentityPresentation.resolve(agentId: "", agentIcon: .emoji("🧘")) == .globalAvatar)
        #expect(AssistantIdentityPresentation.resolve(agentId: "agent-1", agentIcon: .emoji("🧘")) == .agent(.text("🧘")))
        #expect(AssistantIdentityPresentation.resolve(agentId: "agent-1", agentIcon: .symbol("person.crop.circle")) == .agent(.symbol("person.crop.circle")))
        #expect(AssistantIdentityPresentation.resolve(agentId: "agent-1", agentIcon: .symbol("not-a-real-symbol")) == .agent(.fallback))
    }

    @Test func resolvesSupportedIconsAndFallbacks() {
        let assetId = "ia_" + String(repeating: "A", count: 43)

        #expect(AgentIconContent.resolve(.emoji("🧘")) == .text("🧘"))
        #expect(AgentIconContent.resolve(.emoji("👨‍👩‍👧‍👦")) == .text("👨‍👩‍👧‍👦"))
        #expect(AgentIconContent.resolve(.emoji("👋🏽")) == .text("👋🏽"))
        #expect(AgentIconContent.resolve(.emoji("🇺🇸")) == .text("🇺🇸"))
        #expect(AgentIconContent.resolve(.emoji("1️⃣")) == .text("1️⃣"))
        #expect(AgentIconContent.resolve(.symbol("person.crop.circle")) == .symbol("person.crop.circle"))
        #expect(AgentIconContent.resolve(nil) == .fallback)
        #expect(AgentIconContent.resolve(.defaultValue) == .fallback)
        #expect(AgentIconContent.resolve(.symbol("not-a-real-symbol")) == .fallback)
        #expect(AgentIconContent.resolve(.genmoji(
            assetId: assetId,
            contentDescription: "A smiling fox"
        )) == .genmoji(
            assetId: assetId,
            contentDescription: "A smiling fox"
        ))
    }
}

@Suite("Schedule presentation")
struct SchedulePresentationTests {
    @Test func commonCronSchedulesUsePlainLanguage() {
        let daily = AgentScheduleTrigger.cron(expression: "0 8 * * *", timeZone: "America/Los_Angeles")
        let twiceDaily = AgentScheduleTrigger.cron(expression: "0 9,17 * * *", timeZone: "America/Los_Angeles")
        let weekly = AgentScheduleTrigger.cron(expression: "30 9 * * 1", timeZone: "America/Los_Angeles")

        #expect(daily.scheduleScreenCadence == "DAILY")
        #expect(daily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("Every day · 8:00"))
        #expect(twiceDaily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("9:00"))
        #expect(twiceDaily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("5:00"))
        #expect(weekly.scheduleScreenCadence == "WEEKLY")
        #expect(weekly.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("Mondays · 9:30"))
    }

    @Test func advancedSchedulesHideImplementationSyntax() {
        let custom = AgentScheduleTrigger.cron(expression: "0 8 1 * *", timeZone: "UTC")
        let interval = AgentScheduleTrigger.every(intervalMs: 7_200_000, timeZone: "UTC")

        #expect(custom.scheduleScreenCadence == "CUSTOM")
        #expect(custom.scheduleScreenTiming(locale: Locale(identifier: "en_US")) == "Custom schedule")
        #expect(interval.scheduleScreenCadence == "REPEATS")
        #expect(interval.scheduleScreenTiming(locale: Locale(identifier: "en_US")) == "Every 2h")
    }

    @Test func detailTimingNeverSurfacesCronAndQualifiesForeignTimeZones() {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let daily = AgentScheduleTrigger.cron(
            expression: "0 7 * * *",
            timeZone: "America/Los_Angeles"
        )

        let localSummary = daily.detailTimingSummary(
            locale: Locale(identifier: "en_US"),
            deviceTimeZone: losAngeles
        )
        #expect(localSummary.contains("Every day"))
        #expect(localSummary.contains("7:00"))
        #expect(!localSummary.lowercased().contains("cron"))
        #expect(!localSummary.contains("0 7"))

        let foreignSummary = daily.detailTimingSummary(
            locale: Locale(identifier: "en_US"),
            deviceTimeZone: tokyo
        )
        #expect(foreignSummary.contains("Every day"))
        #expect(!foreignSummary.lowercased().contains("cron"))
        #expect(foreignSummary != localSummary)
    }
}

@Suite("Native schedule editing")
struct NativeScheduleEditingTests {
    @Test func simpleDailyAndWeeklyCronRoundTripThroughNativeDraft() {
        let daily = AgentScheduleTrigger.cron(
            expression: "15 8 * * *",
            timeZone: "America/Los_Angeles"
        )
        let weekly = AgentScheduleTrigger.cron(
            expression: "30 9 * * 1",
            timeZone: "America/New_York"
        )

        let dailyDraft = ScheduleTriggerDraft(trigger: daily, now: Date(timeIntervalSince1970: 0))
        let weeklyDraft = ScheduleTriggerDraft(trigger: weekly, now: Date(timeIntervalSince1970: 0))

        #expect(dailyDraft.cadence == .daily)
        #expect(dailyDraft.makeTrigger() == daily)
        #expect(weeklyDraft.cadence == .weekly)
        #expect(weeklyDraft.makeTrigger() == weekly)
    }

    @Test func advancedCronIsPreservedUntilTheUserChoosesANativeCadence() {
        let custom = AgentScheduleTrigger.cron(
            expression: "0 8 1 * *",
            timeZone: "UTC"
        )
        var draft = ScheduleTriggerDraft(trigger: custom)

        #expect(draft.cadence == .custom)
        #expect(draft.makeTrigger() == custom)

        draft.cadence = .daily
        #expect(draft.makeTrigger()?.scheduleScreenCadence == "DAILY")
    }

    @Test func manualRunInsertionKeepsOnlyTheNewestTwentyRows() {
        let existing = (0..<20).map { index in
            makeRun(id: "run-\(index)", timestamp: TimeInterval(20 - index))
        }
        let newest = makeRun(id: "run-new", timestamp: 100)

        let updated = scheduleRunsByInsertingNewest(newest, into: existing, limit: 20)

        #expect(updated.count == 20)
        #expect(updated.first?.id == newest.id)
        #expect(!updated.contains(where: { $0.id == "run-19" }))
    }

    private func makeRun(id: String, timestamp: TimeInterval) -> AgentScheduleRunSummary {
        AgentScheduleRunSummary(
            id: id,
            scheduleId: "schedule-1",
            kind: .manual,
            slotKey: id,
            idempotencyKey: id,
            status: .completed,
            action: AgentScheduleActionSummary(
                type: .newSession,
                workspaceId: "workspace-1",
                sessionId: nil,
                agentId: nil,
                promptChars: 0
            ),
            createdAt: Date(timeIntervalSince1970: timestamp),
            updatedAt: Date(timeIntervalSince1970: timestamp),
            claimedAt: nil,
            leaseOwner: nil,
            leaseExpiresAt: nil,
            startedAt: nil,
            completedAt: Date(timeIntervalSince1970: timestamp),
            sessionId: nil,
            promptDispatch: nil,
            error: nil
        )
    }
}

@Suite("Control session starter prompts")
struct ControlSessionStarterPromptTests {
    @Test func scheduleCreationPromptCarriesRequestWorkspaceAndClarificationContract() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .create,
            workspaceId: "ws-7",
            workspaceName: "Dream",
            userRequest: "Brief me on coaching trends every Monday morning."
        )

        #expect(prompt.contains("User request:\nBrief me on coaching trends every Monday morning."))
        #expect(prompt.contains("Canonical workspace ID: ws-7"))
        #expect(prompt.contains("Canonical workspace name: Dream"))
        #expect(prompt.contains("`oppi schedule`"))
        #expect(prompt.contains("schedule behavior or timing is ambiguous"))
        #expect(prompt.contains("native confirmation"))
        #expect(prompt.contains("Do not ask the user to type approve"))
        #expect(!prompt.contains("wait for explicit approval"))
    }

    @Test func agentCreationPromptTeachesTheAgentCommandAndBehaviorClarification() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .agents,
            intent: .create,
            workspaceId: "ws-2",
            workspaceName: "Oppi",
            userRequest: "Create a careful release reviewer."
        )

        #expect(prompt.contains("`oppi agent`"))
        #expect(prompt.contains("Agent behavior is ambiguous"))
        #expect(prompt.contains("Canonical workspace ID: ws-2"))
        #expect(prompt.contains("User request:\nCreate a careful release reviewer."))
    }

    @Test func SkillRevisionStarterPromptUsesOnlyRestrictedInlineSkillCommands() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .skills,
            intent: .revise,
            targetId: "skill_abc",
            targetName: "review",
            userRequest: "Apply my staged comments."
        )

        #expect(prompt.contains("Canonical target ID: skill_abc"))
        #expect(prompt.contains("`oppi skill`"))
        #expect(prompt.contains("`oppi skill update-file --base-revision <revision> --content-json <json-string>`"))
        #expect(prompt.contains("If a revision conflicts, re-read the file"))
        #expect(prompt.contains("package Skills are read-only"))
        #expect(prompt.contains("Do not use filesystem tools or temporary files"))
    }

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
        #expect(first.contains("--model <provider/model>"))
        #expect(first.contains("canonical `provider/model`"))
        #expect(first.contains("ask one focused provider question"))
        #expect(first.contains("do not guess"))
        #expect(first.contains("Do not use filesystem tools or temporary files"))
        #expect(first.contains("native confirmation"))
        #expect(first.contains("Do not ask the user to type approve"))
        #expect(!first.contains("wait for explicit approval"))
    }
}
