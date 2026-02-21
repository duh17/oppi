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
    var hostMount: String?
    var memoryEnabled: Bool?
    var memoryNamespace: String?
    var extensions: [String]?
    var defaultModel: String?
}

struct UpdateWorkspaceRequest: Encodable {
    var name: String?
    var description: String?
    var icon: String?
    var skills: [String]?
    var systemPrompt: String?
    var hostMount: String?
    var gitStatusEnabled: Bool?
    var memoryEnabled: Bool?
    var memoryNamespace: String?
    var extensions: [String]?
    var defaultModel: String?
}

// MARK: - Policy Models

enum PolicyFallbackDecision: String, CaseIterable, Codable, Sendable {
    case allow
    case ask
    case deny

    init(serverValue: String) {
        switch serverValue {
        case "allow":
            self = .allow
        case "ask":
            self = .ask
        case "deny", "denied", "block":
            self = .deny
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
    let userChoice: PolicyAuditUserChoice?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, sessionId, workspaceId, tool, displaySummary
        case decision, resolvedBy, layer, ruleId, ruleSummary, userChoice
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
        userChoice = try c.decodeIfPresent(PolicyAuditUserChoice.self, forKey: .userChoice)
    }
}

// MARK: - Graph Models

struct WorkspaceGraphResponse: Decodable, Sendable, Equatable {
    struct Current: Decodable, Sendable, Equatable {
        let sessionId: String
        let nodeId: String?
    }

    struct SessionGraph: Decodable, Sendable, Equatable {
        struct Node: Decodable, Identifiable, Sendable, Equatable {
            let id: String
            let createdAt: Date
            let parentId: String?
            let workspaceId: String
            let attachedSessionIds: [String]
            let activeSessionIds: [String]
            let sessionFile: String?
            let parentSessionFile: String?

            enum CodingKeys: String, CodingKey {
                case id, createdAt, parentId, workspaceId, attachedSessionIds, activeSessionIds
                case sessionFile, parentSessionFile
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
                workspaceId = try c.decode(String.self, forKey: .workspaceId)
                attachedSessionIds = try c.decode([String].self, forKey: .attachedSessionIds)
                activeSessionIds = try c.decode([String].self, forKey: .activeSessionIds)
                sessionFile = try c.decodeIfPresent(String.self, forKey: .sessionFile)
                parentSessionFile = try c.decodeIfPresent(String.self, forKey: .parentSessionFile)

                let createdAtMs = try c.decode(Double.self, forKey: .createdAt)
                createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
            }
        }

        struct Edge: Decodable, Sendable, Equatable {
            enum EdgeType: String, Decodable, Sendable {
                case fork
            }

            let from: String
            let to: String
            let type: EdgeType
        }

        let nodes: [Node]
        let edges: [Edge]
        let roots: [String]
    }

    struct EntryGraph: Decodable, Sendable, Equatable {
        struct Node: Decodable, Identifiable, Sendable, Equatable {
            let id: String
            let type: String
            let parentId: String?
            let timestamp: Date?
            let role: String?
            let preview: String?

            enum CodingKeys: String, CodingKey {
                case id, type, parentId, timestamp, role, preview
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                type = try c.decode(String.self, forKey: .type)
                parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
                role = try c.decodeIfPresent(String.self, forKey: .role)
                preview = try c.decodeIfPresent(String.self, forKey: .preview)

                if let timestampMs = try c.decodeIfPresent(Double.self, forKey: .timestamp), timestampMs > 0 {
                    timestamp = Date(timeIntervalSince1970: timestampMs / 1000)
                } else {
                    timestamp = nil
                }
            }
        }

        struct Edge: Decodable, Sendable, Equatable {
            enum EdgeType: String, Decodable, Sendable {
                case parent
            }

            let from: String
            let to: String
            let type: EdgeType
        }

        let piSessionId: String
        let nodes: [Node]
        let edges: [Edge]
        let rootEntryId: String?
        let leafEntryId: String?
    }

    let workspaceId: String
    let generatedAt: Date
    let current: Current?
    let sessionGraph: SessionGraph
    let entryGraph: EntryGraph?

    enum CodingKeys: String, CodingKey {
        case workspaceId, generatedAt, current, sessionGraph, entryGraph
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        current = try c.decodeIfPresent(Current.self, forKey: .current)
        sessionGraph = try c.decode(SessionGraph.self, forKey: .sessionGraph)
        entryGraph = try c.decodeIfPresent(EntryGraph.self, forKey: .entryGraph)

        let generatedAtMs = try c.decode(Double.self, forKey: .generatedAt)
        generatedAt = Date(timeIntervalSince1970: generatedAtMs / 1000)
    }
}

extension WorkspaceGraphResponse {
    init(
        workspaceId: String,
        generatedAt: Date,
        current: Current?,
        sessionGraph: SessionGraph,
        entryGraph: EntryGraph? = nil
    ) {
        self.workspaceId = workspaceId
        self.generatedAt = generatedAt
        self.current = current
        self.sessionGraph = sessionGraph
        self.entryGraph = entryGraph
    }
}

extension WorkspaceGraphResponse.SessionGraph.Node {
    init(
        id: String,
        createdAt: Date,
        parentId: String?,
        workspaceId: String,
        attachedSessionIds: [String],
        activeSessionIds: [String],
        sessionFile: String? = nil,
        parentSessionFile: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.parentId = parentId
        self.workspaceId = workspaceId
        self.attachedSessionIds = attachedSessionIds
        self.activeSessionIds = activeSessionIds
        self.sessionFile = sessionFile
        self.parentSessionFile = parentSessionFile
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

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .server(let status, let message): return "Server error (\(status)): \(message)"
        }
    }
}
