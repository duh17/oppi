import UIKit

enum SessionFileOpenMode: Equatable {
    case review
    case sessionTouched
}

enum SessionFileOpenRouting {
    static func mode(path _: String, gitFile: GitFileStatus?) -> SessionFileOpenMode {
        gitFile == nil ? .sessionTouched : .review
    }
}

/// The Files panel's Changed tab: the files the session created or edited,
/// grouped by folder (collapsible), with Git's line counts. A search filters
/// with `FuzzyMatch` and highlights the matched characters.
///
/// A row pushes its file above the panel through the panel's navigator: a
/// workspace file Git reports changed opens the review (diff and current
/// bytes); any other file the session touched opens its current bytes.
/// The list reads the panel's inputs and the server's Git status in
/// `updateProperties()`; the session's change list loads when it appears.
@MainActor
final class SessionFilesListViewController: UIViewController, UICollectionViewDelegate {
    private let root: AppRootEnvironment
    private let navigator: ScreenNavigator
    private var inputs: ChatFilePanelInputs?
    private var searchText = ""

    private var loadedChangedFiles: [String]?
    private var collapsedDirectories: Set<String> = []
    private var loadTask: Task<Void, Never>?
    private var loadedKey: String?
    private var isOnScreen = false

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<String, String>?
    private let stateView = UIContentUnavailableView(configuration: .empty())
    private var rows: [String: Row] = [:]
    private var headers: [String: Header] = [:]
    private var lastThemeID: ThemeID?
    private var shownQuery: String?

    init(root: AppRootEnvironment, navigator: ScreenNavigator) {
        self.root = root
        self.navigator = navigator
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
    }

    /// The panel's current values and its bar's search text.
    func update(inputs: ChatFilePanelInputs, searchText: String) {
        self.inputs = inputs
        self.searchText = searchText
        setNeedsUpdateProperties()
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        stateView.isHidden = true
        for subview in [collectionView, stateView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: view.topAnchor),
                subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        installDataSource()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        loadedKey = nil
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // SwiftUI `.task(id:)`: the load stops with the view and runs again.
        isOnScreen = false
        loadTask?.cancel()
        loadTask = nil
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = root.themeStore.activeThemeID
        let themeChanged = themeID != lastThemeID
        if themeChanged {
            lastThemeID = themeID
            view.backgroundColor = UIColor(themeID.palette.bg)
            collectionView.backgroundColor = .clear
        }
        guard let inputs, dataSource != nil else { return }
        if isOnScreen {
            startLoadIfNeeded(inputs)
        }
        // Git status drives each row's counts and where it opens.
        let gitFiles = inputs.gitStatusStore.gitStatus?.files ?? []
        apply(inputs: inputs, gitFiles: gitFiles, reconfigureAll: themeChanged)
    }

    // MARK: Data

