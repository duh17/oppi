import UIKit

/// Settings > Editor: keybindings, display, indentation, typing, and the
/// keyboard bar. Values are `CodeEditorPreferences.shared`, which an open
/// editor observes, so changes apply without reopening the file. Everything
/// here is saved on this device.
final class SettingsEditorViewController: SettingsListViewController<SettingsEditorViewController.Section, SettingsEditorViewController.Item> {
    enum Section: Hashable, Sendable { case keyboard, display, indentation, typing }
    enum Item: Hashable, Sendable {
        case keybindings, keyBar, customizeKeyBar
        case syntax, lineNumbers, currentLine, wrapText, wrapCode
        case detectIndentation, indentWith, tabWidth
        case closeBrackets
    }

    private let preferences: CodeEditorPreferences

    init(preferences: CodeEditorPreferences = .shared) {
        self.preferences = preferences
        super.init(
            title: String(localized: "Editor"),
            listIdentifier: "settings.editor.list",
            scope: .device,
            headers: true,
            footers: true
        )
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        // Read every value so any change re-runs this pass.
        _ = (preferences.keybindings, preferences.showsKeyBar, preferences.keyBarKeys, preferences.highlightsSyntax)
        _ = (preferences.showsLineNumbers, preferences.highlightsCurrentLine, preferences.wrapsText, preferences.wrapsCode)
        _ = (preferences.detectsIndentation, preferences.indentsWithTabs, preferences.tabWidth, preferences.closesBrackets)
        return [
            SettingsSectionModel(
                .keyboard,
                header: String(localized: "Keyboard"),
                footer: String(localized: "Vim starts in Normal mode: type commands, press i to insert, and Esc (or the esc key in the bar) to go back. ⌘ shortcuts work in both. Hold ⌘ on a hardware keyboard to see them."),
                items: [.keybindings, .keyBar] + (preferences.showsKeyBar ? [.customizeKeyBar] : [])
            ),
            SettingsSectionModel(
                .display,
                header: String(localized: "Display"),
                footer: String(localized: "The editor uses your code font and size from Text."),
                items: [.syntax, .lineNumbers, .currentLine, .wrapText, .wrapCode]
            ),
            SettingsSectionModel(
                .indentation,
                header: String(localized: "Indentation"),
                footer: String(localized: "With Detect From File, Tab and Return follow the tabs or spaces the file already uses."),
                items: [.detectIndentation, .indentWith, .tabWidth]
            ),
            SettingsSectionModel(
                .typing,
                header: String(localized: "Typing"),
                footer: String(localized: "Typing an opening bracket or quote adds its closer, and Backspace removes an empty pair."),
                items: [.closeBrackets]
            ),
        ]
    }

