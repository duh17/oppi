import UIKit

/// The system's vertical bar (iOS 27.1, the Duo's side rail): whether the
/// system may place one, and the item and trait APIs that put controls on it.
///
/// `verticalBarEdge` is the preferred edge, not "a bar is on screen". It is
/// `.unspecified` where iOS never places a vertical bar. Deployment stays
/// 26.0, so every read is availability-gated. Mac Catalyst lacks these APIs
/// even behind `#available`, and a Mac window has no vertical bar, so they
/// compile out there and the answers are the iOS 26 ones: no rail.
enum SystemVerticalBar {
    static func traitIsActive(_ traits: UITraitCollection) -> Bool {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            return traits.verticalBarEdge != .unspecified
        }
        #endif
        return false
    }

    @MainActor
    static func isActive(_ viewController: UIViewController) -> Bool {
        guard viewController.navigationController?.isNavigationBarHidden != true else { return false }
        return traitIsActive(viewController.traitCollection)
    }

    /// The item moves to the vertical bar when there is one.
    @MainActor
    static func prefersRail(_ item: UIBarButtonItem) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            item.axisBehavior = .verticalPreferred
        }
        #endif
    }

    /// The item stays in the horizontal bar even when a vertical bar exists.
    @MainActor
    static func keepsHorizontal(_ item: UIBarButtonItem) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            item.axisBehavior = .horizontalOnly
        }
        #endif
    }

    /// Calls `handler` whenever a trait that can move the vertical bar changes.
    @MainActor
    static func observeEdgeChanges<Controller: UIViewController>(
        of controller: Controller,
        _ handler: @escaping @MainActor (Controller) -> Void
    ) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            controller.registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                (controller: Controller, _: UITraitCollection) in
                handler(controller)
            }
        }
        #endif
    }
}
