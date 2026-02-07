import Foundation

/// Workspace model matching server's `Workspace` type.
///
/// A workspace defines the agent environment: skills, permissions,
/// mounted directories, and optional system prompt. Sessions are
/// created from a workspace.
struct Workspace: Identifiable, Sendable, Equatable {
    let id: String
    let userId: String
    var name: String
    var description: String?
    var icon: String?           // SF Symbol name or emoji

    // Skills
    var skills: [String]        // ["searxng", "fetch", "ast-grep"]

    // Permissions
    var policyPreset: String    // "container" | "restricted"

    // Context
    var systemPrompt: String?
    var hostMount: String?      // Host directory mounted as /work

    // Memory
    var memoryEnabled: Bool?
    var memoryNamespace: String?

    // Defaults
    var defaultModel: String?

    // Metadata
    let createdAt: Date
    var updatedAt: Date
}

// MARK: - Codable (Unix millisecond timestamps)

extension Workspace: Codable {
    enum CodingKeys: String, CodingKey {
        case id, userId, name, description, icon
        case skills, policyPreset
        case systemPrompt, hostMount
        case memoryEnabled, memoryNamespace
        case defaultModel
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        skills = try c.decode([String].self, forKey: .skills)
        policyPreset = try c.decodeIfPresent(String.self, forKey: .policyPreset) ?? "container"
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        hostMount = try c.decodeIfPresent(String.self, forKey: .hostMount)
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled)
        memoryNamespace = try c.decodeIfPresent(String.self, forKey: .memoryNamespace)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)

        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdMs / 1000)

        let updatedMs = try c.decode(Double.self, forKey: .updatedAt)
        updatedAt = Date(timeIntervalSince1970: updatedMs / 1000)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encode(skills, forKey: .skills)
        try c.encode(policyPreset, forKey: .policyPreset)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(hostMount, forKey: .hostMount)
        try c.encodeIfPresent(memoryEnabled, forKey: .memoryEnabled)
        try c.encodeIfPresent(memoryNamespace, forKey: .memoryNamespace)
        try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
        try c.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try c.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
    }
}
