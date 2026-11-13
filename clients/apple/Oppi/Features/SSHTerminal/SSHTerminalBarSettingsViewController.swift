import UIKit

/// Settings > Terminal > Bottom Bar: Customize for the terminal's bottom bar
/// (`BarCustomizeViewController`), with the sections only this bar has. The
/// bar draws the buttons that are on, in this order, in one pill centred
/// between Back and the trailing corner. A hidden button moves into the …
/// menu, except keys and Paste, which the keyboard bars and the grid's hold
/// menu already offer, and Program Shortcuts, which the keyboard bar has.
///
/// The list holds three kinds of row: the built-in buttons, Program Shortcuts
/// (the detected program's keys, as the key strips show them), and the custom
/// keys the person made. A custom key opens its editor from its row or a swipe,
/// and a swipe deletes it. Add Custom Key… sits under the list.
///
/// A Rex pane draws one Rex control, the pane switcher's pill, and its panel
/// replaces the program-status symbol and Rex Sessions. A **Rex Panel** section
/// says which of the panel's sections show (This pane, Panes, Other sessions)
/// and whether the pill's icon carries the program's status; it is left out of a
/// terminal that Run on Connect started in Herdr, which has no Rex.
///
/// The terminal opens this screen as a sheet from its … menu (Customize Bar…).
/// Opened from a terminal, it leaves out the rows that terminal's multiplexer
/// rules out (`SSHTerminalBarContext`: a Rex pane has no Herdr row), for
/// presentation only: the saved layout keeps those actions' places and
/// switches, and reordering moves only the rows shown. Opened from Settings it
/// has every row.
final class SSHTerminalBarSettingsViewController: BarCustomizeViewController<
    SSHTerminalBarItem, SSHTerminalBarSettingsViewController.Extra
