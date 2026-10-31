import Testing
import UIKit
@testable import Oppi

/// A kit menu row builds its menu's rows when the menu opens
/// (`UIDeferredMenuElement`), so the element itself is opaque. A test asks the
/// row what it will show, and performs one of those rows, the same way a tap
/// does.
@MainActor
enum KitMenuRow {
    /// The choices the row's menu lists now.
    static func actions(of button: UIButton) -> [UIAction] {
        cellOwning(button)?.menuChoices() ?? []
    }

    /// Runs the row's choice titled `title`.
    static func choose(_ title: String, in button: UIButton) throws {
        let action = try #require(
            actions(of: button).first { $0.title == title },
            "no menu item \(title)"
        )
        action.performWithSender(nil, target: nil)
    }

    /// The menu row a button belongs to.
    private static func cellOwning(_ button: UIButton) -> SettingsMenuRowCell? {
        var view: UIView? = button.superview
        while let current = view {
            if let row = current as? SettingsMenuRowCell { return row }
            view = current.superview
        }
        return nil
    }
}
