import UIKit

/// A screen's own Pin or Unpin bar button for the route it shows, where no
/// pane menu offers one (an iPhone screen, a sheet): the Godot pane, the Git
/// panel. Hidden on a server that keeps no pins and for a route a pin can't
/// name. `update` reads the pins under observation, so a screen that calls
/// it from `updateProperties()` follows a change made anywhere.
@MainActor
final class PinBarItem {
    let item: UIBarButtonItem
    private let identifiers: (pin: String, unpin: String)
    private var run: (() -> Void)?

    /// `identifiers`: the button's accessibility identifier as Pin and as Unpin.
    init(identifiers: (pin: String, unpin: String)) {
        self.identifiers = identifiers
        item = UIBarButtonItem(title: String(localized: "Pin"), image: UIImage(systemName: "pin"), primaryAction: nil)
        item.accessibilityIdentifier = identifiers.pin
        item.primaryAction = UIAction(title: String(localized: "Pin")) { [weak self] _ in self?.run?() }
        item.isHidden = true
    }

    /// Shows Pin or Unpin for `route` on `serverId`'s pins, or hides the button.
    func update(route: PaneRoute?, serverId: String?, root: AppRootEnvironment?, view: UIView) {
        guard let route, route.isPinnable, let serverId, let root,
              let (pins, api) = PaneEntries.pins(serverId, coordinator: root.coordinator) else {
            item.isHidden = true
            run = nil
            return
        }
        let toggle = PinMenu.toggle(route: route, identifiers: identifiers, pins: pins, api: api, view: view)
        item.isHidden = false
        item.title = toggle.title
        item.image = UIImage(systemName: toggle.symbol)
        item.accessibilityIdentifier = toggle.identifier
        run = toggle.run
    }
}
