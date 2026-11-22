import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("Agent and schedule API client", .serialized)
struct AgentScheduleAPIClientTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: config)
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

    @Test func defaultModelWriteUsesPiSettingsRoute() async throws {
        let client = makeClient()
        defer { cleanup() }
        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/server/resources/pi/default-model")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: String]
            )
            #expect(json == ["model": "xai/grok-4.6"])
            return mockResponse(json: #"{"model":"xai/grok-4.6"}"#)
        }
        try await client.setPiDefaultModel("xai/grok-4.6")
    }

    @Test func agentDefaultModelPatchIsVersionedAndChangesOnlyModel() async throws {
        let client = makeClient()
        defer { cleanup() }
        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            #expect(request.url?.query == "expectedVersion=3")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(Set(json.keys) == ["sessionDefaults"])
            #expect(json["sessionDefaults"] as? [String: String] == ["model": "xai/grok-4.6"])
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":4,"definition":{"name":"Reviewer","sessionDefaults":{"model":"xai/grok-4.6","thinkingLevel":"high"}},"createdAt":1000,"updatedAt":4000}}
            """)
        }
        let saved = try await client.setAgentDefaultModel(
            agentId: "agent-1", version: 3, model: "xai/grok-4.6"
        )
        #expect(saved.definition.sessionDefaults?.model == "xai/grok-4.6")
        #expect(saved.definition.sessionDefaults?.thinkingLevel == .high)
    }

    @Test func agentListDecodesSavedIconSummary() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/agents")
            return mockResponse(json: """
            {"agents":[{"id":"agent-1","name":"Sensei","icon":{"kind":"emoji","value":"🧘"},"launchConstraints":{"allowedWorkspaceIds":["research"],"requiredRuntime":"sandbox","requiredEngine":"durable"},"status":"active","version":2,"createdAt":1000,"updatedAt":2000}]}
            """)
        }

        let agents = try await client.listAgents()

        #expect(agents.count == 1)
        #expect(agents.first?.icon == .emoji("🧘"))
        #expect(agents.first?.launchConstraints?.allowedWorkspaceIds == ["research"])
        #expect(agents.first?.launchConstraints?.requiredRuntime == .sandbox)
        #expect(agents.first?.launchConstraints?.requiredEngine == .durable)
        #expect(agents.first?.sessionDefaults == nil)
    }

    @Test func agentListDecodesConfiguredModelAndThinking() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/agents")
            return mockResponse(json: """
            {"agents":[{"id":"agent-1","name":"Designer","status":"active","version":1,"createdAt":1000,"updatedAt":2000,"sessionDefaults":{"model":"xai/grok-4.6","thinkingLevel":"high"}}]}
            """)
        }

        let agents = try await client.listAgents()

        #expect(agents.count == 1)
        #expect(agents.first?.sessionDefaults?.model == "xai/grok-4.6")
        #expect(agents.first?.sessionDefaults?.thinkingLevel == .high)
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

    @Test func agentUpdateSendsReplacePromptModelAndThinkingDefaults() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/agents/agent-1")
            let data = requestBodyData(request)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(json.keys) == ["name", "description", "instructions", "capabilities", "context", "sessionDefaults"])
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
            capabilities: AgentCapabilities(tools: ["read", "edit"], ask: true, notify: true, subagent: true),
            context: AgentContext(contextFiles: true, sessionHistory: false),
            model: "openai/gpt-5.6",
            thinkingLevel: .max
        )

        #expect(updated.definition.instructions?.mode == .replace)
        #expect(updated.definition.sessionDefaults?.thinkingLevel == .max)
    }

    /// A read-only Agent states the plugins and MCP servers it may use; going back to every one
    /// of them is an explicit null, which the server's key-by-key PATCH drops.
    @Test func nativeAgentUpdateNamesReadOnlyCapabilitiesAndClearsThemBackToAll() async throws {
        let client = makeClient()
        defer { cleanup() }

        var requestCount = 0
        TestURLProtocol.handler = { request in
            requestCount += 1
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            let capabilities = try #require(json["capabilities"] as? [String: Any])
            let context = try #require(json["context"] as? [String: Any])
            switch requestCount {
            case 1:
                #expect(capabilities["tools"] as? [String] == ["read", "bash"])
                #expect(capabilities["ask"] as? Bool == false)
                #expect(capabilities["notify"] as? Bool == true)
                #expect(capabilities["subagent"] as? Bool == false)
                #expect((capabilities["plugins"] as? [String])?.isEmpty == true)
                #expect((capabilities["mcp"] as? [String: Any])?.isEmpty == true)
                #expect((context["skills"] as? [String])?.isEmpty == true)
                #expect(context["contextFiles"] as? Bool == false)
                #expect(context["sessionHistory"] as? Bool == true)
            default:
                #expect(capabilities["tools"] is NSNull)
                #expect(capabilities["plugins"] is NSNull)
                #expect(capabilities["mcp"] is NSNull)
                #expect(context["skills"] is NSNull)
            }
            let definition = requestCount == 1
                ? #"{"name":"Reviewer","capabilities":{"tools":["read","bash"],"ask":false,"subagent":false,"plugins":[],"mcp":{}},"context":{"skills":[],"contextFiles":false}}"#
                : #"{"name":"Reviewer"}"#
            return mockResponse(json: """
            {"agent":{"id":"agent-1","name":"Reviewer","status":"active","version":\(requestCount + 1),"definition":\(definition),"createdAt":1000,"updatedAt":4000}}
            """)
        }

        let named = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Reviewer",
            description: nil,
            instructions: nil,
            capabilities: AgentCapabilities(
                tools: ["read", "bash"], ask: false, notify: true, subagent: false, plugins: [], mcp: [:]
            ),
            context: AgentContext(skills: [], contextFiles: false, sessionHistory: true),
            model: nil,
            thinkingLevel: nil
        )
        #expect(named.definition.capabilities?.tools == ["read", "bash"])
        #expect(named.definition.capabilities?.plugins?.isEmpty == true)
        #expect(named.definition.capabilities?.mcp?.isEmpty == true)
        #expect(named.definition.context?.skills?.isEmpty == true)
        #expect(named.definition.context?.readsContextFiles == false)

        let followed = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Reviewer",
            description: nil,
            instructions: nil,
            capabilities: AgentCapabilities(ask: true, notify: true, subagent: true),
            context: AgentContext(),
            model: nil,
            thinkingLevel: nil
        )
        #expect(followed.definition.capabilities?.tools == nil)
        #expect(followed.definition.capabilities?.plugins == nil)
        #expect(followed.definition.capabilities?.mcp == nil)
        #expect(followed.definition.context?.skills == nil)
        #expect(requestCount == 2)
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
                #expect(constraints["requiredEngine"] as? String == "durable")
            } else if requestCount == 2 {
                // One constraint kept: the cleared ones go as null so the server's PATCH drops them.
                let constraints = try #require(json["launchConstraints"] as? [String: Any])
                #expect(constraints["requiredRuntime"] as? String == "sandbox")
                #expect(constraints["allowedWorkspaceIds"] is NSNull)
                #expect(constraints["requiredEngine"] is NSNull)
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
            capabilities: nil,
            context: nil,
            model: nil,
            thinkingLevel: nil,
            launchConstraints: AgentLaunchConstraints(
                allowedWorkspaceIds: ["research"],
                requiredRuntime: .sandbox,
                requiredEngine: .durable
            )
        )
        _ = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Research Scout",
            description: nil,
            instructions: nil,
            capabilities: nil,
            context: nil,
            model: nil,
            thinkingLevel: nil,
            launchConstraints: AgentLaunchConstraints(requiredRuntime: .sandbox),
            previouslyHadLaunchConstraints: true
        )
        _ = try await client.updateAgentNative(
            agentId: "agent-1",
            name: "Research Scout",
            description: nil,
            instructions: nil,
            capabilities: nil,
            context: nil,
            model: nil,
            thinkingLevel: nil,
            launchConstraints: nil,
            previouslyHadLaunchConstraints: true
        )
        #expect(requestCount == 3)
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

    @Test func agentLaunchDecodesDiscardedFailureWithoutSessionId() throws {
        let failure = try JSONDecoder().decode(AgentLaunchFailureResponse.self, from: Data("""
        {
          "error":"Research Scout can’t start in Oppi.",
          "code":"agent_workspace_incompatible",
          "receipt":{"accepted":false,"retryable":false,"reason":"agent_workspace_incompatible","promptDispatch":"not_sent"},
          "recovery":{"actions":["choose_workspace","edit_agent"],"agentId":"research-scout","workspaceId":"wrong-workspace","allowedWorkspaceIds":["research-workspace"]}
        }
        """.utf8))

        #expect(failure.sessionId == nil)
        #expect(failure.receipt.sessionId == nil)
        #expect(failure.recovery.actions == [.chooseWorkspace, .editAgent])
        #expect(failure.recovery.allowedWorkspaceIds == ["research-workspace"])
    }

    @Test func agentLaunchCanCreateSessionWithoutDispatchingPrompt() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/agents/agent-1/sessions")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(json["prompt"] == nil)
            #expect(json["idempotencyKey"] as? String == "stable-launch-key")
            let target = try #require(json["target"] as? [String: Any])
            #expect(target["workspaceId"] as? String == "ws-1")
            return mockResponse(status: 201, json: """
            {"receipt":{"accepted":true,"agentId":"agent-1","agentVersion":2,"sessionId":"session-1","promptDispatch":"not_sent"},"session":{"id":"session-1","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"cost":0,"runtime":"oppi","workspaceId":"ws-1"}}
            """)
        }

        let response = try await client.launchAgentSession(
            agentId: "agent-1",
            prompt: nil,
            workspaceId: "ws-1",
            idempotencyKey: "stable-launch-key"
        )

        #expect(response.receipt.promptDispatch == "not_sent")
        #expect(response.session?.id == "session-1")
    }

    @Test func agentLaunchEncodesWorktreeId() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/agents/agent-1/sessions")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            let target = try #require(json["target"] as? [String: Any])
            #expect(target["workspaceId"] as? String == "ws-1")
            #expect(target["worktreeId"] as? String == "wt_feature")
            return mockResponse(status: 201, json: """
            {"receipt":{"accepted":true,"agentId":"agent-1","agentVersion":2,"sessionId":"session-1","promptDispatch":"not_sent"},"session":{"id":"session-1","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"cost":0,"runtime":"oppi","workspaceId":"ws-1","worktreeId":"wt_feature"}}
            """)
        }

        let response = try await client.launchAgentSession(
            agentId: "agent-1",
            prompt: nil,
            workspaceId: "ws-1",
            worktreeId: "wt_feature",
            idempotencyKey: "stable-launch-key"
        )

        #expect(response.session?.id == "session-1")
        #expect(response.session?.worktreeId == "wt_feature")
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

    @Test func controlSessionCreatePostsPromptAndLaunchFields() async throws {
        let client = makeClient()
        defer { cleanup() }

        let prompt = ControlSessionStarterPrompt.make(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Reviewer"
        )
        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/control-sessions")
            let json = try #require(
                JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
            )
            #expect(Set(json.keys) == ["prompt", "name", "model", "thinking", "launchIdempotencyKey"])
            #expect(json["prompt"] as? String == prompt)
            #expect(json["name"] as? String == "Revise Reviewer")
            #expect(json["model"] as? String == "anthropic/claude-opus-4-8")
            #expect(json["thinking"] as? String == "high")
            #expect(json["launchIdempotencyKey"] as? String == "control-revision-request-1")
            return mockResponse(status: 201, json: """
            {"session":{"id":"control-1","name":"Revise Reviewer","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"engine":"durable","serverDurable":{"role":"control"}},"prompted":true}
            """)
        }

        let response = try await client.createControlSession(.init(
            prompt: prompt,
            name: "Revise Reviewer",
            model: "anthropic/claude-opus-4-8",
            thinking: .high,
            launchIdempotencyKey: "control-revision-request-1"
        ))

        #expect(response.session.usesControlRoutes)
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
    visible: Bool,
    type: UTType = .heic,
    frames: Int = 1,
    noise: Bool = false
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

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        type.identifier as CFString,
        frames,
        nil
    ) else { throw HEIFFixtureError.destination }
    for _ in 0..<frames {
        if noise {
            // Incompressible pixels, so a few frames pass the 1 MiB cap.
            context.data?.withMemoryRebound(to: UInt8.self, capacity: bytesPerRow * height) { pixels in
                for index in 0..<(bytesPerRow * height) { pixels[index] = UInt8.random(in: 0...255) | (index % 4 == 3 ? 0xFF : 0) }
            }
        }
        guard let image = context.makeImage() else { throw HEIFFixtureError.context }
        CGImageDestinationAddImage(destination, image, nil)
    }
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
        TestURLProtocol.install(in: configuration)
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

    /// An image icon: its artwork fills the tile, so the icon reads as the artwork's colour.
    private func storedImage(_ assetId: String) -> IconChoiceUIView.Content {
        .choice(.image(assetId: assetId), purpose: .agent, sandbox: false)
    }

    private func shownImage(_ icon: IconChoiceUIView) -> UIImage? {
        icon.subviews.compactMap { $0 as? UIImageView }.first?.image
    }

    private func solidImage(_ colour: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// What the icon shows, by colour: `EntityIcon` owns the drawing and rasters
    /// the artwork into the icon's box, so the view's image is the composited
    /// artwork, not the decoded instance the cache holds.
    private func shows(_ icon: IconChoiceUIView, mostly colour: UIColor) -> Bool {
        guard let shown = shownImage(icon), let average = averageColour(shown) else { return false }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return average.a > 0.5
            && abs(average.r - red) < 0.12
            && abs(average.g - green) < 0.12
            && abs(average.b - blue) < 0.12
    }

    private func averageColour(_ image: UIImage) -> AverageColour? {
        var pixels = [UInt8](repeating: 0, count: 4)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = image.cgImage else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return AverageColour(
            r: CGFloat(pixels[0]) / 255,
            g: CGFloat(pixels[1]) / 255,
            b: CGFloat(pixels[2]) / 255,
            a: CGFloat(pixels[3]) / 255
        )
    }

    /// Lets the icon's load task and any stale one run to completion.
    private func settle() async throws {
        for _ in 0..<5 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func rapidAssetReplacementCannotClearTheNewerResultWithAStaleFailure() async throws {
        let gate = IconAssetResultGate()
        let firstID = "ia_" + String(repeating: "A", count: 43)
        let secondID = "ia_" + String(repeating: "B", count: 43)
        let secondImage = solidImage(.systemPink)
        let cache = IconAssetCache(
            fetch: { try await gate.wait(for: $0) },
            decode: { data, _ in
                #expect(data == Data([2]))
                return (secondImage, NSObject())
            }
        )
        let icon = IconChoiceUIView(frameSize: 24)

        icon.apply(storedImage(firstID), assetCache: cache)
        for _ in 0..<50 where await gate.requestedIDs().isEmpty { await Task.yield() }
        icon.apply(storedImage(secondID), assetCache: cache)
        for _ in 0..<50 where !(await gate.requestedIDs()).contains(secondID) { await Task.yield() }
        await gate.succeed(secondID, data: Data([2]))
        for _ in 0..<50 where !shows(icon, mostly: .systemPink) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shows(icon, mostly: .systemPink), "the newer asset's artwork is what the icon shows")

        await gate.fail(firstID)
        try await settle()
        #expect(shows(icon, mostly: .systemPink), "a stale failure leaves the newer artwork alone")
    }

    @Test func serverCacheReplacementCannotAssignTheOldCachesResult() async throws {
        let assetID = "ia_" + String(repeating: "C", count: 43)
        let oldGate = IconAssetResultGate()
        let newGate = IconAssetResultGate()
        let oldImage = solidImage(.systemGreen)
        let newImage = solidImage(.systemPink)
        let oldCache = IconAssetCache(
            fetch: { try await oldGate.wait(for: $0) },
            decode: { _, _ in (oldImage, NSObject()) }
        )
        let newCache = IconAssetCache(
            fetch: { try await newGate.wait(for: $0) },
            decode: { _, _ in (newImage, NSObject()) }
        )
        let icon = IconChoiceUIView(frameSize: 24)

        icon.apply(storedImage(assetID), assetCache: oldCache)
        for _ in 0..<50 where await oldGate.requestedIDs().isEmpty { await Task.yield() }
        icon.apply(storedImage(assetID), assetCache: newCache)
        for _ in 0..<50 where await newGate.requestedIDs().isEmpty { await Task.yield() }
        await newGate.succeed(assetID, data: Data([2]))
        for _ in 0..<50 where !shows(icon, mostly: .systemPink) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shows(icon, mostly: .systemPink))

        await oldGate.succeed(assetID, data: Data([1]))
        try await settle()
        #expect(shows(icon, mostly: .systemPink), "the replaced cache's artwork never shows")
        #expect(!shows(icon, mostly: .systemGreen))
    }

    /// An animating view asks for an image's bytes while its first frame loads:
    /// one fetch serves both, and the bytes stay for the next view and the next
    /// draw size. A Genmoji's bytes only draw, so they are not kept.
    @Test func imageBytesShareTheDrawFetchAndStayButGenmojiBytesDoNot() async throws {
        let png = try imageIOHEIFFixture(width: 32, height: 32, visible: true, type: .png)
        let heic = try imageIOHEIFFixture(width: 32, height: 32, visible: true)
        for (data, expectedFetches) in [(png, 1), (heic, 4)] {
            let counter = IconAssetFetchCounter()
            let cache = IconAssetCache(fetch: { _ in
                await counter.increment()
                try await Task.sleep(for: .milliseconds(50))
                return data
            })
            let assetId = "ia_" + String(repeating: "F", count: 43)
            async let drawn = cache.image(assetId: assetId, size: 32)
            async let bytes = cache.data(assetId: assetId)
            _ = try await (drawn, bytes)
            _ = try await cache.data(assetId: assetId)
            _ = try await cache.data(assetId: assetId)
            _ = try await cache.image(assetId: assetId, size: 64)
            #expect(await counter.value() == expectedFetches)
        }
    }

    /// A cache keeps a failed asset failed, and a cleared cache (a reconnect)
    /// gives it another chance.
    @Test func aFailedAssetIsNotFetchedAgainUntilTheCacheIsCleared() async throws {
        let assetId = "ia_" + String(repeating: "E", count: 43)
        let counter = IconAssetFetchCounter()
        let cache = IconAssetCache(
            fetch: { _ in
                await counter.increment()
                throw APIError.server(status: 404, message: "no such icon")
            },
            decode: { _, _ in (decodedImage(), NSObject()) }
        )

        #expect(!cache.hasFailedLoad(assetId: assetId))
        _ = try? await cache.image(assetId: assetId, size: 32)
        #expect(cache.hasFailedLoad(assetId: assetId))
        #expect(await counter.value() == 1)

        cache.removeAll()
        #expect(!cache.hasFailedLoad(assetId: assetId), "a new connection retries the asset")
    }

    @Test func productionRemoteDecoderAcceptsVisibleGeneratedHEIF() throws {
        let data = try imageIOHEIFFixture(width: 64, height: 64, visible: true)
        let decoded = try IconAssetCache.decodeRemoteIcon(data: data, size: 32)

        #expect(decoded.image.size.width > 0)
        #expect(decoded.image.size.height > 0)
    }

    @Test func productionRemoteDecoderRejectsFormatsTheServerDoesNotStore() throws {
        let jpeg = try imageIOHEIFFixture(width: 64, height: 64, visible: true, type: .jpeg)
        #expect(throws: Error.self) {
            _ = try IconAssetCache.decodeRemoteIcon(data: jpeg, size: 32)
        }
    }

    @Test func productionRemoteDecoderRejectsTransparentBlankHEIF() throws {
        let data = try imageIOHEIFFixture(width: 64, height: 64, visible: false)

        #expect(throws: Error.self) {
            _ = try IconAssetCache.decodeRemoteIcon(data: data, size: 32)
        }
    }

    @Test func productionRemoteDecoderRejectsInvalidRenderSizes() throws {
        let data = try imageIOHEIFFixture(width: 64, height: 64, visible: true)

        for size in [CGFloat.zero, -1, 513, .infinity, .nan] {
            #expect(throws: Error.self) {
                _ = try IconAssetCache.decodeRemoteIcon(data: data, size: size)
            }
        }
    }

    @Test func productionRemoteDecoderRejectsOversizedDimensions() throws {
        let data = try imageIOHEIFFixture(width: 4_097, height: 1, visible: true)

        #expect(throws: Error.self) {
            _ = try IconAssetCache.decodeRemoteIcon(data: data, size: 32)
        }
    }

    @Test func productionRemoteDecoderRejectsMalformedAndTruncatedHEIF() throws {
        let valid = try imageIOHEIFFixture(width: 64, height: 64, visible: true)
        for data in [Data([1, 2, 3, 4]), Data(valid.prefix(valid.count / 2))] {
            #expect(throws: Error.self) {
                _ = try IconAssetCache.decodeRemoteIcon(data: data, size: 32)
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

        #expect(daily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("Every day · 8:00"))
        #expect(twiceDaily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("9:00"))
        #expect(twiceDaily.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("5:00"))
        #expect(weekly.scheduleScreenTiming(locale: Locale(identifier: "en_US")).contains("Mondays · 9:30"))
    }

    @Test func advancedSchedulesHideImplementationSyntax() {
        let custom = AgentScheduleTrigger.cron(expression: "0 8 1 * *", timeZone: "UTC")
        let interval = AgentScheduleTrigger.every(intervalMs: 7_200_000, timeZone: "UTC")

        #expect(custom.scheduleScreenTiming(locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "\u{202F}", with: " ") == "Monthly on the 1st · 8:00 AM")
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

    @Test func advancedCronCanBeEditedDirectlyWithItsTimeZone() {
        let custom = AgentScheduleTrigger.cron(
            expression: "0 8 1 * *",
            timeZone: "UTC"
        )
        var draft = ScheduleTriggerDraft(trigger: custom)

        #expect(draft.cadence == .custom)
        #expect(draft.customExpression == "0 8 1 * *")
        #expect(draft.makeTrigger() == custom)

        draft.customExpression = "*/15 9-17 * * 1-5"
        draft.timeZone = "America/Los_Angeles"

        #expect(draft.canSave)
        #expect(
            draft.makeTrigger() == .cron(
                expression: "*/15 9-17 * * 1-5",
                timeZone: "America/Los_Angeles"
            )
        )
    }

    @Test func customCronRequiresFiveFieldsOrSixWithSeconds() {
        var draft = ScheduleTriggerDraft(
            trigger: .cron(expression: "0 8 1 * *", timeZone: "UTC")
        )

        draft.customExpression = "not a cron"
        #expect(!draft.canSave)
        #expect(draft.customExpressionError != nil)

        draft.customExpression = "99 25 * * *"
        #expect(!draft.canSave)
        #expect(draft.customExpressionError != nil)

        for invalidSeconds in ["30", "*", "*/1"] {
            draft.customExpression = "\(invalidSeconds) */15 9-17 * * 1-5"
            #expect(!draft.canSave)
            #expect(draft.customExpressionError != nil)
        }

        draft.customExpression = "0 */15 9-17 * * 1-5"
        #expect(draft.canSave)
        #expect(draft.customExpressionError == nil)
        #expect(draft.customFieldLabels.hasPrefix("second"))

        draft.customExpression = "+1 9 * * 1-5"
        #expect(!draft.canSave)
    }

    @Test func advancedCronIsRetainedWhenSwitchingCadenceBeforeSaving() {
        let custom = AgentScheduleTrigger.cron(
            expression: "0 8 1 * *",
            timeZone: "UTC"
        )
        var draft = ScheduleTriggerDraft(trigger: custom)

        draft.cadence = .daily
        #expect(draft.makeTrigger()?.scheduleScreenDays(locale: Locale(identifier: "en_US")) == "Every day")

        draft.cadence = .custom
        #expect(draft.makeTrigger() == custom)
    }

    @Test func zeroSecondsCronStaysCustomAndRoundTripsWithoutDroppingItsField() {
        let custom = AgentScheduleTrigger.cron(
            expression: "0 0 8 * * *",
            timeZone: "UTC"
        )
        let draft = ScheduleTriggerDraft(trigger: custom)

        #expect(draft.cadence == .custom)
        #expect(draft.customFieldLabels.hasPrefix("second"))
        #expect(draft.makeTrigger() == custom)
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
    @Test func createPromptCarriesWorkspaceAndRequestWithoutTargetLines() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .schedules,
            intent: .create,
            targetId: "ignored",
            targetName: "ignored",
            workspaceId: "ws-7",
            workspaceName: "Dream",
            userRequest: "  Brief me on coaching trends every Monday morning.\n"
        )

        #expect(prompt == """
        Help the user create an Oppi Schedule.
        Canonical workspace ID: ws-7
        Canonical workspace name: Dream

        User request:
        Brief me on coaching trends every Monday morning.
        """)
    }

    @Test func revisePromptNamesTheCanonicalTargetAndOmitsEmptyContext() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Reviewer",
            userRequest: "  \n"
        )

        #expect(prompt == """
        Help the user revise an Oppi saved Agent.
        Canonical target ID: agent-1
        Canonical target name: Reviewer
        """)
    }

    @Test(arguments: [
        ControlSessionDomain.agents, .extensions, .schedules, .skills, .themes, .workspaces,
    ])
    func hostFileLineAppearsForEveryDomainWhenAPathIsGiven(domain: ControlSessionDomain) {
        let path = "/Users/alex/.pi/agent/thing/FILE.md"
        let withPath = ControlSessionStarterPrompt.make(
            domain: domain,
            intent: .revise,
            targetId: "id-1",
            targetName: "Thing",
            targetPath: path
        )
        let withoutPath = ControlSessionStarterPrompt.make(
            domain: domain,
            intent: .revise,
            targetId: "id-1",
            targetName: "Thing"
        )

        #expect(withPath.contains("Selected existing host file: \(path)"))
        #expect(!withoutPath.contains("Selected existing host file"))
    }
}

@Suite("Icon image import")
@MainActor
struct IconImageImportTests {
    @Test func aStillImageOfAnyDecodableFormatBecomesA128PixelPNG() throws {
        for type in [UTType.jpeg, .heic, .png] {
            let photo = try imageIOHEIFFixture(width: 900, height: 600, visible: true, type: type)
            let prepared = try IconImageImport.prepare(photo)
            let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier, "\(type)")
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 128, "\(type)")
            // 600 × 128 / 900 = 85.3; ImageIO's rounding and HEVC's even sizes vary it.
            #expect((83...86).contains(properties[kCGImagePropertyPixelHeight] as? Int ?? 0), "\(type)")
        }
    }

    @Test func anAnimatedImageWithinTheCapIsKeptAsUploaded() throws {
        let gif = try imageIOHEIFFixture(width: 200, height: 200, visible: true, type: .gif, frames: 4)
        #expect(try IconImageImport.prepare(gif) == gif)
    }

    @Test func anAnimatedImageWiderThanTheServerAllowsIsRefused() throws {
        let gif = try imageIOHEIFFixture(width: 1_100, height: 8, visible: true, type: .gif, frames: 2)
        #expect(gif.count <= IconImageImport.maxUploadBytes)
        #expect(throws: IconImageImport.Failure.animatedTooLarge) {
            _ = try IconImageImport.prepare(gif)
        }
    }

    @Test func anImageWhoseFirstFrameIsBlankIsRefused() throws {
        let gif = try imageIOHEIFFixture(width: 64, height: 64, visible: false, type: .gif, frames: 2)
        #expect(throws: IconImageImport.Failure.blankFirstFrame) {
            _ = try IconImageImport.prepare(gif)
        }
    }

    @Test func anAnimatedImageOverTheCapIsRefused() throws {
        let gif = try imageIOHEIFFixture(width: 400, height: 400, visible: true, type: .gif, frames: 12, noise: true)
        #expect(gif.count > IconImageImport.maxUploadBytes)
        #expect(throws: IconImageImport.Failure.animatedTooLarge) {
            _ = try IconImageImport.prepare(gif)
        }
    }

    @Test func bytesImageIOCannotDecodeAreRefused() {
        for data in [Data(), Data("not an image".utf8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])] {
            #expect(throws: IconImageImport.Failure.undecodable) {
                _ = try IconImageImport.prepare(data)
            }
        }
    }
}
