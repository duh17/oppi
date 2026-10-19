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
        case agent(id: String, name: String, subtitle: String?, tab: String?, focused: Bool, status: SessionStatusKind?)
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

        let cell = UICollectionView.CellRegistration<HerdrAgentCell, Item> { [weak self] cell, _, item in
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

    private func configure(_ cell: HerdrAgentCell, item: Item) {
        let palette = themeID.palette
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.indentationLevel = 0
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
            content.image = UIImage(systemName: "square.stack")
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = Self.font(focused: focused)
            cell.accessibilityValue = focused ? "Focused" : ""
        case .agent(_, let name, let subtitle, let tab, let focused, let kind):
            content.text = name
            content.secondaryText = [subtitle, tab.map { "tab \($0)" }].compactMap { $0 }.joined(separator: " · ")
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = Self.font(focused: focused)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            // Same mark and label as the status glyph and session rows.
            cell.mark.isHidden = kind == nil
            if let kind {
                cell.mark.apply(status: kind, themeID: themeID, reduceMotion: UIAccessibility.isReduceMotionEnabled)
            }
            cell.accessories = [
                .customView(configuration: .init(customView: cell.mark, placement: .leading(), reservedLayoutWidth: .custom(20))),
                .label(text: kind?.label ?? "Unknown", options: .init(
                    tintColor: UIColor(kind?.tint(themeID.appTheme) ?? palette.comment),
                    font: .preferredFont(forTextStyle: .caption1)
                )),
            ]
            cell.accessibilityIdentifier = "sshTerminal.herdr.agent"
            cell.accessibilityValue = [kind?.label ?? "Unknown", focused ? "Focused" : nil].compactMap { $0 }.joined(separator: ", ")
            cell.indentationLevel = 1
        }
        cell.contentConfiguration = content
    }

    /// Herdr's focused workspace and pane read bold: focus is where the
    /// attached client looks, not a status.
    private static func font(focused: Bool) -> UIFont {
        let body = UIFont.preferredFont(forTextStyle: .body)
        guard focused, let bold = body.fontDescriptor.withSymbolicTraits(.traitBold) else { return body }
        return UIFont(descriptor: bold, size: 0)
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
                            status: snapshotValue.status(of: agent)
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

/// A Herdr row that keeps its own status mark, so a working agent's
/// animation survives reconfiguration instead of restarting on a new view.
final class HerdrAgentCell: UICollectionViewListCell {
    let mark = SSHTerminalStatusMarkView(style: .row)
}
