import UIKit

/// One customizable bar as the shared Customize screen sees it: what the
/// screen is called, where the layout is kept, and how each action's row
/// reads. Chat's top bar, the terminal's bottom bar, the reader's bar, and
/// Edit Sidebar each make one.
@MainActor
struct BarSurface<Action: BarLayoutAction> {
    /// What a row shows for one action.
    struct Row {
        var title: String
        var subtitle: String?
        var image: UIImage?
    }

    let title: String
    let footer: String
    /// The root of the screen's identifiers: the list is `<prefix>.list`, a row
    /// `<prefix>.row.<action>`, its switch `<prefix>.<action>`, and Reset to
    /// Default `<prefix>.reset`.
    let identifierPrefix: String
    let layout: () -> BarLayout<Action>
    /// What Reset to Default restores, and when it is offered.
    let defaultLayout: () -> BarLayout<Action>
    /// Writes the layout; the store announces the change, which the open bar
    /// redraws from.
    let save: (BarLayout<Action>) -> Void
    let reset: () -> Void
    let row: (Action) -> Row
    /// Whether the screen lists `action`. A bar opened from one screen can
    /// leave out actions that screen can never offer; the saved layout keeps
    /// their places and switches.
    var isListed: (Action) -> Bool = { _ in true }
    /// Runs once the screen loads.
    var didOpen: () -> Void = {}
}

extension BarSurface {
    /// A surface whose layout is one `BarLayoutPreference`.
    init(
        title: String,
        footer: String,
        identifierPrefix: String,
        preference: BarLayoutPreference<Action>,
        defaults: UserDefaults,
        row: @escaping (Action) -> Row,
        didOpen: @escaping () -> Void = {}
    ) {
        self.init(
            title: title,
            footer: footer,
            identifierPrefix: identifierPrefix,
            layout: { preference.layout(in: defaults) },
            defaultLayout: { .defaultValue },
            save: { preference.save($0, in: defaults) },
            reset: { preference.reset(in: defaults) },
            row: row,
            didOpen: didOpen
        )
    }
}

enum BarCustomizeSection: Hashable, Sendable {
    case items
    /// The surface's own sections, in the order it gives them.
    case extra(Int)
    case reset
}

enum BarCustomizeRow<Action: BarLayoutAction, Extra: Hashable & Sendable>: Hashable, Sendable {
    case action(Action)
    case extra(Extra)
    case reset
}

/// A section a surface adds under its list (the terminal's Add Custom Key… and
/// Rex Panel).
struct BarCustomizeExtraSection<Extra> {
    var header: String?
    var footer: String?
    var rows: [Extra]
}

/// Customize for every customizable bar: one row per action in the bar's
/// order, a switch that shows or hides its button, and a handle that drags it
/// into place. A button turned off moves into the bar's … menu and keeps its
/// place in the order. Editing stays on, so there is no Edit button. Reset to
/// Default shows while the layout differs from the default.
///
/// Settings pushes it; a bar's … menu opens it as a sheet
/// (`presentSheet(from:)`), so the bar being changed stays in view and
/// redraws as the switches move. The sidebar's Edit opens it as Edit Sidebar
/// (`WorkspaceSidebarEditViewController`), a popover beside the sidebar. A
/// surface with more to set (the terminal, the sidebar) subclasses it and adds
/// its sections through `extraSections()`.
class BarCustomizeViewController<Action: BarLayoutAction, Extra: Hashable & Sendable>: ListScreenController<
    BarCustomizeSection, BarCustomizeRow<Action, Extra>
