import SwiftUI

/// Create a new workspace on a specific server.
///
/// Two-step flow:
/// 1. Pick a project from discovered host directories (or enter manually)
/// 2. Confirm name, skills, and optional advanced settings
struct WorkspaceCreateView: View {
    /// The server to create the workspace on.
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: CreateStep = .pickProject
    @State private var directories: [HostDirectory] = []
    @State private var isLoadingDirectories = true
    @State private var directoriesError: String?

    // Form state (populated from project selection or manual entry)
    @State private var name = ""
    @State private var hostMount = ""
    @State private var description = ""
    @State private var icon = ""
    @State private var selectedSkills: Set<String> = []
    @State private var gitStatusEnabled = true
    @State private var showAdvanced = false
    @State private var sandboxMode = false
    @State private var isCreating = false
    @State private var error: String?

    private enum CreateStep {
        case pickProject
        case configure
    }

    /// Skills from the target server.
    private var skills: [SkillInfo] {
        workspaceStore.skillsByServer[server.id] ?? []
    }

    /// Whether the form is valid for submission.
    private var canCreate: Bool {
        if name.isEmpty { return false }
        if isCreating { return false }
        if sandboxMode && hostMount.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .pickProject:
                    projectPickerView
                case .configure:
                    configureView
                }
            }
            .themedListSurface()
            .navigationTitle(step == .pickProject ? "Pick a Project" : "New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadDirectories() }
            .task { await loadSkills() }
        }
    }

    // MARK: - Step 1: Project Picker

    private var projectPickerView: some View {
        List {
            Section {
                Toggle("Sandbox", isOn: $sandboxMode)
                if sandboxMode {
                    Text("Isolated micro-VM. Pick a project to mount.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            if isLoadingDirectories {
                Section {
                    HStack {
                        ProgressView()
                        Text("Scanning projects on server…")
                            .foregroundStyle(.themeComment)
                    }
                }
            } else if let directoriesError {
                Section {
                    Label(directoriesError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.themeOrange)
                    Button("Enter path manually") {
                        selectManual()
                    }
                }
            } else if directories.isEmpty {
                Section {
                    Text("No projects found in default locations.")
                        .foregroundStyle(.themeComment)
                    Text("Checked: ~/workspace, ~/projects, ~/src, ~/code, ~/Developer")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                    Button("Enter path manually") {
                        selectManual()
                    }
                }
            } else {
                Section {
                    ForEach(directories) { dir in
                        Button { selectProject(dir) } label: {
                            ProjectRow(directory: dir)
                        }
                        .foregroundStyle(.themeFg)
                    }
                } header: {
                    Text("Projects on \(server.name)")
                }

                Section {
                    Button { selectManual() } label: {
                        Label("Enter path manually", systemImage: "keyboard")
                    }
                    if !sandboxMode {
                        Button { selectBlank() } label: {
                            Label("Blank workspace (no project)", systemImage: "square.dashed")
                        }
                        .foregroundStyle(.themeComment)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Step 2: Configure

    private var configureView: some View {
        Form {
            // Sandbox toggle — first thing in the form
            Section {
                Toggle("Sandbox", isOn: $sandboxMode)
                if sandboxMode {
                    Text("Runs in an isolated micro-VM. Secrets and network are controlled by the host.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            // Project name + path
            Section("Project") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()

                if !hostMount.isEmpty {
                    HStack {
                        Text(hostMount)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.themeComment)
                        Spacer()
                        Button("Change") {
                            withAnimation { step = .pickProject }
                        }
                        .font(.caption)
                    }
                } else {
                    TextField(
                        sandboxMode
                            ? "~/workspace/project (required)"
                            : "~/workspace/project (optional)",
                        text: $hostMount
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                }

                if sandboxMode && hostMount.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("Sandbox requires a project path", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.themeOrange)
                }
            }

            // Skills
            Section("Skills") {
                if skills.isEmpty {
                    Text("Loading skills…")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(skills) { skill in
                        Button {
                            toggleSkill(skill.name)
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
                                Image(
                                    systemName: selectedSkills.contains(skill.name)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    selectedSkills.contains(skill.name)
                                        ? .themeBlue : .themeComment
                                )
                                .imageScale(.large)
                            }
                        }
                        .foregroundStyle(.themeFg)
                    }
                }
            }

            // Options
            Section {
                Toggle("Git status bar", isOn: $gitStatusEnabled)
            }

            if showAdvanced {
                Section("Optional") {
                    TextField("Description", text: $description)
                    TextField("Icon (SF Symbol or emoji)", text: $icon)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } else {
                Section {
                    Button("Show advanced options") {
                        withAnimation { showAdvanced = true }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.themeBlue)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.themeRed)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Spacer()
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create Workspace")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canCreate)
            }
        }
    }

    // MARK: - Selection Actions

    private func selectProject(_ dir: HostDirectory) {
        name = dir.name
        hostMount = dir.path
        gitStatusEnabled = dir.isGitRepo

        // Pre-select all skills by default
        if selectedSkills.isEmpty {
            selectedSkills = Set(skills.map(\.name))
        }

        withAnimation { step = .configure }
    }

    private func selectManual() {
        hostMount = ""

        if selectedSkills.isEmpty {
            selectedSkills = Set(skills.map(\.name))
        }

        withAnimation { step = .configure }
    }

    private func selectBlank() {
        name = ""
        hostMount = ""
        gitStatusEnabled = false

        if selectedSkills.isEmpty {
            selectedSkills = Set(skills.map(\.name))
        }

        withAnimation { step = .configure }
    }

    private func toggleSkill(_ skillName: String) {
        if selectedSkills.contains(skillName) {
            selectedSkills.remove(skillName)
        } else {
            selectedSkills.insert(skillName)
        }
    }

    // MARK: - Data Loading

    private func loadDirectories() async {
        guard let api = coordinator.apiClient(for: server.id) else {
            directoriesError = "Cannot connect to \(server.name)"
            isLoadingDirectories = false
            return
        }

        do {
            directories = try await api.listDirectories()
            isLoadingDirectories = false
        } catch {
            directoriesError = "Could not scan projects: \(error.localizedDescription)"
            isLoadingDirectories = false
        }
    }

    private func loadSkills() async {
        if (workspaceStore.skillsByServer[server.id] ?? []).isEmpty {
            guard let api = coordinator.apiClient(for: server.id) else { return }
            do {
                let skills = try await api.listSkills()
                workspaceStore.skillsByServer[server.id] = skills
            } catch {
                // Keep empty state; refresh will retry.
            }
        }
    }

    // MARK: - Create

    private func create() async {
        coordinator.switchToServer(server)

        guard let api = coordinator.apiClient(for: server.id) else {
            error = "Cannot connect to \(server.name)"
            return
        }

        isCreating = true
        error = nil

        let request = CreateWorkspaceRequest(
            name: name,
            description: description.isEmpty ? nil : description,
            icon: icon.isEmpty ? nil : icon,
            skills: Array(selectedSkills),
            hostMount: hostMount.isEmpty ? nil : hostMount,
            gitStatusEnabled: gitStatusEnabled,
            runtime: sandboxMode ? .sandbox : nil,
            sandboxConfig: sandboxMode ? SandboxConfig(allowedHosts: ["*"]) : nil
        )

        do {
            let workspace = try await api.createWorkspace(request)
            workspaceStore.upsert(workspace, serverId: server.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}

// MARK: - Project Row

private struct ProjectRow: View {
    let directory: HostDirectory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: directory.projectTypeIcon)
                .font(.title3)
                .foregroundStyle(.themeBlue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(directory.name)
                        .font(.body.weight(.medium))

                    if directory.isGitRepo {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.themeGreen)
                    }

                    if directory.hasAgentsMd {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.themeOrange)
                    }
                }

                HStack(spacing: 6) {
                    Text(directory.path)
                        .font(.caption)
                        .foregroundStyle(.themeComment)

                    if let language = directory.language {
                        Text(language)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.themeComment.opacity(0.18), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
