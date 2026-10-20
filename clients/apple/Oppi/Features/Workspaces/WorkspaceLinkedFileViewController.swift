import UIKit

enum WorkspaceLinkedFileConnectionState {
    case connecting
    case connected(ServerConnection)
    case failed(String)

    init(preparationSucceeded: Bool, connection: ServerConnection?) {
        if !preparationSucceeded {
            self = .failed("Could not connect to this server.")
        } else if let connection {
            self = .connected(connection)
        } else {
            self = .failed("The server connection is unavailable.")
        }
    }
}

/// The shell's `.linkedFile` route: a file opened from a link, a write, or a
/// file list, read on its own server. While the file's lock (its session's,
/// else its workspace's) is engaged it shows the lock cover and nothing of the
/// file. Unlocked, it makes the file's server the active one ("Connecting…",
/// or "Unable to Load"), then shows the file viewer with the source chat's
/// review-comment scope and Add to Chat destination. The viewer's bar items
/// show in this screen's bar; a split detail root adds the sidebar toggle.
@MainActor
final class WorkspaceLinkedFileViewController: UIViewController {
    let target: WorkspaceLinkedFileNavTarget
    var placement: ShellRoutePlacement {
        didSet {
            guard placement != oldValue else { return }
            setNeedsUpdateProperties()
        }
    }

    private enum Shown: Equatable {
        case locked
        case connecting
        case failed(String)
        case file
    }

    private let root: AppRootEnvironment
    private var connectionState = WorkspaceLinkedFileConnectionState.connecting {
        didSet { setNeedsUpdateProperties() }
    }
    private var shown: Shown?
    private var lockCover: HostedContentController?
    private(set) var viewer: FileViewerViewController?
    private weak var viewerConnection: ServerConnection?
    private var connectTask: Task<Void, Never>?
    private var isOnScreen = false
    /// Set on each appearance and by a lock; the unlocked route spends it on
    /// one server switch, as the hosted gate's `.task(id:)` did.
    private var needsConnect = true
    /// Per-file Markdown viewport, kept while the viewer is rebuilt.
    private let viewportRestore = FileViewerViewportRestore()
    /// Captured when the route opens: the chat the link came from, if it is
    /// still the composer's destination.
    private let addToChatDestination: ComposerCanvasDestination?
    private var canvasAnchor: ComposerCanvasDestinationAnchorController?
    private var sidebarToggle: UIBarButtonItem?

    init(target: WorkspaceLinkedFileNavTarget, placement: ShellRoutePlacement, root: AppRootEnvironment) {
        self.target = target
        self.placement = placement
        self.root = root
        addToChatDestination = Self.capturedAddToChatDestination(
            sourceSessionId: target.sourceSessionId,
            current: ComposerCanvasActiveDestination.current
        )
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
    }

    private var fileName: String {
        switch target.kind {
        case .workspaceFile(_, let fileName), .sessionFile(_, let fileName, _), .hostFile(_, let fileName):
            fileName
        }
    }

