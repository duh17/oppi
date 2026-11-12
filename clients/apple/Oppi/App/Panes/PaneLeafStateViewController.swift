import UIKit

/// The `.paneEntry` route: a restored or linked entry whose content cannot
/// open yet. It shows the entry's leaf state (`PaneLeafState`) from what the
/// app knows now (the server's connection, the local stores, a lookup for a
/// session the stores do not hold, the scoped lock) and, once the content
/// can open, hands its place in the stack to the content's own screen.
///
/// The connection supplies the remedy for an unreachable server: Retry for a
/// remote one. A removed server, a deleted session, file or workspace offer
/// Choose… (the session list) and Close Pane.
final class PaneLeafStateViewController: UIViewController {
    let entry: PaneStackEntry
    private let root: AppRootEnvironment
    private var coordinator: ConnectionCoordinator { root.coordinator }
    private let stateView = UIContentUnavailableView(loadState: .connecting)

    /// The server's answer for a session the local stores do not hold.
    private var lookedUp: PaneContentPresence = .unknown
    private var lookup: Task<Void, Never>?
    private var lookupDone = false
    /// The server took the lookup and did not answer; with its streams up it
    /// would otherwise show "Connecting…" with nothing to press.
    private var lookupUnanswered = false
    private var lastStatus: PaneConnectionStatus?
    private var resolved = false
    private(set) var shownState: PaneLeafState?

    init(entry: PaneStackEntry, root: AppRootEnvironment) {
        self.entry = entry
        self.root = root
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = Self.title(for: entry.route)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { lookup?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        // Observation tracking re-runs this when the stores, the connection
        // or the lock change.
        var state = PaneEntries.state(of: entry, coordinator: coordinator, lookedUp: lookedUp)
        if state == .content, let element = PaneEntries.element(for: entry, coordinator: coordinator) {
            open(element)
            return
        }
        // A server that just connected is asked again.
        let status = PaneEntries.connectionStatus(serverId: entry.serverId, coordinator: coordinator)
        if status == .connected, lastStatus != .connected {
            lookupDone = false
            lookupUnanswered = false
        }
        lastStatus = status
        startLookupIfNeeded(state)
        if state == .connecting, lookupUnanswered {
            state = .unreachable(coordinator.connection(for: entry.serverId)?.unreachableRemedy ?? .retry)
        }
        shownState = state
        view.accessibilityIdentifier = "pane.state.\(Self.identifier(for: state))"
        stateView.configuration = configuration(for: state)
    }

    // MARK: Resolution

    /// The content's screen takes this entry's place, once. Deferred out of
    /// the update pass, which must not change navigation under itself.
    private func open(_ element: WorkspaceStackRouteElement) {
        guard !resolved else { return }
        resolved = true
        let entry = entry
        let navigation = root.navigation
        Task { @MainActor in navigation.resolvePaneEntry(entry, with: element) }
    }

    /// A session (or a session's file) the stores do not hold is asked of its
    /// server, once per Retry: the lookup's HTTPS request can answer while
    /// the live streams are still down. "Not found" makes it missing; no
    /// answer leaves the connection's state.
    private func startLookupIfNeeded(_ state: PaneLeafState) {
        guard lookup == nil, !lookupDone, lookedUp == .unknown else { return }
        switch state {
        case .connecting, .unreachable: break
        default: return
        }
        let sessionId: String
        switch entry.route {
        case .session(let id), .file(.session(let id), _, _): sessionId = id
        default: return
        }
        let serverId = entry.serverId
        let coordinator = coordinator
        lookup = Task { [weak self] in
            // The entry's own server only: another server's "not found" says
            // nothing about a session that lives here.
            let result = await coordinator.lookupSession(id: sessionId, on: serverId)
            guard let self, !Task.isCancelled else { return }
            self.lookup = nil
            self.lookupDone = true
            switch result {
            case .found: self.lookedUp = .present
            case .notFound: self.lookedUp = .absent
            case .unreachable:
                self.lookedUp = .unknown
                self.lookupUnanswered = true
            }
            self.setNeedsUpdateProperties()
        }
    }

    // MARK: Actions

    private func retry() {
        lookedUp = .unknown
        lookupDone = false
        lookupUnanswered = false
        guard let server = coordinator.serverStore.server(for: entry.serverId) else { return }
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            _ = await coordinator.ensureConnectionReady(for: server)
            self?.setNeedsUpdateProperties()
        }
    }

