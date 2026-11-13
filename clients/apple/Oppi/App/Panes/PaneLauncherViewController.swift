import UIKit

/// What a fresh split shows: the workspace's Sessions, Files or a Terminal,
/// as large choices. Picking one replaces the launcher in its leaf. New
/// Session waits for two live chats per server, so a new chat never takes the
/// place of the one already open. Files and Terminal need a workspace.
final class PaneLauncherViewController: UIViewController {
    enum Choice: CaseIterable {
        case sessions, files, terminal
    }

    private let serverId: String
    private let workspaceId: String?
    private let root: AppRootEnvironment?
    private let choose: (PaneStackEntry) -> Void
    private let stack = UIStackView()

    init(serverId: String, workspaceId: String?, root: AppRootEnvironment?, choose: @escaping (PaneStackEntry) -> Void) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.root = root
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "New Pane")
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "pane.launcher"
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 360)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 20),
            preferredWidth,
        ])
        for choice in Choice.allCases {
            stack.addArrangedSubview(button(for: choice))
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
    }

    private func button(for choice: Choice) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = choice.title
        configuration.subtitle = choice.subtitle
        configuration.image = UIImage(systemName: choice.symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title2)
        configuration.imagePadding = 16
        configuration.titleAlignment = .leading
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.pick(choice)
        })
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "pane.launcher.\(choice)"
        button.isEnabled = entry(for: choice) != nil
        return button
    }

    private func pick(_ choice: Choice) {
        guard let entry = entry(for: choice) else { return }
        choose(entry)
    }

    /// The entry a choice opens; nil for Files and Terminal outside a workspace.
    private func entry(for choice: Choice) -> PaneStackEntry? {
        switch choice {
        case .sessions:
            return PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspaceId))
        case .files:
            return workspaceId.map { PaneStackEntry(serverId: serverId, route: .files(workspace: $0, path: nil)) }
        case .terminal:
            return workspaceId.map { PaneStackEntry(serverId: serverId, route: .local(PaneLocalScreen.terminal(workspaceId: $0).token)) }
        }
    }
}

private extension PaneLauncherViewController.Choice {
    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .files: String(localized: "Files")
        case .terminal: String(localized: "Terminal")
        }
    }

    var subtitle: String {
        switch self {
        case .sessions: String(localized: "This workspace's sessions")
        case .files: String(localized: "Browse this workspace's files")
        case .terminal: String(localized: "A shell in this workspace's folder")
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "list.bullet.rectangle"
        case .files: "folder"
        case .terminal: "apple.terminal"
        }
    }
}
