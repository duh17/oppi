import UIKit

/// The Git panel: the workspace context bar, always expanded
/// (`WorkspaceContextBarView.Options.isPanel`), under a Git title with Close.
/// A chat's opens as a sheet in compact width and in the trailing column in
/// regular width, like Outline and Context; a workspace's opens as a sheet
/// from its top bar.
///
/// It reads its host's Git status (and a chat's session) live in
/// `updateProperties()`. The bar presents its file reviews and commit details
/// from this screen, so they stack over the panel.
final class GitPanelViewController: UIViewController {
    private let readContext: () -> WorkspaceContextBarView.Context?
    private let bar: WorkspaceContextBarView
    private let onClose: () -> Void
    private let statusLabel = UILabel()
    private var themeID: ThemeID?

    init(
        context: @escaping () -> WorkspaceContextBarView.Context?,
        options: WorkspaceContextBarView.Options,
        connection: ServerConnection,
        apiClient: APIClient?,
        navigation: AppNavigation,
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

        // Shown instead of the bar while there is no Git status to draw.
        statusLabel.font = UIFont.scaled(.subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "git.panel.status"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

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
            statusLabel.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        let current = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        if current != themeID {
            themeID = current
            overrideUserInterfaceStyle = current.preferredColorScheme == .light ? .light : .dark
            view.backgroundColor = UIColor(current.palette.bg)
            statusLabel.textColor = UIColor(current.palette.comment)
        }
        guard let context = readContext() else { return }
        bar.context = context
        statusLabel.text = Self.statusText(context)
        statusLabel.isHidden = statusLabel.text == nil
    }

    /// Why there is no Git status to show, or nil when the bar draws it.
    private static func statusText(_ context: WorkspaceContextBarView.Context) -> String? {
        guard let gitStatus = context.gitStatus else {
            return context.isLoading ? String(localized: "Loading Git status…") : String(localized: "No Git status")
        }
        return gitStatus.isGitRepo ? nil : String(localized: "Not a Git repository")
    }
}