> {
    /// A choice of the Rex panel.
    enum RexPanelOption: CaseIterable, Hashable, Sendable {
        case thisPane, panes, otherSessions, statusOnIcon

        var title: String {
            switch self {
            case .thisPane: String(localized: "This Pane")
            case .panes: String(localized: "Panes in This Session")
            case .otherSessions: String(localized: "Other Sessions")
            case .statusOnIcon: String(localized: "Status on the Icon")
            }
        }

        var identifier: String {
            switch self {
            case .thisPane: "settings.sshTerminal.bar.rexPanel.thisPane"
            case .panes: "settings.sshTerminal.bar.rexPanel.panes"
            case .otherSessions: "settings.sshTerminal.bar.rexPanel.otherSessions"
            case .statusOnIcon: "settings.sshTerminal.bar.rexPanel.statusOnIcon"
            }
        }

        func isOn(_ settings: SSHTerminalRexPanelSettings) -> Bool {
            switch self {
            case .thisPane: settings.showsThisPane
            case .panes: settings.showsPanes
            case .otherSessions: settings.showsOtherSessions
            case .statusOnIcon: settings.showsStatusOnIcon
            }
        }

        func setting(_ isOn: Bool, in settings: SSHTerminalRexPanelSettings) -> SSHTerminalRexPanelSettings {
            var next = settings
            switch self {
            case .thisPane: next.showsThisPane = isOn
            case .panes: next.showsPanes = isOn
            case .otherSessions: next.showsOtherSessions = isOn
            case .statusOnIcon: next.showsStatusOnIcon = isOn
            }
            return next
        }
    }

    /// The rows only this bar has.
    enum Extra: Hashable, Sendable {
        case addKey
        case rexPanel(RexPanelOption)
    }

    private let store: SSHTerminalBarStore
    private let context: SSHTerminalBarContext

    init(context: SSHTerminalBarContext = .plain, store: SSHTerminalBarStore = SSHTerminalBarStore()) {
        self.context = context
        self.store = store
        let offers = Self.offeredMultiplexers(context: context)
        super.init(surface: BarSurface(
            title: String(localized: "Bottom Bar"),
            footer: Self.barFooter(offers: offers),
            identifierPrefix: "settings.sshTerminal.bar",
            layout: { store.layout },
            defaultLayout: { store.defaultLayout },
            save: { store.setLayout($0) },
            reset: { store.reset() },
            row: { Self.row($0, keys: store.customKeys) },
            isListed: { Self.isListed($0, context: context, store: store) }
        ))
    }

    /// A row's words and symbol; a custom key adds its chord and the program
    /// it shows for.
    private static func row(_ item: SSHTerminalBarItem, keys: [SSHTerminalCustomKey]) -> BarSurface<SSHTerminalBarItem>.Row {
        let symbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        switch item {
        case .action(let action):
            return .init(title: item.title(customKeys: keys), image: action.image(configuration: symbolConfiguration))
        case .programShortcuts:
            return .init(title: item.title(customKeys: keys), image: UIImage(systemName: "command", withConfiguration: symbolConfiguration))
        case .customKey(let id):
            let key = keys.first { $0.id == id }
            return .init(
                title: item.title(customKeys: keys),
                subtitle: key.map { "\($0.chord) \u{00B7} \($0.showFor.title)" },
                image: UIImage(systemName: "keyboard", withConfiguration: symbolConfiguration)
            )
        }
    }

    /// Whether the screen lists `item`: every row, except one this terminal's
    /// multiplexer rules out, and a custom key the store no longer has.
    private static func isListed(_ item: SSHTerminalBarItem, context: SSHTerminalBarContext, store: SSHTerminalBarStore) -> Bool {
        switch item {
        case .action(let action): !context.hidden.contains(action)
        case .programShortcuts: true
        case .customKey(let id): store.customKeys.contains { $0.id == id }
        }
    }

    /// The multiplexers this screen can offer: the terminal has not ruled one
    /// out, and its experiment is on.
    private static func offeredMultiplexers(context: SSHTerminalBarContext) -> (herdr: Bool, rex: Bool) {
        let access = SSHTerminalExperimentAccess.current
        return (access.herdr && context != .rex, access.rex && context != .herdr)
    }

    /// The list's footer, naming only the multiplexers the bar can draw.
    private static func barFooter(offers: (herdr: Bool, rex: Bool)) -> String {
        let base = String(localized: "The bar draws the buttons that are on, in this order, centred between Back and the corner. A button turned off moves into the \u{2026} menu, except the built-in keys, Program Shortcuts, and Paste, which the keyboard bars have. A button that doesn't fit the screen moves there too, except Paste, which is left out.")
        let multiplexers: String? = switch offers {
        case (true, true): String(localized: "Herdr and Rex show when the host runs them, but not in a terminal that is already inside the other, and Switch Terminal when more than one terminal is open.")
        case (true, false): String(localized: "Herdr shows when the host runs it, and Switch Terminal when more than one terminal is open.")
        case (false, true): String(localized: "Rex shows when the host runs it, and Switch Terminal when more than one terminal is open.")
        case (false, false): String(localized: "Switch Terminal shows when more than one terminal is open.")
        }
        let program = String(localized: "Program Shortcuts shows the keys of the program in front, and a custom key shows only for the program you pick.")
        let keyboard = String(localized: "With the terminal keyboard up, the same buttons ride on the keyboard bar, without the ones it already has.")
        return [base, multiplexers, program, keyboard].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - Extra sections

    override func extraSections() -> [BarCustomizeExtraSection<Extra>] {
        var sections = [BarCustomizeExtraSection<Extra>(rows: [.addKey])]
        if Self.offeredMultiplexers(context: context).rex {
            sections.append(BarCustomizeExtraSection(
                header: String(localized: "Rex Panel"),
                footer: String(localized: "In a Rex pane the pane switcher at the bottom right is the one Rex control. Tap it for the panel; touch and hold for the quick pane menu. The panel's sections and the status on the icon are chosen here."),
                rows: RexPanelOption.allCases.map(Extra.rexPanel)
            ))
        }
        return sections
    }

    override func inputs(ofExtra extra: Extra) -> AnyHashable {
        switch extra {
        case .addKey: AnyHashable(0)
        case .rexPanel(let option): AnyHashable(option.isOn(store.rexPanel))
        }
    }

    private lazy var addKeyRow = UICollectionView.CellRegistration<SettingsActionRowCell, Extra> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Add Custom Key\u{2026}"),
            systemImage: "plus",
            identifier: "settings.sshTerminal.bar.addKey"
        ) { [weak self] in self?.present(SSHTerminalCustomKey(), isNew: true) }
    }

    override func prepareRegistrations() {
        super.prepareRegistrations()
        _ = addKeyRow
    }

    override func dequeue(extra: Extra, at indexPath: IndexPath) -> UICollectionViewCell? {
        guard extra == .addKey else { return nil }
        return collectionView.dequeueConfiguredReusableCell(using: addKeyRow, for: indexPath, item: extra)
    }

    override func configure(_ cell: UICollectionViewListCell, extra: Extra) {
        guard case .rexPanel(let option) = extra else { return }
        var content = content(.plain)
        content.text = option.title
        cell.contentConfiguration = content
        cell.accessories = [
            .settingsToggle(option.isOn(store.rexPanel), identifier: option.identifier, reusing: cell) { [weak self] isOn in
                guard let self else { return }
                store.setRexPanel(option.setting(isOn, in: store.rexPanel))
                setNeedsUpdateProperties()
            },
        ]
    }

    // MARK: - Custom keys

    private func key(_ row: Row) -> SSHTerminalCustomKey? {
        guard case .action(.customKey(let id)) = row else { return nil }
        return store.customKeys.first { $0.id == id }
    }

    override func isSelectable(_ item: Row) -> Bool {
        key(item) != nil
    }

    override func select(_ item: Row) {
        guard let key = key(item) else { return }
        present(key, isNew: false)
    }

    override func rowActions(for item: Row) -> [ListRowAction] {
        guard let key = key(item) else { return [] }
        // A full swipe deletes, as in any list; the key is cheap to make again.
        return [
            ListRowAction(
                title: String(localized: "Delete"),
                systemImage: "trash",
                style: .destructive,
                accessibilityLabel: String(localized: "Delete \(key.displayName)")
            ) { [weak self] done in
                self?.store.delete(key.id)
                self?.setNeedsUpdateProperties()
                done(true)
            },
            ListRowAction(
                title: String(localized: "Edit"),
                systemImage: "slider.horizontal.3",
                tint: SettingsStyle.current.accent
            ) { [weak self] done in
                self?.present(key, isNew: false)
                done(true)
            },
        ]
    }

    private func present(_ key: SSHTerminalCustomKey, isNew: Bool) {
        let editor = SSHTerminalCustomKeyViewController(key: key, isNew: isNew) { [weak self] saved in
            self?.store.save(saved)
            self?.setNeedsUpdateProperties()
        }
        Router.present(
            editor,
            presentation: .sheet.detents([.large()]).inNavigation(),
            from: self
        )
    }
}
