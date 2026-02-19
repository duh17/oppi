import SwiftUI

/// Create a new workspace on a specific server.
struct WorkspaceCreateView: View {
    /// The server to create the workspace on. Required for multi-server.
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var icon = ""
    @State private var selectedSkills: Set<String> = []
    @State private var isCreating = false
    @State private var error: String?

    /// Skills from the target server.
    private var skills: [SkillInfo] {
        connection.workspaceStore.skillsByServer[server.id] ?? connection.workspaceStore.skills
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    TextField("Description (optional)", text: $description)
                    TextField("Icon — SF Symbol or emoji (optional)", text: $icon)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Skills") {
                    if skills.isEmpty {
                        Text("Loading skills…")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(skills) { skill in
                            Button {
                                if selectedSkills.contains(skill.name) {
                                    selectedSkills.remove(skill.name)
                                } else {
                                    selectedSkills.insert(skill.name)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name)
                                            .font(.body)

                                        Text(skill.description)
                                            .font(.caption)
                                            .foregroundStyle(.themeComment)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    Image(systemName: selectedSkills.contains(skill.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedSkills.contains(skill.name) ? .themeBlue : .themeComment)
                                        .imageScale(.large)
                                }
                            }
                            .foregroundStyle(.themeFg)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.themeRed)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Workspace on \(server.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(name.isEmpty || isCreating)
                }
            }
            .task { await loadSkills() }
        }
    }

    private func loadSkills() async {
        // Load skills from target server if not cached
        if (connection.workspaceStore.skillsByServer[server.id] ?? []).isEmpty {
            guard let api = coordinator.apiClient(for: server.id) else { return }
            do {
                let skills = try await api.listSkills()
                connection.workspaceStore.skillsByServer[server.id] = skills
            } catch {
                // Fall back to flat skills list
            }
        }
    }

    private func create() async {
        // Ensure we're talking to the right server
        coordinator.switchToServer(server)

        guard let api = coordinator.apiClient(for: server.id) ?? connection.apiClient else {
            error = "Cannot connect to \(server.name)"
            return
        }
        isCreating = true
        error = nil

        let request = CreateWorkspaceRequest(
            name: name,
            description: description.isEmpty ? nil : description,
            icon: icon.isEmpty ? nil : icon,
            skills: Array(selectedSkills)
        )

        do {
            let workspace = try await api.createWorkspace(request)
            connection.workspaceStore.upsert(workspace, serverId: server.id)
            // Also update flat list for backward compat
            connection.workspaceStore.upsert(workspace)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}
