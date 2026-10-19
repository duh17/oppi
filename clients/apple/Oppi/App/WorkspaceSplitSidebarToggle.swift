import UIKit

/// The split detail root's sidebar toggle (`workspace.split.sidebarToggle`)
/// for UIKit screens there (All Sessions, SSH Terminal's host list). Hosted
/// routes get the same control from `ShellRouteView`. The split controller
/// hides its own display-mode button, so the detail root carries this one.
@MainActor
enum WorkspaceSplitSidebarToggle {
    static func makeItem(root: AppRootEnvironment) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "sidebar.leading"), style: .plain, target: nil, action: nil)
        item.primaryAction = UIAction(image: UIImage(systemName: "sidebar.leading")) { [weak item] _ in
            let navigation = root.navigation
            navigation.splitColumnVisibility = navigation.splitColumnVisibility == .detailOnly ? .all : .detailOnly
            if let item { sync(item, root: root) }
        }
        item.accessibilityIdentifier = "workspace.split.sidebarToggle"
        sync(item, root: root)
        return item
    }

    /// Title for the current column state, plus the theme tint. A screen that
    /// reads `splitColumnVisibility` in `updateProperties()` calls this there,
    /// so the system's own sidebar gestures update the title too.
    static func sync(_ item: UIBarButtonItem, root: AppRootEnvironment) {
        // Title plus symbol so the bar can show it on the Duo's vertical rail
        // and in overflow menus.
        item.title = root.navigation.splitColumnVisibility == .detailOnly
            ? String(localized: "Show Sidebar")
            : String(localized: "Hide Sidebar")
        item.image = UIImage(systemName: "sidebar.leading")
        item.tintColor = UIColor(root.themeStore.activeThemeID.palette.fg)
    }
}
