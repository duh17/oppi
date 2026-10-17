import UIKit

/// Native overview of the host's Herdr session: workspaces and their agents
/// with live lifecycle state. Selecting a row asks Herdr to focus it; the
/// attached Herdr client in the terminal follows.
final class HerdrAgentsViewController: UIViewController, UICollectionViewDelegate {
    private let monitor: HerdrMonitor
    private let channel: SSHTerminalChannel
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>?
    private var isVisible = false
    private var themeID: ThemeID { HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID() }

    private enum Item: Hashable {
        case failure(String)
        case empty
        case loading
        case workspace(id: String, label: String, focused: Bool)
        case agent(id: String, name: String, subtitle: String?, tab: String?, focused: Bool, status: HerdrSnapshot.Status)
    }

    init(monitor: HerdrMonitor, channel: SSHTerminalChannel) {
        self.monitor = monitor
        self.channel = channel
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Herdr"
        navigationItem.largeTitleDisplayMode = .inline
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(themeID.palette.bg)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = UIColor(themeID.palette.bg)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            Task { await self?.refresh() }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        applySnapshot()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        monitor.watching = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            isVisible = false
            monitor.watching = false
        }
    }

    override func updateProperties() {
        super.updateProperties()
        applySnapshot()
        view.backgroundColor = UIColor(themeID.palette.bg)
        collectionView.backgroundColor = UIColor(themeID.palette.bg)
    }

    @objc private func close() {
        Router.finish(self)
    }

    private func refresh() async {
        await monitor.refresh(on: channel)
        collectionView.refreshControl?.endRefreshing()
        applySnapshot()
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = themeID.palette
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        switch item {
        case .failure(let message):
            content.text = message
            content.textProperties.color = UIColor(palette.red)
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.accessibilityIdentifier = "sshTerminal.herdr.failure"
            cell.accessories = []
        case .empty:
            content.text = "No Herdr workspaces."
            content.textProperties.color = UIColor(palette.comment)
        case .loading:
            content.text = "Loading…"
            content.textProperties.color = UIColor(palette.comment)
        case .workspace(_, let label, let focused):
            content.text = label
            content.image = UIImage(systemName: focused ? "checkmark.circle.fill" : "square.stack")
            content.imageProperties.tintColor = UIColor(palette.fg)
            content.textProperties.color = UIColor(palette.fg)
            cell.accessories = []
            cell.accessibilityValue = focused ? "Focused" : ""
        case .agent(_, let name, let subtitle, let tab, let focused, let status):
            content.text = name
            content.secondaryText = [subtitle, tab.map { "tab \($0)" }].compactMap { $0 }.joined(separator: " · ")
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            if let kind = status.sessionStatus {
                content.image = UIImage(systemName: kind.terminalSymbol)
                content.imageProperties.tintColor = UIColor(kind.tint(themeID.appTheme))
            } else {
                content.image = UIImage(systemName: "questionmark")
                content.imageProperties.tintColor = UIColor(palette.comment)
            }
            if focused {
                cell.accessories = [.disclosureIndicator()]
            }
            cell.accessibilityIdentifier = "sshTerminal.herdr.agent"
            cell.accessibilityValue = status.sessionStatus?.label ?? "Unknown"
            content.directionalLayoutMargins.leading = 28
        }
        cell.contentConfiguration = content
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        if let failure = monitor.failure {
            snapshot.appendSections(["failure"])
            snapshot.appendItems([.failure(failure)], toSection: "failure")
        }
        if let snapshotValue = monitor.snapshot {
            if snapshotValue.workspaces.isEmpty {
                snapshot.appendSections(["empty"])
                snapshot.appendItems([.empty], toSection: "empty")
            }
            for workspace in snapshotValue.workspaces {
                snapshot.appendSections([workspace.id])
                snapshot.appendItems([
                    .workspace(id: workspace.workspaceID, label: workspace.label, focused: workspace.focused),
                ], toSection: workspace.id)
                for agent in snapshotValue.agents(in: workspace) {
                    snapshot.appendItems([
                        .agent(
                            id: agent.paneID,
                            name: agent.displayName,
                            subtitle: agent.subtitle,
                            tab: snapshotValue.tabLabel(agent.tabID),
                            focused: agent.focused,
                            status: agent.status
                        ),
                    ], toSection: workspace.id)
                }
            }
        } else if monitor.failure == nil {
            snapshot.appendSections(["loading"])
            snapshot.appendItems([.loading], toSection: "loading")
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        let target: HerdrRemote.FocusTarget?
        switch item {
        case .workspace(let id, _, _): target = .workspace(id)
        case .agent(let id, _, _, _, _, _): target = .agent(id)
        default: target = nil
        }
        guard let target else { return }
        Task {
            await monitor.focus(target, on: channel)
            if monitor.failure == nil, isVisible { Router.finish(self) }
        }
    }
}
