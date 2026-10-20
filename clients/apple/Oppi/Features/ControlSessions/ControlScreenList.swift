import UIKit

/// List pieces the UIKit control-definition screens share (Agents, Schedules,
/// Custom Themes): rows whose one accessibility element is a button, the
/// loading and empty states, theme colors, and a small status pill.
///
/// A row that opens or acts is a `SidebarListCell`: its `SidebarRowElement`
/// takes the tap and is the row's accessibility element, a button, because
/// XCUITest types a collection view cell as a Cell whatever its traits. Swipe
/// actions belong to the collection view; a row's long-press menu is its
/// button's (the button takes the touch, so the list's own menu never sees it).
@MainActor
enum ControlScreenList {
    /// The screen's list. It gets its layout in `viewDidLoad()`
    /// (`layout(...)`), where the swipe provider can capture the screen.
    static func makeCollectionView() -> UICollectionView {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        return collectionView
    }

    static func layout(
        appearance: UICollectionLayoutListConfiguration.Appearance,
        headers: Bool = false,
        footers: Bool = false,
        trailingSwipe: ((IndexPath) -> UISwipeActionsConfiguration?)? = nil
    ) -> UICollectionViewLayout {
        var config = UICollectionLayoutListConfiguration(appearance: appearance)
        config.headerMode = headers ? .supplementary : .none
        config.footerMode = footers ? .supplementary : .none
        config.backgroundColor = .clear
        config.trailingSwipeActionsConfigurationProvider = trailingSwipe
        if appearance == .plain {
            config.showsSeparators = false
        }
        return UICollectionViewCompositionalLayout.list(using: config)
    }

    /// The theme's page behind the list and its color scheme on the screen.
    /// Reads the theme store: call from `updateProperties()` to follow it.
    static func applyTheme(_ theme: ThemeStore, to screen: UIViewController, collectionView: UICollectionView) {
        screen.overrideUserInterfaceStyle = theme.userInterfaceStyle
        screen.view.backgroundColor = theme.backgroundColor
        collectionView.backgroundColor = .clear
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
    static func background(
        _ cell: SidebarListCell,
        grouped: Bool,
        palette: ThemePalette
    ) {
        cell.configurationUpdateHandler = { cell, state in
            guard let cell = cell as? SidebarListCell else { return }
            var background = grouped
                ? UIBackgroundConfiguration.listCell().updated(for: state)
                : UIBackgroundConfiguration.clear()
            if !cell.element.isHidden, cell.element.isHighlighted {
                background.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.1)
            }
            cell.backgroundConfiguration = background
        }
        cell.setNeedsUpdateConfiguration()
    }

    /// A centered spinner with its caption (SwiftUI `ProgressView("…")`).
    static func loading(_ text: String) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.loading()
        config.text = text
        return config
    }

    /// An empty or failed state (SwiftUI `ContentUnavailableView`).
    static func unavailable(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        palette: ThemePalette
    ) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: systemImage)
        config.imageProperties.tintColor = UIColor(palette.comment)
        config.text = title
        config.textProperties.color = UIColor(palette.fg)
        config.secondaryText = description
        config.secondaryTextProperties.color = UIColor(palette.comment)
        return config
    }

    /// Font for a text style at a weight, following Dynamic Type.
    static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight = .regular) -> UIFont {
        AskUIFont.preferred(style, weight: weight)
    }

    /// Presents an action sheet over `screen`, centered when it pops over.
    static func presentActionSheet(_ sheet: UIAlertController, from screen: UIViewController) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = screen.view
            popover.sourceRect = CGRect(x: screen.view.bounds.midX, y: screen.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        Router.topPresenter(from: screen).present(sheet, animated: true)
    }
}
