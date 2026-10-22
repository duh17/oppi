import UIKit

/// One extension loaded in the session, from the Context panel: where it lives, the
/// tools it adds to this session with their sizes, and ways to read or change it.
/// The panel owns the hosted pages it opens, so this screen reports actions back.
final class SessionExtensionContextViewController: UIViewController, UICollectionViewDelegate {
    private let resource: SessionResourceSnapshot
    private let tools: [ContextToolSnapshot]
    private let isHostSession: Bool
    private let openHostFile: (String) -> Void
    private let editWithOppi: () -> Void

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var themeID: ThemeID?

    private enum Section: Int, Hashable {
        case summary, actions, tools
    }

    private enum Item: Hashable {
        case path
        case viewSource
        case edit
        case tool(String)
        case noTools
    }

    init(
        resource: SessionResourceSnapshot,
        tools: [ContextToolSnapshot],
        isHostSession: Bool,
        openHostFile: @escaping (String) -> Void,
        editWithOppi: @escaping () -> Void
    ) {
        self.resource = resource
        self.tools = tools.sorted { lhs, rhs in
            if lhs.inContext != rhs.inContext { return lhs.inContext }
            return lhs.tokens > rhs.tokens
        }
        self.isHostSession = isHostSession
        self.openHostFile = openHostFile
        self.editWithOppi = editWithOppi
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        config.headerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The extension's file on the host, when a host session loaded it from one: not a
    /// built-in or inline extension, and not a sandbox session. Reading and editing it
    /// both act on the host, so one check gates both.
    private var hostFilePath: String? {
        let path = resource.path
        guard isHostSession, path.hasPrefix("/"),
              ContextInspectorViewController.isHostReadablePath(path) else { return nil }
        return path
    }

    private var palette: ThemePalette {
        (themeID ?? ThemeRuntimeState.currentThemeID()).palette
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = resource.name
        navigationItem.largeTitleDisplayMode = .never
        // Set before the push configures the bar; `updateProperties` follows theme changes.
        overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "chat.context.extensionDetail"
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
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.header()
            content.text = headerTitle(Section(rawValue: indexPath.section))
            content.textProperties.color = UIColor(palette.comment)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary])
        snapshot.appendItems([.path], toSection: .summary)
        if hostFilePath != nil {
            snapshot.appendSections([.actions])
            snapshot.appendItems([.viewSource, .edit], toSection: .actions)
        }
        snapshot.appendSections([.tools])
        // A diffable list traps on a repeated item; a repeated tool name shows once.
        var seenTools = Set<String>()
        let toolItems = tools.filter { seenTools.insert($0.name).inserted }.map { Item.tool($0.name) }
        snapshot.appendItems(tools.isEmpty ? [.noTools] : toolItems, toSection: .tools)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        let current = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        guard current != themeID else { return }
        themeID = current
        // System cards follow the trait; match it to the palette's scheme.
        overrideUserInterfaceStyle = current.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(palette.bg)
        collectionView.backgroundColor = UIColor(palette.bg)
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func headerTitle(_ section: Section?) -> String? {
        switch section {
        case .summary: "Loaded from"
        case .actions: nil
        case .tools:
            tools.isEmpty
                ? "Tools in this session"
                : "Tools in this session · \(ContextInspectorViewController.toolCountDetail(tools))"
        case nil: nil
        }
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = palette
        cell.accessories = []
        switch item {
        case .path:
            var content = UIListContentConfiguration.cell()
            content.text = resource.path.isEmpty
                ? "Provided by the session runtime"
                : ContextInspectorViewController.displayPath(resource.path)
            content.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
            content.textProperties.color = UIColor(palette.fg)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        case .viewSource:
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "doc.text")
            content.text = "View Source"
            content.textProperties.color = UIColor(palette.fg)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "chat.context.extension.viewSource"
        case .edit:
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "text.bubble")
            content.text = "Edit with Oppi"
            content.secondaryText = "Starts a new session that changes this extension."
            content.textProperties.color = UIColor(palette.blue)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "chat.context.extension.edit"
        case .tool(let name):
            guard let tool = tools.first(where: { $0.name == name }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = tool.name
            content.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = tool.inContext ? "In context" : "On demand"
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
            cell.accessories = [.label(
                text: SessionFormatting.tokenCount(tool.tokens),
                options: .init(tintColor: UIColor(palette.comment))
            )]
        case .noTools:
            var content = UIListContentConfiguration.cell()
            content.text = "Adds no tools to this session."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .viewSource, .edit: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .viewSource:
            if let hostFilePath { openHostFile(hostFilePath) }
        case .edit:
            editWithOppi()
        default:
            break
        }
    }
}
