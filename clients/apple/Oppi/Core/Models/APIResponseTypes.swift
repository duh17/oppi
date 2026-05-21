import Foundation

// MARK: - Pairing + Security Request Types

struct PairDeviceRequest: Encodable {
    let pairingToken: String
    let deviceName: String?
}

struct PairDeviceResponse: Decodable {
    let deviceToken: String
}

// MARK: - Workspace Request Types

struct CreateWorkspaceRequest: Encodable {
    let name: String
    var description: String?
    var icon: String?
    let skills: [String]
    var systemPrompt: String?
    var systemPromptMode: WorkspaceSystemPromptMode?
    var hostMount: String?
    var defaultModel: String?
    var gitStatusEnabled: Bool?
    var tools: [String]? = nil
    var extensions: [String]?
    var runtime: WorkspaceRuntime?
    var sandboxConfig: SandboxConfig?
}

struct UpdateWorkspaceRequest {
    let body: [String: JSONValue]

    init(
        name: String? = nil,
        description: JSONValue? = nil,
        icon: JSONValue? = nil,
        skills: [String]? = nil,
        systemPrompt: JSONValue? = nil,
        systemPromptMode: WorkspaceSystemPromptMode? = nil,
        hostMount: JSONValue? = nil,
        defaultModel: JSONValue? = nil,
        gitStatusEnabled: Bool? = nil,
        tools: [String]? = nil,
        extensions: [String]? = nil,
        sandboxConfig: JSONValue? = nil
    ) {
        var body: [String: JSONValue] = [:]

        if let name {
            body["name"] = .string(name)
        }
        if let description {
            body["description"] = description
        }
        if let icon {
            body["icon"] = icon
        }
        if let skills {
            body["skills"] = .array(skills.map(JSONValue.string))
        }
        if let systemPrompt {
            body["systemPrompt"] = systemPrompt
        }
        if let systemPromptMode {
            body["systemPromptMode"] = .string(systemPromptMode.rawValue)
        }
        if let hostMount {
            body["hostMount"] = hostMount
        }
        if let defaultModel {
            body["defaultModel"] = defaultModel
        }
        if let gitStatusEnabled {
            body["gitStatusEnabled"] = .bool(gitStatusEnabled)
        }
        if let tools {
            body["tools"] = .array(tools.map(JSONValue.string))
        }
        if let extensions {
            body["extensions"] = .array(extensions.map(JSONValue.string))
        }
        if let sandboxConfig {
            body["sandboxConfig"] = sandboxConfig
        }

        self.body = body
    }
}

// MARK: - Policy Models

enum PolicyFallbackDecision: String, CaseIterable, Codable, Sendable {
    case allow
    case auto
    case ask

    init(serverValue: String) {
        switch serverValue {
        case "allow":
            self = .allow
        case "auto":
            self = .auto
        case "ask", "deny":
            self = .ask
        default:
            self = .ask
        }
    }
}

struct PolicyFallbackResponse: Decodable, Sendable {
    let fallback: PolicyFallbackDecision

    enum CodingKeys: String, CodingKey {
        case fallback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .fallback)
        fallback = PolicyFallbackDecision(serverValue: raw)
    }
}

struct PolicyRuleRecord: Decodable, Identifiable, Sendable {
    let id: String
    let decision: String
    let tool: String?
    let pattern: String?
    let executable: String?
    let label: String
    let scope: String
    let workspaceId: String?
    let sessionId: String?
    let source: String
    let createdAt: Date
    let createdBy: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, decision, tool, pattern, executable, label
        case scope, workspaceId, sessionId, source
        case createdAt, createdBy, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        decision = try c.decode(String.self, forKey: .decision)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        label = try c.decode(String.self, forKey: .label)
        scope = try c.decode(String.self, forKey: .scope)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"

        if let createdAtMs = try c.decodeIfPresent(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
        } else {
            createdAt = Date()
        }

        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)

        if let expiresMs = try c.decodeIfPresent(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: expiresMs / 1000)
        } else {
            expiresAt = nil
        }
    }
}

struct PolicyRuleCreateRequest: Encodable, Sendable {
    let decision: String
    let label: String?
    let tool: String?
    let pattern: String?
    let executable: String?
    let scope: String
    let workspaceId: String?
    let sessionId: String?
    let expiresAt: Double?
}

struct PolicyRulePatchRequest: Encodable, Sendable {
    let decision: String?
    let label: String?
    let tool: String?
    let pattern: String?
    let executable: String?
}

struct PolicyRuleMutationResponse: Decodable, Sendable {
    let rule: PolicyRuleRecord
}

struct PolicyAuditUserChoice: Decodable, Sendable {
    let action: String
    let scope: String
    let learnedRuleId: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case action, scope, learnedRuleId, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        scope = try c.decode(String.self, forKey: .scope)
        learnedRuleId = try c.decodeIfPresent(String.self, forKey: .learnedRuleId)
        if let expiresAtMs = try c.decodeIfPresent(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
        } else {
            expiresAt = nil
        }
    }
}

