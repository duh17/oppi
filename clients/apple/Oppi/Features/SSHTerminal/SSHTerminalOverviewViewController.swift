import UIKit

/// Native overview of a multiplexer the terminal's host runs: Herdr's machines,
/// workspaces, and agents, or Rex's sessions and panes, each with its live
/// program status. The source decides the rows (`SSHTerminalOverviewSource`);
/// this sheet draws them the same way for every multiplexer. Selecting a row
/// acts on it: Herdr focuses it on the host, Rex opens the pane on this device.
final class SSHTerminalOverviewViewController: UIViewController, UICollectionViewDelegate {
    private let source: any SSHTerminalOverviewSource
    private let channel: SSHTerminalChannel
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<String, SSHTerminalOverviewRow>?
    private var isVisible = false
    private var themeID: ThemeID { AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID() }

    init(source: any SSHTerminalOverviewSource, channel: SSHTerminalChannel) {
        self.source = source
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
        title = source.title
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

        let cell = UICollectionView.CellRegistration<SSHTerminalOverviewCell, SSHTerminalOverviewRow> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        applySnapshot()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        source.watching = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            isVisible = false
            source.watching = false
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
        await source.refresh(on: channel)
        collectionView.refreshControl?.endRefreshing()
        applySnapshot()
    }

    private func configure(_ cell: SSHTerminalOverviewCell, row: SSHTerminalOverviewRow) {
        let palette = themeID.palette
        let prefix = source.identifierPrefix
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.accessibilityValue = nil
        cell.accessibilityTraits = []
        cell.indentationLevel = 0
        switch row.kind {
        case .header(let note, let failed):
            content.image = UIImage(systemName: "desktopcomputer")
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = note
            content.secondaryTextProperties.color = UIColor(failed ? palette.red : palette.comment)
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.accessibilityIdentifier = "\(prefix).header"
            cell.accessibilityTraits = .header
        case .failure:
            content.textProperties.color = UIColor(palette.red)
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.accessibilityIdentifier = "\(prefix).failure"
        case .placeholder:
            content.textProperties.color = UIColor(palette.comment)
        case .group(let focused):
            content.image = UIImage(systemName: "square.stack")
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = Self.font(focused: focused)
            cell.accessibilityIdentifier = "\(prefix).group"
            cell.accessibilityValue = focused ? "Focused" : ""
            cell.accessibilityTraits = row.focus == nil ? .header : .button
        case .item(let subtitle, let focused, let status):
            content.secondaryText = subtitle?.isEmpty == false ? subtitle : nil
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.font = Self.font(focused: focused)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.accessories = accessories(for: status, cell: cell)
            cell.accessibilityIdentifier = "\(prefix).item"
            cell.accessibilityTraits = row.focus == nil ? [] : .button
            cell.accessibilityValue = [status.label, focused ? "Focused" : nil].compactMap { $0 }.joined(separator: ", ")
            cell.indentationLevel = 1
        }
        cell.contentConfiguration = content
    }

    /// The same mark and label as the status glyph and session rows. A row the
    /// multiplexer has no reading for draws neither, but keeps the mark's slot
    /// so its name lines up with its siblings'; one it reads in a way Oppi
    /// does not know says Unknown.
    private func accessories(for status: SSHTerminalOverviewRow.Status, cell: SSHTerminalOverviewCell) -> [UICellAccessory] {
        let kind: SessionStatusKind? = if case .known(let known) = status { known } else { nil }
        cell.mark.isHidden = kind == nil
        if let kind {
            cell.mark.apply(status: kind, themeID: themeID, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }
        let mark = UICellAccessory.customView(configuration: .init(
            customView: cell.mark, placement: .leading(), reservedLayoutWidth: .custom(20)
        ))
        guard let label = status.label else { return [mark] }
        return [
            mark,
            .label(text: label, options: .init(
                tintColor: kind?.tint(themeID.appTheme) ?? UIColor(themeID.palette.comment),
                font: .preferredFont(forTextStyle: .caption1)
            )),
        ]
    }

    /// The multiplexer's focused workspace and pane read bold: focus is where
    /// an attached client looks, not a status.
    private static func font(focused: Bool) -> UIFont {
        let body = UIFont.preferredFont(forTextStyle: .body)
        guard focused, let bold = body.fontDescriptor.withSymbolicTraits(.traitBold) else { return body }
        return UIFont(descriptor: bold, size: 0)
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<String, SSHTerminalOverviewRow>()
        if let failure = source.focusFailure {
            snapshot.appendSections(["focus-failure"])
            snapshot.appendItems([.init(id: "focus-failure", title: failure, kind: .failure, focus: nil)], toSection: "focus-failure")
        }
        for section in source.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows, toSection: section.id)
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    /// Only rows with something to focus react to a tap.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource?.itemIdentifier(for: indexPath)?.focus != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let focus = dataSource?.itemIdentifier(for: indexPath)?.focus else { return }
        Task {
            let focused = await source.activate(focus, on: channel)
            if focused, isVisible { Router.finish(self) } else { applySnapshot() }
        }
    }
}

extension SSHTerminalOverviewRow.Status {
    /// What the row's trailing label and VoiceOver say; nil says nothing.
    var label: String? {
        switch self {
        case .none: nil
        case .unknown: "Unknown"
        case .known(let kind): kind.label
        }
    }
}

/// An overview row that keeps its own status mark, so a working agent's
/// animation survives reconfiguration instead of restarting on a new view.
final class SSHTerminalOverviewCell: UICollectionViewListCell {
    let mark = SSHTerminalStatusMarkView(style: .row)
}
