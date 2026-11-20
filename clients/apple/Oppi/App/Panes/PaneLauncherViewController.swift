import UIKit

/// What a fresh split shows: the workspace's Sessions, Files, a Terminal,
/// Rex, a Web Page or Godot (with the Godot Pane experiment on), as large choices. Terminal, Rex, Web Page and Godot show only
/// while the leaf's server offers them (`ServerFeature`). Picking one replaces the
/// launcher in its leaf; Rex opens the Terminal page's Rex list, Web Page
/// the browser with its address field up, Godot the server's Godot projects. New Session
/// waits for two live chats per server, so a new chat never takes the place
/// of the one already open. Files and Terminal need a workspace.
///
/// The choices scroll, so a short pane (a Split Down dragged to its minimum)
/// never squeezes them over each other. A pane too short for one column but
/// wide enough for two lays them out two by two.
///
/// Under them, a Pinned group lists the server's pinned folders and files
/// (`PinStore`); one opens its folder's File Browser or its file in this pane.
/// Pinned sessions stay on the Pinned screen: Sessions above already picks a
/// chat, and the group stays a short list of places.
final class PaneLauncherViewController: UIViewController {
    enum Choice: CaseIterable {
        case sessions, files, terminal, rex, web, godot

        /// The server switch a choice needs; Sessions and Files are plain Pi.
        var feature: ServerFeature? {
            switch self {
            case .sessions, .files: nil
            case .terminal: .terminal
            case .rex: .rex
            case .web: .browserPane
            case .godot: .godotPane
            }
        }

        /// The choices for a leaf on a server that `offers` these features: Godot also needs
        /// its experiment on this device.
        static func offered(by offers: (ServerFeature) -> Bool) -> [Self] {
            allCases.filter { choice in
                guard choice.feature.map(offers) ?? true else { return false }
                return choice != .godot || GodotPaneAvailability.isOn
            }
        }
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
    /// The choices' grid, then the Pinned group.
    private let content = UIStackView()
    private let grid = UIStackView()
    private let pinned = UIStackView()
    private var buttons: [UIButton] = []
    private var shownChoices: [Choice] = []
    private var shownPins: [PinnedChoice] = []
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
        pinned.axis = .vertical
        pinned.spacing = 8
        pinned.accessibilityIdentifier = "pane.launcher.pinned"
        content.axis = .vertical
        content.spacing = Self.spacing * 2
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(grid)
        content.addArrangedSubview(pinned)
        scrollView.addSubview(content)