    // MARK: Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        needsConnect = true
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        connectTask?.cancel()
        connectTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        let lock = Self.lockTarget(for: target)
        if ScopedLockService.shared.isLocked(lock) {
            needsConnect = true
            show(.locked)
            lockCover = ScopedLockScreenCover.make(updating: lockCover, target: lock, title: fileName, root: root)
        } else {
            if needsConnect, isOnScreen {
                needsConnect = false
                connect()
            }
            switch connectionState {
            case .connecting:
                show(.connecting)
            case .failed(let message):
                show(.failed(message))
            case .connected(let connection):
                showViewer(connection: connection)
            }
        }
        updateBar()
    }

    /// Makes the file's server the active one. A mounted viewer stays while
    /// the switch runs again on a later appearance.
    private func connect() {
        connectTask?.cancel()
        if viewer == nil {
            connectionState = .connecting
        }
        let coordinator = root.coordinator
        let serverId = target.serverId
        connectTask = Task { [weak self] in
            let succeeded = await coordinator.switchToServerReady(serverId)
            guard !Task.isCancelled, let self else { return }
            self.connectionState = WorkspaceLinkedFileConnectionState(
                preparationSucceeded: succeeded,
                connection: succeeded ? coordinator.connection(for: serverId) : nil
            )
        }
    }

    // MARK: Content

    private func show(_ next: Shown) {
        guard shown != next else { return }
        shown = next
        if next != .file {
            removeViewer()
            // Pushed text hid the stack's bar for its own; the cover and the
            // status pages need it back for the title and Back.
            navigationController?.setNavigationBarHidden(false, animated: false)
        }
        if next != .locked, let lockCover {
            remove(lockCover)
            self.lockCover = nil
        }
        if next == .locked {
            removeCanvasAnchor()
            connectTask?.cancel()
            connectTask = nil
            connectionState = .connecting
            let cover = ScopedLockScreenCover.make(updating: nil, target: Self.lockTarget(for: target), title: fileName, root: root)
            embed(cover)
            lockCover = cover
        } else {
            installCanvasAnchor()
        }
        switch next {
        case .connecting:
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = String(localized: "Connecting…")
            loading.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = loading
        case .failed(let message):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "exclamationmark.triangle")
            failed.text = String(localized: "Unable to Load")
            failed.secondaryText = message
            failed.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = failed
        case .locked, .file:
            contentUnavailableConfiguration = nil
        }
    }

    private func showViewer(connection: ServerConnection) {
        show(.file)
        if viewer != nil, viewerConnection === connection { return }
        removeViewer()
        let viewer = FileViewerViewController(
            configuration: Self.viewerConfiguration(
                for: target,
                workspaceRuntime: connection.workspaceStore.workspaces
                    .first(where: { $0.id == target.workspaceId })?.runtime,
                addToChatDestination: addToChatDestination
            ),
            services: .init(connection: connection)
        )
        viewer.onLineAnchorNotice = { [weak connection] notice in connection?.extensionToast = notice }
        viewer.markdownViewportRestore = viewportRestore
        embed(viewer)
        self.viewer = viewer
        viewerConnection = connection
    }

    /// The viewer for `target`'s kind: a workspace file keeps its worktree,
    /// adjacent files, and runtime; a session file reads that session's copy;
    /// a host file resolves against its control session's directory.
    static func viewerConfiguration(
        for target: WorkspaceLinkedFileNavTarget,
        workspaceRuntime: WorkspaceRuntime?,
        addToChatDestination: ComposerCanvasDestination?
    ) -> FileViewerViewController.Configuration {
        let file: (path: String, name: String)
        let source: FileBrowserContentSource
        let sessionId: String?
        switch target.kind {
        case .workspaceFile(let path, let fileName):
            file = (path, fileName)
            source = .workspaceFile
            sessionId = target.sourceSessionId
        case .sessionFile(let path, let fileName, let sourceSessionId):
            file = (path, fileName)
            source = .sessionFile(sessionId: sourceSessionId)
            sessionId = sourceSessionId
        case .hostFile(let path, let fileName):
            file = (path, fileName)
            source = .hostFile
            sessionId = target.sourceSessionId
        }
        return FileViewerViewController.Configuration(
            workspaceId: target.workspaceId,
            worktreeId: source == .workspaceFile ? target.worktreeId : nil,
            serverId: target.serverId,
            filePath: file.path,
            fileName: file.name,
            source: source,
            sessionId: sessionId,
            controlSessionId: source == .hostFile ? target.controlSessionId : nil,
            workspaceRuntime: source == .hostFile ? nil : workspaceRuntime,
            navigationContext: source == .workspaceFile ? target.navigationContext : nil,
            lineAnchor: target.lineAnchor,
            addToChatDestination: addToChatDestination,
            reviewCommentSelectionScope: reviewCommentSelectionScope(sourceSessionId: target.sourceSessionId)
        )
    }

    private func removeViewer() {
        guard let viewer else { return }
        remove(viewer)
        self.viewer = nil
        viewerConnection = nil
    }

    private func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func remove(_ controller: UIViewController) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    /// Image and diagram viewers opened from this file add to the source chat.
    private func installCanvasAnchor() {
        guard canvasAnchor == nil, let addToChatDestination else { return }
        let anchor = ComposerCanvasDestinationAnchorController()
        addChild(anchor)
        anchor.view.frame = .zero
        anchor.view.isHidden = true
        view.addSubview(anchor.view)
        anchor.didMove(toParent: self)
        anchor.destination = addToChatDestination
        canvasAnchor = anchor
    }

    private func removeCanvasAnchor() {
        guard let canvasAnchor else { return }
        remove(canvasAnchor)
        self.canvasAnchor = nil
    }

    // MARK: Bar

    private func updateBar() {
        if placement == .splitDetailRoot {
            let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
            sidebarToggle = toggle
            WorkspaceSplitSidebarToggle.sync(toggle, root: root)
            if navigationItem.leftBarButtonItems?.first !== toggle {
                navigationItem.leftBarButtonItems = [toggle]
            }
        } else if sidebarToggle != nil {
            sidebarToggle = nil
            navigationItem.leftBarButtonItems = nil
        }
        if let viewer {
            viewer.bar.apply(to: navigationItem)
        } else {
            navigationItem.title = nil
            navigationItem.rightBarButtonItems = nil
        }
    }
}

extension WorkspaceLinkedFileViewController {
    /// A file opened from a session follows that session's lock (and so its
    /// workspace and server); any other file follows its workspace.
    static func lockTarget(for target: WorkspaceLinkedFileNavTarget) -> ScopedLockTarget {
        let sessionId: String? = switch target.kind {
        case .sessionFile(_, _, let sessionId): sessionId
        case .workspaceFile, .hostFile: target.sourceSessionId
        }
        guard let sessionId else {
            return .workspace(serverId: target.serverId, workspaceId: target.workspaceId)
        }
        return ScopedLockService.shared.sessionTarget(
            serverId: target.serverId,
            sessionId: sessionId,
            workspaceId: target.workspaceId
        )
    }

    static func reviewCommentSelectionScope(sourceSessionId: String?) -> ReviewCommentSelectionScope? {
        guard let sourceSessionId,
              let router = ReviewCommentSelectionActiveRouter.router(for: sourceSessionId) else {
            return nil
        }
        return .activeSession(router)
    }

    static func capturedAddToChatDestination(
        sourceSessionId: String?,
        current: ComposerCanvasDestination?
    ) -> ComposerCanvasDestination? {
        guard let sourceSessionId, let current, current.sessionId == sourceSessionId else {
            return nil
        }
        return current
    }
}
