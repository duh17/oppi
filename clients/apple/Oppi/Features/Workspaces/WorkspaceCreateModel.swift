import Foundation
import Observation
import UIKit

enum WorkspaceCreatePresentation: Equatable, Sendable {
    case standard
    case guidedFirstWorkspace
}

enum WorkspaceCreateStep: Equatable {
    case pickProject
    case configure
}

/// What the server said about a typed workspace folder, as the one thing the
/// form shows under it: checking, missing (with a confirm-before-create flow),
/// invalid, or valid. Shared by New Workspace and Workspace Details so both
/// describe a folder the same way.
enum WorkspaceFolderCheck: Hashable {
    case none
    case checking
    case missing
    case invalid(String)
    case valid

    /// `folder` is the trimmed path `status` and `validationMessage` describe.
    init(folder: String, status: HostPathStatus?, validationMessage: String?, isChecking: Bool) {
        guard !folder.isEmpty else {
            self = .none
            return
        }
        let describesFolder = status?.path == folder
        if isChecking {
            self = .checking
        } else if describesFolder, status?.issue == "missing" {
            self = .missing
        } else if let validationMessage {
            self = .invalid(validationMessage)
        } else if describesFolder, status?.isValidWorkspaceDirectory == true {
            self = .valid
        } else {
            self = .none
        }
    }
}

/// Create a new workspace on a specific server.
///
/// Two steps:
/// 1. Pick a project from discovered host directories (or enter a path)
/// 2. Confirm name, folder, icon, and optional advanced settings
///
/// The form's state and its server work. `WorkspaceCreateViewController` draws
/// it. Every change to the folder goes through a method here, which restarts
/// the folder check and the skills lookup when what they describe changed.
@MainActor @Observable
final class WorkspaceCreateModel {
    let server: PairedServer
    let presentation: WorkspaceCreatePresentation

    private(set) var step: WorkspaceCreateStep = .pickProject
    private(set) var directories: [HostDirectory] = []
    private(set) var isLoadingDirectories = true
    private(set) var directoriesError: String?

    // Form state (populated from project selection or manual entry)
    var name = ""
    private(set) var hostMount = ""
    private(set) var isHostMountFromProjectPicker = false
    var description = ""
    var icon: IconChoice = .defaultValue
    var gitStatusEnabled = true
    var sandboxMode = false
    private(set) var showAdvanced = false
    private(set) var hostMountStatus: HostPathStatus?
    private(set) var hostMountValidationMessage: String?
    private(set) var isCheckingHostMount = false
    private(set) var isCreatingHostDirectory = false
    var hostPathPendingCreation: String?
    private(set) var hostMountCompletions: [HostPathCompletion] = []
    private(set) var isCreating = false
    var error: String?
    private(set) var skillsByLookupKey: [String: [SkillInfo]] = [:]

    @ObservationIgnored private let coordinator: ConnectionCoordinator
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var directoriesTask: Task<Void, Never>?
    @ObservationIgnored private var skillsTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var runningSkillsKey: String?
    @ObservationIgnored private var runningValidationKey: String?

    init(
        server: PairedServer,
        coordinator: ConnectionCoordinator,
        presentation: WorkspaceCreatePresentation = .standard,
        prefillName: String? = nil,
        prefillPath: String? = nil
    ) {
        self.server = server
        self.coordinator = coordinator
        self.presentation = presentation
        if let prefillPath {
            // Deep-linked workspaces use Pi's normal cwd resource discovery.
            name = prefillName ?? ""
            hostMount = prefillPath
            isHostMountFromProjectPicker = false
            step = .configure
        } else if let prefillName {
            name = prefillName
        }
    }

    // MARK: - Derived

    var isGuidedFirstWorkspace: Bool {
        presentation == .guidedFirstWorkspace
    }

    var navigationTitle: String {
        switch (presentation, step) {
        case (.guidedFirstWorkspace, .pickProject): "Set Up Workspace"
        case (.guidedFirstWorkspace, .configure): "Review Workspace"
        case (_, .pickProject): "Pick a Project"
        case (_, .configure): "New Workspace"
        }
    }

