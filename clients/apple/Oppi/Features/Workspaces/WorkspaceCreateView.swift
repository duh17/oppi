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
        prefillName: String? = nil,
        prefillPath: String? = nil,
        onCreate: ((Workspace) -> Void)? = nil
    ) {
        self.server = server
        self.presentation = presentation
        self.onCreate = onCreate

        if let prefillPath {
            // Deep-linked workspaces intentionally start minimal: skills remain
            // empty unless the user opts in before creating the workspace.
            _name = State(initialValue: prefillName ?? "")
            _hostMount = State(initialValue: prefillPath)
            _isHostMountFromProjectPicker = State(initialValue: false)
            _step = State(initialValue: .configure)
        } else if let prefillName {
            _name = State(initialValue: prefillName)
        }
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
    @State private var isHostMountFromProjectPicker = false
    @State private var description = ""
    @State private var icon = ""
    @State private var selectedSkills: Set<String> = []
    @State private var gitStatusEnabled = true
    @State private var hostMountStatus: HostPathStatus?
    @State private var hostMountValidationMessage: String?
    @State private var isCheckingHostMount = false
    @State private var isCreatingHostDirectory = false
    @State private var hostPathPendingCreation: String?
    @State private var hostMountCompletions: [HostPathCompletion] = []
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

    /// Store scoped to the server this sheet creates on. The environment store
    /// normally matches, but deep links can switch servers just before presenting.
    private var targetWorkspaceStore: WorkspaceStore {
        coordinator.connection(for: server.id)?.workspaceStore ?? workspaceStore
    }

    /// Skills from the target server.
    private var skills: [SkillInfo] {
        targetWorkspaceStore.skillsByServer[server.id] ?? []
    }

    private var trimmedHostMount: String {
        hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the form is valid for submission.
    private var canCreate: Bool {
        if name.isEmpty { return false }
        if isCreating { return false }
        if !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount else { return false }
            if !hostMountStatus.isValidWorkspaceDirectory { return false }
        }
        return true
    }

    private var hostMountLookupKey: String {
        "\(server.id)|\(isHostMountFromProjectPicker)|\(trimmedHostMount)"
    }

    private var skillNames: Set<String> {
        Set(skills.map(\.name))
    }

    private var areAllSkillsSelected: Bool {
        !skills.isEmpty && selectedSkills == skillNames
    }

    private var skillsSelectionSummary: String {
        if skills.isEmpty { return "Loading skills…" }
        if selectedSkills.isEmpty { return "No skills enabled" }
        if areAllSkillsSelected { return "All skills enabled" }
        return "\(selectedSkills.count) of \(skills.count) skills enabled"
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
                if step == .configure {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await create() }
                        } label: {
                            if isCreating {
                                ProgressView()
                            } else {
                                Text("Create")
                            }
                        }
                        .disabled(!canCreate)
                        .accessibilityIdentifier("workspace.create.submit")
                    }
                }
            }
            .task { await loadDirectories() }
            .task { await loadSkills() }
            .task(id: hostMountLookupKey) {
                await validateAndCompleteHostMount()
            }
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
                        Text("A workspace tells Oppi which folder to work in. Pick a project on \(server.name), enter an existing path manually, or start blank if you just want to explore the app.")
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

            Section {
                Button { selectManual() } label: {
                    Label("Enter path manually", systemImage: "keyboard")
                }
                .accessibilityIdentifier("workspace.create.manual")

                if !sandboxMode {
                    Button { selectBlank() } label: {
                        Label("Blank workspace (home folder)", systemImage: "house")
                    }
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
                        Text("You can still enter an existing path manually or create a blank workspace that uses the server home folder.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
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
                        Text("That’s okay. Enter an existing path manually or create a blank workspace that uses the server home folder.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
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
                    .accessibilityIdentifier("workspace.create.name")

                if isHostMountFromProjectPicker {
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
                    TextField("~/workspace/project (must exist)", text: $hostMount)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("workspace.create.hostMount")

                    Text(
                        sandboxMode
                            ? "Leave empty to let Oppi create a sandbox folder. Network starts denied by default; edit the workspace later to allow specific hosts. For a custom path, use Create this folder when the path is missing."
                            : "Leave empty to use the server home folder. If the path doesn’t exist, use Create this folder below; Oppi asks before creating one directory."
                    )
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                }

                hostMountValidationView

                if !isHostMountFromProjectPicker && !hostMountCompletions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Suggestions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                        ForEach(hostMountCompletions) { completion in
                            Button {
                                applyHostMountCompletion(completion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.themeComment)
                                    Text(completion.path)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer(minLength: 8)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if sandboxMode && hostMount.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("A new directory will be created at ~/sandbox/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))/")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            // Skills
            Section {
                HStack {
                    Text(skillsSelectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                    Spacer()
                    HStack(spacing: 8) {
                        Button("All") { selectAllSkills() }
                            .disabled(skills.isEmpty || areAllSkillsSelected)
                        Button("Off") { clearAllSkills() }
                            .disabled(skills.isEmpty || selectedSkills.isEmpty)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

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
            } header: {
                Text("Skills")
            } footer: {
                Text("Use All for the full skill catalog, or Off to start minimal and enable only what this workspace needs.")
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
                .accessibilityIdentifier("workspace.create.submit.form")
            }
        }
    }

    @ViewBuilder
    private var hostMountValidationView: some View {
        if !trimmedHostMount.isEmpty {
            if isCheckingHostMount {
                Label("Checking path…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            } else if let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                      hostMountStatus.issue == "missing" {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Path doesn’t exist", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.themeComment)

                    if hostPathPendingCreation == trimmedHostMount {
                        Text("Create this one folder on \(server.name)? The parent folder must already exist.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)

                        if isCreatingHostDirectory {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Creating folder…")
                                    .font(.caption)
                                    .foregroundStyle(.themeComment)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Button {
                                    Task { await createHostDirectoryFromPendingPath() }
                                } label: {
                                    Label("Create Folder", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("workspace.create.confirmCreateFolder")

                                Button("Cancel") {
                                    hostPathPendingCreation = nil
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("workspace.create.cancelCreateFolder")
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button {
                            hostPathPendingCreation = trimmedHostMount
                        } label: {
                            Label("Create this folder", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace.create.createMissingFolder")
                        .disabled(isCreatingHostDirectory)
                    }
                }
            } else if let hostMountValidationMessage {
                Label(hostMountValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                      hostMountStatus.isValidWorkspaceDirectory {
                Label("Path exists", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeGreen)
            }
        }
    }

    // MARK: - Selection Actions

    private func selectProject(_ dir: HostDirectory) {
        name = dir.name
        hostMount = dir.path
        isHostMountFromProjectPicker = true
        hostMountStatus = HostPathStatus(
            path: dir.path,
            resolvedPath: dir.path,
            exists: true,
            isDirectory: true,
            isFile: false,
            issue: nil,
            message: nil
        )
        hostMountValidationMessage = nil
        hostPathPendingCreation = nil
        hostMountCompletions = []
        gitStatusEnabled = dir.isGitRepo
        requestDefaultSkillSelectionIfNeeded()
        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .configure }
    }

    private func selectManual() {
        resetHostMountInput()
        requestDefaultSkillSelectionIfNeeded()
        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .configure }
    }

    private func selectBlank() {
        name = ""
        resetHostMountInput()
        gitStatusEnabled = false
        requestDefaultSkillSelectionIfNeeded()
        withAnimation(ThemeMotion.standard(reduceMotion: reduceMotion)) { step = .configure }
    }

    private func resetHostMountInput() {
        hostMount = ""
        isHostMountFromProjectPicker = false
        hostMountStatus = nil
        hostMountValidationMessage = nil
        hostPathPendingCreation = nil
        hostMountCompletions = []
        isCheckingHostMount = false
        isCreatingHostDirectory = false
    }

    private func applyHostMountCompletion(_ completion: HostPathCompletion) {
        hostMount = completion.path
        isHostMountFromProjectPicker = false
        hostMountStatus = HostPathStatus(
            path: completion.path,
            resolvedPath: completion.path,
            exists: true,
            isDirectory: true,
            isFile: false,
            issue: nil,
            message: nil
        )
        hostMountValidationMessage = nil
        hostPathPendingCreation = nil
        hostMountCompletions = []
    }

    private func requestDefaultSkillSelectionIfNeeded() {
        guard selectedSkills.isEmpty else { return }

        if skills.isEmpty {
            selectAllSkillsWhenLoaded = true
            return
        }

        selectedSkills = skillNames
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

    private func selectAllSkills() {
        selectedSkills = skillNames
        selectAllSkillsWhenLoaded = skills.isEmpty
    }

    private func clearAllSkills() {
        selectedSkills.removeAll()
        selectAllSkillsWhenLoaded = false
    }

    // MARK: - Data Loading

    @MainActor
    private func validateAndCompleteHostMount() async {
        let current = trimmedHostMount
        if let pending = hostPathPendingCreation, pending != current {
            hostPathPendingCreation = nil
        }
        guard !current.isEmpty else {
            hostMountStatus = nil
            hostMountValidationMessage = nil
            hostPathPendingCreation = nil
            hostMountCompletions = []
            isCheckingHostMount = false
            return
        }

        guard let api = coordinator.apiClient(for: server.id) else {
            hostMountStatus = nil
            hostMountValidationMessage = "Cannot check path while the server is offline"
            hostMountCompletions = []
            isCheckingHostMount = false
            return
        }

        isCheckingHostMount = true
        hostMountValidationMessage = nil
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard current == trimmedHostMount else { return }

        do {
            let status = try await api.getHostPathStatus(path: current)
            let completions = isHostMountFromProjectPicker
                ? []
                : try await api.completeHostPath(prefix: current, limit: 8)
            guard current == trimmedHostMount else { return }
            hostMountStatus = status
            hostMountValidationMessage = status.isValidWorkspaceDirectory
                ? nil
                : status.userMessage
            hostMountCompletions = completions.filter { $0.path != current }
        } catch {
            guard current == trimmedHostMount else { return }
            hostMountStatus = nil
            hostMountValidationMessage = "Could not check path: \(error.localizedDescription)"
            hostMountCompletions = []
        }

        if current == trimmedHostMount {
            isCheckingHostMount = false
        }
    }

    @MainActor
    private func createHostDirectoryFromPendingPath() async {
        guard let path = hostPathPendingCreation else { return }
        guard path == trimmedHostMount else {
            hostPathPendingCreation = nil
            return
        }
        guard let api = coordinator.apiClient(for: server.id) else {
            error = "Cannot connect to \(server.name)"
            hostPathPendingCreation = nil
            return
        }

        isCreatingHostDirectory = true
        error = nil
        defer {
            isCreatingHostDirectory = false
            hostPathPendingCreation = nil
        }

        do {
            let result = try await api.createHostPath(path: path)
            hostMount = result.status.path.isEmpty ? path : result.status.path
            hostMountStatus = result.status
            hostMountValidationMessage = result.status.isValidWorkspaceDirectory
                ? nil
                : result.status.userMessage
            isCheckingHostMount = false
            hostMountCompletions = []
        } catch {
            self.error = "Create folder failed: \(error.localizedDescription)"
        }
    }

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
        let store = targetWorkspaceStore
        if (store.skillsByServer[server.id] ?? []).isEmpty {
            guard let api = coordinator.apiClient(for: server.id) else { return }
            do {
                let loadedSkills = try await api.listSkills()
                store.skillsByServer[server.id] = loadedSkills

                if selectAllSkillsWhenLoaded && selectedSkills.isEmpty {
                    selectedSkills = skillNames
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

        let trimmedHostMount = hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                  hostMountStatus.isValidWorkspaceDirectory else {
                error = hostMountValidationMessage ?? "Path doesn’t exist"
                return
            }
        }

        isCreating = true
        error = nil

        let request = CreateWorkspaceRequest(
            name: name,
            description: description.isEmpty ? nil : description,
            icon: icon.isEmpty ? nil : icon,
            skills: Array(selectedSkills).sorted(),
            hostMount: trimmedHostMount.isEmpty ? nil : trimmedHostMount,
            gitStatusEnabled: gitStatusEnabled,
            runtime: sandboxMode ? .sandbox : nil,
            sandboxConfig: sandboxMode ? SandboxConfig(allowedHosts: []) : nil
        )

        do {
            let workspace = try await api.createWorkspace(request)
            let targetConnection = coordinator.connection(for: server.id)
            (targetConnection?.workspaceStore ?? workspaceStore).upsert(workspace, serverId: server.id)
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
