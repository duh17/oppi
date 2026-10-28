import UIKit

/// Settings > Chat > Quick Comments: the ordered templates that appear after
/// selecting text and choosing Comment. Tap a template to edit it in a sheet,
/// Edit to reorder and delete (a swipe deletes too), Add Quick Comment for a new
/// one, and Reset to Defaults (behind a confirmation) for the built-in set.
/// The templates live on this device (`QuickCommentTemplateStore`).
@MainActor
final class QuickCommentsViewController: SettingsListViewController<QuickCommentsViewController.Section, QuickCommentsViewController.Item> {
    enum Section: Hashable, Sendable { case templates, add, reset }
    enum Item: Hashable, Sendable {
        case template(UUID)
        case add
        case reset
    }

    private let root: AppRootEnvironment
    private let store: QuickCommentTemplateStore

    /// `store` is the app's templates unless a test passes its own.
    init(root: AppRootEnvironment, store: QuickCommentTemplateStore? = nil) {
        self.root = root
        self.store = store ?? root.quickCommentTemplateStore
        super.init(
            title: String(localized: "Quick Comments"),
            listIdentifier: "settings.quickComments.list",
            scope: .device,
            headers: true,
            footers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = editButtonItem
        editButtonItem.accessibilityIdentifier = "settings.quickComments.edit"
        dataSource?.reorderingHandlers.canReorderItem = { item in
            if case .template = item { return true }
            return false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self, let move = Self.move(of: transaction.difference) else { return }
            store.move(from: IndexSet(integer: move.from), to: move.to)
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        // Rows carry delete and reorder accessories only while editing.
        setNeedsUpdateProperties()
    }

    // MARK: - Sections

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        [
            SettingsSectionModel(
                .templates,
                header: String(localized: "Templates"),
                footer: String(localized: "Quick comments appear after selecting text and choosing Comment."),
                items: store.templates.map { .template($0.id) }
            ),
            SettingsSectionModel(.add, items: [.add]),
            SettingsSectionModel(.reset, items: [.reset]),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .template(let id):
            guard let template = store.templates.first(where: { $0.id == id }) else { return AnyHashable(0) }
            return AnyHashable([AnyHashable(template), AnyHashable(isEditing)])
        case .add, .reset:
            return AnyHashable(0)
        }
    }

    // MARK: - Cells

    private lazy var templateRow = UICollectionView.CellRegistration<SettingsEntryRowCell, Item> { [weak self] cell, _, item in
        guard let self, case .template(let id) = item, let template = store.templates.first(where: { $0.id == id }) else { return }
        cell.configure(
            title: template.title,
            caption: template.quickCommentText,
            systemImage: template.systemImage,
            identifier: "settings.quickComments.template.\(id.uuidString)"
        ) { [weak self] in self?.edit(template) }
        cell.accessories = [
            .delete(displayed: .whenEditing) { [weak self] in self?.delete(id) },
            .reorder(displayed: .whenEditing),
        ]
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        if item == .add {
            cell.configure(
                title: String(localized: "Add Quick Comment"),
                systemImage: "plus",
                identifier: "settings.quickComments.add"
            ) { [weak self] in self?.addTemplate() }
        } else {
            cell.configure(
                title: String(localized: "Reset to Defaults"),
                systemImage: "arrow.counterclockwise",
                tint: .destructive,
                identifier: "settings.quickComments.reset",
                confirmation: .init(
                    title: String(localized: "Reset quick comments to defaults?"),
                    message: String(localized: "This replaces your quick comments with the built-in set."),
                    actionTitle: String(localized: "Reset")
                )
            ) { [weak self] in self?.store.resetToDefaults() }
        }
    }

    override func prepareRegistrations() {
        _ = (templateRow, actionRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .template: collectionView.dequeueConfiguredReusableCell(using: templateRow, for: indexPath, item: item)
        case .add, .reset: collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        }
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .template(let id) = item else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.delete(id)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - Changes

    private func delete(_ id: UUID) {
        guard let index = store.templates.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: index))
    }

    private func addTemplate() {
        let template = QuickCommentTemplate(
            id: UUID(),
            title: "",
            systemImage: "text.bubble",
            promptPrefix: "",
            sortOrder: store.templates.count
        )
        present(template, isNew: true)
    }

    private func edit(_ template: QuickCommentTemplate) {
        present(template, isNew: false)
    }

    private func present(_ template: QuickCommentTemplate, isNew: Bool) {
        let editor = QuickCommentEditorViewController(template: template, isNew: isNew) { [weak self] saved in
            guard let self else { return }
            if isNew { store.add(saved) } else { store.update(saved) }
        }
        Router.present(
            editor,
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            theme: root.themeStore
        )
    }

    /// The one move a drag made, as `QuickCommentTemplateStore.move` takes it:
    /// the source index and the destination before the source is removed.
    static func move(of difference: CollectionDifference<Item>) -> (from: Int, to: Int)? {
        var removal: (offset: Int, item: Item)?
        var insertion: (offset: Int, item: Item)?
        for change in difference {
            switch change {
            case .remove(let offset, let element, _): removal = (offset, element)
            case .insert(let offset, let element, _): insertion = (offset, element)
            }
        }
        guard let removal, let insertion, removal.item == insertion.item else { return nil }
        return (removal.offset, insertion.offset > removal.offset ? insertion.offset + 1 : insertion.offset)
    }
}
