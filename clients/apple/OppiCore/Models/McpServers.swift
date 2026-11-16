import Foundation

enum McpExposure: String, Codable, CaseIterable, Sendable {
    case codemode
    case deferred
    case direct
    case hidden
}

struct McpServerConfig: Codable, Sendable, Equatable {
    var url: String?
    var command: String?
    var args: [String]?
    var cwd: String?
    var env: [String: String]?
    var headers: [String: String]?
    var oauth: OAuth?

    struct OAuth: Codable, Sendable, Equatable {
        var clientId: String?
        var clientSecret: String?
        var callbackPort: Int?
    }
}

struct McpServerSummary: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let transport: String
    let config: McpServerConfig
    let enabled: Bool
    let exposure: McpExposure
    let state: String
    let tools: [String]
    let toolExposure: [String: McpExposure]?
    let error: String?
    let supportsOAuth: Bool
    var id: String { name }
}

/// One MCP scope as the server lists it. The app reads a sandbox workspace's (the global servers
/// it may load); the global and host-workspace lists are the server's MCP Servers plugin page.
struct McpScopeSnapshot: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String
    /// Project scopes only: the trust answer Workspace settings show for all project resources.
    let projectTrust: ProjectTrustState?
    /// This scope's own mcp.json.
    let servers: [McpServerSummary]
    /// Project scopes only: global servers that also load here, read-only.
    let inherited: [McpServerSummary]?
    let errors: [String]
}
struct McpServersResponse: Codable, Sendable, Equatable {
    let scope: McpScopeSnapshot
    /// The host-wide sign-in still blocking MCP changes, whichever scope started it. While
    /// present, `scope` is the host's last live probe, not a fresh one.
    let activeSignIn: McpAuthFlowSnapshot?
}
struct McpAuthFlowSnapshot: Codable, Sendable, Equatable {
    let flowId: String
    let scopeId: String
    let serverName: String
    let launchMode: ProviderAuthFlowSnapshot.LaunchMode
    let status: ProviderAuthFlowSnapshot.Status
    let auth: ProviderAuthFlowSnapshot.AuthInfo?
    let error: String?
    let createdAt: Double
    let updatedAt: Double
    let expiresAt: Double
}
