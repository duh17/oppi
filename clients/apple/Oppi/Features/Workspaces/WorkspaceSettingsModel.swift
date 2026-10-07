import Foundation

/// Classifies Pi resource load failures for workspace settings.
/// Cancellation is control flow for stale/background requests, not a Pi resource failure.
enum WorkspacePiResourceErrorPolicy {
    static func shouldPresent(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return false }

        return true
    }
}

enum WorkspaceSettingsError: LocalizedError {
    case serverOffline

    var errorDescription: String? { "Server is offline" }
}

/// How a workspace write ended. `superseded` means the workspace or server
/// changed (or the request was cancelled) while it ran, so the caller must not
/// show a result for it.
enum WorkspaceWriteOutcome: Equatable, Sendable {
    case saved
    case failed(String)
    case superseded
}

/// Which Pi settings list a toggle belongs to. The raw value is the server's resource type.
enum WorkspacePiResourceKind: String {
    case skills
    case extensions
}

/// Fields of the Details page as the user is editing them.
struct WorkspaceDetailsDraft: Equatable {
    var name: String
    var description: String
    var icon: IconChoice
    var hostMount: String

    init(workspace: Workspace) {
        name = workspace.name
        description = workspace.description ?? ""
        icon = workspace.icon
        hostMount = workspace.hostMount ?? ""
    }

