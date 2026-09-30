import Foundation

extension APIClient {
    func listMcpServers(scopeId: String) async throws -> McpServersResponse {
        // Pi probes are bounded at 20 seconds. Leave termination/transport headroom
        // without changing the 30-second resource deadline or ordinary API requests.
        let (data, response) = try await request("GET", path: mcpScopePath(scopeId) + "/servers", timeoutInterval: 25)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(McpServersResponse.self, from: data)
    }
    func addMcpServer(scopeId: String, _ input: McpAddServerRequest) async throws {
        let (data, response) = try await request("POST", path: mcpScopePath(scopeId) + "/servers", body: input, timeoutInterval: 25)
        try checkStatus(response, data: data)
    }
    func patchMcpServer(scopeId: String, name: String, patch: McpPatchServerRequest) async throws {
        let (data, response) = try await request(
            "PATCH", path: mcpServerPath(scopeId: scopeId, name: name),
            body: patch, timeoutInterval: 25
        )
        try checkStatus(response, data: data)
    }
    func removeMcpServer(scopeId: String, name: String) async throws {
        let (data, response) = try await request("DELETE", path: mcpServerPath(scopeId: scopeId, name: name), timeoutInterval: 25)
        try checkStatus(response, data: data)
    }
    func startMcpAuthFlow(scopeId: String, name: String) async throws -> McpAuthFlowSnapshot {
        struct Body: Encodable { let launchMode = "phone_browser" }
        let (data, response) = try await request(
            "POST", path: mcpServerPath(scopeId: scopeId, name: name) + "/login",
            body: Body(), timeoutInterval: 25
        )
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(McpFlowResponse.self, from: data).flow
    }
    func logoutMcpServer(scopeId: String, name: String) async throws {
        struct Body: Encodable {}
        let (data, response) = try await request(
            "POST", path: mcpServerPath(scopeId: scopeId, name: name) + "/logout",
            body: Body(), timeoutInterval: 25
        )
        try checkStatus(response, data: data)
    }
    func getMcpAuthFlow(flowId: String) async throws -> McpAuthFlowSnapshot {
        try JSONDecoder().decode(McpFlowResponse.self, from: await get("/mcp/auth/flows/\(flowId)")).flow
    }
    func submitMcpCallback(flowId: String, input: String) async throws -> McpAuthFlowSnapshot {
        struct Body: Encodable { let input: String }
        let data = try await post("/mcp/auth/flows/\(flowId)/manual-code", body: Body(input: input))
        return try JSONDecoder().decode(McpFlowResponse.self, from: data).flow
    }
    func cancelMcpAuthFlow(flowId: String) async throws -> McpAuthFlowSnapshot {
        struct Body: Encodable {}
        let data = try await post("/mcp/auth/flows/\(flowId)/cancel", body: Body())
        return try JSONDecoder().decode(McpFlowResponse.self, from: data).flow
    }
    private static let mcpPathSegment = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    private func mcpScopePath(_ scopeId: String) -> String {
        "/mcp/scopes/\(scopeId.addingPercentEncoding(withAllowedCharacters: Self.mcpPathSegment) ?? "")"
    }
    private func mcpServerPath(scopeId: String, name: String) -> String {
        mcpScopePath(scopeId) + "/servers/\(name.addingPercentEncoding(withAllowedCharacters: Self.mcpPathSegment) ?? "")"
    }
}
private struct McpFlowResponse: Decodable { let flow: McpAuthFlowSnapshot }
