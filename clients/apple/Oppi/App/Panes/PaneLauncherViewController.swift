import UIKit

/// What a fresh split shows: the workspace's Sessions, Files, a Terminal or
/// a Web Page, as large choices. Picking one replaces the launcher in its
/// leaf; Web Page opens the browser with its address field up. New Session
/// waits for two live chats per server, so a new chat never takes the place
/// of the one already open. Files and Terminal need a workspace.
///
/// The choices scroll, so a short pane (a Split Down dragged to its minimum)
/// never squeezes them over each other. A pane too short for one column but
/// wide enough for two lays them out two by two.
final class PaneLauncherViewController: UIViewController {
    enum Choice: CaseIterable {
        case sessions, files, terminal, web
    }

    /// The narrowest a choice gets in a two-column grid.
    static let minimumGridColumnWidth: CGFloat = 260
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 20
    /// The width of one column of choices, when the pane has it.
    static let preferredColumnWidth: CGFloat = 360

    private let serverId: String
    private let workspaceId: String?
    private let root: AppRootEnvironment?
    private let choose: (PaneStackEntry) -> Void
    private let scrollView = UIScrollView()
    private let grid = UIStackView()
    private var buttons: [UIButton] = []
    private var preferredWidth: NSLayoutConstraint?
    private(set) var columns = 1

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.accessibilityIdentifier = "pane.launcher.choices"
        view.addSubview(scrollView)
        grid.axis = .vertical
        grid.spacing = Self.spacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(grid)

        let guide = view.safeAreaLayoutGuide
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        let preferredWidth = grid.widthAnchor.constraint(equalToConstant: Self.preferredColumnWidth)
        preferredWidth.priority = .defaultHigh
        self.preferredWidth = preferredWidth
        // The content is the frame's height when the choices fit, and theirs
        // (scrolling) when they do not; the choices sit in its middle.
        let fitsFrame = content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        fitsFrame.priority = .defaultLow
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            fitsFrame,
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            grid.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Self.spacing),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Self.spacing),
            grid.widthAnchor.constraint(lessThanOrEqualTo: frame.widthAnchor, constant: -2 * Self.margin),
            preferredWidth,
        ])
        buttons = Choice.allCases.map(button(for:))
        arrange(columns: 1)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wanted = Self.columns(for: scrollView.bounds.size, choiceHeight: choiceHeight(), count: buttons.count)
        guard wanted != columns else { return }
        arrange(columns: wanted)
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
    }

    /// Two columns only when one column would scroll and two fit side by
    /// side; otherwise one, which scrolls when the pane is shorter still.
    static func columns(for size: CGSize, choiceHeight: CGFloat, count: Int) -> Int {
        let oneColumn = CGFloat(count) * choiceHeight + CGFloat(count - 1) * spacing + 2 * spacing
        let twoColumnsFit = size.width - 2 * margin >= 2 * minimumGridColumnWidth + spacing
        return size.height < oneColumn && twoColumnsFit ? 2 : 1
    }

    /// The tallest choice at the width a column gives it.
    private func choiceHeight() -> CGFloat {
        let width = min(Self.preferredColumnWidth, max(0, scrollView.bounds.width - 2 * Self.margin))
        return buttons.map {
            $0.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        }.max() ?? 0
    }

    private func arrange(columns: Int) {
        self.columns = columns
        for row in grid.arrangedSubviews {
            grid.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for start in stride(from: 0, to: buttons.count, by: columns) {
            let row = UIStackView(arrangedSubviews: Array(buttons[start..<min(start + columns, buttons.count)]))
            row.axis = .horizontal
            row.spacing = Self.spacing
            row.distribution = .fillEqually
            row.alignment = .fill
            grid.addArrangedSubview(row)
        }
        preferredWidth?.constant = CGFloat(columns) * Self.preferredColumnWidth + CGFloat(columns - 1) * Self.spacing
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

    /// The entry a choice opens; nil for Files and Terminal outside a
    /// workspace. A web page opens with no address, its field up.
    private func entry(for choice: Choice) -> PaneStackEntry? {
        switch choice {
        case .web:
            return PaneStackEntry(serverId: serverId, route: .local(PaneLocalScreen.browser.token))
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
