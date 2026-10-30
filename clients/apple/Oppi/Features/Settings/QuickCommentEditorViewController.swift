import UIKit

/// The form for creating or editing one quick comment: a title, an icon, and the
/// text the comment composer gets. A draft: Save (enabled once the title and the
/// text are not blank) hands the trimmed template to `onSave` and closes the
/// sheet; Cancel closes it. A new template's preview shows "Untitled" and
/// "Comment text required" until they are filled in.
@MainActor
final class QuickCommentEditorViewController: ListScreenController<QuickCommentEditorViewController.Section, QuickCommentEditorViewController.Item> {
    enum Section: Hashable, Sendable { case basics, text, preview }
    enum Item: Hashable, Sendable { case title, icon, text, preview }

    private let templateId: UUID
    private let sortOrder: Int
    private let isNew: Bool
    private let onSave: (QuickCommentTemplate) -> Void
    private(set) var draftTitle: String
    private(set) var draftSymbol: String
    private(set) var draftText: String
    private var saveItem: UIBarButtonItem?

    init(template: QuickCommentTemplate, isNew: Bool, onSave: @escaping (QuickCommentTemplate) -> Void) {
        templateId = template.id
        sortOrder = template.sortOrder
        self.isNew = isNew
        self.onSave = onSave
        draftTitle = template.title
        draftSymbol = template.systemImage
        draftText = template.promptPrefix
        super.init(
            title: isNew ? String(localized: "New Quick Comment") : String(localized: "Edit Quick Comment"),
            listIdentifier: "settings.quickComments.editor.list",
            scope: .device,
            headers: true,
            footers: true,
            dismissesKeyboardOnDrag: true
        )
    }

    /// Both fields hold something other than whitespace.
    var canSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cancel = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        cancel.accessibilityIdentifier = "settings.quickComments.editor.cancel"
        navigationItem.leftBarButtonItem = cancel
        let save = UIBarButtonItem(title: String(localized: "Save"), primaryAction: UIAction { [weak self] _ in
            self?.save()
        })
        save.style = .prominent
        save.accessibilityLabel = String(localized: "Save")
        save.accessibilityIdentifier = "settings.quickComments.editor.save"
        navigationItem.rightBarButtonItem = save
        saveItem = save
    }

    override func updateProperties() {
        super.updateProperties()
        saveItem?.isEnabled = canSave
    }

    /// The template as saved: trimmed title and text.
    func finishedTemplate() -> QuickCommentTemplate {
        QuickCommentTemplate(
            id: templateId,
            title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            systemImage: draftSymbol,
            promptPrefix: draftText.trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: sortOrder
        )
    }

    func save() {
        guard canSave else { return }
        onSave(finishedTemplate())
        Router.finish(self)
    }

    func setTitle(_ title: String) {
        draftTitle = title
        setNeedsUpdateProperties()
    }

    func setText(_ text: String) {
        draftText = text
        setNeedsUpdateProperties()
    }

    func setSymbol(_ symbol: String) {
        draftSymbol = symbol
        setNeedsUpdateProperties()
    }

    // MARK: - Sections

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.basics, header: String(localized: "Basics"), items: [.title, .icon]),
            ListSection(
                .text,
                header: String(localized: "Inserted Text"),
                footer: String(localized: "Inserted into the comment composer when you tap the quick comment."),
                items: [.text]
            ),
            ListSection(.preview, header: String(localized: "Preview"), items: [.preview]),
        ]
    }

    /// Field rows keep what the person is typing; only the icon and preview
    /// follow the draft.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .title, .text: AnyHashable(0)
        case .icon: AnyHashable(draftSymbol)
        case .preview: AnyHashable([draftTitle, draftSymbol, draftText])
        }
    }

    // MARK: - Cells

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        let style = SettingsStyle.current
        if item == .title {
            cell.configure(
                text: draftTitle,
                placeholder: String(localized: "Title"),
                identifier: "quickComments.editor.title",
                autocapitalization: .words,
                autocorrection: .default,
                textColor: style.title,
                onChange: { [weak self] in self?.setTitle($0) }
            )
        } else {
            cell.configure(
                text: draftText,
                placeholder: String(localized: "Comment text (e.g. \"Fix this.\")"),
                identifier: "quickComments.editor.text",
                autocapitalization: .sentences,
                autocorrection: .default,
                textColor: style.title,
                onChange: { [weak self] in self?.setText($0) }
            )
        }
    }

    override func prepareRegistrations() {
        _ = fieldRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .title, .text: collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .icon, .preview: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        let style = SettingsStyle.current
        switch item {
        case .icon:
            var content = content(.plain)
            content.text = String(localized: "Icon")
            cell.contentConfiguration = content
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: draftSymbol)
            config.baseForegroundColor = style.accent
            config.background.backgroundColor = style.value.withAlphaComponent(0.1)
            config.background.cornerRadius = 8
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            button.configuration = config
            button.accessibilityIdentifier = "quickComments.editor.symbolPicker"
            button.accessibilityLabel = String(localized: "Icon")
            button.accessibilityValue = QuickCommentSymbols.label(for: draftSymbol)
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                presentSymbolPicker(from: button)
            }, for: .touchUpInside)
            cell.accessories = [.customView(configuration: .init(customView: button, placement: .trailing()))]
        case .preview:
            var content = content(.subtitle)
            content.image = UIImage(systemName: draftSymbol)
            content.imageProperties.tintColor = style.accent
            content.text = draftTitle.isEmpty ? String(localized: "Untitled") : draftTitle
            content.textProperties.color = draftTitle.isEmpty ? style.value : style.title
            content.secondaryText = draftText.isEmpty ? String(localized: "Comment text required") : draftText
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
        case .title, .text:
            break
        }
    }

    private func presentSymbolPicker(from button: UIButton) {
        view.endEditing(true)
        let picker = QuickCommentSymbolPickerViewController(selected: draftSymbol) { [weak self] symbol in
            self?.setSymbol(symbol)
        }
        Router.present(
            picker,
            presentation: .popover.keepsPopoverInCompactWidth(),
            from: self,
            sourceView: button
        )
    }
}