    var trimmedHostMount: String {
        hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the folder differs from the saved one, which is what needs validating.
    func changesFolder(of workspace: Workspace) -> Bool {
        trimmedHostMount != (workspace.hostMount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Only the fields that differ from `workspace`; nil when nothing changed.
    func request(against workspace: Workspace) -> UpdateWorkspaceRequest? {
        let request = UpdateWorkspaceRequest(
            name: name != workspace.name ? name : nil,
            description: Self.changed(description != (workspace.description ?? ""), Self.nullable(description)),
            icon: Self.changed(icon != workspace.icon, icon.jsonValue),
            hostMount: Self.changed(changesFolder(of: workspace), Self.nullable(trimmedHostMount))
        )
        return request.body.isEmpty ? nil : request
    }

    /// `JSONValue` is `ExpressibleByNilLiteral`, so `condition ? json : nil`
    /// would send `.null` (clearing the field) for an unchanged one. Spell out
    /// `Optional.none` instead.
    private static func changed(_ condition: Bool, _ value: @autoclosure () -> JSONValue) -> JSONValue? {
        guard condition else { return Optional<JSONValue>.none }
        return value()
    }

    private static func nullable(_ value: String) -> JSONValue {
        value.isEmpty ? .null : .string(value)
    }
}

/// Request bodies for workspace writes that need more than one field.
enum WorkspaceSettingsRequests {
    /// The server replaces `sandboxConfig` as a whole, so every write carries
    /// every field: the one being changed plus the saved values of the rest.
    static func sandboxConfig(
        current: SandboxConfig?,
        allowedHosts: [String]? = nil,
        mcpServers: [String]? = nil
    ) -> JSONValue {
        var config: [String: JSONValue] = [
            "allowedHosts": .array((allowedHosts ?? current?.allowedHosts ?? ["*"]).map { .string($0) }),
            "mcpServers": .array((mcpServers ?? current?.mcpServers ?? []).sorted().map { .string($0) }),
        ]
        if let env = current?.env {
            config["env"] = .object(env.mapValues { .string($0) })
        }
        return .object(config)
    }
}

/// Everything Workspace Settings loads and writes for one workspace, owned in
/// one place so the root and its pushed pages read the same values.
///
/// The root view owns the model and calls `attach` with the workspace it was
/// opened for. Every async result is applied only while the `(server,
/// workspace)` it was requested for is still the model's `scope`: a late
/// response or a finished write never paints another workspace. Data that
/// belongs to the server (a returned workspace) is still stored under the
/// server it was written to, because that write really happened.
///
/// The workspace itself is read from the connection's `WorkspaceStore`, so a
/// write that upserts the returned workspace also updates the rest of the app.
@MainActor @Observable
final class WorkspaceSettingsModel {
    struct Scope: Hashable, Sendable {
        let serverId: String
        let workspaceId: String
    }

    private(set) var scope: Scope?

    /// Pi skills and extensions for this workspace.
    private(set) var skills: [SkillInfo] = []
    private(set) var isLoadingSkills = false
    private(set) var skillsError: String?
    private(set) var extensions: [ExtensionInfo] = []
    private(set) var isLoadingExtensions = false
    private(set) var extensionsError: String?
    /// From the extensions list: one answer for this folder's skills, extensions, and MCP.
    private(set) var projectTrust: ProjectTrustState?
    /// Toggles in flight, keyed `kind|path`, with the value being written.
    private(set) var pendingPiResources: [String: Bool] = [:]

    /// Global MCP servers a sandbox may load, as the server reports them for this workspace.
    private(set) var sandboxMcpServers: [McpServerSummary]?
    private(set) var sandboxMcpLoadError: String?
    private(set) var sandboxMcpError: String?
    /// Sandbox config writes (MCP toggles, Allowed Hosts) queued or in flight for this scope.
    private var sandboxWriteCount = 0
    var isWritingSandboxConfig: Bool { sandboxWriteCount > 0 }
    private var pendingSandboxMcp: Set<String>?
    /// Workspace writes queued or running, across every scope this model has had.
    private(set) var queuedWriteCount = 0
    var isWriteQueueIdle: Bool { queuedWriteCount == 0 }

    private(set) var isSavingGitStatus = false
    private var pendingGitStatus: Bool?
    private(set) var isDeleting = false
    /// Last failure of a root-level action (Show Changes in Chat, Delete Workspace).
    private(set) var error: String?

    private var seed: Workspace
    @ObservationIgnored private var connection: ServerConnection?
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    /// Never upserted again: a late response must not bring a deleted workspace back.
    @ObservationIgnored private var deletedWorkspaces: Set<Scope> = []
    @ObservationIgnored private var piResourceLoad: Task<Void, Never>?
    @ObservationIgnored private var piResourceLoadToken = 0
    @ObservationIgnored private var skillsGeneration = 0
    @ObservationIgnored private var extensionsGeneration = 0
    @ObservationIgnored private var sandboxMcpGeneration = 0
    private var skillsLoaded = false
    private var extensionsLoaded = false
    #if DEBUG
    @ObservationIgnored fileprivate var isFixture = false
    #endif

    /// A client and store prepared for one scope, with the scope they were prepared for.
    private struct Context {
        let api: APIClient
        let store: WorkspaceStore
        let scope: Scope
    }

    init(seed: Workspace) {
        self.seed = seed
    }

    /// Binds the model to the workspace the view was opened for. Switching
    /// workspace or server drops everything loaded for the previous one;
    /// re-attaching the same scope keeps it so a page pop does not refetch.
    func attach(connection: ServerConnection, workspace: Workspace) {
        self.connection = connection
        let serverId = connection.workspaceStore.activeServerId ?? connection.currentServerId
        let next = serverId.map { Scope(serverId: $0, workspaceId: workspace.id) }
        guard next != scope else { return }
        #if DEBUG
        if isFixture {
            scope = next
            return
        }
        #endif
        reset()
        seed = workspace
        scope = next
    }

    private func reset() {
        piResourceLoad?.cancel()
        piResourceLoad = nil
        piResourceLoadToken += 1
        skillsGeneration += 1
        extensionsGeneration += 1
        sandboxMcpGeneration += 1
        skills = []
        isLoadingSkills = false
        skillsError = nil
        skillsLoaded = false
        extensions = []
        isLoadingExtensions = false
        extensionsError = nil
        extensionsLoaded = false
        projectTrust = nil
        pendingPiResources = [:]
        sandboxMcpServers = nil
        sandboxMcpLoadError = nil
        sandboxMcpError = nil
        sandboxWriteCount = 0
        pendingSandboxMcp = nil
        isSavingGitStatus = false
        pendingGitStatus = nil
        isDeleting = false
        error = nil
    }

    // MARK: - Derived values

    /// The stored workspace, or the one the view was opened with until the store has it.
    var workspace: Workspace {
        guard let scope,
              let stored = connection?.workspaceStore.workspacesByServer[scope.serverId]?
                .first(where: { $0.id == scope.workspaceId }) else {
            return seed
        }
        return stored
    }

    var isSandbox: Bool { workspace.runtime == .sandbox }

    /// Whether a request can be sent at all.
    var isServerReachable: Bool { connection?.apiClient != nil }

    var savedFolder: String? {
        let folder = workspace.hostMount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return folder.isEmpty ? nil : folder
    }

    var instructionsSummary: String {
        guard let prompt = workspace.systemPrompt, !prompt.isEmpty else { return "None" }
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    /// "N of M" once the list has loaded, nothing before.
    var skillsSummary: String? {
        guard skillsLoaded else { return nil }
        return skills.isEmpty ? "None" : "\(skills.filter(\.enabled).count) of \(skills.count)"
    }

    var extensionsSummary: String? {
        guard extensionsLoaded else { return nil }
        return extensions.isEmpty ? "None" : "\(extensions.filter(\.enabled).count) of \(extensions.count)"
    }

    /// Sandbox workspaces know their picks locally; a host workspace's list needs a probe, so it has no value.
    var mcpSummary: String? {
        guard isSandbox else { return nil }
        let count = sandboxMcpSelection.count
        return count == 0 ? "None" : "\(count) Enabled"
    }

    var networkAccessSummary: String {
        let hosts = workspace.sandboxConfig?.allowedHosts ?? ["*"]
        if hosts.isEmpty { return "Blocked" }
        if hosts.contains("*") { return "All Hosts" }
        return hosts.count == 1 ? "1 Host" : "\(hosts.count) Hosts"
    }

    /// Pi ignores a distrusted folder's project settings, so a toggle there would do nothing.
    var canTogglePiResources: Bool { projectTrust != .distrusted }

    var piResourceFooter: String {
        canTogglePiResources
            ? "Toggles write Pi user/project settings for this folder. Use reload in an active session to apply changes immediately."
            : "Pi ignores this folder\u{2019}s project settings while it isn\u{2019}t trusted, so toggles are off."
    }

    /// The value the Show Changes in Chat toggle shows: the pending write, else the saved one.
    var gitStatusEnabled: Bool {
        pendingGitStatus ?? workspace.gitStatusEnabled ?? true
    }

    var sandboxMcpSelection: Set<String> {
        pendingSandboxMcp ?? Set(workspace.sandboxConfig?.mcpServers ?? [])
    }

    func isPending(_ kind: WorkspacePiResourceKind, path: String) -> Bool {
        pendingPiResources[Self.resourceKey(kind, path)] != nil
    }

    /// What a Pi resource toggle shows: the value being written, else the server's.
    func displayedEnabled(_ kind: WorkspacePiResourceKind, path: String, server: Bool) -> Bool {
        pendingPiResources[Self.resourceKey(kind, path)] ?? server
    }

    private static func resourceKey(_ kind: WorkspacePiResourceKind, _ path: String) -> String {
        "\(kind.rawValue)|\(path)"
    }

    // MARK: - Pi resources

    /// Loads skills and extensions once per scope. A load already in flight is
    /// awaited instead of repeated; a failed one is retried by the next caller.
    /// The load is owned by the model, so a view disappearing (a page push)
    /// does not cancel it.
    func loadPiResourcesIfNeeded() async {
        #if DEBUG
        if isFixture { return }
        #endif
        if piResourceLoad == nil {
            guard !(skillsLoaded && extensionsLoaded) else { return }
            startPiResourceReload()
        }
        await piResourceLoad?.value
    }

    /// Drops the lists and loads them again, for when the folder they describe changed.
    func startPiResourceReload() {
        #if DEBUG
        if isFixture { return }
        #endif
        piResourceLoad?.cancel()
        piResourceLoadToken += 1
        let token = piResourceLoadToken
        piResourceLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            async let skills: Void = loadSkills()
            async let extensions: Void = loadExtensions()
            _ = await (skills, extensions)
            if piResourceLoadToken == token { piResourceLoad = nil }
        }
    }

    private func loadSkills() async {
        guard let context = context() else {
            skillsError = "Server is offline"
            isLoadingSkills = false
            return
        }
        skillsGeneration += 1
        let generation = skillsGeneration
        isLoadingSkills = true
        skillsError = nil
        defer {
            if isCurrent(context.scope), generation == skillsGeneration { isLoadingSkills = false }
        }

        do {
            let loaded = try await context.api.listSkills(workspaceId: context.scope.workspaceId)
            guard isCurrent(context.scope), generation == skillsGeneration else { return }
            skills = loaded
            skillsLoaded = true
        } catch {
            guard isCurrent(context.scope), generation == skillsGeneration,
                  WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            skillsError = error.localizedDescription
        }
    }

    private func loadExtensions() async {
        guard let context = context() else {
            extensionsError = "Server is offline"
            isLoadingExtensions = false
            return
        }
        extensionsGeneration += 1
        let generation = extensionsGeneration
        isLoadingExtensions = true
        extensionsError = nil
        defer {
            if isCurrent(context.scope), generation == extensionsGeneration { isLoadingExtensions = false }
        }

        do {
            let loaded = try await context.api.listExtensions(workspaceId: context.scope.workspaceId)
            guard isCurrent(context.scope), generation == extensionsGeneration else { return }
            extensions = loaded.extensions
            projectTrust = loaded.projectTrust
            extensionsLoaded = true
        } catch {
            guard isCurrent(context.scope), generation == extensionsGeneration,
                  WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            projectTrust = nil
            extensionsError = error.localizedDescription
        }
    }

    /// Writes one skill or extension toggle to Pi settings and reloads that list.
    /// The toggle shows the new value while the write runs and snaps back with
    /// the error if it fails.
    func setPiResource(_ kind: WorkspacePiResourceKind, path: String, enabled: Bool) async {
        let key = Self.resourceKey(kind, path)
        guard pendingPiResources[key] == nil else { return }
        guard let context = context() else {
            setPiResourceError("Server is offline", kind: kind)
            return
        }
        pendingPiResources[key] = enabled
        setPiResourceError(nil, kind: kind)
        defer {
            if isCurrent(context.scope) { pendingPiResources[key] = nil }
        }

        do {
            try await context.api.setPiResourceEnabled(
                type: kind.rawValue,
                path: path,
                workspaceId: context.scope.workspaceId,
                enabled: enabled
            )
            guard isCurrent(context.scope) else { return }
            switch kind {
            case .skills: await loadSkills()
            case .extensions: await loadExtensions()
            }
        } catch {
            guard isCurrent(context.scope), WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            setPiResourceError(error.localizedDescription, kind: kind)
        }
    }

    private func setPiResourceError(_ message: String?, kind: WorkspacePiResourceKind) {
        switch kind {
        case .skills: skillsError = message
        case .extensions: extensionsError = message
        }
    }

    // MARK: - Workspace writes

    /// Workspace writes run one at a time, in the order they were asked for.
    /// Each builds its request at its turn from the workspace the previous
    /// write left in the store, so overlapping writes (a toggle during a Save,
    /// rapid MCP toggles) never replace `sandboxConfig` from a stale snapshot.
    private func enqueueWrite<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = writeTail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        writeTail = Task { @MainActor in _ = await task.value }
        queuedWriteCount += 1
        let result = await task.value
        queuedWriteCount -= 1
        return result
    }

    private func storedWorkspace(_ context: Context) -> Workspace? {
        context.store.workspacesByServer[context.scope.serverId]?
            .first { $0.id == context.scope.workspaceId }
            ?? (isCurrent(context.scope) ? seed : nil)
    }

    /// Stores a returned workspace under the server it was written to, so the
    /// rest of the app sees it. A deleted workspace is never brought back, and
    /// a response older than the stored workspace is dropped.
    private func storeUpdate(_ updated: Workspace, context: Context) {
        guard !deletedWorkspaces.contains(context.scope) else { return }
        if let stored = context.store.workspacesByServer[context.scope.serverId]?
            .first(where: { $0.id == context.scope.workspaceId }),
           updated.updatedAt < stored.updatedAt {
            return
        }
        context.store.upsert(updated, serverId: context.scope.serverId)
    }

    /// Runs inside the write queue. `build` sees the stored workspace at this
    /// turn and returns the request, or nil when there is nothing to send.
    /// `sent` is the body that went out.
    private func write(
        context: Context,
        build: (Workspace) -> UpdateWorkspaceRequest?
    ) async -> (outcome: WorkspaceWriteOutcome, sent: [String: JSONValue]) {
        guard !deletedWorkspaces.contains(context.scope),
              let current = storedWorkspace(context) else {
            return (.superseded, [:])
        }
        guard let request = build(current) else { return (.saved, [:]) }
        do {
            let updated = try await context.api.updateWorkspace(id: context.scope.workspaceId, request)
            storeUpdate(updated, context: context)
            return (isCurrent(context.scope) ? .saved : .superseded, request.body)
        } catch {
            guard isCurrent(context.scope), WorkspacePiResourceErrorPolicy.shouldPresent(error) else {
                return (.superseded, request.body)
            }
            return (.failed(error.localizedDescription), request.body)
        }
    }

    func saveDetails(_ draft: WorkspaceDetailsDraft) async -> WorkspaceWriteOutcome {
        guard let context = context() else { return .failed("Server is offline") }
        let result = await enqueueWrite { [self] in
            await write(context: context) { draft.request(against: $0) }
        }
        if result.outcome == .saved, result.sent["hostMount"] != nil, isCurrent(context.scope) {
            // Skills, extensions, trust, and MCP all describe the folder.
            skills = []
            skillsLoaded = false
            extensions = []
            extensionsLoaded = false
            projectTrust = nil
            startPiResourceReload()
        }
        return result.outcome
    }

    func saveInstructions(_ text: String) async -> WorkspaceWriteOutcome {
        guard let context = context() else { return .failed("Server is offline") }
        return await enqueueWrite { [self] in
            await write(context: context) { _ in
                UpdateWorkspaceRequest(
                    systemPrompt: text.isEmpty ? .null : .string(text),
                    systemPromptMode: .append
                )
            }.outcome
        }
    }

    /// Applies Show Changes in Chat at once. Failure reverts the toggle and sets `error`.
    func setGitStatusEnabled(_ enabled: Bool) async {
        guard !isSavingGitStatus else { return }
        guard let context = context() else {
            error = "Server is offline"
            return
        }
        isSavingGitStatus = true
        pendingGitStatus = enabled
        error = nil
        let outcome = await enqueueWrite { [self] in
            await write(context: context) { _ in UpdateWorkspaceRequest(gitStatusEnabled: enabled) }.outcome
        }
        guard isCurrent(context.scope) else { return }
        isSavingGitStatus = false
        pendingGitStatus = nil
        if case .failed(let message) = outcome { error = message }
    }

    func saveAllowedHosts(_ hosts: [String]) async -> WorkspaceWriteOutcome {
        guard let context = context() else { return .failed("Server is offline") }
        sandboxWriteCount += 1
        let outcome = await enqueueWrite { [self] in
            await write(context: context) { current in
                UpdateWorkspaceRequest(
                    sandboxConfig: WorkspaceSettingsRequests.sandboxConfig(
                        current: current.sandboxConfig,
                        allowedHosts: hosts
                    )
                )
            }.outcome
        }
        guard isCurrent(context.scope) else { return outcome }
        sandboxWriteCount -= 1
        if sandboxWriteCount == 0 { pendingSandboxMcp = nil }
        if outcome == .saved {
            // Which servers can run in the VM depends on Allowed Hosts.
            sandboxMcpServers = nil
        }
        return outcome
    }

    /// Switches one global MCP server on or off for this sandbox at once.
    /// Quick toggles queue and compose: each is applied to the config the
    /// previous one left. Failure reverts the toggle and sets `sandboxMcpError`.
    func setSandboxMcpServer(_ name: String, enabled: Bool) async {
        guard let context = context() else {
            sandboxMcpError = "Server is offline"
            return
        }
        var optimistic = pendingSandboxMcp ?? Set(workspace.sandboxConfig?.mcpServers ?? [])
        if enabled { optimistic.insert(name) } else { optimistic.remove(name) }
        pendingSandboxMcp = optimistic
        sandboxWriteCount += 1
        sandboxMcpError = nil
        let outcome = await enqueueWrite { [self] in
            await write(context: context) { current in
                var next = Set(current.sandboxConfig?.mcpServers ?? [])
                if enabled { next.insert(name) } else { next.remove(name) }
                return UpdateWorkspaceRequest(
                    sandboxConfig: WorkspaceSettingsRequests.sandboxConfig(
                        current: current.sandboxConfig,
                        mcpServers: next.sorted()
                    )
                )
            }.outcome
        }
        guard isCurrent(context.scope) else { return }
        sandboxWriteCount -= 1
        // Show the saved truth once every queued toggle has settled.
        if sandboxWriteCount == 0 { pendingSandboxMcp = nil }
        if case .failed(let message) = outcome { sandboxMcpError = message }
    }

    func loadSandboxMcpServers() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard let context = context() else {
            sandboxMcpLoadError = "Server is offline"
            return
        }
        sandboxMcpGeneration += 1
        let generation = sandboxMcpGeneration
        sandboxMcpLoadError = nil
        do {
            let response = try await context.api.listMcpServers(scopeId: context.scope.workspaceId)
            guard isCurrent(context.scope), generation == sandboxMcpGeneration else { return }
            sandboxMcpServers = response.scope.servers
        } catch {
            guard isCurrent(context.scope), generation == sandboxMcpGeneration,
                  WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            sandboxMcpLoadError = error.localizedDescription
        }
    }

    // MARK: - Folder checks

    /// Checks a folder on the server. Nil when the workspace changed meanwhile.
    func hostPathStatus(_ path: String) async throws -> HostPathStatus? {
        guard let context = context() else { throw WorkspaceSettingsError.serverOffline }
        let status = try await context.api.getHostPathStatus(path: path)
        return isCurrent(context.scope) ? status : nil
    }

    /// Creates one folder on the server. Nil when the workspace changed meanwhile.
    func createHostPath(_ path: String) async throws -> HostPathCreateResult? {
        guard let context = context() else { throw WorkspaceSettingsError.serverOffline }
        let result = try await context.api.createHostPath(path: path)
        return isCurrent(context.scope) ? result : nil
    }

    // MARK: - Delete

    /// Deletes the workspace and drops it from the store it was deleted from.
    /// It waits for queued writes, and no later write brings the workspace
    /// back. Returns the deleted scope so the caller can leave its routes,
    /// even if the view moved to another workspace while the request ran.
    func deleteWorkspace() async -> Scope? {
        guard !isDeleting else { return nil }
        guard let context = context() else {
            error = "Server is offline"
            return nil
        }
        isDeleting = true
        error = nil
        let result = await enqueueWrite { [self] () -> (deleted: Scope?, message: String?) in
            do {
                try await context.api.deleteWorkspace(id: context.scope.workspaceId)
                deletedWorkspaces.insert(context.scope)
                context.store.remove(id: context.scope.workspaceId, serverId: context.scope.serverId)
                return (context.scope, nil)
            } catch {
                return (nil, WorkspacePiResourceErrorPolicy.shouldPresent(error) ? error.localizedDescription : nil)
            }
        }
        if isCurrent(context.scope) {
            isDeleting = false
            if let message = result.message { error = message }
        }
        return result.deleted
    }

    // MARK: - Transport

    private func isCurrent(_ requested: Scope) -> Bool {
        scope == requested
    }

    /// Reads the scope, client, and store together before any await so they agree.
    private func context() -> Context? {
        guard let scope, let connection, let api = connection.apiClient else { return nil }
        return Context(api: api, store: connection.workspaceStore, scope: scope)
    }
}

#if DEBUG
extension WorkspaceSettingsModel {
    /// Fixture for the screenshot harness: loads leave it untouched, so pages
    /// render without a server. The workspace itself comes from the connection's store.
    static func screenshotFixture(
        workspace: Workspace,
        skills: [SkillInfo],
        extensions: [ExtensionInfo],
        projectTrust: ProjectTrustState?,
        sandboxMcpServers: [McpServerSummary]
    ) -> WorkspaceSettingsModel {
        let model = WorkspaceSettingsModel(seed: workspace)
        model.isFixture = true
        model.skills = skills
        model.skillsLoaded = true
        model.extensions = extensions
        model.extensionsLoaded = true
        model.projectTrust = projectTrust
        model.sandboxMcpServers = sandboxMcpServers
        return model
    }
}
#endif
