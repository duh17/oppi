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

    @Test func usageRequestsUseSupportedRangeAndIanaTimezoneForEveryRoute() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }
        var observed: [(path: String, query: [String: String])] = []

        TestURLProtocol.handler = { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            observed.append((
                path: components.path,
                query: Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                })
            ))
            return mockResponse(json: Self.emptyUsageJSON)
        }

        _ = try await client.getServerSkillUsage(
            id: "skill_abc",
            range: .sevenDays,
            timezone: "America/Los_Angeles"
        )
        _ = try await client.getServerExtensionUsage(
            id: "extension_abc",
            range: .thirtyDays,
            timezone: "Asia/Tokyo"
        )
        _ = try await client.getToolActivity(
            range: .ninetyDays,
            timezone: "Europe/London"
        )

        #expect(observed.map(\.path) == [
            "/server/resources/skills/skill_abc/usage",
            "/server/resources/extensions/extension_abc/usage",
            "/server/stats/tool-activity",
        ])
        #expect(observed.map(\.query) == [
            ["range": "7", "timezone": "America/Los_Angeles"],
            ["range": "30", "timezone": "Asia/Tokyo"],
            ["range": "90", "timezone": "Europe/London"],
        ])
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
                {"extensions":[{"id":"oppi","name":"Oppi","description":"Server-owned controls.","kind":"builtIn","provenance":{"kind":"builtIn","label":"Built-in extension"},"state":"off","warnings":[],"isRemovable":false}],"builtInTools":[{"name":"read","description":"Read files","defaultEnabled":true},{"name":"grep","description":"Search files","defaultEnabled":false}],"oppiConfiguration":{"enabled":false,"approvalPolicy":"confirmDestructiveOnly","revision":0}}
                """)
            }

            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/server/resources/extensions/oppi")
            return mockResponse(json: """
            {"summary":{"id":"oppi","name":"Oppi","description":"Server-owned controls.","kind":"builtIn","provenance":{"kind":"builtIn","label":"Built-in extension"},"state":"off","warnings":[],"isRemovable":false,"contributedTools":["oppi"]},"contributedTools":["oppi"],"contributedToolDetails":[{"name":"oppi","description":"Manage Oppi"}]}
            """)
        }

        let catalog = try await client.listServerExtensions()
        let detail = try await client.getServerExtension(id: "oppi")

        #expect(catalog.extensions.first?.path == nil)
        #expect(catalog.oppiConfiguration.revision == 0)
        #expect(catalog.builtInTools.map(\.name) == ["read", "grep"])
        #expect(catalog.builtInTools.first?.defaultEnabled == true)
        #expect(detail.summary.kind == .builtIn)
        #expect(detail.contributedToolDetails?.first?.description == "Manage Oppi")
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

    @Test func oppiConfigurationPutUsesFullCASBodyAndDecodesAuthoritativeResponse() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/server/extensions/oppi/config")
            let body = try JSONDecoder().decode(OppiConfigurationRequest.self, from: requestBodyData(request))
            #expect(body.enabled)
            #expect(body.approvalPolicy == .confirmAllChanges)
            #expect(body.mobileOutputGuideEnabled == true)
            #expect(body.baseRevision == 7)
            return mockResponse(json: """
            {"enabled":true,"approvalPolicy":"confirmAllChanges","mobileOutputGuideEnabled":true,"revision":8}
            """)
        }

        let configuration = try await client.setOppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmAllChanges,
            mobileOutputGuideEnabled: true,
            baseRevision: 7
        )

        #expect(configuration == OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmAllChanges,
            mobileOutputGuideEnabled: true,
            revision: 8
        ))
    }

    @Test func oppiConfigurationGetUsesDedicatedRoute() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/server/extensions/oppi/config")
            return mockResponse(json: #"{"enabled":false,"approvalPolicy":"readOnly","revision":12}"#)
        }

        let configuration = try await client.getOppiExtensionConfiguration()

        #expect(configuration.approvalPolicy == .readOnly)
        #expect(configuration.revision == 12)
    }

    @Test func revisionConflictUsesExistingAPIErrorConvention() async throws {
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            mockResponse(status: 409, json: """
            {"error":"Oppi extension configuration changed","code":"revision_conflict","current":{"enabled":false,"approvalPolicy":"readOnly","revision":8}}
            """)
        }

        do {
            _ = try await client.setOppiExtensionConfiguration(
                enabled: true,
                approvalPolicy: .confirmAllChanges,
                mobileOutputGuideEnabled: false,
                baseRevision: 7
            )
            Issue.record("Expected revision conflict")
        } catch let APIError.server(status, message) {
            #expect(status == 409)
            #expect(message == "Oppi extension configuration changed")
        }
    }

    private static let emptyUsageJSON = """
    {
      "subject":{"kind":"tools"},
      "rangeDays":30,
      "timezone":"UTC",
      "recordingStartedAt":1765843200000,
      "recordedActions":0,
      "distinctSessions":0,
      "activeDays":0,
      "retainedHistory":{"retentionDays":120},
      "daily":[],
      "breakdown":[],
      "capture":{"status":"active","failedWrites":0,"droppedEvents":0}
    }
    """

    private struct EnabledRequest: Decodable {
        let enabled: Bool
    }

    private struct OppiConfigurationRequest: Decodable {
        let enabled: Bool
        let approvalPolicy: OppiApprovalPolicy
        let mobileOutputGuideEnabled: Bool?
        let baseRevision: Int
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