    private var palette: ThemePalette {
        (lastThemeID ?? root.themeStore.activeThemeID).palette
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startLoadIfNeeded(_ inputs: ChatFilePanelInputs) {
        let key = "\(inputs.workspaceId ?? "")|\(inputs.sessionId)"
        guard key != loadedKey else { return }
        loadedKey = key
        loadTask?.cancel()
        guard let workspaceId = inputs.workspaceId, let api = inputs.apiClient else {
            loadedChangedFiles = nil
            return
        }
        let sessionId = inputs.sessionId
        loadTask = Task { [weak self] in
            do {
                let response = try await api.listSessionChanges(workspaceId: workspaceId, sessionId: sessionId)
                guard !Task.isCancelled else { return }
                self?.loadedChangedFiles = response.files.map(\.path)
            } catch {
                // Keep the live session snapshot as the fallback list.
                guard !Task.isCancelled else { return }
                self?.loadedChangedFiles = nil
            }
            self?.setNeedsUpdateProperties()
        }
    }

    private func apply(inputs: ChatFilePanelInputs, gitFiles: [GitFileStatus], reconfigureAll: Bool) {
        guard let dataSource else { return }
        let files = loadedChangedFiles ?? inputs.changedFiles
        let gitByPath = Dictionary(gitFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let query = query
        let isSearching = !query.isEmpty
        let groups = Self.groups(files: files, query: query)
        let canOpen = inputs.workspaceId != nil

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        var nextRows: [String: Row] = [:]
        var nextHeaders: [String: Header] = [:]
        for group in groups {
            let collapsed = !isSearching && collapsedDirectories.contains(group.directory)
            nextHeaders[group.directory] = Header(
                title: group.title,
                fileCount: group.files.count,
                isCollapsed: collapsed,
                isSearching: isSearching
            )
            snapshot.appendSections([group.directory])
            guard !collapsed else { continue }
            var ids: [String] = []
            for file in group.files where nextRows[file.path] == nil {
                let gitFile = gitByPath[file.path]
                let split = Self.splitPositions(file.matchPositions, in: file.path)
                nextRows[file.path] = Row(
                    path: file.path,
                    fileName: file.path.lastPathComponentForDisplay,
                    parentPath: file.path.parentPathForDisplay?.shortenedPath,
                    filePositions: split.filename,
                    parentPositions: split.parent,
                    addedLines: gitFile?.addedLines,
                    removedLines: gitFile?.removedLines,
                    canOpen: canOpen
                )
                ids.append(file.path)
            }
            snapshot.appendItems(ids, toSection: group.directory)
        }

        if files.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "doc.text")
            configuration.text = String(localized: "No Files")
            configuration.secondaryText = String(localized: "This session hasn't created or edited any files yet.")
            showState(configuration)
        } else if groups.isEmpty {
            var configuration = UIContentUnavailableConfiguration.search()
            configuration.text = String(localized: "No Results for “\(searchText)”")
            showState(configuration)
        } else {
            stateView.isHidden = true
        }

        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter {
            existing.contains($0) && (reconfigureAll || rows[$0] != nextRows[$0])
        }
        let headersChanged = reconfigureAll || headers != nextHeaders
        rows = nextRows
        headers = nextHeaders
        snapshot.reconfigureItems(changed)
        // A folder folds open or shut in place, without motion when Reduce
        // Motion is on.
        let animated = shownQuery == query && view.window != nil && !UIAccessibility.isReduceMotionEnabled
        shownQuery = query
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            if headersChanged { self?.refreshHeaders() }
        }
    }

    private func showState(_ configuration: UIContentUnavailableConfiguration) {
        var configuration = configuration
        configuration.background.backgroundColor = UIColor(palette.bg)
        stateView.configuration = configuration
        stateView.isHidden = false
    }

    /// Folders in path order; while searching, the best match's folder first.
    private static func groups(files: [String], query: String) -> [Group] {
        let display: [DisplayFile] = query.isEmpty
            ? files.map { DisplayFile(path: $0, matchPositions: []) }
            : FuzzyMatch.search(query: query, candidates: files, limit: 100)
                .map { DisplayFile(path: $0.path, matchPositions: $0.positions) }
        guard !display.isEmpty else { return [] }
        var byDirectory: [String: [DisplayFile]] = [:]
        var firstIndex: [String: Int] = [:]
        for (index, file) in display.enumerated() {
            let directory = file.path.parentPathForDisplay?.shortenedPath ?? ""
            byDirectory[directory, default: []].append(file)
            firstIndex[directory] = min(firstIndex[directory] ?? index, index)
        }
        let directories = byDirectory.keys.sorted { lhs, rhs in
            if !query.isEmpty {
                let lhsIndex = firstIndex[lhs] ?? Int.max
                let rhsIndex = firstIndex[rhs] ?? Int.max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            }
            let order = lhs.localizedTreePathCompare(to: rhs)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs < rhs
        }
        return directories.map { directory in
            Group(
                directory: directory,
                title: directory.isEmpty ? String(localized: "Workspace root") : directory,
                files: byDirectory[directory] ?? []
            )
        }
    }

    /// Full-path match positions split into the file name's and the parent
    /// path's (unicode scalar indices); the last "/" belongs to neither.
    private static func splitPositions(_ positions: [Int], in path: String) -> (filename: [Int], parent: [Int]) {
        guard !positions.isEmpty else { return ([], []) }
        let scalars = Array(path.unicodeScalars)
        guard let lastSlash = scalars.lastIndex(of: "/") else { return (positions, []) }
        let filenameStart = lastSlash + 1
        var filename: [Int] = []
        var parent: [Int] = []
        for position in positions {
            if position >= filenameStart {
                filename.append(position - filenameStart)
            } else if position < lastSlash {
                parent.append(position)
            }
        }
        return (filename, parent)
    }

    // MARK: Layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            configuration.headerMode = .supplementary
            // Folders follow each other directly, as the SwiftUI sections did.
            configuration.headerTopPadding = 0
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, path in
            guard let self, let row = rows[path] else { return }
            configure(cell, row: row)
        }
        let dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, path in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: path)
        }
        let header = UICollectionView.SupplementaryRegistration<SessionFileDirectoryHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configure(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
    }

    private func configure(_ view: SessionFileDirectoryHeaderView, at indexPath: IndexPath) {
        guard let directory = dataSource?.sectionIdentifier(for: indexPath.section),
              let header = headers[directory] else { return }
        view.configure(header: header, palette: palette) { [weak self] in
            self?.toggle(directory)
        }
    }

    private func refreshHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? SessionFileDirectoryHeaderView else { continue }
            configure(view, at: indexPath)
        }
    }

    private func toggle(_ directory: String) {
        if collapsedDirectories.contains(directory) {
            collapsedDirectories.remove(directory)
        } else {
            collapsedDirectories.insert(directory)
        }
        shownQuery = query
        setNeedsUpdateProperties()
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        let palette = palette
        let icon = FileIcon.forPath(row.path)
        var content = UIListContentConfiguration.subtitleCell()
        content.image = SessionFileIconTile.image(for: icon, themeID: lastThemeID ?? root.themeStore.activeThemeID)
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        content.imageToTextPadding = 10
        content.attributedText = Self.highlighted(
            row.fileName,
            positions: row.filePositions,
            font: Self.font(.subheadline, .medium),
            color: UIColor(palette.fg),
            highlight: UIColor(palette.yellow)
        )
        content.textProperties.numberOfLines = 1
        if let parentPath = row.parentPath {
            content.secondaryAttributedText = Self.highlighted(
                parentPath,
                positions: row.parentPositions,
                font: UIFont.preferredFont(forTextStyle: .caption2),
                color: UIColor(palette.comment),
                highlight: UIColor(palette.yellow)
            )
        } else {
            content.secondaryAttributedText = nil
        }
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        content.textToSecondaryTextVerticalPadding = 2
        content.directionalLayoutMargins.top = 6
        content.directionalLayoutMargins.bottom = 6
        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = []
        // One accessory for both counts: a cell takes each accessory type once.
        if let counts = Self.lineCounts(added: row.addedLines, removed: row.removedLines, palette: palette) {
            let label = UILabel()
            label.attributedText = counts
            label.isAccessibilityElement = false
            accessories.append(.customView(configuration: .init(
                customView: label,
                placement: .trailing(displayed: .always),
                reservedLayoutWidth: .actual
            )))
        }
        if row.canOpen {
            accessories.append(.disclosureIndicator())
        }
        cell.accessories = accessories

        let page = UIColor(palette.bg)
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listCell().updated(for: state)
            if !state.isHighlighted, !state.isSelected { background.backgroundColor = page }
            cell.backgroundConfiguration = background
        }

        // A row that opens is one button whose label holds its texts, as the
        // SwiftUI row was; one that cannot open reads as its texts.
        let element = cell.contentView
        cell.isAccessibilityElement = false
        if row.canOpen {
            element.isAccessibilityElement = true
            element.accessibilityTraits = .button
            var parts = [row.fileName]
            if let parentPath = row.parentPath { parts.append(parentPath) }
            if let added = row.addedLines, added > 0 { parts.append("+\(added)") }
            if let removed = row.removedLines, removed > 0 { parts.append("-\(removed)") }
            element.accessibilityLabel = parts.joined(separator: ", ")
            cell.accessibilityElements = [element]
        } else {
            element.isAccessibilityElement = false
            element.accessibilityTraits = .none
            element.accessibilityLabel = nil
            cell.accessibilityElements = nil
        }
    }

    /// "+12 -3" in the diff colors; nil when Git reports no changed lines.
    private static func lineCounts(added: Int?, removed: Int?, palette: ThemePalette) -> NSAttributedString? {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .bold)
        let text = NSMutableAttributedString()
        if let added, added > 0 {
            text.append(NSAttributedString(
                string: "+\(added)",
                attributes: [.font: font, .foregroundColor: UIColor(palette.toolDiffAdded)]
            ))
        }
        if let removed, removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            text.append(NSAttributedString(
                string: "-\(removed)",
                attributes: [.font: font, .foregroundColor: UIColor(palette.toolDiffRemoved)]
            ))
        }
        return text.length > 0 ? text : nil
    }

    private static func highlighted(
        _ text: String,
        positions: [Int],
        font: UIFont,
        color: UIColor,
        highlight: UIColor
    ) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard !positions.isEmpty else { return NSAttributedString(string: text, attributes: plain) }
        let bold = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: 0)
        let matched: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: highlight]
        let scalars = Array(text.unicodeScalars)
        let matches = Set(positions)
        let result = NSMutableAttributedString()
        var index = 0
        while index < scalars.count {
            let isMatch = matches.contains(index)
            var end = index
            while end + 1 < scalars.count, matches.contains(end + 1) == isMatch { end += 1 }
            result.append(NSAttributedString(
                string: String(String.UnicodeScalarView(scalars[index...end])),
                attributes: isMatch ? matched : plain
            ))
            index = end + 1
        }
        return result
    }

    private static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        FileBrowserBreadcrumbCell.font(style, weight)
    }

    // MARK: Opening a file

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let path = dataSource?.itemIdentifier(for: indexPath) else { return false }
        return rows[path]?.canOpen == true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let path = dataSource?.itemIdentifier(for: indexPath),
              let inputs, let workspaceId = inputs.workspaceId else { return }
        let gitByPath = Dictionary(
            (inputs.gitStatusStore.gitStatus?.files ?? []).map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Previous and next walk every listed file, collapsed folders too.
        let orderedPaths = Self.groups(files: loadedChangedFiles ?? inputs.changedFiles, query: query)
            .flatMap { $0.files.map(\.path) }
        let scope = SessionFilePages.closingPanelScope(inputs.reviewCommentSelectionScope, closePanel: inputs.closePanel)
        if let gitFile = gitByPath[path], SessionFileOpenRouting.mode(path: path, gitFile: gitFile) == .review {
            SessionFilePages.pushReview(
                Self.reviewDetail(
                    file: gitFile.toReviewFile(),
                    navigationFiles: orderedPaths.compactMap { gitByPath[$0]?.toReviewFile() },
                    workspaceId: workspaceId,
                    inputs: inputs,
                    scope: scope
                ),
                inputs: inputs,
                navigator: navigator
            )
        } else {
            let touched = orderedPaths.filter {
                SessionFileOpenRouting.mode(path: $0, gitFile: gitByPath[$0]) == .sessionTouched
            }
            SessionFilePages.pushSessionTouchedFile(
                workspaceId: workspaceId,
                sessionId: inputs.sessionId,
                path: path,
                navigationContext: FileBrowserNavigationContext(files: touched.map {
                    FileBrowserSelection(path: $0, name: $0.lastPathComponentForDisplay, size: nil)
                }),
                reviewCommentSelectionScope: scope,
                inputs: inputs,
                navigator: navigator
            )
        }
    }
}

