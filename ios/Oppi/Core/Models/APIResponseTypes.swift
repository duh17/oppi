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
    var runtime: String?
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
    var runtime: String?
    var systemPrompt: String?
    var hostMount: String?
    var memoryEnabled: Bool?
    var memoryNamespace: String?
    var extensions: [String]?
    var defaultModel: String?
}

// MARK: - Policy Models

struct PolicyPermissionRecord: Codable, Identifiable, Sendable {
    struct Match: Codable, Sendable {
        let tool: String?
        let executable: String?
        let commandMatches: String?
        let pathMatches: String?
        let pathWithin: String?
        let domain: String?
    }

    let id: String
    let decision: String
    let label: String?
    let reason: String?
    let immutable: Bool?
    let match: Match
}

struct PolicyConfigRecord: Codable, Sendable {
    let schemaVersion: Int?
    let mode: String?
    let description: String?
    let fallback: String
    let guardrails: [PolicyPermissionRecord]
    let permissions: [PolicyPermissionRecord]
}

struct WorkspacePolicyRecord: Codable, Sendable {
    let fallback: String?
    let permissions: [PolicyPermissionRecord]
}

struct WorkspacePolicyResponse: Decodable, Sendable {
    let workspaceId: String
    let globalPolicy: PolicyConfigRecord?
    let workspacePolicy: WorkspacePolicyRecord
    let effectivePolicy: PolicyConfigRecord
}

struct WorkspacePolicyPatchRequest: Encodable, Sendable {
    let permissions: [PolicyPermissionRecord]?
    let fallback: String?
}

struct WorkspacePolicyMutationResponse: Decodable, Sendable {
    let workspace: Workspace
    let policy: WorkspacePolicyRecord
}

struct PolicyRuleRecord: Decodable, Identifiable, Sendable {
    struct Match: Decodable, Sendable {
        let executable: String?
        let domain: String?
        let pathPattern: String?
        let commandPattern: String?
    }

    let id: String
    let effect: String
    let tool: String?
    let match: Match?
    let scope: String
    let workspaceId: String?
    let sessionId: String?
    let source: String
    let description: String
    let createdAt: Date
    let createdBy: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, effect, tool, match, scope, workspaceId, sessionId, source
        case description, createdAt, createdBy, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        effect = try c.decode(String.self, forKey: .effect)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        match = try c.decodeIfPresent(Match.self, forKey: .match)
        scope = try c.decode(String.self, forKey: .scope)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        source = try c.decode(String.self, forKey: .source)
        description = try c.decode(String.self, forKey: .description)
        let createdAtMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        if let expiresMs = try c.decodeIfPresent(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: expiresMs / 1000)
        } else {
            expiresAt = nil
        }
    }
}

struct PolicyRulePatchRequest: Encodable, Sendable {
    struct Match: Encodable, Sendable {
        let executable: String?
        let domain: String?
        let pathPattern: String?
        let commandPattern: String?
    }

    let effect: String?
    let description: String?
    let tool: String?
    let match: Match?
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
