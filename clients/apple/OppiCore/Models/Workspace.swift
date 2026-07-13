import Foundation

enum WorkspaceSystemPromptMode: String, Codable, Sendable, CaseIterable {
    case append
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
/// A workspace defines the agent environment: mounted directory,
/// optional instructions, and runtime policy. Pi settings own skills,
/// extensions, prompts, and themes for SDK-backed host sessions.
struct Workspace: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    var name: String
    var description: String?
    var icon: String?           // SF Symbol name or emoji

    // Context
    var systemPrompt: String?
    var systemPromptMode: WorkspaceSystemPromptMode = .append
    var hostMount: String?      // Host directory mounted as /work
    var defaultModel: String?   // Optional default model for new sessions

    // Tool allowlist is only a sandbox VM security policy. Host runtime uses Pi defaults.
    var tools: [String]?

    // Git status
    var gitStatusEnabled: Bool?  // Show git context bar (default: true)

    // Runtime
    var runtime: WorkspaceRuntime?
    var sandboxConfig: SandboxConfig?

    // Metadata
    let createdAt: Date
    var updatedAt: Date

}

struct WorkspaceGitSummary: Codable, Sendable, Equatable {
    let isGitRepo: Bool
    let changedCount: Int
    let ahead: Int?
    let behind: Int?
}

struct WorkspaceListSummary: Codable, Sendable, Equatable {
    let workspaceId: String
    var activeCount: Int
    var stoppedCount: Int
    var hasAttention: Bool
    var hasErrorRoot: Bool
    var latestActivity: Date?
    var gitSummary: WorkspaceGitSummary?
    private(set) var hasGitSummarySnapshot: Bool

    enum CodingKeys: String, CodingKey {
        case workspaceId, activeCount, stoppedCount, hasAttention, hasErrorRoot, latestActivity, gitSummary
    }

    init(
        workspaceId: String,
        activeCount: Int,
        stoppedCount: Int,
        hasAttention: Bool,
        hasErrorRoot: Bool = false,
        latestActivity: Date? = nil,
        gitSummary: WorkspaceGitSummary? = nil,
        hasGitSummarySnapshot: Bool? = nil
    ) {
        self.workspaceId = workspaceId
        self.activeCount = activeCount
        self.stoppedCount = stoppedCount
        self.hasAttention = hasAttention
        self.hasErrorRoot = hasErrorRoot
        self.latestActivity = latestActivity
        self.gitSummary = gitSummary
        self.hasGitSummarySnapshot = hasGitSummarySnapshot ?? (gitSummary != nil)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        activeCount = try c.decode(Int.self, forKey: .activeCount)
        stoppedCount = try c.decode(Int.self, forKey: .stoppedCount)
        hasAttention = try c.decode(Bool.self, forKey: .hasAttention)
        hasErrorRoot = try c.decodeIfPresent(Bool.self, forKey: .hasErrorRoot) ?? false
        hasGitSummarySnapshot = c.contains(.gitSummary)
        gitSummary = try c.decodeIfPresent(WorkspaceGitSummary.self, forKey: .gitSummary)

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
        try c.encodeIfPresent(gitSummary, forKey: .gitSummary)
    }
}

// MARK: - Codable (Unix millisecond timestamps)

extension Workspace: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, description, icon
        case systemPrompt, systemPromptMode, hostMount, defaultModel
        case tools
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
        hostMount = try c.decodeIfPresent(String.self, forKey: .hostMount)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        systemPromptMode = try c.decodeIfPresent(WorkspaceSystemPromptMode.self, forKey: .systemPromptMode) ?? .append
        tools = try c.decodeIfPresent([String].self, forKey: .tools)
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
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encode(systemPromptMode, forKey: .systemPromptMode)
        try c.encodeIfPresent(hostMount, forKey: .hostMount)
        try c.encodeIfPresent(defaultModel, forKey: .defaultModel)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(gitStatusEnabled, forKey: .gitStatusEnabled)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(sandboxConfig, forKey: .sandboxConfig)
        try c.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try c.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
    }
}
