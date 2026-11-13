import UIKit

/// Places the app's keyboard commands (`KeyboardCommand`) in the main menu, which
/// iPadOS shows in the menu bar and in the Command-hold shortcut overlay. A
/// system menu that already has the command's job (Close, Settings, Sidebar)
/// gives it its place; the rest sit in View and a Session menu. Edit > Find is
/// the system's own. The window answers both (`AppWindow`).
@MainActor
enum KeyboardCommandMenu {
    static let sessionMenuID = UIMenu.Identifier("\(AppIdentifiers.subsystem).menu.session")

    static func build(into builder: any UIMenuBuilder, action: Selector) {
        func item(_ command: KeyboardCommand) -> UIKeyCommand { command.makeKeyCommand(action: action) }
        func inline(_ commands: [KeyboardCommand], identifier: UIMenu.Identifier? = nil) -> UIMenu {
            UIMenu(identifier: identifier, options: .displayInline, children: commands.map(item))
        }

        builder.insertChild(inline([.newSession]), atStartOfMenu: .file)

        if builder.menu(for: .close) != nil {
            builder.replace(menu: .close, with: inline([.close], identifier: .close))
        } else {
            builder.insertChild(inline([.close]), atEndOfMenu: .file)
        }

        if builder.menu(for: .preferences) != nil {
            builder.replace(menu: .preferences, with: inline([.settings], identifier: .preferences))
        } else {
            builder.insertChild(inline([.settings]), atStartOfMenu: .application)
        }

        if builder.menu(for: .sidebar) != nil {
            builder.replace(menu: .sidebar, with: inline([.toggleSidebar], identifier: .sidebar))
            builder.insertSibling(inline([.toggleFileTree]), afterMenu: .sidebar)
        } else {
            builder.insertChild(inline([.toggleSidebar, .toggleFileTree]), atStartOfMenu: .view)
        }
        builder.insertChild(inline(KeyboardCommand.panes.map(KeyboardCommand.pane)), atStartOfMenu: .view)

        let session = UIMenu(
            title: String(localized: "Session"),
            identifier: sessionMenuID,
            children: [.stop, .focusComposer, .nextSession, .previousSession].map(item)
        )
        builder.insertSibling(session, afterMenu: .view)
    }
}

extension AppDelegate {
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        KeyboardCommandMenu.build(into: builder, action: #selector(AppWindow.performKeyboardCommand(_:)))
    }
}

/// The app's window. It answers the keyboard commands and the system Find
/// itself, from the responder chain, so a command typed in a window acts in
/// that window's focused leaf and never in another window.
final class AppWindow: UIWindow {
    /// The app root the front screen sees, found as the app's own UIKit code
    /// finds it (`AppRootEnvironment.near`: the window's in the real scene, a
    /// fixture's in a UI harness), else the window's.
    private var commandSurface: LiveKeyboardCommandSurface? {
        let frontRoot = FrontScreens.screens(in: self).lazy.compactMap { AppRootEnvironment.near($0) }.first
        return (frontRoot ?? traitCollection.appRootEnvironment).map { LiveKeyboardCommandSurface(root: $0, window: self) }
    }

    @objc func performKeyboardCommand(_ sender: UICommand) {
        guard let id = sender.propertyList as? String, let command = KeyboardCommand(id: id) else { return }
        commandSurface?.resolve(command)?.run()
    }

    /// The menu item is on only while its owner is available, and says what it
    /// would do now (Show or Hide).
    override func validate(_ command: UICommand) {
        guard command.action == #selector(performKeyboardCommand(_:)),
              let id = command.propertyList as? String, let keyboardCommand = KeyboardCommand(id: id) else {
            super.validate(command)
            return
        }
        guard let resolved = commandSurface?.resolve(keyboardCommand) else {
            // A disabled Cmd-W falls through to the system's Close Window, which
            // would end the app's only window. Close stays enabled and does nothing.
            command.attributes = keyboardCommand == .close ? [] : .disabled
            return
        }
        command.title = resolved.title
        command.attributes = []
    }

    // MARK: Find

    /// The system Edit > Find reaches the window when no focused text view
    /// has a find of its own: it drives the search bar in front.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponder.find(_:)) {
            return commandSurface?.find() != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func find(_ sender: Any?) {
        commandSurface?.find()?()
    }
}