/// The icons a quick comment can take: common coding and review marks, each with
/// the word the picker shows under it.
enum QuickCommentSymbols {
    static let all: [(symbol: String, label: String)] = [
        ("questionmark.bubble", "Explain"),
        ("play.circle", "Do"),
        ("wrench.and.screwdriver", "Fix"),
        ("arrow.triangle.branch", "Branch"),
        ("plus.bubble", "Add"),
        ("plus.message", "New"),
        ("sparkles", "Sparkle"),
        ("lightbulb", "Idea"),
        ("magnifyingglass", "Search"),
        ("doc.text", "Doc"),
        ("terminal", "Terminal"),
        ("checkmark.shield", "Check"),
        ("arrow.2.squarepath", "Convert"),
        ("text.badge.checkmark", "Review"),
        ("pencil.and.outline", "Edit"),
        ("scissors", "Cut"),
        ("eye", "View"),
        ("bolt", "Quick"),
        ("hammer", "Build"),
        ("ant", "Debug"),
    ]

    static func label(for symbol: String) -> String? {
        all.first { $0.symbol == symbol }?.label
    }
}

/// The icon popover: a grid of the icons with their words, the chosen one
/// marked. Picking one reports it and closes the popover. At accessibility text
/// sizes the grid is two icons wide, so no word is cut off.
final class QuickCommentSymbolPickerViewController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private let selected: String
    private let onPick: (String) -> Void
    private let scrollView = UIScrollView()
    private let grid = UIStackView()

    init(selected: String, onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let style = SettingsStyle.current
        view.backgroundColor = style.page
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        grid.axis = .vertical
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(grid)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            grid.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -24),
        ])
        buildGrid()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.buildGrid()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fitted = grid.systemLayoutSizeFitting(
            CGSize(width: 276, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let size = CGSize(width: 300, height: min(fitted.height + 24, 520))
        if preferredContentSize != size { preferredContentSize = size }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    private var columns: Int {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 4
    }

    private func buildGrid() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let columns = columns
        for start in stride(from: 0, to: QuickCommentSymbols.all.count, by: columns) {
            let row = UIStackView(arrangedSubviews: QuickCommentSymbols.all[start..<min(start + columns, QuickCommentSymbols.all.count)].map(button))
            row.distribution = .fillEqually
            row.spacing = 8
            // A short last row keeps the columns of the rows above it.
            for _ in row.arrangedSubviews.count..<columns { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
        }
    }

    private func button(_ entry: (symbol: String, label: String)) -> UIButton {
        let style = SettingsStyle.current
        let isSelected = entry.symbol == selected
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: entry.symbol)
        config.title = entry.label
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = isSelected ? style.accent : style.title
        config.background.backgroundColor = isSelected ? style.accent.withAlphaComponent(0.15) : .clear
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption2)
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = entry.label
        button.accessibilityValue = isSelected ? String(localized: "Selected") : nil
        button.accessibilityIdentifier = "quickComments.editor.symbol.\(entry.symbol)"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onPick(entry.symbol)
            dismiss(animated: true)
        }, for: .touchUpInside)
        return button
    }
}
