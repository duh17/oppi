import UIKit

/// The bar a file viewer asks for: its title and trailing items, and whether
/// the editor owns it. A viewer at the top of a stack applies it to its own
/// navigation item; a screen that embeds one (a route, a review, a file list)
/// reads it in `updateProperties()` and shows the items in its own bar.
@MainActor @Observable
final class FileViewerBar {
    var title = ""
    /// In `rightBarButtonItems` order: the first is the trailing-most.
    var trailingItems: [UIBarButtonItem] = []
    /// The text editor is open; its status, Preview, and Done own the bar.
    var isEditing = false

    /// Shows the title and items on `navigationItem`. Assigns only what
    /// changed, so open menus and glass groups survive.
    func apply(to navigationItem: UINavigationItem) {
        if navigationItem.title != title {
            navigationItem.title = title
        }
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(trailingItems, by: ===) {
            navigationItem.rightBarButtonItems = trailingItems
        }
    }
}
