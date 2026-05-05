import SwiftUI

enum WorkspaceCreatePresentation: Equatable, Sendable {
    case standard
    case guidedFirstWorkspace
}

/// Create a new workspace on a specific server.
///
/// Two-step flow:
/// 1. Pick a project from discovered host directories (or enter manually)
/// 2. Confirm name, skills, and optional advanced settings
struct WorkspaceCreateView: View {
    /// The server to create the workspace on.
    let server: PairedServer
    let presentation: WorkspaceCreatePresentation
    let onCreate: ((Workspace) -> Void)?

    init(
        server: PairedServer,
        presentation: WorkspaceCreatePresentation = .standard,
        onCreate: ((Workspace) -> Void)? = nil
    ) {
        self.server = server
        self.presentation = presentation
        self.onCreate = onCreate
    }

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var selectAllSkillsWhenLoaded = false

    private enum CreateStep {
        case pickProject
        case configure
    }

    private var isGuidedFirstWorkspace: Bool {
        presentation == .guidedFirstWorkspace
    }

    private var navigationTitle: String {
        switch (presentation, step) {
        case (.guidedFirstWorkspace, .pickProject):
            return "Set Up Workspace"
        case (.guidedFirstWorkspace, .configure):
            return "Review Workspace"
        case (_, .pickProject):
            return "Pick a Project"
        case (_, .configure):
            return "New Workspace"
        }
    }

    private var cancelButtonTitle: String {
        isGuidedFirstWorkspace ? "Not Now" : "Cancel"
    }

    /// Skills from the target server.
    private var skills: [SkillInfo] {
        workspaceStore.skillsByServer[server.id] ?? []
    }

    /// Whether the form is valid for submission.
    private var canCreate: Bool {
        if name.isEmpty { return false }
        if isCreating { return false }
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
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelButtonTitle) { dismiss() }
                }
            }
            .task { await loadDirectories() }
            .task { await loadSkills() }
        }
    }

    // MARK: - Step 1: Project Picker

    private var projectPickerView: some View {
        List {
            if isGuidedFirstWorkspace {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create your first workspace")
                            .font(.headline)
                        Text("A workspace tells Oppi which folder to work in. Pick a project on \(server.name), enter a path manually, or start blank if you just want to explore the app.")
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                    }
                    .padding(.vertical, 4)
                }
            }

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
                    if isGuidedFirstWorkspace {
                        Text("You can still enter a path manually or create a blank workspace to keep going.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                    Button("Enter path manually") {
                        selectManual()
                    }
                    if !sandboxMode {
                        Button("Create blank workspace") {
                            selectBlank()
                        }
                    }
                }
            } else if directories.isEmpty {
                Section {
                    Text("No projects found in default locations.")
                        .foregroundStyle(.themeComment)
                    Text("Checked: ~/workspace, ~/projects, ~/src, ~/code, ~/Developer")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                    if isGuidedFirstWorkspace {
                        Text("That’s okay. Enter a path manually or create a blank workspace to see how Oppi works.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                    Button("Enter path manually") {
                        selectManual()
                    }
                    if !sandboxMode {
                        Button("Create blank workspace") {
                            selectBlank()
                        }
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
            if isGuidedFirstWorkspace {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Almost there")
                            .font(.headline)
                        Text("Review the workspace settings, then create it. Oppi will open the workspace next so you can start your first session.")
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                    }
                    .padding(.vertical, 4)
                }
            }

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
                            withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .pickProject }
                        }
                        .font(.caption)
                    }
                } else {
                    TextField("~/workspace/project (optional)", text: $hostMount)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }

                if sandboxMode && hostMount.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("A new directory will be created at ~/sandbox/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))/")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            // Skills
            Section("Skills") {
                if skills.isEmpty {
                    Text("Loading skills…")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(skills) { skill in
                        WorkspaceCreateSkillSelectionRow(
                            skill: skill,
                            isSelected: selectedSkills.contains(skill.name),
                            onToggle: {
                                toggleSkill(skill.name)
                            }
                        )
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
                        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { showAdvanced = true }
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
        requestDefaultSkillSelectionIfNeeded()
        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .configure }
    }

    private func selectManual() {
        hostMount = ""
        requestDefaultSkillSelectionIfNeeded()
        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .configure }
    }

    private func selectBlank() {
        name = ""
        hostMount = ""
        gitStatusEnabled = false
        requestDefaultSkillSelectionIfNeeded()
        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .configure }
    }

    private func requestDefaultSkillSelectionIfNeeded() {
        guard selectedSkills.isEmpty else { return }

        if skills.isEmpty {
            selectAllSkillsWhenLoaded = true
            return
        }

        selectedSkills = Set(skills.map(\.name))
        selectAllSkillsWhenLoaded = false
    }

    private func toggleSkill(_ skillName: String) {
        if selectedSkills.contains(skillName) {
            selectedSkills.remove(skillName)
        } else {
            selectedSkills.insert(skillName)
        }
        selectAllSkillsWhenLoaded = false
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
                let loadedSkills = try await api.listSkills()
                workspaceStore.skillsByServer[server.id] = loadedSkills

                if selectAllSkillsWhenLoaded && selectedSkills.isEmpty {
                    selectedSkills = Set(loadedSkills.map(\.name))
                    selectAllSkillsWhenLoaded = false
                }
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
            skills: Array(selectedSkills).sorted(),
            hostMount: hostMount.isEmpty ? nil : hostMount,
            gitStatusEnabled: gitStatusEnabled,
            runtime: sandboxMode ? .sandbox : nil,
            sandboxConfig: sandboxMode ? SandboxConfig(allowedHosts: ["*"]) : nil
        )

        do {
            let workspace = try await api.createWorkspace(request)
            workspaceStore.upsert(workspace, serverId: server.id)
            onCreate?(workspace)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}

// MARK: - Skill Selection Row

private struct WorkspaceCreateSkillSelectionRow: View {
    let skill: SkillInfo
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body)
                    .foregroundStyle(.themeFg)

                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            WorkspaceSelectionButton(
                isSelected: isSelected,
                accessibilityLabel: isSelected
                    ? "Disable \(skill.name) skill"
                    : "Enable \(skill.name) skill",
                action: onToggle
            )
        }
    }
}

// MARK: - Project Row

private struct ProjectRow: View {
    let directory: HostDirectory

    private var accessibilityLabel: String {
        var parts = [directory.name]

        if let language = directory.language {
            parts.append(language)
        }
        if directory.isGitRepo {
            parts.append("Git repository")
        }
        if directory.hasAgentsMd {
            parts.append("Has agent configuration")
        }

        parts.append(directory.path)
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: directory.projectTypeIcon)
                .font(.title3)
                .foregroundStyle(.themeBlue)
                .frame(minWidth: 28)

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Select project")
    }
}