    var trimmedHostMount: String {
        hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server this sheet creates on, when it can take a request.
    var oppiConnection: ServerConnection? {
        guard let connection = coordinator.connection(for: server.id),
              connection.apiClient != nil else { return nil }
        return connection
    }

    /// Store scoped to the server this sheet creates on. The active server's
    /// store is the fallback: deep links can switch servers just before presenting.
    private var targetWorkspaceStore: WorkspaceStore {
        coordinator.connection(for: server.id)?.workspaceStore ?? coordinator.activeConnection.workspaceStore
    }

    /// Skills discovered for the current server and folder.
    var skills: [SkillInfo] {
        if let cached = skillsByLookupKey[skillCatalogLookupKey] {
            return cached
        }
        if trimmedHostMount.isEmpty {
            return targetWorkspaceStore.skillsByServer[server.id] ?? []
        }
        return []
    }

    var folderCheck: WorkspaceFolderCheck {
        WorkspaceFolderCheck(
            folder: trimmedHostMount,
            status: hostMountStatus,
            validationMessage: hostMountValidationMessage,
            isChecking: isCheckingHostMount
        )
    }

    /// Whether the form is valid for submission.
    var canCreate: Bool {
        Self.canCreate(
            name: name,
            isCreating: isCreating,
            trimmedHostMount: trimmedHostMount,
            hostMountStatus: hostMountStatus
        )
    }

    static func canCreate(
        name: String,
        isCreating: Bool,
        trimmedHostMount: String,
        hostMountStatus: HostPathStatus?
    ) -> Bool {
        if name.isEmpty { return false }
        if isCreating { return false }
        if !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount else { return false }
            if !hostMountStatus.isValidWorkspaceDirectory { return false }
        }
        return true
    }