        let guide = view.safeAreaLayoutGuide
        let scrolled = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        let preferredWidth = content.widthAnchor.constraint(equalToConstant: Self.preferredColumnWidth)
        preferredWidth.priority = .defaultHigh
        self.preferredWidth = preferredWidth
        // The content is the frame's height when the choices fit, and theirs
        // (scrolling) when they do not; the choices sit in its middle.
        let fitsFrame = scrolled.heightAnchor.constraint(equalTo: frame.heightAnchor)
        fitsFrame.priority = .defaultLow
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrolled.widthAnchor.constraint(equalTo: frame.widthAnchor),
            scrolled.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            fitsFrame,
            content.centerXAnchor.constraint(equalTo: scrolled.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: scrolled.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: scrolled.topAnchor, constant: Self.spacing),
            content.bottomAnchor.constraint(lessThanOrEqualTo: scrolled.bottomAnchor, constant: -Self.spacing),
            content.widthAnchor.constraint(lessThanOrEqualTo: frame.widthAnchor, constant: -2 * Self.margin),
            preferredWidth,
        ])
        showChoices(offeredChoices)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wanted = Self.columns(for: scrollView.bounds.size, choiceHeight: choiceHeight(), count: buttons.count)
        guard wanted != columns else { return }
        arrange(columns: wanted)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if let pins {
            Task { await pins.store.refresh(api: pins.api) }
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store or the pins change.
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        // A server switch that changes while the launcher is up adds or takes away its choice.
        let offered = offeredChoices
        if offered != shownChoices { showChoices(offered) }
        let choices = (pins?.store.pins ?? []).filter { $0.target.isBrowserPlace }.map { PinnedChoice(pin: $0, workspaceName: workspaceName($0.target.workspaceId)) }
        if choices != shownPins { showPinned(choices) }
    }

    /// The choices this leaf's server offers now (its connection is observed).
    private var offeredChoices: [Choice] {
        guard let coordinator = root?.coordinator else { return Choice.offered { _ in true } }
        return Choice.offered { coordinator.server(serverId, offers: $0) }
    }

    private func showChoices(_ choices: [Choice]) {
        shownChoices = choices
        buttons = choices.map(button(for:))
        arrange(columns: 1)
        view.setNeedsLayout()
    }

    /// This leaf's server's pins, never the window's active server's.
    private var pins: (store: PinStore, api: APIClient)? {
        root.flatMap { PaneEntries.pins(serverId, coordinator: $0.coordinator) }
    }

    private func workspaceName(_ id: String?) -> String? {
        guard let id, let root else { return nil }
        if let name = PaneEntries.workspace(id, serverId: serverId, coordinator: root.coordinator)?.workspace.name {
            return name
        }
        // A workspace newer than the catalog: the name shows once it is read again.
        PaneEntries.refreshCatalog(forUnknownWorkspace: id, serverId: serverId, coordinator: root.coordinator)
        return nil
    }

    // MARK: Pinned

    /// What one pin's button shows; the group rebuilds when these change.
    private struct PinnedChoice: Equatable {
        let pin: Pin
        let workspaceName: String?
    }

    private func showPinned(_ choices: [PinnedChoice]) {
        shownPins = choices
        for view in pinned.arrangedSubviews {
            pinned.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        pinned.isHidden = choices.isEmpty
        guard !choices.isEmpty else { return }
        let title = UILabel()
        title.text = String(localized: "Pinned")
        title.font = UIFont.preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .secondaryLabel
        title.accessibilityTraits = .header
        pinned.addArrangedSubview(title)
        for choice in choices {
            pinned.addArrangedSubview(pinButton(choice))
        }
    }

    private func pinButton(_ choice: PinnedChoice) -> UIButton {
        let pin = choice.pin
        let gone = pin.status == .missing || pin.status == .workspaceMissing
        var configuration = UIButton.Configuration.gray()
        let names = PinNames(workspace: choice.workspaceName)
        configuration.title = pin.displayName(names)
        configuration.subtitle = pin.subtitle(names)
        let filePath: String? = if case .file(_, let path, _) = pin.target { path } else { nil }
        configuration.image = UIImage(systemName: filePath.map { FileIcon.forPath($0).symbolName } ?? "folder.fill")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        configuration.imagePadding = 12
        configuration.titleAlignment = .leading
        configuration.titleLineBreakMode = .byTruncatingMiddle
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        configuration.cornerStyle = .large
        let entry = pin.paneEntry(serverId: serverId)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.choose(entry)
        })
        button.contentHorizontalAlignment = .leading
        button.isEnabled = !gone
        button.accessibilityIdentifier = "pane.launcher.pin.\(pin.target.pinKey)"
        return button
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
        case .rex:
            return PaneStackEntry(serverId: serverId, route: .local(PaneLocalScreen.rex.token))
        case .godot:
            return PaneStackEntry(serverId: serverId, route: .local(PaneLocalScreen.godot.token))
        }
    }
}

private extension PaneLauncherViewController.Choice {
    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .files: String(localized: "Files")
        case .terminal: String(localized: "Terminal")
        case .rex: String(localized: "Rex")
        case .web: String(localized: "Web Page")
        case .godot: String(localized: "Godot")
        }
    }

    var subtitle: String {
        switch self {
        case .sessions: String(localized: "This workspace's sessions")
        case .files: String(localized: "Browse this workspace's files")
        case .terminal: String(localized: "A shell in this workspace's folder")
        case .rex: String(localized: "Sessions on your Rex hosts")
        case .web: String(localized: "A website, such as a dev server")
        case .godot: String(localized: "A Godot game from this server")
        }
    }

    var symbol: String {
        switch self {
        case .sessions: "list.bullet.rectangle"
        case .files: "folder"
        case .terminal: "apple.terminal"
        case .rex: "rectangle.split.3x1"
        case .web: "safari"
        case .godot: "gamecontroller"
        }
    }
}
