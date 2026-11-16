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
        try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("mcp-http.json"))
    }

    @Test func decodesServerAuthAndTrustStatesFromServerFixture() throws {
        let catalogs = try fixture().catalogs
        #expect(catalogs.map(\.scope.id) == ["global", "workspace-one", "workspace-trusted", "workspace-distrusted", "workspace-sandbox"])
        let global = try #require(catalogs.first).scope
        #expect(global.servers.map(\.state) == ["connected", "needs-auth", "failed", "disabled"])
        #expect(global.servers[0].tools == ["echo"])
        #expect(global.servers[0].toolExposure?["echo"] == .direct)
        #expect(global.servers[0].config.env?["KEY"] == "[redacted]")
        #expect(global.servers[0].config.env?["REF"] == "${TOKEN}")
        #expect(global.servers[1].config.oauth?.clientSecret == "[redacted]")
        #expect(global.projectTrust == nil && global.inherited == nil)
        #expect(catalogs.dropFirst().map(\.scope.projectTrust) == [.ask, .trusted, .distrusted, nil])
        let sandbox = catalogs[4].scope
        #expect(sandbox.kind == "sandbox")
        #expect(sandbox.servers.map(\.state) == ["available", "blocked"])
        #expect(sandbox.servers[1].error?.contains("Allowed Hosts") == true)
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
    @Test func malformedRequiredFieldsFailDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(McpServersResponse.self, from: Data("{\"scope\":{\"id\":\"global\"}}".utf8))
        }
    }
}
