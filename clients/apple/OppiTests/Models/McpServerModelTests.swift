import Foundation
import Testing
@testable import Oppi

@Suite("MCP server wire contract")
struct McpServerModelTests {
    private struct Fixture: Codable {
        let catalog: McpServersResponse
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
        let catalog = try fixture().catalog
        #expect(catalog.scopes.map(\.id) == ["global", "workspace-one", "workspace-empty"])
        let global = try #require(catalog.scopes.first)
        #expect(global.servers.map(\.state) == ["connected", "needs-auth", "failed", "disabled"])
        #expect(global.servers[0].tools == ["echo"])
        #expect(global.servers[0].toolExposure?["echo"] == .direct)
        #expect(global.servers[0].config.env?["KEY"] == "[redacted]")
        #expect(global.servers[0].config.env?["REF"] == "${TOKEN}")
        #expect(global.servers[1].config.oauth?.clientSecret == "[redacted]")
        #expect(global.servers[1].stateLabel == "Needs sign-in")
        #expect(catalog.scopes[1].trusted == false)
        #expect(catalog.scopes[1].servers[0].stateLabel == "Untrusted project")
        #expect(catalog.scopes[2].hasConfig == false)
    }
    @Test func decodesAndRoundTripsAllMcpFlowStates() throws {
        let data = try fixture()
        #expect(data.flows.map(\.status) == [.pending, .awaitingExternal, .completed, .failed, .cancelled, .expired])
        #expect(data.flows[1].auth?.url.contains("redirect_uri=") == true)
        #expect(data.flows[1].scopeId == "global")
        #expect(data.flows[1].launchMode == .phoneBrowser)
        #expect(data.flows.filter { $0.status.isTerminal }.count == 4)
        let decoded = try JSONDecoder().decode(Fixture.self, from: JSONEncoder().encode(data))
        #expect(decoded.catalog == data.catalog)
        #expect(decoded.flows == data.flows)
    }
    @Test func addAndPatchEncodeOnlyRequestedFields() throws {
        let add = McpAddServerRequest(scopeId: "global", name: "echo", command: "node", args: ["echo.cjs"], env: ["KEY": "${TOOLS_KEY}"])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(add)) as? [String: Any])
        #expect(object["url"] == nil)
        #expect(object["oauth"] == nil)
        #expect(object["scopeId"] as? String == "global")
        #expect(object["env"] as? [String: String] == ["KEY": "${TOOLS_KEY}"])
        let patch = McpPatchServerRequest(enabled: true, exposure: .codemode)
        let patchObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect(Set(patchObject.keys) == ["enabled", "exposure"])
        #expect(patchObject["enabled"] as? Bool == true)
        #expect(patchObject["exposure"] as? String == "codemode")
    }
    @Test func malformedRequiredFieldsFailDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(McpServersResponse.self, from: Data("{\"scopes\":[{\"id\":\"global\"}]}".utf8))
        }
    }
}
