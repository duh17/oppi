import UIKit

/// The kit's row builders: the items of a bar that changes, and rows whose one
/// accessibility element is a button.
///
/// The base draws its own list and theme (`ListScreenController`); a page on it
/// uses these builders for its rows, and so does a list that keeps its own
/// collection view. The row builders (`buttonRow`, `staticRow`, `stateRow`,
/// `background`) are what a page on the base draws its own cell classes with
/// (`SidebarListCell`).
///
/// A row that opens or acts is a `SidebarListCell`: its `SidebarRowElement`
/// takes the tap and is the row's accessibility element, a button, because
/// XCUITest types a collection view cell as a Cell whatever its traits. Swipe
/// actions belong to the collection view; a row's long-press menu is its
/// button's (the button takes the touch, so the list's own menu never sees it).
@MainActor
enum ListScreen {
    /// Sets the bar's items only when they changed, as the chat does:
    /// `updateProperties()` runs often, and each assignment lays the bar out
    /// again.
    static func setBarItems(trailing: [UIBarButtonItem], leading: [UIBarButtonItem], on item: UINavigationItem) {
        if !(item.rightBarButtonItems ?? []).elementsEqual(trailing, by: ===) {
            item.rightBarButtonItems = trailing
        }
        if !(item.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) {
            item.leftBarButtonItems = leading
        }
    }

    /// Readies a reused row as a button with `action`.
    static func buttonRow(
        _ cell: SidebarListCell,
        identifier: String,
        label: String?,
        value: String? = nil,
        hint: String? = nil,
        enabled: Bool = true,
        contextMenu: UIMenu? = nil,
        action: @escaping () -> Void
    ) {
        resetElement(cell)
        cell.element.isHidden = false
        cell.element.isEnabled = enabled
        // The traits are set explicitly, so a disabled row says so itself.
        cell.element.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        cell.element.menu = contextMenu
        cell.element.isContextMenuInteractionEnabled = contextMenu != nil
        cell.element.accessibilityIdentifier = identifier
        cell.element.accessibilityLabel = label
        cell.element.accessibilityValue = value
        cell.element.accessibilityHint = hint
        cell.element.onActivate = action
        cell.element.onHighlightChange = { [weak cell] in cell?.setNeedsUpdateConfiguration() }
        cell.accessibilityElements = [cell.element]
        cell.isAccessibilityElement = false
    }

    /// Readies a reused row that does nothing on tap; its content (a switch,
    /// selectable text) is reachable as it is.
    static func staticRow(_ cell: SidebarListCell, identifier: String? = nil) {
        resetElement(cell)
        cell.element.isHidden = true
        cell.accessibilityElements = nil
        cell.accessibilityIdentifier = identifier
    }

    /// A row that says the list's own state in place: `LoadState`'s words (a
    /// spinner, a symbol, or a failure) as one row's content. The row is not a
    /// card of its own, so the card a list paints behind its rows is cleared;
    /// `keepsCard` leaves it, for a list that states itself inside a card.
    static func stateRow(_ cell: SidebarListCell, _ state: LoadState, palette: ThemePalette, keepsCard: Bool = false) {
        staticRow(cell)
        cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(state, palette: palette)
        if !keepsCard { background(cell, grouped: false, palette: palette) }
    }

    /// Reuse: every row sets all of these, the cell's own accessibility
    /// included, so a row never keeps what the last one set.
    private static func resetElement(_ cell: SidebarListCell) {
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.isAccessibilityElement = false
        cell.accessibilityLabel = nil
        cell.accessibilityValue = nil
        cell.accessibilityHint = nil
        cell.element.onActivate = nil
        cell.element.onHighlightChange = nil
        cell.element.accessibilityIdentifier = nil
        cell.element.accessibilityLabel = nil
        cell.element.accessibilityValue = nil
        cell.element.accessibilityHint = nil
        cell.element.accessibilityTraits = .button
        cell.element.isAccessibilityElement = true
        cell.element.isEnabled = true
        cell.element.menu = nil
        cell.element.showsMenuAsPrimaryAction = false
        cell.element.isContextMenuInteractionEnabled = false
    }

    /// The row's background: grouped card or clear, dimmed while its button
    /// is pressed.
    ///
    /// `settingsCard` paints the grouped card as a settings page does (the
    /// theme's card color at rest); the control-definition screens keep the
    /// system card.
    static func background(
        _ cell: SidebarListCell,
        grouped: Bool,
        palette: ThemePalette,
        settingsCard: Bool = false
    ) {
        cell.configurationUpdateHandler = { cell, state in
            guard let cell = cell as? SidebarListCell else { return }
            var background = grouped
                ? (settingsCard ? SettingsStyle.cardBackground(for: state) : UIBackgroundConfiguration.listCell().updated(for: state))
                : UIBackgroundConfiguration.clear()
            if !cell.element.isHidden, cell.element.isHighlighted {
                background.backgroundColor = palette.ui.fg.withAlphaComponent(0.1)
            }
            cell.backgroundConfiguration = background
        }
        cell.setNeedsUpdateConfiguration()
    }
}