struct PolicyAuditAutoReview: Decodable, Sendable {
    let outcome: String
    let status: String
    let reason: String
    let model: String?
    let riskLevel: String?
    let confidence: Double?
    let durationMs: Int?
    let tokens: Int?
    let promptHash: String?
}

struct PolicyAuditEntry: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let sessionId: String
    let workspaceId: String
    let tool: String
    let displaySummary: String
    let decision: String
    let resolvedBy: String
    let layer: String
    let ruleId: String?
    let ruleSummary: String?
    let autoReview: PolicyAuditAutoReview?
    let userChoice: PolicyAuditUserChoice?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, sessionId, workspaceId, tool, displaySummary
        case decision, resolvedBy, layer, ruleId, ruleSummary, autoReview, userChoice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let timestampMs = try c.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: timestampMs / 1000)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        tool = try c.decode(String.self, forKey: .tool)
        displaySummary = try c.decode(String.self, forKey: .displaySummary)
        decision = try c.decode(String.self, forKey: .decision)
        resolvedBy = try c.decode(String.self, forKey: .resolvedBy)
        layer = try c.decode(String.self, forKey: .layer)
        ruleId = try c.decodeIfPresent(String.self, forKey: .ruleId)
        ruleSummary = try c.decodeIfPresent(String.self, forKey: .ruleSummary)
        autoReview = try c.decodeIfPresent(PolicyAuditAutoReview.self, forKey: .autoReview)
        userChoice = try c.decodeIfPresent(PolicyAuditUserChoice.self, forKey: .userChoice)
    }
}

// MARK: - Local Sessions

/// A pi TUI session discovered on the host (not yet managed by oppi).
struct LocalSession: Identifiable, Sendable, Equatable {
    let path: String
    let piSessionId: String
    let cwd: String
    let name: String?
    let firstMessage: String?
    let model: String?
    let messageCount: Int
    let createdAt: Date
    let lastModified: Date

    var id: String { path }

    /// Short model name for display (e.g. "claude-sonnet-4-5" from "anthropic/claude-sonnet-4-5").
    var modelShort: String? {
        guard let model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Display title: name, first message preview, or session ID prefix.
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let firstMessage, !firstMessage.isEmpty {
            let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(80))
        }
        return "Session \(String(piSessionId.prefix(8)))"
    }
}

extension LocalSession: Decodable {
    enum CodingKeys: String, CodingKey {
        case path, piSessionId, cwd, name, firstMessage, model, messageCount
        case createdAt, lastModified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        piSessionId = try c.decode(String.self, forKey: .piSessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        messageCount = try c.decode(Int.self, forKey: .messageCount)

        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdMs / 1000)

        let modifiedMs = try c.decode(Double.self, forKey: .lastModified)
        lastModified = Date(timeIntervalSince1970: modifiedMs / 1000)
    }
}

struct WorkspaceSessionArchiveBucket: Identifiable, Sendable, Equatable {
    enum Kind: String, Decodable, Sendable {
        case day
        case month
    }

    let id: String
    let kind: Kind
    let startAt: Date
    let endAt: Date
    var itemCount: Int
    var managedStoppedCount: Int
    var importableLocalCount: Int

    var latestActivity: Date?
}

extension WorkspaceSessionArchiveBucket: Decodable {
    enum CodingKeys: String, CodingKey {
        case id = "bucketId"
        case kind = "bucketKind"
        case startAt = "startMs"
        case endAt = "endMs"
        case itemCount
        case managedStoppedCount
        case importableLocalCount
        case latestActivity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        let startMs = try c.decode(Double.self, forKey: .startAt)
        startAt = Date(timeIntervalSince1970: startMs / 1000)
        let endMs = try c.decode(Double.self, forKey: .endAt)
        endAt = Date(timeIntervalSince1970: endMs / 1000)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        managedStoppedCount = try c.decode(Int.self, forKey: .managedStoppedCount)
        importableLocalCount = try c.decode(Int.self, forKey: .importableLocalCount)
        if let latestActivityMs = try c.decodeIfPresent(Double.self, forKey: .latestActivity) {
            latestActivity = Date(timeIntervalSince1970: latestActivityMs / 1000)
        } else {
            latestActivity = nil
        }
    }
}

// MARK: - Session Search

struct SessionSearchResponse: Decodable, Sendable {
    let results: [SessionSearchResult]
    let query: String
    let totalResults: Int
}

struct SessionSearchResult: Decodable, Sendable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let workspaceId: String
    let title: String
    let snippet: String?
    let rank: Double
    let session: Session?
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .server(_, let message):
            return UserFacingErrorText.normalize(message)
        }
    }
}
