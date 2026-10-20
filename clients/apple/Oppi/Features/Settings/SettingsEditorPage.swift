import UIKit

/// Settings > Editor: keybindings, display, indentation, typing, and the
/// keyboard bar. Values are `CodeEditorPreferences.shared`, which an open
/// editor observes, so changes apply without reopening the file.
final class SettingsEditorViewController: UIViewController, UICollectionViewDelegate {
    private let preferences: CodeEditorPreferences
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()

    private enum Section: Hashable { case keyboard, display, indentation, typing }
    private enum Item: Hashable {
        case keybindings, keyBar, customizeKeyBar
        case syntax, lineNumbers, currentLine, wrap
        case detectIndentation, indentWith, tabWidth
        case closeBrackets
    }

    init(preferences: CodeEditorPreferences = .shared) {
        self.preferences = preferences
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Editor")
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "settings.editor.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Read every value so any change re-runs this pass.
        _ = (preferences.keybindings, preferences.showsKeyBar, preferences.keyBarKeys, preferences.highlightsSyntax)
        _ = (preferences.showsLineNumbers, preferences.highlightsCurrentLine, preferences.wrapsLines)
        _ = (preferences.detectsIndentation, preferences.indentsWithTabs, preferences.tabWidth, preferences.closesBrackets)
        applySnapshot()
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.keyboard, .display, .indentation, .typing])
        snapshot.appendItems([.keybindings, .keyBar] + (preferences.showsKeyBar ? [.customizeKeyBar] : []), toSection: .keyboard)
        snapshot.appendItems([.syntax, .lineNumbers, .currentLine, .wrap], toSection: .display)
        snapshot.appendItems([.detectIndentation, .indentWith, .tabWidth], toSection: .indentation)
        snapshot.appendItems([.closeBrackets], toSection: .typing)
        let themeID = ThemeRuntimeState.currentThemeID()
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
    }

    /// The preference values a row is drawn from.
    private func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .keybindings: AnyHashable(preferences.keybindings)
        case .keyBar: AnyHashable(preferences.showsKeyBar)
        case .customizeKeyBar: AnyHashable(preferences.keyBarKeys.count)
        case .syntax: AnyHashable(preferences.highlightsSyntax)
        case .lineNumbers: AnyHashable(preferences.showsLineNumbers)
        case .currentLine: AnyHashable(preferences.highlightsCurrentLine)
        case .wrap: AnyHashable(preferences.wrapsLines)
        case .detectIndentation: AnyHashable(preferences.detectsIndentation)
        case .indentWith: AnyHashable(preferences.indentsWithTabs)
        case .tabWidth: AnyHashable(preferences.tabWidth)
        case .closeBrackets: AnyHashable(preferences.closesBrackets)
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.section(at: indexPath).map(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.section(at: indexPath).flatMap(Self.footer)
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func section(at indexPath: IndexPath) -> Section? {
        dataSource?.sectionIdentifier(for: indexPath.section)
    }

    private static func header(_ section: Section) -> String {
        switch section {
        case .keyboard: String(localized: "Keyboard")
        case .display: String(localized: "Display")
        case .indentation: String(localized: "Indentation")
        case .typing: String(localized: "Typing")
        }
    }

    private static func footer(_ section: Section) -> String? {
        switch section {
        case .keyboard:
            String(localized: "Vim starts in Normal mode: type commands, press i to insert, and Esc (or the esc key in the bar) to go back. ⌘ shortcuts work in both. Hold ⌘ on a hardware keyboard to see them.")
        case .display:
            String(localized: "The editor uses your code font and size from Text.")
        case .indentation:
            String(localized: "With Detect From File, Tab and Return follow the tabs or spaces the file already uses.")
        case .typing:
            String(localized: "Typing an opening bracket or quote adds its closer, and Backspace removes an empty pair.")
        }
    }

    // MARK: - Cells

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        cell.accessories = []
        cell.accessibilityIdentifier = "settings.editor.\(item)"
        switch item {
        case .keybindings:
            content.text = String(localized: "Keybindings")
            cell.accessories = [.settingsPopUpMenu(
                identifier: "settings.editor.keybindings.menu",
                options: CodeEditorKeybindings.allCases.map { keybindings in
                    (keybindings.label, keybindings == preferences.keybindings, { [weak self] in self?.preferences.keybindings = keybindings })
                }
            )]
        case .keyBar:
            content.text = String(localized: "Keyboard Bar")
            cell.accessories = [.settingsToggle(preferences.showsKeyBar) { [weak self] in self?.preferences.showsKeyBar = $0 }]
        case .customizeKeyBar:
            content.text = String(localized: "Customize Keys")
            content.secondaryText = String(localized: "\(preferences.keyBarKeys.count) keys")
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "settings.editor.keyBar.customize"
            cell.accessibilityTraits.insert(.button)
        case .syntax:
            content.text = String(localized: "Syntax Highlighting")
            cell.accessories = [.settingsToggle(preferences.highlightsSyntax) { [weak self] in self?.preferences.highlightsSyntax = $0 }]
        case .lineNumbers:
            content.text = String(localized: "Line Numbers")
            cell.accessories = [.settingsToggle(preferences.showsLineNumbers) { [weak self] in self?.preferences.showsLineNumbers = $0 }]
        case .currentLine:
            content.text = String(localized: "Highlight Current Line")
            cell.accessories = [.settingsToggle(preferences.highlightsCurrentLine) { [weak self] in self?.preferences.highlightsCurrentLine = $0 }]
        case .wrap:
            content.text = String(localized: "Wrap Lines")
            cell.accessories = [.settingsToggle(preferences.wrapsLines) { [weak self] in self?.preferences.wrapsLines = $0 }]
        case .detectIndentation:
            content.text = String(localized: "Detect From File")
            cell.accessories = [.settingsToggle(preferences.detectsIndentation) { [weak self] in self?.preferences.detectsIndentation = $0 }]
        case .indentWith:
            content.text = String(localized: "Indent With")
            cell.accessories = [.settingsPopUpMenu(
                identifier: "settings.editor.indentWith.menu",
                options: [
                    (String(localized: "Spaces"), !preferences.indentsWithTabs, { [weak self] in self?.preferences.indentsWithTabs = false }),
                    (String(localized: "Tabs"), preferences.indentsWithTabs, { [weak self] in self?.preferences.indentsWithTabs = true }),
                ]
            )]
        case .tabWidth:
            content.text = String(localized: "Tab Width")
            cell.accessories = [.settingsPopUpMenu(
                identifier: "settings.editor.tabWidth.menu",
                options: CodeEditorPreferences.tabWidths.map { width in
                    (String(width), width == preferences.tabWidth, { [weak self] in self?.preferences.tabWidth = width })
                }
            )]
        case .closeBrackets:
            content.text = String(localized: "Close Brackets and Quotes")
            cell.accessories = [.settingsToggle(preferences.closesBrackets) { [weak self] in self?.preferences.closesBrackets = $0 }]
        }
        cell.contentConfiguration = content
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource?.itemIdentifier(for: indexPath) == .customizeKeyBar
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource?.itemIdentifier(for: indexPath) == .customizeKeyBar else { return }
        navigationController?.pushViewController(SettingsEditorKeyBarViewController(preferences: preferences), animated: true)
    }
}

