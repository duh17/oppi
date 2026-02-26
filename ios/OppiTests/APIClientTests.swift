import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_unwrapping non_optional_string_data_conversion

// MARK: - Mock URL Protocol

/// Backward-compatible alias. Shared implementation lives in Support/TestDoubles.swift.
typealias MockURLProtocol = TestURLProtocol

@Suite("APIClient", .serialized)
struct APIClientTests {

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func cleanup() {
        MockURLProtocol.handler = nil
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
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(read))
        }

        return data
    }

    // MARK: - Health

    @Test func healthReturnsTrue() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: "{\"status\":\"ok\"}")
        }

        let result = try await client.health()
        #expect(result == true)
    }

    @Test func healthReturnsFalseOnNon200() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 503, json: "{\"error\":\"down\"}")
        }

        let result = try await client.health()
        #expect(result == false)
    }

    // MARK: - me

    @Test func meDecodesUser() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: "{\"user\":\"u1\",\"name\":\"Chen\"}")
        }

        let user = try await client.me()
        #expect(user.user == "u1")
        #expect(user.name == "Chen")
    }

    // MARK: - Sessions

    @Test func listSessions() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/workspaces":
                return self.mockResponse(json: """
                {"workspaces":[
                    {"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0},
                    {"id":"w2","name":"Ops","skills":[],"createdAt":0,"updatedAt":0}
                ]}
                """)

            case "/workspaces/w1/sessions":
                return self.mockResponse(json: """
                {"sessions":[
                    {"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}
                ]}
                """)

            case "/workspaces/w2/sessions":
                return self.mockResponse(json: """
                {"sessions":[
                    {"id":"s2","workspaceId":"w2","status":"busy","createdAt":0,"lastActivity":2000,"messageCount":5,"tokens":{"input":100,"output":50},"cost":0.01}
                ]}
                """)

            default:
                Issue.record("Unexpected path: \(request.url?.path ?? "nil")")
                return self.mockResponse(status: 404, json: "{\"error\":\"not found\"}")
            }
        }

        let sessions = try await client.listSessions()
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "s2")
        #expect(sessions[1].id == "s1")
        #expect(sessions[0].status == .busy)
    }

    @Test func createSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/workspaces":
                return self.mockResponse(json: """
                {"workspaces":[{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}]}
                """)

            case "/workspaces/w1/sessions":
                #expect(request.httpMethod == "POST")
                return self.mockResponse(json: """
                {"session":{"id":"new","workspaceId":"w1","status":"starting","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
                """)

            default:
                Issue.record("Unexpected path: \(request.url?.path ?? "nil")")
                return self.mockResponse(status: 404, json: "{\"error\":\"not found\"}")
            }
        }

        let session = try await client.createSession(name: "Test", model: "claude-sonnet-4-20250514")
        #expect(session.id == "new")
        #expect(session.status == .starting)
        #expect(session.workspaceId == "w1")
    }

    @Test func forkWorkspaceSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/w1/sessions/s1/fork")

            let body = self.requestBodyData(request)
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(json["entryId"] as? String == "entry-123")
                #expect(json["name"] as? String == "Fork: feature branch")
            } else {
                Issue.record("Expected JSON body")
            }

            return self.mockResponse(json: """
            {"session":{"id":"forked-1","workspaceId":"w1","name":"Fork: feature branch","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
            """)
        }

        let session = try await client.forkWorkspaceSession(
            workspaceId: "w1",
            sessionId: "s1",
            entryId: "entry-123",
            name: "Fork: feature branch"
        )

        #expect(session.id == "forked-1")
        #expect(session.workspaceId == "w1")
        #expect(session.name == "Fork: feature branch")
    }

    @Test func getSessionWithTrace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1")
            #expect(request.url?.query == "view=context")
            return self.mockResponse(json: """
            {
                "session":{"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"e1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"Hello"}
                ]
            }
            """)
        }

        let (session, trace) = try await client.getSession(workspaceId: "w1", id: "s1")
        #expect(session.id == "s1")
        #expect(trace.count == 1)
        #expect(trace[0].type == .user)
    }

    @Test func getSessionWithFullTraceViewUsesQuery() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1")
            #expect(request.url?.query == "view=full")
            return self.mockResponse(json: """
            {
                "session":{"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
                "trace":[
                    {"id":"e1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"Hello"}
                ]
            }
            """)
        }

        let (_, trace) = try await client.getSession(workspaceId: "w1", id: "s1", traceView: .full)
        #expect(trace.count == 1)
    }

    @Test func getSessionEventsDecodesSequencedCatchUp() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/workspaces/w1/sessions/s1/events") == true)
            #expect(request.url?.query == "since=5")
            return self.mockResponse(json: """
            {
              "events": [
                {"type":"agent_start","seq":6},
                {"type":"message_end","role":"assistant","content":"Recovered","seq":7},
                {"type":"agent_end","seq":8}
              ],
              "currentSeq": 8,
              "session": {"id":"s1","workspaceId":"w1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":1,"tokens":{"input":10,"output":5},"cost":0},
              "catchUpComplete": true
            }
            """)
        }

        let response = try await client.getSessionEvents(workspaceId: "w1", id: "s1", since: 5)
        #expect(response.currentSeq == 8)
        #expect(response.catchUpComplete)
        #expect(response.events.count == 3)
        #expect(response.events.map(\.seq) == [6, 7, 8])

        guard case .messageEnd(_, let content) = response.events[1].message else {
            Issue.record("Expected message_end in second event")
            return
        }
        #expect(content == "Recovered")
    }

    @Test func stopSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/sessions/s1/stop")
            return self.mockResponse(json: """
            {"session":{"id":"s1","workspaceId":"w1","status":"stopped","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
            """)
        }

        let session = try await client.stopSession(workspaceId: "w1", id: "s1")
        #expect(session.status == .stopped)
    }

    @Test func deleteSession() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/workspaces/w1/sessions/s1")
            return self.mockResponse(json: "{}")
        }

        try await client.deleteSession(workspaceId: "w1", id: "s1")
    }

    // getSessionTrace removed — merged into getSession.

    // MARK: - Models

    @Test func listModels() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"models":[{"id":"claude-sonnet-4-20250514","name":"Claude Sonnet 4","provider":"anthropic","contextWindow":200000}]}
            """)
        }

        let models = try await client.listModels()
        #expect(models.count == 1)
        #expect(models[0].id == "claude-sonnet-4-20250514")
    }

    // MARK: - Workspaces

    @Test func listWorkspaces() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"workspaces":[{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}]}
            """)
        }

        let workspaces = try await client.listWorkspaces()
        #expect(workspaces.count == 1)
        #expect(workspaces[0].name == "Dev")
    }

    @Test func getWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"workspace":{"id":"w1","name":"Dev","skills":["fetch"],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.getWorkspace(id: "w1")
        #expect(ws.skills == ["fetch"])
    }

    @Test func createWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            return self.mockResponse(json: """
            {"workspace":{"id":"w2","name":"New","skills":["searxng"],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.createWorkspace(CreateWorkspaceRequest(name: "New", skills: ["searxng"]))
        #expect(ws.id == "w2")
    }

    @Test func listPolicyRulesDecodesResponse() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/policy/rules")
            return self.mockResponse(json: """
            {
              "rules": [
                {
                  "id":"r1",
                  "decision":"allow",
                  "tool":"bash",
                  "pattern":"git status*",
                  "executable":"git",
                  "scope":"global",
                  "source":"learned",
                  "label":"Allow git status",
                  "createdAt":1700000000000
                }
              ]
            }
            """)
        }

        let rules = try await client.listPolicyRules()
        #expect(rules.count == 1)
        #expect(rules[0].id == "r1")
        #expect(rules[0].decision == "allow")
        #expect(rules[0].scope == "global")
    }

    @Test func patchPolicyRuleSendsPatchAndDecodesResponse() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/policy/rules/r1")

            let bodyData = self.requestBodyData(request)
            guard
                let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                let decision = json["decision"] as? String,
                let label = json["label"] as? String
            else {
                Issue.record("Expected JSON patch body")
                return self.mockResponse(status: 400, json: "{\"error\":\"bad request\"}")
            }

            #expect(decision == "deny")
            #expect(label == "Block git push")

            return self.mockResponse(json: """
            {
              "rule": {
                "id":"r1",
                "decision":"deny",
                "tool":"bash",
                "pattern":"git push*",
                "scope":"workspace",
                "workspaceId":"w1",
                "source":"learned",
                "label":"Block git push",
                "createdAt":1700000000000
              }
            }
            """)
        }

        let updated = try await client.patchPolicyRule(
            ruleId: "r1",
            request: PolicyRulePatchRequest(
                decision: "deny",
                label: "Block git push",
                tool: "bash",
                pattern: "git push*",
                executable: nil
            )
        )

        #expect(updated.id == "r1")
        #expect(updated.decision == "deny")
        #expect(updated.scope == "workspace")
    }

    @Test func deletePolicyRuleUsesDeleteRoute() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/policy/rules/r1")
            return self.mockResponse(json: "{\"ok\":true,\"deleted\":\"r1\"}")
        }

        try await client.deletePolicyRule(ruleId: "r1")
    }

    @Test func listPolicyAuditDecodesResponse() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/policy/audit")
            #expect(request.url?.query?.contains("workspaceId=w1") == true)
            return self.mockResponse(json: """
            {
              "entries": [
                {
                  "id":"a1",
                  "timestamp":1700000000000,
                  "sessionId":"s1",
                  "workspaceId":"w1",

                  "tool":"bash",
                  "displaySummary":"git push",
                  "decision":"allow",
                  "resolvedBy":"user",
                  "layer":"user_response"
                }
              ]
            }
            """)
        }

        let entries = try await client.listPolicyAudit(workspaceId: "w1", limit: 25)
        #expect(entries.count == 1)
        #expect(entries[0].id == "a1")
        #expect(entries[0].workspaceId == "w1")
    }

    @Test func updateWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            return self.mockResponse(json: """
            {"workspace":{"id":"w1","name":"Updated","skills":[],"createdAt":0,"updatedAt":0}}
            """)
        }

        let ws = try await client.updateWorkspace(id: "w1", UpdateWorkspaceRequest(name: "Updated"))
        #expect(ws.name == "Updated")
    }

    @Test func deleteWorkspace() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return self.mockResponse(json: "{}")
        }

        try await client.deleteWorkspace(id: "w1")
    }

    @Test func getWorkspaceGraphBuildsQueryAndDecodesGraphs() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/graph")

            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            #expect(queryItems.contains(where: { $0.name == "sessionId" && $0.value == "s1" }))
            #expect(queryItems.contains(where: { $0.name == "include" && $0.value == "entry" }))
            #expect(queryItems.contains(where: { $0.name == "entrySessionId" && $0.value == "pi-child" }))
            #expect(queryItems.contains(where: { $0.name == "includePaths" && $0.value == "true" }))

            return self.mockResponse(json: """
            {
              "workspaceId": "w1",
              "generatedAt": 1700000000000,
              "current": {
                "sessionId": "s1",
                "nodeId": "pi-child"
              },
              "sessionGraph": {
                "nodes": [
                  {
                    "id": "pi-root",
                    "createdAt": 1700000000000,
                    "workspaceId": "w1",
                    "attachedSessionIds": ["s0"],
                    "activeSessionIds": []
                  },
                  {
                    "id": "pi-child",
                    "createdAt": 1700000100000,
                    "workspaceId": "w1",
                    "parentId": "pi-root",
                    "attachedSessionIds": ["s1"],
                    "activeSessionIds": ["s1"],
                    "sessionFile": "/tmp/child.jsonl",
                    "parentSessionFile": "/tmp/root.jsonl"
                  }
                ],
                "edges": [
                  {"from": "pi-root", "to": "pi-child", "type": "fork"}
                ],
                "roots": ["pi-root"]
              },
              "entryGraph": {
                "piSessionId": "pi-child",
                "nodes": [
                  {"id": "m1", "type": "model_change", "timestamp": 1700000100000},
                  {"id": "u1", "type": "message", "parentId": "m1", "timestamp": 1700000100500, "role": "user", "preview": "Try branch B"}
                ],
                "edges": [
                  {"from": "m1", "to": "u1", "type": "parent"}
                ],
                "rootEntryId": "m1",
                "leafEntryId": "u1"
              }
            }
            """)
        }

        let graph = try await client.getWorkspaceGraph(
            workspaceId: "w1",
            sessionId: "s1",
            includeEntryGraph: true,
            entrySessionId: "pi-child",
            includePaths: true
        )

        #expect(graph.workspaceId == "w1")
        #expect(graph.current?.sessionId == "s1")
        #expect(graph.current?.nodeId == "pi-child")
        #expect(graph.sessionGraph.nodes.count == 2)
        #expect(graph.sessionGraph.edges.first?.type == .fork)
        #expect(graph.sessionGraph.roots == ["pi-root"])

        let child = graph.sessionGraph.nodes.first(where: { $0.id == "pi-child" })
        #expect(child?.parentId == "pi-root")
        #expect(child?.activeSessionIds == ["s1"])
        #expect(child?.sessionFile == "/tmp/child.jsonl")

        #expect(graph.entryGraph?.piSessionId == "pi-child")
        #expect(graph.entryGraph?.nodes.count == 2)
        #expect(graph.entryGraph?.nodes.last?.role == "user")
        #expect(graph.entryGraph?.nodes.last?.preview == "Try branch B")
        #expect(graph.entryGraph?.edges.first?.type == .parent)
        #expect(graph.entryGraph?.leafEntryId == "u1")
    }

    // MARK: - Skills

    @Test func listSkills() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"skills":[{"name":"fetch","description":"Fetch URLs","path":"/path"}]}
            """)
        }

        let skills = try await client.listSkills()
        #expect(skills.count == 1)
        #expect(skills[0].name == "fetch")
    }

    @Test func rescanSkills() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(json: """
            {"skills":[]}
            """)
        }

        let skills = try await client.rescanSkills()
        #expect(skills.isEmpty)
    }

    @Test func listExtensions() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/extensions")
            return self.mockResponse(json: """
            {"extensions":[{"name":"memory","path":"/Users/me/.pi/agent/extensions/memory.ts","kind":"file"}]}
            """)
        }

        let extensions = try await client.listExtensions()
        #expect(extensions.count == 1)
        #expect(extensions[0].name == "memory")
        #expect(extensions[0].kind == "file")
    }

    // MARK: - Files + Query Paths

    @Test func getSkillFileUsesQueryString() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let pathQuery = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(request.url?.path == "/skills/fetch/file")
            #expect(pathQuery == "nested dir/SKILL.md")
            #expect(request.url?.absoluteString.contains("%3Fpath=") == false)
            return self.mockResponse(json: "{\"content\":\"ok\"}")
        }

        let content = try await client.getSkillFile(name: "fetch", path: "nested dir/SKILL.md")
        #expect(content == "ok")
    }

    @Test func getSessionFileUsesQueryString() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let pathQuery = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(request.url?.path == "/workspaces/w1/sessions/s1/files")
            #expect(pathQuery == "/tmp/main.swift")
            #expect(request.url?.absoluteString.contains("%3Fpath=") == false)

            let body = "print(\"hello\")".data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (body, response)
        }

        let content = try await client.getSessionFile(workspaceId: "w1", sessionId: "s1", path: "/tmp/main.swift")
        #expect(content == "print(\"hello\")")
    }

    @Test func getSessionOverallDiffUsesWorkspaceScopedEndpointWhenWorkspaceProvided() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let pathQuery = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(request.url?.path == "/workspaces/w1/sessions/s1/overall-diff")
            #expect(pathQuery == "Sources/App.swift")

            return self.mockResponse(json: """
            {
              "path": "Sources/App.swift",
              "revisionCount": 3,
              "baselineText": "old",
              "currentText": "new",
              "diffLines": [
                { "kind": "removed", "text": "old" },
                { "kind": "added", "text": "new" }
              ],
              "addedLines": 10,
              "removedLines": 4,
              "cacheKey": "s1:Sources/App.swift:tc-3"
            }
            """)
        }

        let response = try await client.getSessionOverallDiff(
            sessionId: "s1",
            workspaceId: "w1",
            path: "Sources/App.swift"
        )

        #expect(response.path == "Sources/App.swift")
        #expect(response.revisionCount == 3)
        #expect(response.baselineText == "old")
        #expect(response.currentText == "new")
        #expect(response.diffLines.count == 2)
        #expect(response.diffLines[0].kind == .removed)
        #expect(response.diffLines[0].text == "old")
        #expect(response.diffLines[1].kind == .added)
        #expect(response.diffLines[1].text == "new")
        #expect(response.addedLines == 10)
        #expect(response.removedLines == 4)
        #expect(response.cacheKey == "s1:Sources/App.swift:tc-3")
    }

    // MARK: - Permissions

    @Test func respondToPermissionUsesRestEndpoint() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/permissions/perm-123/respond")

            let body = self.requestBodyData(request)
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                Issue.record("Expected JSON body")
                return self.mockResponse(status: 400, json: "{\"error\":\"bad request\"}")
            }

            #expect(json["action"] as? String == "allow")
            #expect(json["scope"] as? String == "once")
            #expect(json["expiresInMs"] as? Int == nil)

            return self.mockResponse(json: "{\"ok\":true}")
        }

        try await client.respondToPermission(id: "perm-123", action: .allow)
    }

    // MARK: - Device Token

    @Test func registerDeviceToken() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path.hasSuffix("/me/device-token") == true)
            return self.mockResponse(json: "{}")
        }

        try await client.registerDeviceToken("abc123")
    }

    @Test func unregisterDeviceToken() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return self.mockResponse(json: "{}")
        }

        try await client.unregisterDeviceToken("abc123")
    }

    // MARK: - Error handling

    @Test func serverErrorExtractsMessage() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 401, json: "{\"error\":\"Invalid token\"}")
        }

        do {
            _ = try await client.me()
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .server(let status, let msg) = error else {
                Issue.record("Expected server error")
                return
            }
            #expect(status == 401)
            #expect(msg == "Invalid token")
        }
    }

    @Test func serverErrorFallsBackToBody() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { _ in
            self.mockResponse(status: 500, json: "raw error text")
        }

        do {
            _ = try await client.me()
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .server(let status, let msg) = error else {
                Issue.record("Expected server error")
                return
            }
            #expect(status == 500)
            #expect(msg == "raw error text")
        }
    }

    @Test func authorizationHeaderSet() async throws {
        let client = makeClient()
        defer { cleanup() }

        MockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            #expect(auth == "Bearer sk_test")
            return self.mockResponse(json: "{\"user\":\"u1\",\"name\":\"Test\"}")
        }

        _ = try await client.me()
    }

    // MARK: - APIError descriptions

    @Test func apiErrorDescriptions() {
        let invalid = APIError.invalidResponse
        #expect(invalid.errorDescription?.contains("Invalid") == true)

        let server = APIError.server(status: 500, message: "Internal error")
        #expect(server.errorDescription?.contains("500") == true)
        #expect(server.errorDescription?.contains("Internal error") == true)
    }
}