extension SessionFilesListViewController {
    /// The review a Git-changed row opens, on the session's checkout and server.
    private static func reviewDetail(
        file: WorkspaceReviewFile,
        navigationFiles: [WorkspaceReviewFile],
        workspaceId: String,
        inputs: ChatFilePanelInputs,
        scope: ReviewCommentSelectionScope?
    ) -> WorkspaceReviewFileDetailViewController.Configuration {
        SessionFilePages.reviewDetail(
            workspaceId: workspaceId,
            sessionId: inputs.sessionId,
            file: file,
            worktreeId: inputs.worktreeId,
            serverId: inputs.serverId,
            reviewCommentSelectionScope: scope,
            navigationFiles: navigationFiles
        )
    }

#if DEBUG
    /// The review a row for `file` opens, as the list builds it.
    func debugReviewDetailForTesting(file: WorkspaceReviewFile) -> WorkspaceReviewFileDetailViewController.Configuration? {
        guard let inputs, let workspaceId = inputs.workspaceId else { return nil }
        return Self.reviewDetail(
            file: file,
            navigationFiles: [file],
            workspaceId: workspaceId,
            inputs: inputs,
            scope: inputs.reviewCommentSelectionScope
        )
    }
#endif
}

private extension SessionFilesListViewController {
    struct DisplayFile {
        let path: String
        let matchPositions: [Int]
    }