    /// The preference values a row is drawn from.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .keybindings: AnyHashable(preferences.keybindings)
        case .keyBar: AnyHashable(preferences.showsKeyBar)
        case .customizeKeyBar: AnyHashable(preferences.keyBarKeys.count)
        case .syntax: AnyHashable(preferences.highlightsSyntax)
        case .lineNumbers: AnyHashable(preferences.showsLineNumbers)
        case .currentLine: AnyHashable(preferences.highlightsCurrentLine)
        case .wrapText: AnyHashable(preferences.wrapsText)
        case .wrapCode: AnyHashable(preferences.wrapsCode)
        case .detectIndentation: AnyHashable(preferences.detectsIndentation)
        case .indentWith: AnyHashable(preferences.indentsWithTabs)
        case .tabWidth: AnyHashable(preferences.tabWidth)
        case .closeBrackets: AnyHashable(preferences.closesBrackets)
        }
    }

    // MARK: - Cells

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .keybindings:
            cell.configure(
                title: String(localized: "Keybindings"),
                identifier: "settings.editor.keybindings.menu",
                options: CodeEditorKeybindings.allCases.map { keybindings in
                    (keybindings.label, keybindings == preferences.keybindings, { [weak self] in self?.preferences.keybindings = keybindings })
                }
            )
        case .indentWith:
            cell.configure(
                title: String(localized: "Indent With"),
                identifier: "settings.editor.indentWith.menu",
                options: [
                    (String(localized: "Spaces"), !preferences.indentsWithTabs, { [weak self] in self?.preferences.indentsWithTabs = false }),
                    (String(localized: "Tabs"), preferences.indentsWithTabs, { [weak self] in self?.preferences.indentsWithTabs = true }),
                ]
            )
        default:
            cell.configure(
                title: String(localized: "Tab Width"),
                identifier: "settings.editor.tabWidth.menu",
                options: CodeEditorPreferences.tabWidths.map { width in
                    (String(width), width == preferences.tabWidth, { [weak self] in self?.preferences.tabWidth = width })
                }
            )
        }
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "Customize Keys"),
            systemImage: nil,
            value: String(localized: "\(preferences.keyBarKeys.count) keys"),
            identifier: "settings.editor.keyBar.customize"
        ) { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(SettingsEditorKeyBarViewController(preferences: preferences), animated: true)
        }
    }

    override func prepareRegistrations() {
        _ = (menuRow, indexRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .keybindings, .indentWith, .tabWidth:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .customizeKeyBar:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        default:
            super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        cell.accessibilityIdentifier = "settings.editor.\(item)"
        switch item {
        case .keyBar:
            toggleRow(cell, title: String(localized: "Keyboard Bar"), isOn: preferences.showsKeyBar) { [weak self] in self?.preferences.showsKeyBar = $0 }
        case .syntax:
            toggleRow(cell, title: String(localized: "Syntax Highlighting"), isOn: preferences.highlightsSyntax) { [weak self] in self?.preferences.highlightsSyntax = $0 }
        case .lineNumbers:
            toggleRow(cell, title: String(localized: "Line Numbers"), isOn: preferences.showsLineNumbers) { [weak self] in self?.preferences.showsLineNumbers = $0 }
        case .currentLine:
            toggleRow(cell, title: String(localized: "Highlight Current Line"), isOn: preferences.highlightsCurrentLine) { [weak self] in self?.preferences.highlightsCurrentLine = $0 }
        case .wrapText, .wrapCode:
            let kind: CodeEditorWrapKind = item == .wrapText ? .text : .code
            let title = kind == .text ? String(localized: "Wrap Markdown and Text") : String(localized: "Wrap Code")
            toggleRow(cell, title: title, isOn: preferences.wrapsLines(for: kind)) { [weak self] in self?.preferences.setWrapsLines($0, for: kind) }
        case .detectIndentation:
            toggleRow(cell, title: String(localized: "Detect From File"), isOn: preferences.detectsIndentation) { [weak self] in self?.preferences.detectsIndentation = $0 }
        case .closeBrackets:
            toggleRow(cell, title: String(localized: "Close Brackets and Quotes"), isOn: preferences.closesBrackets) { [weak self] in self?.preferences.closesBrackets = $0 }
        case .keybindings, .customizeKeyBar, .indentWith, .tabWidth:
            break
        }
    }
}

/// Choose and order the keyboard bar's keys. Shown keys reorder with their
/// handles and leave with the remove control; More Keys adds one.
final class SettingsEditorKeyBarViewController: SettingsListViewController<SettingsEditorKeyBarViewController.Section, String> {
    enum Section: Hashable, Sendable { case shown, more }

    private let preferences: CodeEditorPreferences

    init(preferences: CodeEditorPreferences) {
        self.preferences = preferences
        super.init(
            title: String(localized: "Keyboard Bar"),
            listIdentifier: "settings.editor.keyBar.list",
            scope: .device,
            headers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.isEditing = true
        let reset = UIBarButtonItem(title: String(localized: "Reset"), primaryAction: UIAction { [weak self] _ in
            self?.preferences.resetKeyBar()
        })
        reset.accessibilityIdentifier = "settings.editor.keyBar.reset"
        navigationItem.rightBarButtonItem = reset
        dataSource?.reorderingHandlers.canReorderItem = { [weak self] id in
            self?.preferences.keyBarKeys.contains { $0.id == id } ?? false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.preferences.keyBarKeys = transaction.finalSnapshot.itemIdentifiers(inSection: .shown).compactMap(CodeEditorBarKey.init(id:))
        }
    }

    override func sections() -> [SettingsSectionModel<Section, String>] {
        let shown = preferences.keyBarKeys
        return [
            SettingsSectionModel(.shown, header: String(localized: "In the Bar"), items: shown.map(\.id)),
            SettingsSectionModel(
                .more,
                header: String(localized: "More Keys"),
                items: CodeEditorBarKey.catalog.filter { !shown.contains($0) }.map(\.id)
            ),
        ]
    }

    /// Whether the key is in the bar decides its accessories.
    override func inputs(of id: String) -> AnyHashable {
        AnyHashable(preferences.keyBarKeys.contains { $0.id == id })
    }

    override func configure(_ cell: UICollectionViewListCell, item id: String) {
        guard let key = CodeEditorBarKey(id: id) else { return }
        var content = content(.plain)
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
        let shown = preferences.keyBarKeys.contains(key)
        cell.accessories = shown
            ? [.delete(displayed: .always) { [weak self] in self?.remove(key) }, .reorder(displayed: .always)]
            : [.insert(displayed: .always) { [weak self] in self?.add(key) }]
    }

    private func remove(_ key: CodeEditorBarKey) {
        preferences.keyBarKeys.removeAll { $0 == key }
    }

    private func add(_ key: CodeEditorBarKey) {
        guard !preferences.keyBarKeys.contains(key) else { return }
        preferences.keyBarKeys.append(key)
    }
}
