import Foundation

struct SubagentConfig: Codable, Sendable, Equatable {
    var maxDepth: Int
    var autoStopWhenDone: Bool
    var childIdleTimeoutMs: Int
    var startupGraceMs: Int
    var defaultWaitTimeoutMs: Int
    var modelPolicy: SubagentModelPolicy?

    static let fallback = SubagentConfig(
        maxDepth: 1,
        autoStopWhenDone: false,
        childIdleTimeoutMs: 300_000,
        startupGraceMs: 60000,
        defaultWaitTimeoutMs: 1_800_000,
        modelPolicy: nil
    )
}

struct SubagentModelPolicy: Codable, Sendable, Equatable {
    var approvedModels: [String]?
    var defaultModel: String?
    var defaultThinking: ThinkingLevel?
    var profiles: [String: SubagentModelProfile]?
}

struct SubagentModelProfile: Codable, Sendable, Equatable {
    var description: String?
    var model: String?
    var thinking: ThinkingLevel?
    var guidelines: [String]?
}
