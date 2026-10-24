import UIKit

/// Native overview of the host's Herdr session and the machines saved in it:
/// each machine's workspaces and their agents with live lifecycle state.
/// Selecting a row asks the Herdr server that owns it to focus it; a Herdr
/// client showing that machine follows.
final class HerdrAgentsViewController: UIViewController, UICollectionViewDelegate {
    private let monitor: HerdrMonitor
    private let channel: SSHTerminalChannel
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>?
    private var isVisible = false
    private var themeID: ThemeID { HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID() }

    /// `machine` is the saved machine's profile ID, nil for Local. Workspace
    /// and pane IDs are only unique within one machine.
    private enum Item: Hashable {
        case machine(id: String?, label: String, note: String?, failed: Bool)
        /// `section` keeps a tap's failure and Local's apart when both say the same.
        case failure(section: String, message: String)
        case empty
        case loading
        case workspace(machine: String?, id: String, label: String, focused: Bool)
        case agent(machine: String?, id: String, name: String, subtitle: String?, tab: String?, focused: Bool, status: SessionStatusKind?)
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
        cell.accessibilityValue = nil
        cell.accessibilityTraits = []
        cell.indentationLevel = 0
        switch item {
        case .machine(_, let label, let note, let failed):
            content.text = label
            content.image = UIImage(systemName: "desktopcomputer")
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = note
            content.secondaryTextProperties.color = UIColor(failed ? palette.red : palette.comment)
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.accessibilityIdentifier = "sshTerminal.herdr.machine"
            cell.accessibilityTraits = .header
        case .failure(_, let message):
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
        case .workspace(_, _, let label, let focused):
            content.text = label
            content.image = UIImage(systemName: "square.stack")
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = Self.font(focused: focused)
            cell.accessibilityValue = focused ? "Focused" : ""
            cell.accessibilityTraits = .button
        case .agent(_, _, let name, let subtitle, let tab, let focused, let kind):
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
            cell.accessibilityTraits = .button
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
        // With no saved machines the sheet is Local's alone and needs no
        // machine headers; otherwise every machine leads its own workspaces
        // with its state, so a machine that is down or disabled still shows.
        let headed = monitor.machines.count > 1
        if let failure = monitor.focusFailure {
            snapshot.appendSections(["focus-failure"])
            snapshot.appendItems([.failure(section: "focus-failure", message: failure)], toSection: "focus-failure")
        }
        for machine in monitor.machines {
            let key = "machine|\(machine.id)|"
            if headed {
                snapshot.appendSections([key])
                snapshot.appendItems([.machine(
                    id: machine.machineID, label: machine.label,
                    note: Self.note(machine), failed: machine.failure != nil
                )], toSection: key)
            } else if let failure = machine.failure {
                snapshot.appendSections(["failure"])
                snapshot.appendItems([.failure(section: "failure", message: failure)], toSection: "failure")
            }
            guard let machineSnapshot = machine.snapshot else {
                if !headed, machine.failure == nil {
                    snapshot.appendSections(["loading"])
                    snapshot.appendItems([.loading], toSection: "loading")
                }
                continue
            }
            if !headed, machineSnapshot.workspaces.isEmpty {
                snapshot.appendSections(["empty"])
                snapshot.appendItems([.empty], toSection: "empty")
            }
            for workspace in machineSnapshot.workspaces {
                let section = key + workspace.id
                snapshot.appendSections([section])
                snapshot.appendItems([
                    .workspace(machine: machine.machineID, id: workspace.workspaceID, label: workspace.label, focused: workspace.focused),
                ], toSection: section)
                for agent in machineSnapshot.agents(in: workspace) {
                    snapshot.appendItems([
                        .agent(
                            machine: machine.machineID,
                            id: agent.paneID,
                            name: agent.displayName,
                            subtitle: agent.subtitle,
                            tab: machineSnapshot.tabLabel(agent.tabID),
                            focused: agent.focused,
                            status: machineSnapshot.status(of: agent)
                        ),
                    ], toSection: section)
                }
            }
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    /// A machine header's second line: why it cannot be read (its rows, if
    /// any, are what it last reported), else its count of agents that need you.
    private static func note(_ machine: HerdrMachineState) -> String? {
        if let failure = machine.failure { return failure }
        if !machine.enabled { return "Disabled in Herdr" }
        guard let snapshot = machine.snapshot else { return "Loading…" }
        if snapshot.workspaces.isEmpty { return "No workspaces" }
        let waiting = snapshot.needsAttention
        return waiting > 0 ? "\(waiting) waiting" : nil
    }

    /// Only workspaces and agents do something when tapped.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource?.itemIdentifier(for: indexPath) {
        case .workspace?, .agent?: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        let target: (HerdrRemote.FocusTarget, machine: String?)?
        switch item {
        case .workspace(let machine, let id, _, _): target = (.workspace(id), machine)
        case .agent(let machine, let id, _, _, _, _, _): target = (.agent(id), machine)
        default: target = nil
        }
        guard let target else { return }
        Task {
            let focused = await monitor.focus(target.0, machine: target.machine, on: channel)
            if focused, isVisible { Router.finish(self) } else { applySnapshot() }
        }
    }
}

/// A Herdr row that keeps its own status mark, so a working agent's
/// animation survives reconfiguration instead of restarting on a new view.
final class HerdrAgentCell: UICollectionViewListCell {
    let mark = SSHTerminalStatusMarkView(style: .row)
}
