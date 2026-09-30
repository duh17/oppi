import Foundation

extension APIClient {
    func listMcpServers() async throws -> McpServersResponse {
        try JSONDecoder().decode(McpServersResponse.self, from: await get("/mcp/servers"))
    }
    func addMcpServer(_ input: McpAddServerRequest) async throws {
        _ = try await post("/mcp/servers", body: input)
    }
    func patchMcpServer(scopeId: String, name: String, patch: McpPatchServerRequest) async throws {
        let (data, response) = try await request(
            "PATCH", path: mcpServerPath(scopeId: scopeId, name: name),
            body: JSONEncoder().encode(patch), contentType: "application/json"
        )
        try checkStatus(response, data: data)
    }
    func removeMcpServer(scopeId: String, name: String) async throws {
        let (data, response) = try await request("DELETE", path: mcpServerPath(scopeId: scopeId, name: name))
        try checkStatus(response, data: data)
    }
    func startMcpAuthFlow(scopeId: String, name: String) async throws -> McpAuthFlowSnapshot {
        struct Body: Encodable { let launchMode = "phone_browser" }
        let data = try await post(mcpServerPath(scopeId: scopeId, name: name) + "/login", body: Body())
        return try JSONDecoder().decode(McpFlowResponse.self, from: data).flow
    }
    func logoutMcpServer(scopeId: String, name: String) async throws {
        struct Body: Encodable {}
        _ = try await post(mcpServerPath(scopeId: scopeId, name: name) + "/logout", body: Body())
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
    private func mcpServerPath(scopeId: String, name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return "/mcp/scopes/\(scopeId.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")/servers/\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }
}
private struct McpFlowResponse: Decodable { let flow: McpAuthFlowSnapshot }
