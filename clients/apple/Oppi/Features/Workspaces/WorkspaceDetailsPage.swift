import SwiftUI

/// Name, description, icon, and folder of one workspace. Edits are a draft:
/// Save writes the changed fields, back discards them.
struct WorkspaceDetailsPage: View {
    let model: WorkspaceSettingsModel

    @Environment(\.dismiss) private var dismiss

    @State private var draft: WorkspaceDetailsDraft
    @State private var hostMountStatus: HostPathStatus?
    @State private var hostMountValidationMessage: String?
    @State private var isCheckingHostMount = false
    @State private var isCreatingHostDirectory = false
    @State private var hostPathPendingCreation: String?
    @State private var isShowingIconPicker = false
    @State private var isSaving = false
    @State private var error: String?
    /// A save that finishes after Back must not pop whatever is on top now.
    @State private var isVisible = true

    init(model: WorkspaceSettingsModel) {
        self.model = model
        _draft = State(initialValue: WorkspaceDetailsDraft(workspace: model.workspace))
    }

    private var trimmedHostMount: String { draft.trimmedHostMount }

    private var hostMountLookupKey: String {
        "\(model.workspace.id)|\(trimmedHostMount)"
    }

    private var isDirty: Bool {
        draft.request(against: model.workspace) != nil
    }

    private var canSave: Bool {
        if draft.name.isEmpty || isSaving || !isDirty { return false }
        // An unchanged folder was valid when it was saved; only a new one is checked.
        if draft.changesFolder(of: model.workspace), !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount else { return false }
            if !hostMountStatus.isValidWorkspaceDirectory { return false }
        }
        return true
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Required"))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("workspace.edit.name")
                }
                LabeledContent("Description") {
                    TextField("Description", text: $draft.description, prompt: Text("Optional"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("workspace.edit.description")
                }
                Button {
                    isShowingIconPicker = true
                } label: {
                    HStack {
                        Text("Icon")
                        Spacer(minLength: 12)
                        WorkspaceIcon(icon: draft.icon, size: 22)
                            .frame(width: 32, height: 32)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workspace icon")
                .accessibilityValue(WorkspaceIconPickerView.description(draft.icon))
                .accessibilityHint("Opens the icon picker")
                .accessibilityIdentifier("workspace.edit.icon")
            }

            Section {
                TextField("~/workspace/project (must exist)", text: $draft.hostMount)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("workspace.edit.hostMount")

                hostMountValidationView
            } header: {
                Text("Workspace Folder")
            } footer: {
                Text("Leave empty to use the server home folder. If the folder doesn\u{2019}t exist, use Create this folder below; Oppi asks before creating one directory.")
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.themeRed)
                        .accessibilityIdentifier("workspace.edit.details.error")
                }
            }
        }
        .settingsPage("Details")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("workspace.edit.save")
            }
        }
        .sheet(isPresented: $isShowingIconPicker) {
            WorkspaceIconPickerView(icon: $draft.icon)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: hostMountLookupKey) {
            await validateHostMount()
        }
    }

    // MARK: - Folder validation

    @ViewBuilder
    private var hostMountValidationView: some View {
        if !trimmedHostMount.isEmpty {
            if isCheckingHostMount {
                Label("Checking folder\u{2026}", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            } else if let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                      hostMountStatus.issue == "missing" {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Folder doesn\u{2019}t exist", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.themeComment)

                    if hostPathPendingCreation == trimmedHostMount {
                        Text("Create this one folder on the server? The parent folder must already exist.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)

                        if isCreatingHostDirectory {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Creating folder\u{2026}")
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
                                .accessibilityIdentifier("workspace.edit.confirmCreateFolder")

                                Button("Cancel") {
                                    hostPathPendingCreation = nil
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("workspace.edit.cancelCreateFolder")
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
                        .accessibilityIdentifier("workspace.edit.createMissingFolder")
                        .disabled(isCreatingHostDirectory)
                    }
                }
            } else if let hostMountValidationMessage {
                Label(hostMountValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                      hostMountStatus.isValidWorkspaceDirectory {
                Label("Folder exists", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeGreen)
            }
        }
    }

    @MainActor
    private func validateHostMount() async {
        let current = trimmedHostMount
        if let pending = hostPathPendingCreation, pending != current {
            hostPathPendingCreation = nil
        }
        guard !current.isEmpty else {
            hostMountStatus = nil
            hostMountValidationMessage = nil
            hostPathPendingCreation = nil
            isCheckingHostMount = false
            return
        }

        guard model.isServerReachable else {
            hostMountStatus = nil
            hostMountValidationMessage = "Cannot check path while the server is offline"
            isCheckingHostMount = false
            return
        }

        isCheckingHostMount = true
        hostMountValidationMessage = nil
        // Debounce typing; a newer keystroke cancels this task.
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            return
        }
        guard current == trimmedHostMount else { return }

        do {
            guard let status = try await model.hostPathStatus(current) else { return }
            guard current == trimmedHostMount else { return }
            hostMountStatus = status
            hostMountValidationMessage = status.isValidWorkspaceDirectory
                ? nil
                : status.userMessage
        } catch {
            guard current == trimmedHostMount,
                  WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            hostMountStatus = nil
            hostMountValidationMessage = "Could not check path: \(error.localizedDescription)"
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
        guard model.isServerReachable else {
            error = "Server is offline"
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
            guard let result = try await model.createHostPath(path) else { return }
            draft.hostMount = result.status.path.isEmpty ? path : result.status.path
            hostMountStatus = result.status
            hostMountValidationMessage = result.status.isValidWorkspaceDirectory
                ? nil
                : result.status.userMessage
            isCheckingHostMount = false
        } catch {
            guard WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            self.error = "Create folder failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func save() async {
        if draft.changesFolder(of: model.workspace), !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                  hostMountStatus.isValidWorkspaceDirectory else {
                error = hostMountValidationMessage ?? "Folder doesn\u{2019}t exist"
                return
            }
        }

        isSaving = true
        error = nil
        switch await model.saveDetails(draft) {
        case .saved:
            if isVisible { dismiss() }
            isSaving = false
        case .failed(let message):
            error = message
            isSaving = false
        case .superseded:
            isSaving = false
        }
    }
}
