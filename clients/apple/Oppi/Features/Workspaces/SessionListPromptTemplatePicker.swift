import SwiftUI

extension View {
    func sessionListPromptSwipeActions(
        sessionId: String,
        status: SessionStatus,
        workspaceId: String?,
        onPrompt: @escaping () -> Void
    ) -> some View {
        swipeActions(edge: .leading, allowsFullSwipe: false) {
            if SessionListPromptSwipePolicy.leadingAction(
                status: status,
                workspaceId: workspaceId
            ) == .prompt {
                Button(action: onPrompt) {
                    Label("Prompt", systemImage: SlashCommand.Source.prompt.iconName)
                }
                .tint(.themeCyan)
                .accessibilityIdentifier("session.prompt.\(sessionId)")
            }
        }
    }
}

/// Sheet listing a workspace's prompt templates for sending into a live session.
struct SessionListPromptTemplatePicker: View {
    let workspaceId: String
    let apiClient: APIClient?
    let onSelect: (String) -> Void
    let onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var commands: [SlashCommand] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if isLoading && commands.isEmpty {
                    Text("Loading templates…")
                        .foregroundStyle(.themeComment)
                        .themedListRowBackground()
                } else if commands.isEmpty {
                    Text("No prompt templates")
                        .foregroundStyle(.themeComment)
                        .themedListRowBackground()
                } else {
                    ForEach(commands) { command in
                        Button {
                            onSelect(command.name)
                            dismiss()
                        } label: {
                            Label(command.invocation, systemImage: SlashCommand.Source.prompt.iconName)
                        }
                        .themedListRowBackground()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .navigationTitle("Prompt Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await loadTemplates()
            }
        }
    }

    private func loadTemplates() async {
        guard let apiClient else {
            // Parent owns presentation so the Error alert is not raced away by dismiss.
            onError("Server is offline — reconnecting in background")
            return
        }

        do {
            let options = try await apiClient.getWorkspaceQuickActions(workspaceId: workspaceId).actions
            guard !Task.isCancelled else { return }
            commands = SlashCommand.promptTemplates(from: options)
            isLoading = false
        } catch {
            guard SessionListPromptTemplateLoadErrorPolicy.shouldPresent(error),
                  !Task.isCancelled else { return }
            isLoading = false
            onError("Failed to load prompt templates: \(error.localizedDescription)")
        }
    }
}
