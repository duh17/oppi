import Foundation

struct MacWorkspaceCreationDraft: Equatable, Sendable {
    var name: String = ""
    var hostMount: String = ""
    var description: String = ""
    var defaultModel: String = ""
    var gitStatusEnabled = true
    var runtime: WorkspaceRuntime = .host

    init(
        name: String = "",
        hostMount: String = "",
        description: String = "",
        defaultModel: String = "",
        gitStatusEnabled: Bool = true,
        runtime: WorkspaceRuntime = .host
    ) {
        self.name = name
        self.hostMount = hostMount
        self.description = description
        self.defaultModel = defaultModel
        self.gitStatusEnabled = gitStatusEnabled
        self.runtime = runtime
    }

    init(workspace: Workspace) {
        name = workspace.name
        hostMount = workspace.hostMount ?? ""
        description = workspace.description ?? ""
        defaultModel = workspace.defaultModel ?? ""
        gitStatusEnabled = workspace.gitStatusEnabled ?? true
        runtime = workspace.runtime ?? .host
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedHostMount: String {
        hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedDefaultModel: String {
        defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        !trimmedName.isEmpty
    }

    var validationMessage: String? {
        if trimmedName.isEmpty { return "Workspace name is required." }
        return nil
    }

    var request: CreateWorkspaceRequest? {
        guard canSubmit else { return nil }
        return CreateWorkspaceRequest(
            name: trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            icon: .defaultValue,
            systemPrompt: nil,
            systemPromptMode: nil,
            hostMount: trimmedHostMount.isEmpty ? nil : trimmedHostMount,
            defaultModel: trimmedDefaultModel.isEmpty ? nil : trimmedDefaultModel,
            gitStatusEnabled: gitStatusEnabled,
            runtime: runtime,
            sandboxConfig: nil
        )
    }

    var updateRequest: UpdateWorkspaceRequest? {
        guard canSubmit else { return nil }
        return UpdateWorkspaceRequest(
            name: trimmedName,
            description: trimmedDescription.isEmpty ? .null : .string(trimmedDescription),
            hostMount: trimmedHostMount.isEmpty ? .null : .string(trimmedHostMount),
            defaultModel: trimmedDefaultModel.isEmpty ? .null : .string(trimmedDefaultModel),
            gitStatusEnabled: gitStatusEnabled
        )
    }
}
