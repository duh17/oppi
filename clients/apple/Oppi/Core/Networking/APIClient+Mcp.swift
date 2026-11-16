import Foundation

extension APIClient {
    /// One MCP scope's servers: a sandbox workspace reads the global servers it may load. The
    /// global and host-workspace pages are the server's MCP Servers plugin page.
    /// `cached`: the host's last known status at once (configured rows with status `unknown`
    /// before its first probe) while it probes in the background. Otherwise Pi's live probe.
    func listMcpServers(scopeId: String, cached: Bool = false) async throws -> McpServersResponse {
        // Pi probes are bounded at 20 seconds. Leave termination/transport headroom
        // without changing the 30-second resource deadline or ordinary API requests.
        let path = mcpScopePath(scopeId) + "/servers" + (cached ? "?cached=true" : "")
        let (data, response) = try await request("GET", path: path, timeoutInterval: 25)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(McpServersResponse.self, from: data)
    }
    private static let mcpPathSegment = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    private func mcpScopePath(_ scopeId: String) -> String {
        "/mcp/scopes/\(scopeId.addingPercentEncoding(withAllowedCharacters: Self.mcpPathSegment) ?? "")"
    }
}
