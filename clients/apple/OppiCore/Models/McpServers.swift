import Foundation

enum McpExposure: String, Codable, CaseIterable, Sendable {
    case codemode
    case codemodeDeferred = "codemode-deferred"
    case deferred
    case direct
    case hidden

    var explanation: String {
        switch self {
        case .codemode: "Tools are listed for scripts, without model declarations."
        case .codemodeDeferred: "Scripts discover tools on demand."
        case .deferred: "Tool search loads tools into the model context."
        case .direct: "Tools are always declared to the model."
        case .hidden: "Tools cannot be called."
        }
    }
    var configurationValue: McpExposure? { self == .codemode ? nil : self }
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
    var stateLabel: String {
        switch state {
        case "needs-auth": "Needs sign-in"
        case "connected": "Connected"
        case "disabled": "Disabled"
        case "untrusted": "Untrusted project"
        case "failed", "disconnected": "Failed"
        default: state.capitalized
        }
    }
}

struct McpScopeSnapshot: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String
    let hasConfig: Bool
    let trusted: Bool
    let servers: [McpServerSummary]
    let errors: [String]
    let note: String?
}
struct McpServersResponse: Codable, Sendable, Equatable {
    let scopes: [McpScopeSnapshot]
    /// The sign-in still blocking MCP changes on the host. While present, `scopes` is the
    /// host's last live probe, not a fresh one.
    let activeSignIn: McpAuthFlowSnapshot?
}
struct McpPatchServerRequest: Encodable, Sendable {
    var enabled: Bool?
    var exposure: McpExposure?
}
struct McpAddServerRequest: Encodable, Sendable {
    let scopeId: String
    let name: String
    var url: String?
    var command: String?
    var args: [String]?
    var cwd: String?
    var env: [String: String]?
    var headers: [String: String]?
    var oauth: McpServerConfig.OAuth?
    var exposure: McpExposure?
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
