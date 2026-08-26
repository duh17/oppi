import Foundation

/// Request-boundary policy for composer launches. Only a model chosen in the
/// current composer becomes an override; nil leaves selection to Pi settings.
struct NewSessionModelOverride: Equatable, Sendable {
    let requestModelId: String?

    init(explicitlySelectedModelId: String?) {
        let trimmed = explicitlySelectedModelId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        requestModelId = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Display vs request split for composer model pills. Catalog `isDefault` is
/// inherited for the label only and never copied into the create payload.
/// `pillText` is the raw model id so SessionToolbar can show the same short
/// id as session rows (`grok-4.6`), not the catalog pretty name.
struct NewSessionModelPresentation: Equatable, Sendable {
    let requestModelId: String?
    let pillText: String
    /// Catalog provider for the pill icon when the id has no `provider/` prefix.
    let pillProvider: String?

    static func resolve(
        explicitlySelectedModelId: String?,
        isAgent: Bool,
        catalogModels: [ModelInfo]
    ) -> Self {
        let requestModelId = NewSessionModelOverride(
            explicitlySelectedModelId: explicitlySelectedModelId
        ).requestModelId
        if let requestModelId {
            let catalog = catalogModels.first(where: { $0.id == requestModelId })
            return Self(
                requestModelId: requestModelId,
                pillText: requestModelId,
                pillProvider: Self.displayProvider(catalog?.provider)
                    ?? providerFromModel(requestModelId)
            )
        }
        if isAgent {
            return Self(requestModelId: nil, pillText: "Agent", pillProvider: nil)
        }
        if let starred = catalogModels.first(where: \.isDefault) {
            return Self(
                requestModelId: nil,
                pillText: starred.id,
                pillProvider: Self.displayProvider(starred.provider)
            )
        }
        return Self(requestModelId: nil, pillText: "Model", pillProvider: nil)
    }

    private static func displayProvider(_ provider: String?) -> String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
    /// Selected checkout. Blank or missing resolves to Main.
    var worktreeId: String? = nil
    /// `nil` means plain Pi (no Agent).
    var agentId: String?
    var prompt: String
    var hasAttachments: Bool
    var hasRepoReferences: Bool
}

struct QuickSessionLaunchPlan: Equatable, Sendable {
    var mode: QuickSessionLaunchMode
    var workspaceId: String
    var worktreeId: String
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
        let worktreeId = QuickSessionWorktreePickerPolicy.normalizedLaunchWorktreeId(request.worktreeId)

        if let agentId, !agentId.isEmpty {
            if prompt.isEmpty {
                return .failure(.agentRequiresPrompt)
            }
            return .success(
                QuickSessionLaunchPlan(
                    mode: .agent(agentId: agentId),
                    workspaceId: workspaceId,
                    worktreeId: worktreeId,
                    prompt: prompt,
                    shouldAutoSend: true
                )
            )
        }

        return .success(
            QuickSessionLaunchPlan(
                mode: .plainPi,
                workspaceId: workspaceId,
                worktreeId: worktreeId,
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

/// Worktree selection for Quick Session create and Agent launch.
enum QuickSessionWorktreePickerPolicy {
    /// Hide the pill for single-checkout workspaces so Main is not a dead control.
    static func shouldShowPicker(worktreeCount: Int) -> Bool {
        worktreeCount > 1
    }

    static func resolvedWorktreeId(
        selectedId: String?,
        worktrees: [WorkspaceWorktree]
    ) -> String {
        if let selectedId, worktrees.contains(where: { $0.id == selectedId }) {
            return selectedId
        }
        return worktrees.first(where: \.isMain)?.id
            ?? worktrees.first?.id
            ?? WorkspaceWorktree.mainId
    }

    /// Create and Agent launch always send a concrete checkout. Blank input is Main.
    static func normalizedLaunchWorktreeId(_ worktreeId: String?) -> String {
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return WorkspaceWorktree.mainId
        }
        return trimmed
    }
}
