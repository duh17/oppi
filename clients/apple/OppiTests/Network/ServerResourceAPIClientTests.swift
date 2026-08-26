import Foundation
import Testing
@testable import Oppi

@Suite("Server resource API client", .serialized)
struct ServerResourceAPIClientTests {
    @Test func listSkillsUsesGlobalRouteWithoutCwdAndDecodesCatalog() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/server/resources/skills")
            #expect(request.url?.query == nil)
            return mockResponse(json: """
            {"skills":[{"id":"skill_abc","name":"Release","description":"Review releases.","provenance":{"kind":"package","label":"Configured package source"},"packageName":"@scope/review-tools","state":"enabled","warnings":[],"editable":false}]}
            """)
        }

        let skills = try await client.listServerSkills()

        #expect(skills.map(\.id) == ["skill_abc"])
        #expect(skills.first?.state == .enabled)
        #expect(skills.first?.packageName == "@scope/review-tools")
    }

    @Test func skillDetailAndFileSafelyEncodeOpaqueIDAndFilePath() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        let resourceID = "skill a/b?c"
        let filePath = "nested dir/ü?notes.md"
        var requestCount = 0

        TestURLProtocol.handler = { request in
            requestCount += 1
            let url = try #require(request.url)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if requestCount == 1 {
                #expect(components?.percentEncodedPath == "/server/resources/skills/skill%20a%2Fb%3Fc")
                return mockResponse(json: """
                {"summary":{"id":"skill a/b?c","name":"Release","description":"Review releases.","provenance":{"kind":"piAgent","label":"~/.pi/agent/skills"},"state":"enabled","warnings":[],"editable":true},"skillMarkdown":"# Release","files":[]}
                """)
            }

            #expect(components?.percentEncodedPath == "/server/resources/skills/skill%20a%2Fb%3Fc/file")
            #expect(components?.queryItems?.first(where: { $0.name == "path" })?.value == filePath)
            return mockResponse(json: #"{"content":"notes"}"#)
        }

        let detail = try await client.getServerSkill(id: resourceID)
        let content = try await client.getServerSkillFile(id: resourceID, path: filePath)

        #expect(detail.summary.id == resourceID)
        #expect(content == "notes")
        #expect(requestCount == 2)
    }

    @Test func normalEnablePutsBooleanAndDecodesAuthoritativeSummaries() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        var requestCount = 0

        TestURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.httpMethod == "PUT")
            let body = try JSONDecoder().decode(EnabledRequest.self, from: requestBodyData(request))
            #expect(body.enabled)

            if requestCount == 1 {
                #expect(request.url?.path == "/server/resources/skills/skill_abc/enabled")
                return mockResponse(json: """
                {"id":"skill_abc","name":"Release","description":"Review releases.","provenance":{"kind":"piAgent","label":"~/.pi/agent/skills"},"state":"enabled","warnings":[],"editable":true}
                """)
            }

            #expect(request.url?.path == "/server/resources/extensions/extension_abc/enabled")
            return mockResponse(json: """
            {"id":"extension_abc","name":"Review helpers","kind":"file","provenance":{"kind":"userSettings","label":"Pi user settings"},"state":"on","warnings":[],"isRemovable":false}
            """)
        }

        let skill = try await client.setServerSkillEnabled(id: "skill_abc", enabled: true)
        let serverExtension = try await client.setServerExtensionEnabled(id: "extension_abc", enabled: true)

        #expect(skill.state == .enabled)
        #expect(serverExtension.state == .on)
        #expect(requestCount == 2)
    }

    @Test func extensionsCatalogAndDetailUseGlobalRoutes() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        var requestCount = 0

        TestURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == "/server/resources/extensions")
                #expect(request.url?.query == nil)
                return mockResponse(json: """
                {"extensions":[{"id":"extension_abc","name":"Review","kind":"file","provenance":{"kind":"userSettings","label":"Pi user settings"},"state":"on","warnings":[],"isRemovable":false}],"builtInTools":[{"name":"read","description":"Read files","defaultEnabled":true},{"name":"grep","description":"Search files","defaultEnabled":false}]}
                """)
            }

            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/server/resources/extensions/extension_abc")
            return mockResponse(json: """
            {"summary":{"id":"extension_abc","name":"Review","kind":"file","provenance":{"kind":"userSettings","label":"Pi user settings"},"state":"on","warnings":[],"isRemovable":false,"contributedTools":["review"]},"contributedTools":["review"],"contributedToolDetails":[{"name":"review","description":"Review changes"}]}
            """)
        }

        let catalog = try await client.listServerExtensions()
        let detail = try await client.getServerExtension(id: "extension_abc")

        #expect(catalog.extensions.map(\.id) == ["extension_abc"])
        #expect(catalog.builtInTools.map(\.name) == ["read", "grep"])
        #expect(catalog.builtInTools.first?.defaultEnabled == true)
        #expect(detail.summary.kind == .file)
        #expect(detail.contributedToolDetails?.first?.description == "Review changes")
    }

    @Test func agentToolInspectionUsesExplicitExtensionDetailQuery() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/server/resources/extensions/extension_abc")
            #expect(request.url?.query == "agentTools=true")
            return mockResponse(json: """
            {"summary":{"id":"extension_abc","name":"Search","kind":"file","provenance":{"kind":"piAgent","label":"~/.pi/agent/extensions"},"state":"off","warnings":[],"isRemovable":false,"contributedTools":["search"]},"contributedTools":["search"],"contributedToolDetails":[{"name":"search","description":"Search files"}]}
            """)
        }

        let detail = try await client.inspectAgentExtensionTools(id: "extension_abc")
        #expect(detail.contributedTools == ["search"])
    }

    @Test func mobileOutputGuideUsesDedicatedCASRoute() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        var requestCount = 0

        TestURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.url?.path == "/server/mobile-output-guide")
            if requestCount == 1 {
                #expect(request.httpMethod == "GET")
                return mockResponse(json: #"{"enabled":false,"revision":7}"#)
            }

            #expect(request.httpMethod == "PUT")
            let body = try JSONDecoder().decode(MobileOutputGuideRequest.self, from: requestBodyData(request))
            #expect(body.enabled)
            #expect(body.baseRevision == 7)
            return mockResponse(json: #"{"enabled":true,"revision":8}"#)
        }

        let current = try await client.getMobileOutputGuideConfiguration()
        let updated = try await client.setMobileOutputGuideConfiguration(
            enabled: true,
            baseRevision: current.revision
        )

        #expect(current == MobileOutputGuideConfiguration(enabled: false, revision: 7))
        #expect(updated == MobileOutputGuideConfiguration(enabled: true, revision: 8))
        #expect(requestCount == 2)
    }

    @Test func piSystemPromptAndDefaultToolsUseGlobalResourceRoutes() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        var requestCount = 0

        TestURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == "/server/resources/pi/system-prompt")
                #expect(request.url?.query == nil)
                return mockResponse(json: """
                {"source":"file","path":"~/.pi/agent/SYSTEM.md","resolvedPath":"/Users/test/.pi/agent/SYSTEM.md","content":"# Custom"}
                """)
            }
            if requestCount == 2 {
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == "/server/resources/pi/default-tools")
                return mockResponse(json: #"{"defaultTools":null}"#)
            }
            if requestCount == 3 {
                #expect(request.httpMethod == "PUT")
                #expect(request.url?.path == "/server/resources/pi/default-tools")
                let body = try JSONDecoder().decode(PiDefaultToolsRequest.self, from: requestBodyData(request))
                #expect(body.defaultTools == ["read", "grep"])
                return mockResponse(json: #"{"defaultTools":["read","grep"]}"#)
            }

            #expect(request.httpMethod == "PUT")
            let body = try JSONDecoder().decode(PiDefaultToolsRequest.self, from: requestBodyData(request))
            #expect(body.defaultTools == nil)
            let object = try JSONSerialization.jsonObject(with: requestBodyData(request))
            let json = try #require(object as? [String: Any])
            #expect(json["defaultTools"] is NSNull)
            return mockResponse(json: #"{"defaultTools":null}"#)
        }

        let prompt = try await client.getPiSystemPrompt()
        let inherited = try await client.getPiDefaultTools()
        let exact = try await client.setPiDefaultTools(["read", "grep"])
        let omitted = try await client.setPiDefaultTools(nil)

        #expect(prompt.source == .file)
        #expect(prompt.path == "~/.pi/agent/SYSTEM.md")
        #expect(prompt.content == "# Custom")
        #expect(inherited.defaultTools == nil)
        #expect(exact.defaultTools == ["read", "grep"])
        #expect(omitted.defaultTools == nil)
        #expect(requestCount == 4)
    }

    @Test func mobileOutputGuideRevisionConflictUsesExistingAPIErrorConvention() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            mockResponse(status: 409, json: """
            {"error":"Mobile Output Guide setting changed","code":"revision_conflict","current":{"enabled":false,"revision":8}}
            """)
        }

        do {
            _ = try await client.setMobileOutputGuideConfiguration(enabled: true, baseRevision: 7)
            Issue.record("Expected revision conflict")
        } catch let APIError.codedServer(status, message, code) {
            #expect(status == 409)
            #expect(message == "Mobile Output Guide setting changed")
            #expect(code == "revision_conflict")
        }
    }

    private struct EnabledRequest: Decodable {
        let enabled: Bool
    }

    private struct MobileOutputGuideRequest: Decodable {
        let enabled: Bool
        let baseRevision: Int
    }

    private struct PiDefaultToolsRequest: Decodable {
        let defaultTools: [String]?
    }

    private func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        guard let baseURL = URL(string: "http://localhost:7749") else {
            fatalError("Invalid test URL")
        }
        return APIClient(baseURL: baseURL, token: "sk_test", configuration: configuration)
    }

    private func mockResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "http://localhost:7749") else {
            fatalError("Invalid response URL")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            fatalError("Could not construct HTTP response")
        }
        return (Data(json.utf8), response)
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
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }
}
