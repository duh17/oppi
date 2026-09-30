import Foundation
import Testing
@testable import Oppi

@Suite("MCP server wire contract")
struct McpServerModelTests {
    private struct Fixture: Codable {
        let catalogs: [McpServersResponse]
        let signInCatalog: McpServersResponse
        let flows: [McpAuthFlowSnapshot]
    }
    private func fixture() throws -> Fixture {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: repo.appendingPathComponent("protocol/mcp-http.json")))
    }

    @Test func decodesServerAuthAndTrustStatesFromServerFixture() throws {
        let catalogs = try fixture().catalogs
        #expect(catalogs.map(\.scope.id) == ["global", "workspace-one", "workspace-trusted", "workspace-distrusted"])
        let global = try #require(catalogs.first).scope
        #expect(global.servers.map(\.state) == ["connected", "needs-auth", "failed", "disabled"])
        #expect(global.servers[0].tools == ["echo"])
        #expect(global.servers[0].toolExposure?["echo"] == .direct)
        #expect(global.servers[0].config.env?["KEY"] == "[redacted]")
        #expect(global.servers[0].config.env?["REF"] == "${TOKEN}")
        #expect(global.servers[1].config.oauth?.clientSecret == "[redacted]")
        #expect(global.servers[1].stateLabel == "Needs sign-in")
        #expect(global.projectTrust == nil && global.inherited == nil)
        #expect(catalogs.dropFirst().map(\.scope.projectTrust) == [.ask, .trusted, .distrusted])
        #expect(catalogs[1].scope.servers[0].state == "untrusted")
        #expect(catalogs[1].scope.inherited?.first?.state == "connected")
        #expect(catalogs[2].scope.inherited?.first?.state == "replaced")
    }
    @Test func decodesTheListServedDuringASignIn() throws {
        let data = try fixture()
        #expect(data.catalogs.allSatisfy { $0.activeSignIn == nil })
        let flow = try #require(data.signInCatalog.activeSignIn)
        #expect(flow.flowId == "flow-awaiting_external")
        #expect(flow.status == .awaitingExternal)
        #expect(flow.scopeId == "global")
        #expect(flow.serverName == "remote")
        #expect(data.signInCatalog.scope.id == "global")
    }
    @Test func decodesAndRoundTripsAllMcpFlowStates() throws {
        let data = try fixture()
        #expect(data.flows.map(\.status) == [.pending, .awaitingExternal, .completed, .failed, .cancelled, .expired])
        #expect(data.flows[1].auth?.url.contains("redirect_uri=") == true)
        #expect(data.flows[1].scopeId == "global")
        #expect(data.flows[1].launchMode == .phoneBrowser)
        #expect(data.flows.filter { $0.status.isTerminal }.count == 4)
        let decoded = try JSONDecoder().decode(Fixture.self, from: JSONEncoder().encode(data))
        #expect(decoded.catalogs == data.catalogs)
        #expect(decoded.flows == data.flows)
    }
    @Test func addAndPatchEncodeOnlyRequestedFields() throws {
        let add = McpAddServerRequest(name: "echo", command: "node", args: ["echo.cjs"], env: ["KEY": "${TOOLS_KEY}"])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(add)) as? [String: Any])
        #expect(object["url"] == nil)
        #expect(object["oauth"] == nil)
        #expect(object["scopeId"] == nil)
        #expect(object["env"] as? [String: String] == ["KEY": "${TOOLS_KEY}"])
        let patch = McpPatchServerRequest(enabled: true, exposure: .codemode)
        let patchObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect(Set(patchObject.keys) == ["enabled", "exposure"])
        #expect(patchObject["enabled"] as? Bool == true)
        #expect(patchObject["exposure"] as? String == "codemode")
    }
    @Test(arguments: McpExposure.allCases)
    func addExposureSelectionOmitsOnlyTheDefault(exposure: McpExposure) throws {
        let add = McpAddServerRequest(name: "echo", command: "node", exposure: exposure.configurationValue)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(add)) as? [String: Any])
        #expect(object["exposure"] as? String == (exposure == .codemode ? nil : exposure.rawValue))
        #expect(!exposure.explanation.isEmpty)
    }

    @Test func malformedRequiredFieldsFailDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(McpServersResponse.self, from: Data("{\"scope\":{\"id\":\"global\"}}".utf8))
        }
    }
}
