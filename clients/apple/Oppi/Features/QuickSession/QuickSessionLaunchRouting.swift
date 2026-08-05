import Foundation

/// Pure Quick Session start decision for plain Pi vs saved-Agent launch.
enum QuickSessionLaunchMode: Equatable, Sendable {
    /// Create an empty workspace session, then optionally auto-send through chat.
    case plainPi
    /// Launch through `POST /agents/{id}/sessions` so Agent definition applies.
    case agent(agentId: String)
}

enum QuickSessionLaunchValidationError: Equatable, Sendable, LocalizedError {
    case missingWorkspace
    case agentRequiresPrompt
    case agentAttachmentsUnsupported

    var errorDescription: String? {
        switch self {
        case .missingWorkspace:
            return "Choose a workspace first."
        case .agentRequiresPrompt:
            return "Add a message to start with an Agent."
        case .agentAttachmentsUnsupported:
            return "Remove attachments to start with an Agent."
        }
    }
}

struct QuickSessionLaunchRequest: Equatable, Sendable {
    var workspaceId: String?
    /// `nil` means plain Pi (no Agent).
    var agentId: String?
    var prompt: String
    var hasAttachments: Bool
    var hasRepoReferences: Bool
}

struct QuickSessionLaunchPlan: Equatable, Sendable {
    var mode: QuickSessionLaunchMode
    var workspaceId: String
    var prompt: String
    /// Only meaningful for plain Pi — Agent launch delivers the prompt server-side.
    var shouldAutoSend: Bool
}

enum QuickSessionLaunchRouting {
    /// Resolve whether Quick Session should create a plain Pi session or launch an Agent.
    static func plan(for request: QuickSessionLaunchRequest) -> Result<QuickSessionLaunchPlan, QuickSessionLaunchValidationError> {
        guard let workspaceId = request.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceId.isEmpty
        else {
            return .failure(.missingWorkspace)
        }

        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentId = request.agentId?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let agentId, !agentId.isEmpty {
            if request.hasAttachments || request.hasRepoReferences {
                return .failure(.agentAttachmentsUnsupported)
            }
            if prompt.isEmpty {
                return .failure(.agentRequiresPrompt)
            }
            return .success(
                QuickSessionLaunchPlan(
                    mode: .agent(agentId: agentId),
                    workspaceId: workspaceId,
                    prompt: prompt,
                    shouldAutoSend: false
                )
            )
        }

        return .success(
            QuickSessionLaunchPlan(
                mode: .plainPi,
                workspaceId: workspaceId,
                prompt: prompt,
                shouldAutoSend: !prompt.isEmpty || request.hasAttachments || request.hasRepoReferences
            )
        )
    }

    /// Prefer a remembered Agent only when it still exists in the active server list.
    static func preferredAgentId(
        lastAgentId: String?,
        availableAgentIds: [String]
    ) -> String? {
        guard let lastAgentId, !lastAgentId.isEmpty else { return nil }
        return availableAgentIds.contains(lastAgentId) ? lastAgentId : nil
    }
}