    /// Explains the Workspace Folder section, one paragraph per line.
    var folderFooter: String {
        var lines: [String] = []
        if !isHostMountFromProjectPicker {
            lines.append(
                sandboxMode
                    ? "Leave empty to let Oppi create a sandbox folder. Network follows Gondolin’s default; edit the workspace later to restrict or deny hosts. For a custom folder, use Create This Folder when the folder is missing."
                    : "Leave empty to let Oppi create a folder. If the folder doesn’t exist, use Create This Folder; Oppi asks before creating one directory."
            )
        }
        if sandboxMode && hostMount.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("A new directory will be created at ~/sandbox/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))/")
        }
        return lines.joined(separator: "\n")
    }

    private var hostMountLookupKey: String {
        "\(server.id)|\(isHostMountFromProjectPicker)|\(trimmedHostMount)"
    }

    private var skillCatalogLookupKey: String {
        "\(server.id)|\(trimmedHostMount)"
    }

    // MARK: - Lifecycle

    /// The form is on screen: scan for projects, look up skills, and check the
    /// prefilled folder.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        directoriesTask = Task { [weak self] in await self?.loadDirectories() }
        syncHostMountTasks()
    }

    /// The form closed: stop every lookup.
    func stop() {
        hasStarted = false
        directoriesTask?.cancel()
        skillsTask?.cancel()
        validationTask?.cancel()
        directoriesTask = nil
        skillsTask = nil
        validationTask = nil
        runningSkillsKey = nil
        runningValidationKey = nil
    }

    /// Starts the skills lookup and the folder check again when the folder (or
    /// where it came from) changed since they last ran.
    private func syncHostMountTasks() {
        guard hasStarted else { return }
        let skillsKey = skillCatalogLookupKey
        if skillsKey != runningSkillsKey {
            runningSkillsKey = skillsKey
            skillsTask?.cancel()
            skillsTask = Task { [weak self] in await self?.loadSkills() }
        }
        let validationKey = hostMountLookupKey
        if validationKey != runningValidationKey {
            runningValidationKey = validationKey
            validationTask?.cancel()
            validationTask = Task { [weak self] in await self?.validateAndCompleteHostMount() }
        }
    }

    // MARK: - Selection

    func selectProject(_ directory: HostDirectory) {
        name = directory.name
        hostMount = directory.path
        isHostMountFromProjectPicker = true
        hostMountStatus = Self.existingDirectoryStatus(directory.path)
        hostMountValidationMessage = nil
        hostPathPendingCreation = nil
        hostMountCompletions = []
        gitStatusEnabled = directory.isGitRepo
        step = .configure
        syncHostMountTasks()
    }

    func selectManual() {
        resetHostMountInput()
        step = .configure
        syncHostMountTasks()
    }

    func selectBlank() {
        name = ""
        resetHostMountInput()
        gitStatusEnabled = false
        step = .configure
        syncHostMountTasks()
    }

    /// Back to the project list from a folder picked there.
    func changeProject() {
        step = .pickProject
    }

    func showAdvancedOptions() {
        showAdvanced = true
    }

    /// The user typed in the folder field.
    func setHostMount(_ path: String) {
        hostMount = path
        syncHostMountTasks()
    }

    func applyHostMountCompletion(_ completion: HostPathCompletion) {
        hostMount = completion.path
        isHostMountFromProjectPicker = false
        hostMountStatus = Self.existingDirectoryStatus(completion.path)
        hostMountValidationMessage = nil
        hostPathPendingCreation = nil
        hostMountCompletions = []
        syncHostMountTasks()
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

    private static func existingDirectoryStatus(_ path: String) -> HostPathStatus {
        HostPathStatus(
            path: path,
            resolvedPath: path,
            exists: true,
            isDirectory: true,
            isFile: false,
            issue: nil,
            message: nil
        )
    }

    // MARK: - Data Loading

    private func preparedAPIClient() async -> APIClient? {
        await coordinator.apiClientReady(for: server.id)
    }

    private func loadDirectories() async {
        guard let api = await preparedAPIClient() else {
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
        let lookupKey = skillCatalogLookupKey
        let cwd = trimmedHostMount.isEmpty ? nil : trimmedHostMount
        if skillsByLookupKey[lookupKey] != nil { return }
        if cwd == nil, (targetWorkspaceStore.skillsByServer[server.id] ?? []).isEmpty == false {
            skillsByLookupKey[lookupKey] = targetWorkspaceStore.skillsByServer[server.id]
            return
        }
        guard let api = await preparedAPIClient() else { return }
        do {
            let loaded = try await api.listSkills(cwd: cwd)
            guard lookupKey == skillCatalogLookupKey else { return }
            skillsByLookupKey[lookupKey] = loaded
            if cwd == nil {
                targetWorkspaceStore.skillsByServer[server.id] = loaded
            }
        } catch {
            // Keep empty state; refresh will retry.
        }
    }

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

        guard let api = await preparedAPIClient() else {
            hostMountStatus = nil
            hostMountValidationMessage = "Cannot check path while the server is offline"
            hostMountCompletions = []
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
        guard !Task.isCancelled, current == trimmedHostMount else { return }

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
            guard !Task.isCancelled, current == trimmedHostMount else { return }
            hostMountStatus = nil
            hostMountValidationMessage = "Could not check path: \(error.localizedDescription)"
            hostMountCompletions = []
        }

        if current == trimmedHostMount {
            isCheckingHostMount = false
        }
    }

    // MARK: - Create

    /// Creates the folder the user confirmed. The server answers with the
    /// path it resolved, which becomes the folder.
    func createHostDirectoryFromPendingPath() async {
        guard let path = hostPathPendingCreation else { return }
        guard path == trimmedHostMount else {
            hostPathPendingCreation = nil
            return
        }
        guard let api = await preparedAPIClient() else {
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
            syncHostMountTasks()
        } catch {
            self.error = "Create folder failed: \(error.localizedDescription)"
        }
    }

    func uploadGenmoji(data: Data, contentDescription: String) async throws -> IconChoice {
        guard let api = await preparedAPIClient() else {
            throw APIError.server(status: 503, message: "Server is offline")
        }
        let asset = try await api.uploadIconAsset(
            data: data,
            contentType: NSAdaptiveImageGlyph.contentType.preferredMIMEType ?? "image/heic"
        )
        return .genmoji(
            assetId: asset.assetId,
            contentDescription: contentDescription
        )
    }

    /// Creates the workspace on the server and adds it to that server's store.
    /// Nil when it could not: `error` says why.
    func create() async -> Workspace? {
        guard !isCreating else { return nil }
        isCreating = true
        error = nil

        guard await coordinator.switchToServerReady(server),
              let api = coordinator.apiClient(for: server.id) else {
            error = "Cannot connect to \(server.name)"
            isCreating = false
            return nil
        }

        let trimmedHostMount = trimmedHostMount
        if !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                  hostMountStatus.isValidWorkspaceDirectory else {
                error = hostMountValidationMessage ?? "Folder doesn’t exist"
                isCreating = false
                return nil
            }
        }

        let request = CreateWorkspaceRequest(
            name: name,
            description: description.isEmpty ? nil : description,
            icon: icon,
            hostMount: trimmedHostMount.isEmpty ? nil : trimmedHostMount,
            gitStatusEnabled: gitStatusEnabled,
            runtime: sandboxMode ? .sandbox : nil,
            sandboxConfig: nil
        )

        do {
            let workspace = try await api.createWorkspace(request)
            targetWorkspaceStore.upsert(workspace, serverId: server.id)
            return workspace
        } catch {
            self.error = error.localizedDescription
            isCreating = false
            return nil
        }
    }
}