    struct Group {
        let directory: String
        let title: String
        let files: [DisplayFile]
    }

    struct Row: Equatable {
        let path: String
        let fileName: String
        let parentPath: String?
        let filePositions: [Int]
        let parentPositions: [Int]
        let addedLines: Int?
        let removedLines: Int?
        let canOpen: Bool
    }
}

extension SessionFilesListViewController {
    struct Header: Equatable {
        let title: String
        let fileCount: Int
        let isCollapsed: Bool
        let isSearching: Bool
    }
}

/// A folder's header in the Changed list. Outside a search it is a button
/// that collapses or expands the folder's files.
final class SessionFileDirectoryHeaderView: UICollectionReusableView {
    private let control = UIControl()
    private let folder = UIImageView(image: UIImage(systemName: "folder.fill"))
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let chevron = UIImageView()
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let caption = FileBrowserBreadcrumbCell.font(.caption1, .semibold)
        folder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: caption)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: caption)
        chevron.contentMode = .center
        titleLabel.font = FileBrowserBreadcrumbCell.font(.caption1, .bold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        for view in [folder, countLabel, chevron] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [folder, titleLabel, UIView(), countLabel, chevron])
        row.axis = .horizontal
        row.spacing = 7
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        control.addSubview(row)
        control.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
            control.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            row.topAnchor.constraint(equalTo: control.topAnchor),
            row.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 18),
        ])
        isAccessibilityElement = false
        accessibilityElements = [control]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(header: SessionFilesListViewController.Header, palette: ThemePalette, onToggle: @escaping () -> Void) {
        self.onToggle = header.isSearching ? nil : onToggle
        backgroundColor = UIColor(palette.bg)
        folder.tintColor = UIColor(palette.blue)
        titleLabel.text = header.title
        titleLabel.textColor = UIColor(palette.fgDim)
        countLabel.text = "\(header.fileCount)"
        countLabel.textColor = UIColor(palette.comment)
        chevron.image = UIImage(systemName: header.isCollapsed ? "chevron.right" : "chevron.down")
        chevron.tintColor = UIColor(palette.comment)
        chevron.isHidden = header.isSearching
        control.isEnabled = !header.isSearching
        let files = header.fileCount == 1 ? "1 file" : "\(header.fileCount) files"
        control.isAccessibilityElement = true
        if header.isSearching {
            control.accessibilityTraits = .staticText
            control.accessibilityLabel = "\(header.title), \(files)"
            control.accessibilityValue = nil
        } else {
            control.accessibilityTraits = .button
            control.accessibilityLabel = header.isCollapsed ? "Expand \(header.title) files" : "Collapse \(header.title) files"
            control.accessibilityValue = "\(header.isCollapsed ? "Collapsed" : "Expanded"), \(files)"
        }
    }
}

/// A file's icon on its tinted rounded tile, drawn once per icon and theme.
@MainActor
enum SessionFileIconTile {
    private static var cache: [String: UIImage] = [:]

    static func image(for icon: FileIcon, themeID: ThemeID) -> UIImage {
        let key = "\(icon.symbolName)|\(icon.assetName ?? "")|\(icon.tint)|\(themeID)"
        if let cached = cache[key] { return cached }
        let tint = UIColor(icon.tint.snapshotColor)
        let glyph = icon.uiImage(pointSize: 13, weight: .semibold)
        let size = CGSize(width: 28, height: 28)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            tint.withAlphaComponent(0.1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7).fill()
            let fitted = icon.isAssetImage ? CGSize(width: 18, height: 18) : glyph.size
            let origin = CGPoint(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
            if icon.isAssetImage {
                glyph.withTintColor(tint, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: origin, size: fitted))
            } else {
                glyph.draw(in: CGRect(origin: origin, size: fitted))
            }
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }
}
