import Foundation

enum WorkspaceSystemPromptMode: String, Codable, Sendable, CaseIterable {
    case append
    case replace
}

enum WorkspaceRuntime: String, Codable, Sendable {
    case host
    case sandbox
}

struct SandboxConfig: Codable, Sendable, Equatable, Hashable {
    var allowedHosts: [String]?
}

/// Workspace model matching server's `Workspace` type.
///
/// A workspace defines the agent environment: skills, permissions,
/// mounted directories, and optional system prompt. Sessions are
/// created from a workspace.
struct Workspace: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    var name: String
    var description: String?
    var icon: String?           // SF Symbol name or emoji

    // Skills
    var skills: [String]        // ["searxng", "fetch", "ast-grep"]

    // Context
    var systemPrompt: String?
    var systemPromptMode: WorkspaceSystemPromptMode = .append
    var hostMount: String?      // Host directory mounted as /work
    var defaultModel: String?   // Optional default model for new sessions

    // Tools and extensions
    var tools: [String]?
    var extensions: [String]?

    // Git status
    var gitStatusEnabled: Bool?  // Show git context bar (default: true)

    // Runtime
    var runtime: WorkspaceRuntime?
    var sandboxConfig: SandboxConfig?

    // Metadata
    let createdAt: Date
    var updatedAt: Date

}

struct WorkspaceListSummary: Codable, Sendable, Equatable {
    let workspaceId: String
    var activeCount: Int
    var stoppedCount: Int
    var hasAttention: Bool
    var hasErrorRoot: Bool
    var latestActivity: Date?

    enum CodingKeys: String, CodingKey {
        case workspaceId, activeCount, stoppedCount, hasAttention, hasErrorRoot, latestActivity
    }

    init(
        workspaceId: String,
        activeCount: Int,
        stoppedCount: Int,
        hasAttention: Bool,
        hasErrorRoot: Bool = false,
        latestActivity: Date? = nil
    ) {
        self.workspaceId = workspaceId
        self.activeCount = activeCount
        self.stoppedCount = stoppedCount
        self.hasAttention = hasAttention
        self.hasErrorRoot = hasErrorRoot
        self.latestActivity = latestActivity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        activeCount = try c.decode(Int.self, forKey: .activeCount)
        stoppedCount = try c.decode(Int.self, forKey: .stoppedCount)
        hasAttention = try c.decode(Bool.self, forKey: .hasAttention)
        hasErrorRoot = try c.decodeIfPresent(Bool.self, forKey: .hasErrorRoot) ?? false

        if let latestActivityMs = try c.decodeIfPresent(Double.self, forKey: .latestActivity) {
            latestActivity = Date(timeIntervalSince1970: latestActivityMs / 1000)
        } else {
            latestActivity = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(activeCount, forKey: .activeCount)
        try c.encode(stoppedCount, forKey: .stoppedCount)
        try c.encode(hasAttention, forKey: .hasAttention)
        try c.encode(hasErrorRoot, forKey: .hasErrorRoot)
        try c.encodeIfPresent(latestActivity.map { $0.timeIntervalSince1970 * 1000 }, forKey: .latestActivity)
    }
}

// MARK: - Codable (Unix millisecond timestamps)

extension Workspace: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, description, icon
        case skills
        case systemPrompt, systemPromptMode, hostMount, defaultModel
        case tools, extensions
        case gitStatusEnabled
        case runtime, sandboxConfig
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        skills = try c.decode([String].self, forKey: .skills)
        hostMount = try c.decodeIfPresent(String.self, forKey: .hostMount)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        systemPromptMode = try c.decodeIfPresent(WorkspaceSystemPromptMode.self, forKey: .systemPromptMode) ?? .append
        tools = try c.decodeIfPresent([String].self, forKey: .tools)
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)
        gitStatusEnabled = try c.decodeIfPresent(Bool.self, forKey: .gitStatusEnabled)
        runtime = try c.decodeIfPresent(WorkspaceRuntime.self, forKey: .runtime)
        sandboxConfig = try c.decodeIfPresent(SandboxConfig.self, forKey: .sandboxConfig)

        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdMs / 1000)

        let updatedMs = try c.decode(Double.self, forKey: .updatedAt)
        updatedAt = Date(timeIntervalSince1970: updatedMs / 1000)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encode(skills, forKey: .skills)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encode(systemPromptMode, forKey: .systemPromptMode)
        try c.encodeIfPresent(hostMount, forKey: .hostMount)
        try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(extensions, forKey: .extensions)
        try c.encodeIfPresent(gitStatusEnabled, forKey: .gitStatusEnabled)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(sandboxConfig, forKey: .sandboxConfig)
        try c.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try c.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
    }
}