    private func unlock() {
        _ = ScopedLockService.shared.gate(PaneEntries.lockTarget(entry)) { [weak self] in
            self?.setNeedsUpdateProperties()
        }
    }

    private func choose() {
        root.navigation.showAllWorkspaceSessions()
    }

    private func closePane() {
        root.navigation.closePaneEntry(entry)
    }

    // MARK: Presentation

    private func configuration(for state: PaneLeafState) -> UIContentUnavailableConfiguration {
        let palette = root.themeStore.activeThemeID.palette
        let serverName = coordinator.serverStore.server(for: entry.serverId)?.name
        var config: UIContentUnavailableConfiguration
        switch state {
        case .content, .connecting:
            config = .loadState(.connecting, palette: palette)
            if let serverName { config.text = String(localized: "Connecting to \(serverName)…") }
        case .locked:
            config = .loadState(.empty(
                title: String(localized: "Locked"),
                systemImage: "lock.fill",
                message: String(localized: "Unlock to show this pane.")
            ), palette: palette)
            config.setProminentButton(String(localized: "Unlock")) { [weak self] in self?.unlock() }
        case .missing(let content):
            config = .loadState(.paneMissing(content), palette: palette)
            config.setProminentButton(String(localized: "Choose…")) { [weak self] in self?.choose() }
            addCloseButton(to: &config)
        case .unreachable(let remedy):
            let name = serverName ?? String(localized: "The server")
            switch remedy {
            case .retry:
                config = .loadState(.failed(
                    title: String(localized: "\(name) Is Offline"),
                    message: String(localized: "This pane opens when the server is reachable."),
                    retry: RetryAction { [weak self] in self?.retry() }
                ), palette: palette)
            case .restart:
                config = .loadState(.failed(
                    title: String(localized: "\(name) Stopped"),
                    message: String(localized: "Start the Oppi server on this Mac to open this pane."),
                    retry: nil
                ), palette: palette)
            case .openLoginItems:
                config = .loadState(.failed(
                    title: String(localized: "\(name) Is Turned Off"),
                    message: String(localized: "Turn on Oppi in System Settings › Login Items to open this pane."),
                    retry: nil
                ), palette: palette)
            }
            addCloseButton(to: &config)
        case .unsupported:
            config = .loadState(.empty(
                title: String(localized: "Needs a Newer Oppi"),
                systemImage: "arrow.down.app",
                message: String(localized: "Update Oppi to open this pane.")
            ), palette: palette)
            addCloseButton(to: &config)
        }
        return config
    }

    private func addCloseButton(to config: inout UIContentUnavailableConfiguration) {
        var button = UIButton.Configuration.plain()
        button.title = String(localized: "Close Pane")
        config.secondaryButton = button
        config.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in self?.closePane() }
    }

    private static func identifier(for state: PaneLeafState) -> String {
        switch state {
        case .content, .connecting: "connecting"
        case .locked: "locked"
        case .missing(let content): "missing.\(content)"
        case .unreachable: "unreachable"
        case .unsupported: "unsupported"
        }
    }

    private static func title(for route: PaneRoute) -> String {
        switch route {
        case .session, .thread, .panel: String(localized: "Session")
        case .file: String(localized: "File")
        case .files: String(localized: "Files")
        case .sessions: String(localized: "Sessions")
        case .git, .commit: String(localized: "Git")
        case .local, .unsupported: String(localized: "Pane")
        }
    }
}
