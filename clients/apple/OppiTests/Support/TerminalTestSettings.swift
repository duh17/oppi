import Foundation
import Testing
import UIKit
@testable import Oppi

/// A device settings store for a test: over `defaults`, with the Terminal page's mode
/// as given (nil leaves nothing chosen). A page that reads the device store would
/// otherwise answer with whatever the slot's app container holds.
@MainActor
func terminalTestSettings(mode: SSHTerminalPageMode?, defaults: UserDefaults) -> SettingsStore {
    if let mode {
        defaults.set(mode.rawValue, forKey: AppPreferenceStore.Terminal.pageModeKey)
    } else {
        defaults.removeObject(forKey: AppPreferenceStore.Terminal.pageModeKey)
    }
    return SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil })
}


/// A page mounted in a window that has appeared: what it draws, by identifier, and its
/// list. Shared by the Terminal page's suites.
@MainActor
struct MountedPage<Page: UIViewController> {
    let window: UIWindow
    let page: Page

    /// Every accessible identifier on screen, so a test asks what the page shows.
    var identifiers: [String] { Self.allIdentifiers(in: page.view) }

    func element(_ identifier: String) -> UIView? { Self.view(identifier, in: page.view) }

    /// Draws the page again, as a pass after a store change would.
    func reload() {
        page.setNeedsUpdateProperties()
        page.updatePropertiesIfNeeded()
        page.view.layoutIfNeeded()
    }

    private static func allIdentifiers(in view: UIView) -> [String] {
        (view.accessibilityIdentifier.map { [$0] } ?? [])
            + view.subviews.flatMap { allIdentifiers(in: $0) }
    }

    private static func view(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap { view(identifier, in: $0) }.first
    }
}


/// `height` makes room for a page longer than a phone: a row that is not on
/// screen is not dequeued, so a test that reads one down a long form mounts it
/// in a window tall enough to show it. `wrappingInNavigation` is for a page that
/// has to take focus: a field takes it only in a window that installed its view,
/// and a page made the window's own root is.
@MainActor
func mountPage<Page: UIViewController>(
    _ page: Page,
    height: CGFloat = 844,
    wrappingInNavigation: Bool = true
) throws -> MountedPage<Page> {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
    window.traitOverrides.appRootEnvironment = makeTestAppRoot()
    window.rootViewController = wrappingInNavigation ? RouterNavigationController(rootViewController: page) : page
    window.makeKeyAndVisible()
    page.beginAppearanceTransition(true, animated: false)
    page.endAppearanceTransition()
    page.setNeedsUpdateProperties()
    page.updatePropertiesIfNeeded()
    page.view.layoutIfNeeded()
    return MountedPage(window: window, page: page)
}

