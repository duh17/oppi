import Foundation

/// The Details page's draft: name, description, icon, and folder as the person
/// is editing them, the check of the typed folder, and the Save. Nothing is
/// written until `save()`; leaving the page drops the draft.
///
/// A folder that differs from the saved one is checked on the server (after a
/// short pause while typing), and Save waits for a folder that exists. A
/// missing folder can be created from here, after a confirmation.
/// `WorkspaceDetailsViewController` draws it; `WorkspaceSettingsModel` does the
/// server work.
@MainActor @Observable
final class WorkspaceDetailsModel {
    private let settings: WorkspaceSettingsModel

    private(set) var draft: WorkspaceDetailsDraft
    private(set) var hostMountStatus: HostPathStatus?
    private(set) var hostMountValidationMessage: String?
    private(set) var isCheckingHostMount = false
    private(set) var isCreatingHostDirectory = false
    /// The folder the person asked to create and has not yet confirmed.
    var hostPathPendingCreation: String?
    private(set) var isSaving = false
    private(set) var error: String?

    @ObservationIgnored private var validationTask: Task<Void, Never>?
    /// The typing pause before a folder is checked.
    @ObservationIgnored private let debounce: Duration

    init(settings: WorkspaceSettingsModel, debounce: Duration = .milliseconds(250)) {
        self.settings = settings
        self.debounce = debounce
        draft = WorkspaceDetailsDraft(workspace: settings.workspace)
    }

    isolated deinit {
        validationTask?.cancel()
    }

    var trimmedHostMount: String { draft.trimmedHostMount }

    /// What the server said about the typed folder.
    var folderCheck: WorkspaceFolderCheck {
        WorkspaceFolderCheck(
            folder: trimmedHostMount,
            status: hostMountStatus,
            validationMessage: hostMountValidationMessage,
            isChecking: isCheckingHostMount
        )
    }

    var isDirty: Bool {
        draft.request(against: settings.workspace) != nil
    }

    var canSave: Bool {
        if draft.name.isEmpty || isSaving || !isDirty { return false }
        // An unchanged folder was valid when it was saved; only a new one is checked.
        if draft.changesFolder(of: settings.workspace), !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount else { return false }
            if !hostMountStatus.isValidWorkspaceDirectory { return false }
        }
        return true
    }

    // MARK: - Editing

    func setName(_ name: String) { draft.name = name }
    func setDescription(_ description: String) { draft.description = description }
    func setIcon(_ icon: IconChoice) { draft.icon = icon }

    /// Takes the typed folder and checks it again.
    func setHostMount(_ text: String) {
        draft.hostMount = text
        startFolderCheck()
    }

    // MARK: - Folder check

    private func startFolderCheck() {
        validationTask?.cancel()
        validationTask = Task { [weak self] in await self?.validateHostMount() }
    }

    /// Checks the typed folder. A newer edit cancels this one, so a late answer
    /// never describes a folder that is no longer typed.
    func validateHostMount() async {
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

        guard settings.isServerReachable else {
            hostMountStatus = nil
            hostMountValidationMessage = "Cannot check path while the server is offline"
            isCheckingHostMount = false
            return
        }

        isCheckingHostMount = true
        hostMountValidationMessage = nil
        // Debounce typing; a newer keystroke cancels this task.
        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }
        guard current == trimmedHostMount else { return }

        do {
            guard let status = try await settings.hostPathStatus(current) else { return }
            guard current == trimmedHostMount else { return }
            hostMountStatus = status
            hostMountValidationMessage = status.isValidWorkspaceDirectory ? nil : status.userMessage
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

    /// Creates the folder the person confirmed. The server answers with the
    /// path it resolved, which becomes the folder.
    func createHostDirectoryFromPendingPath() async {
        guard let path = hostPathPendingCreation else { return }
        guard path == trimmedHostMount else {
            hostPathPendingCreation = nil
            return
        }
        guard settings.isServerReachable else {
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
            guard let result = try await settings.createHostPath(path) else { return }
            draft.hostMount = result.status.path.isEmpty ? path : result.status.path
            hostMountStatus = result.status
            hostMountValidationMessage = result.status.isValidWorkspaceDirectory ? nil : result.status.userMessage
            isCheckingHostMount = false
        } catch {
            guard WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            self.error = "Create folder failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    /// Writes the changed fields. A folder that is not known to exist stops
    /// here with the reason. `error` carries a failed save's message.
    func save() async -> WorkspaceWriteOutcome {
        if draft.changesFolder(of: settings.workspace), !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                  hostMountStatus.isValidWorkspaceDirectory else {
                let message = hostMountValidationMessage ?? "Folder doesn\u{2019}t exist"
                error = message
                return .failed(message)
            }
        }

        isSaving = true
        error = nil
        let outcome = await settings.saveDetails(draft)
        isSaving = false
        if case .failed(let message) = outcome { error = message }
        return outcome
    }
}
