import UIKit

/// The sidebar button belongs to the main pane, not to a screen. The window's
/// routed stack (`ShellNavigationController`) puts one in the leading items of
/// each of its screens: every screen in a wide window (the iPad, either way
/// round), the root alone in a compact one (the iPhone, the Duo's cover
/// display). Side panes have their own stacks and never get one.
///
/// It follows the layout holding the stack (`ShellSidebar`): beside the split
/// view's sidebar column it shows or hides the column
/// (`workspace.split.sidebarToggle`); over the drawer it opens the drawer
/// (`workspace.sidebar.open`). Touch, accessibility, and a screen's own drawn
/// copy all run `toggle`.
///
/// A screen that writes its own leading items keeps the button among them
/// (`UINavigationItem.setLeadingItems`); a screen that hides the bar draws a
/// copy in its own chrome from `UIViewController.mainPaneSidebarItem`.
@MainActor
final class MainPaneSidebarItem: UIBarButtonItem {
    let toggle: () -> Void

    init(toggle: @escaping () -> Void) {
        self.toggle = toggle
        super.init()
        primaryAction = UIAction(image: UIImage(systemName: "sidebar.leading")) { _ in toggle() }
        // On the Duo's rail it joins the rail with its title.
        _ = SessionListBarItems.railItem(self, priority: .navigation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Title plus symbol, so the rail and overflow menus can show it. Says
    /// whether the change took, for the screens that draw a copy.
    func apply(_ sidebar: ShellSidebar, tint: UIColor) -> Bool {
        let title = sidebar.isShown()
            ? String(localized: "Hide Sidebar")
            : String(localized: "Show Sidebar")
        tintColor = tint
        guard title != self.title || sidebar.identifier != accessibilityIdentifier else { return false }
        self.title = title
        image = UIImage(systemName: "sidebar.leading")
        accessibilityIdentifier = sidebar.identifier
        return true
    }
}

/// The sidebar the main pane's sidebar button reaches, set by the layout that
/// holds the window's routed stack (`WorkspacePaneLayout.adopt`).
@MainActor
struct ShellSidebar {
    let identifier: String
    /// Read in `updateProperties()`, so a sidebar the system's own gestures
    /// moved retitles the button.
    let isShown: () -> Bool
    let toggle: () -> Void
}

extension UINavigationItem {
    /// The main pane's sidebar button, while the stack shows one on this screen.
    var mainPaneSidebarItem: MainPaneSidebarItem? {
        leadingItemGroups.lazy.flatMap(\.barButtonItems).compactMap { $0 as? MainPaneSidebarItem }.first
    }

    /// A screen's own leading items. The main pane's sidebar button stays: after
    /// `back` (a Back the screen draws itself), before the rest, as it follows
    /// the system's Back.
    func setLeadingItems(_ items: [UIBarButtonItem], back: UIBarButtonItem? = nil) {
        setLeadingGroups(items.isEmpty ? [] : [UIBarButtonItemGroup(barButtonItems: items, representativeItem: nil)], back: back)
    }

    func setLeadingGroups(_ groups: [UIBarButtonItemGroup], back: UIBarButtonItem? = nil) {
        let next = [back, mainPaneSidebarItem].compactMap { $0.map { UIBarButtonItemGroup(barButtonItems: [$0], representativeItem: nil) } }
            + groups
        guard !next.flatMap(\.barButtonItems).elementsEqual(leadingItemGroups.flatMap(\.barButtonItems), by: ===) else { return }
        leadingItemGroups = next
    }

    /// The stack's half: shows or removes its button, which leads until the
    /// screen sets its own items again.
    func setMainPaneSidebarItem(_ item: MainPaneSidebarItem?) {
        let current = mainPaneSidebarItem
        guard item !== current else { return }
        var groups = leadingItemGroups.filter { group in !group.barButtonItems.contains { $0 === current } }
        if let item {
            groups.insert(UIBarButtonItemGroup(barButtonItems: [item], representativeItem: nil), at: 0)
            leftItemsSupplementBackButton = true
        }
        leadingItemGroups = groups
    }
}

extension UIViewController {
    /// The main pane's sidebar button on the stack screen this controller is,
    /// or is inside: for a screen that hides the bar and draws it itself.
    var mainPaneSidebarItem: MainPaneSidebarItem? {
        var screen: UIViewController = self
        while let parent = screen.parent, !(parent is UINavigationController) {
            screen = parent
        }
        return screen.navigationItem.mainPaneSidebarItem
    }

    /// Asks this controller and everything inside it to redraw: the stack
    /// changed the button the screen's own chrome copies.
    func setNeedsUpdatePropertiesInTree() {
        setNeedsUpdateProperties()
        for child in children {
            child.setNeedsUpdatePropertiesInTree()
        }
    }
}