/// Choose and order the keyboard bar's keys. Shown keys reorder with their
/// handles and leave with the remove control; More Keys adds one.
final class SettingsEditorKeyBarViewController: UIViewController, UICollectionViewDelegate {
    private let preferences: CodeEditorPreferences
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>?
    private var appliedThemeID: ThemeID?

    private enum Section: Hashable { case shown, more }

    init(preferences: CodeEditorPreferences) {
        self.preferences = preferences
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Keyboard Bar")
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.isEditing = true
        collectionView.accessibilityIdentifier = "settings.editor.keyBar.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        let reset = UIBarButtonItem(title: String(localized: "Reset"), primaryAction: UIAction { [weak self] _ in
            self?.preferences.resetKeyBar()
        })
        reset.accessibilityIdentifier = "settings.editor.keyBar.reset"
        navigationItem.rightBarButtonItem = reset
        installDataSource()
        setNeedsUpdateProperties()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        applySnapshot(preferences.keyBarKeys)
    }

    private func applySnapshot(_ shown: [CodeEditorBarKey]) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.shown, .more])
        snapshot.appendItems(shown.map(\.id), toSection: .shown)
        snapshot.appendItems(CodeEditorBarKey.catalog.filter { !shown.contains($0) }.map(\.id), toSection: .more)
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, id in
            guard let self, let key = CodeEditorBarKey(id: id) else { return }
            var content = cell.defaultContentConfiguration()
            content.text = key.label
            if let systemImage = key.systemImage {
                content.image = UIImage(systemName: systemImage)
            } else if case .symbol = key {
                content.text = key.title
            } else {
                content.secondaryText = key.title
            }
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "settings.editor.keyBar.\(id)"
            let shown = self.dataSource?.sectionIdentifier(for: indexPath.section) == .shown
            cell.accessories = shown
                ? [.delete(displayed: .always) { [weak self] in self?.remove(key) }, .reorder(displayed: .always)]
                : [.insert(displayed: .always) { [weak self] in self?.add(key) }]
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .shown
                ? String(localized: "In the Bar")
                : String(localized: "More Keys")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        dataSource?.reorderingHandlers.canReorderItem = { [weak self] id in
            self?.preferences.keyBarKeys.contains { $0.id == id } ?? false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.preferences.keyBarKeys = transaction.finalSnapshot.itemIdentifiers(inSection: .shown).compactMap(CodeEditorBarKey.init(id:))
        }
    }

    /// Keys reorder only within the bar's section.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section != originalIndexPath.section else { return proposedIndexPath }
        let count = collectionView.numberOfItems(inSection: originalIndexPath.section)
        return IndexPath(item: max(0, count - 1), section: originalIndexPath.section)
    }

    private func remove(_ key: CodeEditorBarKey) {
        preferences.keyBarKeys.removeAll { $0 == key }
    }

    private func add(_ key: CodeEditorBarKey) {
        guard !preferences.keyBarKeys.contains(key) else { return }
        preferences.keyBarKeys.append(key)
    }
}
