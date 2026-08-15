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

    var errorDescription: String? {
        switch self {
        case .missingWorkspace:
            return "Choose a workspace first."
        case .agentRequiresPrompt:
            return "Add a message to start with an Agent."
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

extension SlashCommand {
    static func promptTemplates(from options: [WorkspaceQuickActionOption]) -> [SlashCommand] {
        options.map {
            SlashCommand(
                name: $0.commandName,
                description: $0.description,
                source: .prompt
            )
        }
    }

    static func skills(from skills: [SkillInfo]) -> [SlashCommand] {
        skills.compactMap { skill in
            guard skill.enabled else { return nil }
            return SlashCommand(
                name: "skill:\(skill.name)",
                description: skill.description.isEmpty ? nil : skill.description,
                source: .skill
            )
        }
    }
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
            if prompt.isEmpty {
                return .failure(.agentRequiresPrompt)
            }
            return .success(
                QuickSessionLaunchPlan(
                    mode: .agent(agentId: agentId),
                    workspaceId: workspaceId,
                    prompt: prompt,
                    shouldAutoSend: true
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

    static func compatibleWorkspaces(
        for constraints: AgentLaunchConstraints?,
        in workspaces: [Workspace]
    ) -> [Workspace] {
        guard let constraints else { return workspaces }
        return workspaces.filter(constraints.allows)
    }

    static func canNavigateAfterAgentLaunch(_ response: AgentSessionLaunchResponse) -> Bool {
        response.receipt.accepted
            && response.receipt.promptDispatch == "delivered"
            && response.session != nil
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
