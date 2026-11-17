import UIKit

/// The Git panel: the workspace context bar (`WorkspaceContextBarView`),
/// under a Git title with Close.
/// A chat's opens as a sheet in compact width and in the attached leaf in
/// regular width, like Outline and Context; a workspace's opens as a sheet
/// from its top bar; a linked Git is a pane (`PaneGitScreens`).
///
/// It reads its host's Git status (and a chat's session) live in
/// `updateProperties()`, and asks `GitStatusStore` for its checkout each time
/// it appears, so it never depends on its host having loaded it: a Git pane
/// restored at launch has no host that would. Without a status it shows a
/// `LoadState`: connecting, loading, a failure with Retry, or why there is
/// none. The bar opens its file reviews and commit details
/// from this screen (`Options.hostedInPanel`): pushed onto this panel's own
/// stack, with a back button to it, while the panel is the trailing column's
/// root, a Git pane's root, or a pushed page (`PaneGitScreens`); a sheet over
/// the panel otherwise (a compact-width chat panel, or a workspace's own Git
/// sheet).
final class GitPanelViewController: UIViewController {
    private let readContext: () -> WorkspaceContextBarView.Context?
    private let bar: WorkspaceContextBarView
    private let connection: ServerConnection
    private let onClose: () -> Void
    /// Shown instead of the bar while there is no Git status to draw
    /// (`git.panel.status`; its value names the state).
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private var themeID: ThemeID?

    init(
        context: @escaping () -> WorkspaceContextBarView.Context?,
        options: WorkspaceContextBarView.Options,
        connection: ServerConnection,
        apiClient: APIClient?,
        navigation: SceneNavigation,
        onClose: @escaping () -> Void
    ) {
        readContext = context
        bar = WorkspaceContextBarView(
            context: context() ?? WorkspaceContextBarView.Context(),
            options: options,
            connection: connection,
            apiClient: apiClient,
            navigation: navigation
        )
        self.connection = connection
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Git")
        navigationItem.largeTitleDisplayMode = .never
        // Set before the bar first draws; `updateProperties` follows theme changes.
        overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.onClose()
        })
        close.accessibilityIdentifier = "git.panel.close"
        navigationItem.leftBarButtonItem = close

        bar.presenter = self
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        stateView.accessibilityIdentifier = "git.panel.status"
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: guide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            // The bar's table scrolls in this height; an empty bar (no Git
            // content) is 0 tall instead.
            bar.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
            {
                let fill = bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
                fill.priority = .defaultHigh
                return fill
            }(),
            stateView.topAnchor.constraint(equalTo: guide.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadStatus()
    }

    /// Asks the store for this panel's checkout: on appear, and from Retry.
    /// With no client yet the store holds it as on its way, and the event
    /// stream's connect fetches it (`GitStatusStore.refreshTracked`).
    private func loadStatus() {
        guard let context = readContext(), let workspaceId = context.workspaceId else { return }
        let workspace = connection.workspaceStore.workspaces.first { $0.id == workspaceId }
        connection.gitStatusStore.loadInitial(
            workspaceId: workspaceId,
            worktreeId: context.worktreeId,
            apiClient: connection.apiClient,
            gitStatusEnabled: workspace?.gitStatusEnabled ?? true
        )
    }

    override func updateProperties() {
        super.updateProperties()
        let current = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        if current != themeID {
            themeID = current
            overrideUserInterfaceStyle = current.preferredColorScheme == .light ? .light : .dark
            view.backgroundColor = current.palette.ui.bg
        }
        guard let context = readContext() else { return }
        bar.context = context
        let state = loadState(context)
        stateView.isHidden = state == nil
        stateView.accessibilityValue = state?.kind
        if let state {
            stateView.configuration = UIContentUnavailableConfiguration.loadState(state.loadState, palette: current.palette)
        }
    }

    /// What shows instead of the bar, or nil when the bar draws the status.
    private struct ShownState {
        let kind: String
        let loadState: LoadState
    }

    private func loadState(_ context: WorkspaceContextBarView.Context) -> ShownState? {
        if let gitStatus = context.gitStatus {
            guard !gitStatus.isGitRepo else { return nil }
            return ShownState(kind: "empty", loadState: .empty(
                title: String(localized: "Not a Git Repository"), systemImage: "arrow.triangle.branch"
            ))
        }
        let error = context.workspaceId.flatMap {
            connection.gitStatusStore.loadError(workspaceId: $0, worktreeId: context.worktreeId)
        }
        if let error {
            return ShownState(kind: "failed", loadState: .failed(
                title: String(localized: "Couldn\u{2019}t Load Git Status"),
                message: error,
                retry: RetryAction { [weak self] in self?.loadStatus() }
            ))
        }
        if context.isLoading {
            return connection.apiClient == nil
                ? ShownState(kind: "connecting", loadState: .connecting)
                : ShownState(kind: "loading", loadState: .loading(String(localized: "Loading Git status…")))
        }
        return ShownState(kind: "empty", loadState: .empty(
            title: String(localized: "No Git Status"), systemImage: "arrow.triangle.branch"
        ))
    }
}
