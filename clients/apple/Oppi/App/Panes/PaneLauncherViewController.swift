import UIKit

/// What a fresh split shows: the workspace's Sessions, Files, a Terminal or
/// a Web Page, as large choices. Picking one replaces the launcher in its
/// leaf; Web Page first asks for the address. New Session waits for two live
/// chats per server, so a new chat never takes the place of the one already
/// open. Files and Terminal need a workspace.
final class PaneLauncherViewController: UIViewController {
    enum Choice: CaseIterable {
        case sessions, files, terminal, web
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
        button.isEnabled = choice == .web || entry(for: choice) != nil
        return button
    }

    private func pick(_ choice: Choice) {
        if choice == .web { return askForAddress() }
        guard let entry = entry(for: choice) else { return }
        choose(entry)
    }

    /// The page the person types loads at once (owner decision D3). A bare
    /// name gets `https://`.
    private func askForAddress() {
        TextPrompt(
            title: String(localized: "Open Web Page"),
            placeholder: "example.com",
            actionTitle: String(localized: "Open"),
            fieldIdentifier: "pane.launcher.web.address",
            actionIdentifier: "pane.launcher.web.open",
            keyboardType: .URL
        ).present(from: self) { [weak self] text in
            guard let self else { return }
            guard let url = Self.webAddress(text) else {
                self.errorAlerts.show(
                    title: String(localized: "Can\u{2019}t Open This Address"),
                    message: String(localized: "Enter a web address, such as example.com or https://example.com.")
                )
                return
            }
            self.choose(PaneStackEntry(serverId: self.serverId, route: .browser(url)))
        }
    }

    /// `text` as an http or https page; one with no scheme is https.
    static func webAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), PaneWebAddress.isHTTP(url),
              url.host(percentEncoded: false)?.isEmpty == false else { return nil }
        return url
    }

    /// The entry a choice opens; nil for Files and Terminal outside a
    /// workspace. A web page's entry waits for its address.
    private func entry(for choice: Choice) -> PaneStackEntry? {
        switch choice {
        case .web:
            return nil
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
        case .web: String(localized: "Web Page")
        }
    }

    var subtitle: String {
        switch self {
        case .sessions: String(localized: "This workspace's sessions")
        case .files: String(localized: "Browse this workspace's files")
        case .terminal: String(localized: "A shell in this workspace's folder")
        case .web: String(localized: "A website, such as a dev server")
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "list.bullet.rectangle"
        case .files: "folder"
        case .terminal: "apple.terminal"
        case .web: "safari"
        }
    }
}
