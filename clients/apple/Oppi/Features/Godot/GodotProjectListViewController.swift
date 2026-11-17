import UIKit

/// The launcher's Godot choice: the Godot projects the server discovered in
/// its workspaces (design §6, discovery first). A project with no exported
/// pack says "No build yet". Picking one shows it in this pane. On a server
/// that keeps pins, a row's swipe, menu, and accessibility actions offer Pin
/// or Unpin.
final class GodotProjectListViewController: UIViewController, UICollectionViewDelegate {
    private let serverId: String
    private let root: AppRootEnvironment?
    private let choose: (PaneStackEntry) -> Void
    private var projects: [GodotProject] = []
    private var loadState: LoadState? = .connecting
    private var loadTask: Task<Void, Never>?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout())
    private let stateView = UIContentUnavailableView(loadState: .connecting)
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?

    init(serverId: String, root: AppRootEnvironment?, choose: @escaping (PaneStackEntry) -> Void) {
        self.serverId = serverId
        self.root = root
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Godot")
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        loadTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "godot.projects"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "godot.projects.list"
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.accessibilityIdentifier = "godot.projects.state"
        view.addSubview(collectionView)
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let registration = UICollectionView.CellRegistration<GodotProjectCell, String> { [weak self] cell, _, id in
            guard let self, let project = projects.first(where: { $0.id == id }) else { return }
            cell.configure(
                project, pinToggle: { [weak self] in self?.pinToggle(id) }, activate: { [weak self] in self?.open(id) }
            )
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        load()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme changes.
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        collectionView.backgroundColor = .clear
        stateView.isHidden = loadState == nil
        stateView.accessibilityValue = loadState.map(Self.kind)
        if let loadState { stateView.configuration = UIContentUnavailableConfiguration.loadState(loadState, palette: palette) }
    }

    private func load() {
        loadTask?.cancel()
        loadState = .connecting
        view.setNeedsUpdateProperties()
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let root else { return }
            var link = PaneEntries.godotLink(serverId, coordinator: root.coordinator)
            while link == nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                link = PaneEntries.godotLink(serverId, coordinator: root.coordinator)
            }
            guard let link else { return }
            loadState = .loading(nil)
            view.setNeedsUpdateProperties()
            do {
                let projects = try await link.projects()
                guard !Task.isCancelled else { return }
                show(projects)
            } catch APIError.server(404, _), APIError.codedServer(404, _, _) {
                // A server from before games has no /godot route.
                loadState = .empty(
                    title: String(localized: "No Godot Projects on This Server"), systemImage: "gamecontroller",
                    message: String(localized: "Update the Oppi server to play its workspaces’ Godot projects here.")
                )
                view.setNeedsUpdateProperties()
            } catch {
                guard !Task.isCancelled else { return }
                loadState = .failed(
                    title: String(localized: "Couldn’t Load Godot Projects"), message: error.localizedDescription,
                    retry: RetryAction { [weak self] in self?.load() }
                )
                view.setNeedsUpdateProperties()
            }
        }
    }

    private func show(_ projects: [GodotProject]) {
        self.projects = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loadState = projects.isEmpty ? .empty(
            title: String(localized: "No Godot Projects"), systemImage: "gamecontroller",
            message: String(localized: "A folder with a project.godot in one of this server’s workspaces shows up here.")
        ) : nil
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(self.projects.map(\.id))
        snapshot.reconfigureItems(self.projects.map(\.id))
        dataSource?.apply(snapshot, animatingDifferences: false)
        view.setNeedsUpdateProperties()
    }

    private func open(_ id: String) {
        choose(PaneStackEntry(serverId: serverId, route: .godot(project: id)))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        open(id)
    }

    /// Touch and hold: Pin or Unpin, read when the menu opens.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource?.itemIdentifier(for: indexPaths[0]),
              pinToggle(id) != nil else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let toggle = self?.pinToggle(id) else { return nil }
            return UIMenu(children: [toggle.action])
        }
    }

    /// The game's Pin or Unpin; nil on a server that keeps no pins.
    private func pinToggle(_ id: String) -> PinMenu.Toggle? {
        guard let root, let view = viewIfLoaded,
              let (pins, api) = PaneEntries.pins(serverId, coordinator: root.coordinator) else { return nil }
        return PinMenu.toggle(
            route: .godot(project: id), identifiers: ("godot.projects.pin.\(id)", "godot.projects.unpin.\(id)"), pins: pins, api: api, view: view
        )
    }

    private func layout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let id = dataSource?.itemIdentifier(for: indexPath), let toggle = pinToggle(id) else { return nil }
            let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
            return UISwipeActionsConfiguration(actions: [toggle.swipeAction(color: palette.ui.yellow)])
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private static func kind(_ state: LoadState) -> String {
        switch state {
        case .connecting: "connecting"
        case .loading: "loading"
        case .empty: "empty"
        case .missing: "missing"
        case .noResults: "noResults"
        case .failed: "failed"
        }
    }
}

/// One project: its name, and its build with how old it is, "No build yet",
/// or why its build won't play here. The cell is the one element; activating
/// it opens the project, as a tap does, and its Pin or Unpin is an action.
private final class GodotProjectCell: UICollectionViewListCell {
    private var activate: (() -> Void)?
    private var pinToggle: (() -> PinMenu.Toggle?)?

    func configure(_ project: GodotProject, pinToggle: @escaping () -> PinMenu.Toggle?, activate: @escaping () -> Void) {
        self.activate = activate
        self.pinToggle = pinToggle
        var content = defaultContentConfiguration()
        content.text = project.name
        content.image = UIImage(systemName: "gamecontroller")
        content.secondaryTextProperties.color = .secondaryLabel
        if let release = project.release {
            if let needed = Self.newerEngine(release) {
                content.secondaryText = String(localized: "Needs Godot \(needed.description)")
                content.image = UIImage(systemName: "exclamationmark.triangle.fill")
                content.imageProperties.tintColor = .systemOrange
            } else {
                let age = Date(timeIntervalSince1970: release.createdAt / 1000).relativeOrShortDateString()
                content.secondaryText = "\(release.label ?? String(localized: "Ready to play")) · \(age)"
            }
        } else {
            content.secondaryText = String(localized: "No build yet")
        }
        contentConfiguration = content
        accessories = [.disclosureIndicator()]
        // Rows sit on the page's theme background, as the launcher's choices do.
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        accessibilityIdentifier = "godot.projects.row.\(project.id)"
        accessibilityTraits = .button
    }

    /// The Godot a release needs when this app's engine is older; the pane
    /// refuses such a build (`GodotPackPolicy`).
    private static func newerEngine(_ release: GodotRelease) -> GodotEngineVersion? {
        guard let version = release.engine.version.flatMap(GodotEngineVersion.init),
              version > GodotPackPolicy.engineVersion else { return nil }
        return version
    }

    override func accessibilityActivate() -> Bool {
        activate?()
        return activate != nil
    }

    /// Pin or Unpin as the pins are now, the same toggle the swipe and menu run.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { (pinToggle?()).flatMap { $0 }.map { [$0.accessibilityAction] } }
        set {}
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityIdentifier = nil
        activate = nil
        pinToggle = nil
    }
}
