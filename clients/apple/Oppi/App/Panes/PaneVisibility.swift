import UIKit

/// What a leaf's screens can see of themselves. A pane host reports each
/// change once, at the transition, so a screen that streams or renders live
/// (a terminal, a screen stream) can pause while nobody sees it.
enum PaneVisibility: Equatable {
    /// On screen; `focused` when it is the leaf keys and Find act in.
    case visible(focused: Bool)
    /// Laid out, but the companion covers it (full window).
    case covered
    /// Not shown: its owner was covered by a push, or it gave way to a
    /// narrower window. Its view leaves the hierarchy
    /// `PaneHostController.parkedViewLifetime` later; a memory warning drops
    /// it to what rebuilds it.
    case parked
}

/// A screen in a leaf that wants `PaneVisibility` changes. The leaf's front
/// screen hears each transition; a screen pushed inside the leaf hears the
/// leaf's current visibility once it is shown.
@MainActor
protocol PaneVisibilityObserving: UIViewController {
    func paneVisibilityDidChange(_ visibility: PaneVisibility)
}

@MainActor
enum PaneLeafScreens {
    /// The screens in `controller` and the children it shows that adopt
    /// `Adopter`, outermost first; an adopter speaks for its own children,
    /// and a nested pane host for its own leaves. A pane host asks this of
    /// each leaf for live resize (`PaneLiveResizing`), visibility
    /// (`PaneVisibilityObserving`) and the keyboard rule
    /// (`PaneKeyboardFollowing`).
    static func adopters<Adopter>(in controller: UIViewController?, as _: Adopter.Type) -> [Adopter] {
        guard let controller, !(controller is PaneHostController) else { return [] }
        if let adopter = controller as? Adopter { return [adopter] }
        let shown = (controller as? UINavigationController).map { $0.topViewController.map { [$0] } ?? [] }
            ?? controller.children
        return shown.flatMap { adopters(in: $0, as: Adopter.self) }
    }
}

/// A screen that moves its content with the software keyboard itself (the
/// chat). The keyboard spans the window, so a field in another leaf (the
/// Outline's search) would lift this screen's composer over its timeline: the
/// host turns `followsKeyboard` off while the first responder is in another
/// leaf, and back on otherwise.
@MainActor
protocol PaneKeyboardFollowing: UIViewController {
    var followsKeyboard: Bool { get set }
}
