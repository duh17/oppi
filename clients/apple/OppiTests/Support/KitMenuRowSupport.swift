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
        if let row = cellOwning(button) { return row.menuChoices() }
        return button.menu?.children.compactMap { $0 as? UIAction } ?? []
    }

    /// The row a button belongs to, if it is a kit menu row's overlay button.
    static func cellOwning(_ button: UIButton) -> SettingsMenuRowCell? {
        var view: UIView? = button.superview
        while let current = view {
            if let row = current as? SettingsMenuRowCell { return row }
            view = current.superview
        }
        return nil
    }

    /// Runs the row's choice titled `title`.
    static func choose(_ title: String, in button: UIButton) throws {
        let action = try #require(
            actions(of: button).first { $0.title == title },
            "no menu item \(title)"
        )
        action.performWithSender(nil, target: nil)
    }
}