> {
    typealias Row = BarCustomizeRow<Action, Extra>

    let surface: BarSurface<Action>

    init(surface: BarSurface<Action>) {
        self.surface = surface
        super.init(
            title: surface.title,
            listIdentifier: "\(surface.identifierPrefix).list",
            scope: .device,
            headers: true,
            footers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.didOpen()
        collectionView.isEditing = true
        dataSource?.reorderingHandlers.canReorderItem = { slot in
            if case .action = slot.pageItem { return true }
            return false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            // The base keeps a drag inside its section, so the items section's
            // order is the new order of the rows listed.
            let rows = transaction.finalSnapshot.itemIdentifiers(inSection: .items).compactMap(\.pageItem)
            let listed = rows.compactMap { (row: Row) -> Action? in
                if case .action(let action) = row { return action }
                return nil
            }
            save(layout.reordering(listed))
        }
    }

    /// Opens this screen as a sheet over `presenter`, with Done. At the medium
    /// height a top bar it changes stays in view; a bar at the bottom of the
    /// screen is covered at any height, so its sheet opens full (`large`).
    func presentSheet(
        from presenter: UIViewController,
        detents: [UISheetPresentationController.Detent] = [.medium(), .large()],
        onDismiss: (() -> Void)? = nil
    ) {
        presentWithDone(from: presenter, presentation: .sheet.detents(detents).inNavigation(), onDismiss: onDismiss)
    }

    /// Opens this screen in `presentation` over `presenter`, with Done: a sheet,
    /// or a popover at `sourceView` that a compact width turns into a sheet.
    func presentWithDone(
        from presenter: UIViewController,
        presentation: ModalPresentation,
        sourceView: UIView? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        done.accessibilityIdentifier = "barCustomize.done"
        navigationItem.rightBarButtonItem = done
        Router.present(self, presentation: presentation, from: presenter, sourceView: sourceView, onDismiss: onDismiss)
    }

    var layout: BarLayout<Action> { surface.layout() }

    /// The screen's one write of the layout; it redraws itself, and the store
    /// tells the open bar.
    func save(_ next: BarLayout<Action>) {
        surface.save(next)
        setNeedsUpdateProperties()
    }

    // MARK: - Hooks

    /// The surface's own sections under the list.
    func extraSections() -> [BarCustomizeExtraSection<Extra>] { [] }

    func inputs(ofExtra extra: Extra) -> AnyHashable { AnyHashable(0) }

    func configure(_ cell: UICollectionViewListCell, extra: Extra) {}

    /// A cell of its own for `extra`, or nil for a list cell `configure` fills.
    func dequeue(extra: Extra, at indexPath: IndexPath) -> UICollectionViewCell? { nil }

    // MARK: - List

    override func sections() -> [ListSection<BarCustomizeSection, Row>] {
        let layout = layout
        var sections: [ListSection<BarCustomizeSection, Row>] = [
            ListSection(.items, footer: surface.footer, items: layout.order.filter(surface.isListed).map(Row.action)),
        ]
        for (index, extra) in extraSections().enumerated() {
            sections.append(ListSection(.extra(index), header: extra.header, footer: extra.footer, items: extra.rows.map(Row.extra)))
        }
        if layout != surface.defaultLayout() {
            sections.append(ListSection(.reset, items: [.reset]))
        }
        return sections
    }

    override func showsHeader(for section: BarCustomizeSection) -> Bool {
        guard case .extra(let index) = section else { return false }
        return extraSections().indices.contains(index) && extraSections()[index].header != nil
    }

    override func inputs(of item: Row) -> AnyHashable {
        switch item {
        case .action(let action):
            // An image is a new instance each read; the words and the switch
            // are what a row redraws for.
            let row = surface.row(action)
            return AnyHashable([AnyHashable(layout.isShown(action)), AnyHashable(row.title), AnyHashable(row.subtitle)])
        case .extra(let extra): return inputs(ofExtra: extra)
        case .reset: return AnyHashable(0)
        }
    }

    private lazy var resetRow = UICollectionView.CellRegistration<SettingsActionRowCell, Row> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(title: String(localized: "Reset to Default"), identifier: "\(surface.identifierPrefix).reset") { [weak self] in
            self?.surface.reset()
            self?.setNeedsUpdateProperties()
        }
    }

    override func prepareRegistrations() {
        _ = resetRow
    }

    override func dequeue(_ item: Row, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .reset:
            return collectionView.dequeueConfiguredReusableCell(using: resetRow, for: indexPath, item: item)
        case .extra(let extra):
            return dequeue(extra: extra, at: indexPath) ?? super.dequeue(item, at: indexPath)
        case .action:
            return super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Row) {
        switch item {
        case .action(let action):
            configure(cell, action: action)
        case .extra(let extra):
            configure(cell, extra: extra)
        case .reset:
            break
        }
    }

    private func configure(_ cell: UICollectionViewListCell, action: Action) {
        let row = surface.row(action)
        var content = content(row.subtitle == nil ? .plain : .subtitle)
        content.text = row.title
        content.secondaryText = row.subtitle
        content.image = row.image
        // The symbol column's width for every row, so a label beside an image
        // that is not a symbol (the Git logo) lines up with the others.
        content.imageProperties.reservedLayoutSize.width = UIListContentConfiguration.ImageProperties.standardDimension
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "\(surface.identifierPrefix).row.\(action.rawValue)"
        cell.accessories = [
            .settingsToggle(
                layout.isShown(action),
                identifier: "\(surface.identifierPrefix).\(action.rawValue)",
                reusing: cell
            ) { [weak self] isOn in
                guard let self else { return }
                save(layout.setting(action, shown: isOn))
            },
            // Always editing, so the handle is part of the row, not a mode.
            .reorder(displayed: .always),
        ]
    }
}
