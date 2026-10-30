import UIKit

/// Workspace creation the shell starts by itself: an `oppi://workspace` link,
/// or the guided first workspace after pairing a server that has none.
///
/// `AppRootViewController` owns one while it shows the shell and drops it when
/// the shell goes (so `guidedCreateConsumed` starts over with the next shell).
/// It calls `update()` from its `updateProperties()`: that reads the active
/// server and the two navigation flags, so the call comes again when they
/// change, and it drives the create sheet's slot on the root.
@MainActor
final class WorkspaceCreationIntake {
    private let root: AppRootEnvironment
    private weak var anchor: UIViewController?
    private let slot = RouterModalPresenter()

    /// The create sheet's request; the slot presents while it is set.
    private(set) var createSheetContext: WorkspaceCreateSheetContext? {
        didSet { anchor?.setNeedsUpdateProperties() }
    }
    private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?
    private var guidedCreateConsumed = false
    /// Set once the shell is gone: a run that was waiting on the server does nothing when it resumes.
    private var isStopped = false

    /// Runs `processWorkspaceCreationIntake` for the active server; a server
    /// switch cancels it and starts over for the new server.
    private(set) var intakeTask: Task<Void, Never>?
    private var intakeServerId: String??
    /// Loads a server's workspaces before the guided create decides whether it has none.
    private let refreshServer: (String) async -> Void
    private var hadPendingDeepLink: Bool
    private var wasGuidingCreation: Bool

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var navigation: AppNavigation { root.navigation }

    init(
        root: AppRootEnvironment,
        anchor: UIViewController,
        refreshServer: ((String) async -> Void)? = nil
    ) {
        self.root = root
        self.refreshServer = refreshServer ?? { [coordinator = root.coordinator] serverId in
            await coordinator.refreshServer(serverId, force: true)
        }
        self.anchor = anchor
        slot.anchor = anchor
        hadPendingDeepLink = root.navigation.pendingWorkspaceDeepLink != nil
        wasGuidingCreation = root.navigation.shouldGuideWorkspaceCreation
    }

    isolated deinit {
        intakeTask?.cancel()
    }

    /// The shell is going: stop the work in flight. The slot dismisses a sheet
    /// that is up when the intake is released.
    func stop() {
        isStopped = true
        intakeTask?.cancel()
        intakeTask = nil
    }

    func update() {
        let activeServerId = coordinator.activeServerId
        let hasPendingDeepLink = navigation.pendingWorkspaceDeepLink != nil
        let isGuidingCreation = navigation.shouldGuideWorkspaceCreation

        updateSlot()

        // The `.task(id: activeServerId)`: once on mount, then on every switch.
        if intakeServerId != .some(activeServerId) {
            intakeServerId = .some(activeServerId)
            intakeTask?.cancel()
            intakeTask = Task { [weak self] in
                await self?.processWorkspaceCreationIntake()
            }
        }
        if hasPendingDeepLink != hadPendingDeepLink {
            hadPendingDeepLink = hasPendingDeepLink
            if hasPendingDeepLink {
                Task { [weak self] in await self?.consumeWorkspaceDeepLinkIfNeeded() }
            }
        }
        if isGuidingCreation != wasGuidingCreation {
            wasGuidingCreation = isGuidingCreation
            if isGuidingCreation {
                Task { [weak self] in await self?.presentGuidedWorkspaceCreationIfNeeded() }
            }
        }
    }

    /// The anchor is in a window: a sheet requested earlier can present now.
    func anchorDidAppear() {
        slot.sync()
    }

    private func updateSlot() {
        let context = createSheetContext
        let root = root
        slot.update(
            id: context?.id,
            presentation: .sheet.inNavigation(),
            root: root,
            onDismiss: { [weak self] in self?.createSheetDidDismiss() },
            clear: { [weak self] in self?.createSheetContext = nil },
            screen: {
                guard let context else { return .controller({ UIViewController() }) }
                return .controller {
                    context.makeScreen(root: root) { [weak self] workspace in
                        guard context.openWorkspaceAfterCreate else { return }
                        self?.pendingCreatedWorkspaceTarget = WorkspaceNavTarget(
                            serverId: context.server.id,
                            workspace: workspace
                        )
                    }
                }
            }
        )
    }

    private var servers: [PairedServer] {
        coordinator.serverStore.servers
    }

    private var selectedServer: PairedServer? {
        if let activeServerId = coordinator.activeServerId,
           let server = servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return servers.first
    }

    private func processWorkspaceCreationIntake() async {
        if await consumeWorkspaceDeepLinkIfNeeded() {
            return
        }
        await presentGuidedWorkspaceCreationIfNeeded()
    }

    @discardableResult
    private func consumeWorkspaceDeepLinkIfNeeded() async -> Bool {
        guard !isStopped, let payload = navigation.pendingWorkspaceDeepLink else { return false }
        navigation.pendingWorkspaceDeepLink = nil
        navigation.shouldGuideWorkspaceCreation = false

        // AppOpener resolved the server and switched to it before parking this
        // payload. Do not resolve or switch again with different rules.
        guard let serverId = payload.resolvedServerId,
              let server = servers.first(where: { $0.id == serverId }) else {
            coordinator.activeConnection.extensionToast = "Server not found for this workspace link"
            return true
        }

        navigation.showAllWorkspaceSessions()
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: .standard,
            openWorkspaceAfterCreate: false,
            prefillName: payload.name,
            prefillPath: payload.path
        )
        return true
    }

    private func presentGuidedWorkspaceCreationIfNeeded() async {
        guard !isStopped, navigation.shouldGuideWorkspaceCreation, !guidedCreateConsumed else { return }
        guard let server = selectedServer else { return }

        await refreshServer(server.id)

        guard !isStopped, !Task.isCancelled else { return }
        guard navigation.shouldGuideWorkspaceCreation, !guidedCreateConsumed else { return }
        guard coordinator.activeServerId == server.id else { return }
        guard let connection = coordinator.connection(for: server.id),
              !connection.workspaceStore.lastSyncFailed else { return }
        let workspaces = connection.workspaceStore.workspaces
        guard workspaces.isEmpty else {
            navigation.shouldGuideWorkspaceCreation = false
            return
        }

        guidedCreateConsumed = true
        navigation.shouldGuideWorkspaceCreation = false
        navigation.showAllWorkspaceSessions()
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: .guidedFirstWorkspace,
            openWorkspaceAfterCreate: true,
            prefillName: nil,
            prefillPath: nil
        )
    }

    private func createSheetDidDismiss() {
        guard let target = pendingCreatedWorkspaceTarget else { return }
        pendingCreatedWorkspaceTarget = nil
        navigation.openWorkspace(target)
    }
}

/// The root's hold on the intake: one while the shell shows, none otherwise, so
/// the next shell starts with a fresh one.
@MainActor
final class WorkspaceCreationIntakeHolder {
    private(set) var intake: WorkspaceCreationIntake?

    func update(showsShell: Bool, root: AppRootEnvironment, anchor: UIViewController) {
        guard showsShell else {
            intake?.stop()
            intake = nil
            return
        }
        let current = intake ?? WorkspaceCreationIntake(root: root, anchor: anchor)
        intake = current
        current.update()
    }

    func anchorDidAppear() {
        intake?.anchorDidAppear()
    }
}
