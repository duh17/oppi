import UIKit

// The UIKit half of declarative modals: the root screen of a router modal and
// the presenter that reconciles one slot's requested modal with what UIKit has
// on screen. UIKit owners keep a presenter per slot and drive it from
// `updateProperties()`; the SwiftUI anchors in `HostFactory.swift` drive the same
// presenter until the last hosted screen is gone.

/// The root screen of a router modal: SwiftUI content
/// hosted through `HostFactory.screen`, or a UIKit view controller that owns
/// its `navigationItem` (title, bar items, search) itself. A UIKit root needs
/// a navigation presentation (`.inNavigation()`) unless it is a
/// `RouterModalContainer` that presents bare (`Router.present`). It is built once per
/// presentation. When the presenter re-renders, hosted content refreshes and
/// a controller's `update` runs with the presenter's current values, so a
/// UIKit modal that mirrors presenter state stays live like hosted content.
enum RouterScreen {
    case hosted(RouterHostedContent)
    case controller(() -> UIViewController, update: ((UIViewController) -> Void)? = nil)

    /// A UIKit root that the presenter refreshes on every re-render.
    static func liveController<Controller: UIViewController>(
        _ make: @escaping () -> Controller,
        update: @escaping (Controller) -> Void
    ) -> Self {
        .controller(make, update: { controller in
            // The router passes back the controller `make` built, so a
            // mismatch is a router bug that would silently freeze the modal.
            guard let controller = controller as? Controller else {
                preconditionFailure("RouterScreen.liveController got \(type(of: controller)), not \(Controller.self)")
            }
            update(controller)
        })
    }
}

private extension ModalPresentation {
    /// Whether the controller presented for `other` can show this request:
    /// same style and the same navigation wrapper. Sheet detents and the
    /// grabber change in place.
    func isPresentable(as other: ModalPresentation) -> Bool {
        style == other.style && (navigation == nil) == (other.navigation == nil)
    }

    func hasSheetChrome(of other: ModalPresentation) -> Bool {
        detents.map(\.identifier) == other.detents.map(\.identifier)
            && prefersGrabberVisible == other.prefersGrabberVisible
    }
}

/// Reconciles one anchor's requested modal with what UIKit has on screen.
@MainActor
final class RouterModalPresenter {
    struct Request {
        let id: AnyHashable
        let presentation: ModalPresentation
        let root: AppRootEnvironment
        let screen: RouterScreen
    }

    weak var anchor: UIViewController?
    var request: Request?
    var onDismiss: (() -> Void)?
    var clearItem: (() -> Void)?

    /// The presented root screen; `hostedScreen` too when it is SwiftUI.
    private var screen: UIViewController?
    private var hostedScreen: HostedScreenController?
    private var presentedID: AnyHashable?
    private var presentedPresentation: ModalPresentation?
    private var presentationCount = 0
    private var presentationScheduled = false
    /// Dismissing to present the same item again with another style.
    private var isRepresenting = false

    /// The screen that owns this slot is gone: the shell drops its whole
    /// layout on an iPad rotation (stack and split swap) and under a server lock.
    /// The modal presents from the window's root, so it would outlive its
    /// screen with callbacks into nothing. Close it the way SwiftUI closed a
    /// sheet with its view. Neither `clearItem` nor `onDismiss` runs, and the
    /// container's late `onDismissed` finds no presenter.
    isolated deinit {
        guard let screen else { return }
        let container = screen.navigationController ?? screen
        guard !container.isBeingDismissed else { return }
        let dismiss = {
            guard !container.isBeingDismissed else { return }
            Router.dismiss(container)
        }
        // Still presenting, or another of the screen's modals above it is
        // closing: dismiss once that transition ends. A coordinator that cannot
        // queue the completion returns false; dismiss now rather than leave the
        // modal up with no owner.
        if let transition = container.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in dismiss() }) {
            return
        }
        dismiss()
    }

    /// What the dialog slot holds and what UIKit has presented, for an E2E to
    /// read when a sheet it expects does not appear.
    #if DEBUG
    var debugSummary: String {
        let request = request.map { "\($0.id)" } ?? "nil"
        let anchorWindow = anchor?.viewIfLoaded?.window != nil
        let presented = anchor?.presentedViewController.map { String(describing: type(of: $0)) } ?? "nil"
        return "request=\(request) screen=\(screen.map { String(describing: type(of: $0)) } ?? "nil") anchorWindow=\(anchorWindow) presented=\(presented)"
    }
    #endif

    /// A UIKit screen's slot, set from its state in `updateProperties()`: a
    /// non-nil `id` presents `screen`, nil dismisses, and `clear` resets the
    /// screen's state after a swipe-down or the modal's own `finish()`.
    func update(
        id: AnyHashable?,
        presentation: ModalPresentation,
        root: AppRootEnvironment,
        onDismiss: (() -> Void)? = nil,
        clear: @escaping () -> Void,
        screen: () -> RouterScreen
    ) {
        self.onDismiss = onDismiss
        clearItem = clear
        request = id.map { Request(id: $0, presentation: presentation, root: root, screen: screen()) }
        sync()
    }

    func sync() {
        if let screen {
            let container = screen.navigationController ?? screen
            if container.isBeingDismissed { return }
            if let request, request.id == presentedID {
                if let presentedPresentation,
                   !request.presentation.isPresentable(as: presentedPresentation) {
                    // A size class change asked for another style, such as
                    // a document viewer moving between the page sheet and
                    // the full-window cover. UIKit cannot restyle a
                    // presented controller, so present the item again.
                    isRepresenting = true
                    Router.dismiss(container)
                    return
                }
                if let sheet = container.sheetPresentationController,
                   let presentedPresentation,
                   !request.presentation.hasSheetChrome(of: presentedPresentation) {
                    sheet.animateChanges {
                        if !request.presentation.detents.isEmpty {
                            sheet.detents = request.presentation.detents
                        }
                        sheet.prefersGrabberVisible = request.presentation.prefersGrabberVisible
                    }
                    self.presentedPresentation = request.presentation
                }
                // The presenter re-rendered (it is still in the window under
                // sheets and popovers): refresh the content it builds.
                switch request.screen {
                case .hosted(let makeContent):
                    hostedScreen?.setContent(makeContent)
                case .controller(_, let update):
                    update?(screen)
                }
                return
            }
            // Cleared, or replaced by another item: dismiss first. The
            // replacement presents from `screenDidDismiss` once UIKit is done.
            Router.dismiss(container)
            return
        }
        guard request != nil, anchor?.viewIfLoaded?.window != nil, !presentationScheduled else { return }
        // Present after the presenter's SwiftUI update, not inside it:
        // `sync()` runs from the anchor's `updateUIViewController`, and a
        // hosting controller created during that update joined the
        // presenter's graph, and its title and bar items moved into the
        // presenter's bar while its own bar stayed empty.
        presentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.presentRequest()
        }
    }

    private func presentRequest() {
        guard screen == nil, let request, let anchor, anchor.viewIfLoaded?.window != nil else { return }
        presentationCount += 1
        let count = presentationCount
        let onDismiss = { [weak self] in
            // Only the presentation on screen: a late callback from an
            // earlier one must not clear a newer item.
            guard let self, count == self.presentationCount, self.screen != nil else { return }
            self.screenDidDismiss()
        }
        switch request.screen {
        case .hosted(let makeContent):
            let hosted = Router.present(
                root: request.root,
                presentation: request.presentation,
                from: anchor,
                sourceView: anchor.view,
                onDismiss: onDismiss,
                content: makeContent
            )
            screen = hosted
            hostedScreen = hosted
        case .controller(let makeController, _):
            let controller = makeController()
            screen = controller
            Router.present(
                controller,
                presentation: request.presentation,
                from: anchor,
                sourceView: anchor.view,
                theme: request.root.themeStore,
                onDismiss: onDismiss
            )
        }
        presentedID = request.id
        presentedPresentation = request.presentation
    }

    private func screenDidDismiss() {
        let dismissedID = presentedID
        let representing = isRepresenting
        isRepresenting = false
        screen = nil
        hostedScreen = nil
        presentedID = nil
        presentedPresentation = nil
        if !representing {
            // Swipe-down and the content's own finish() leave the binding set.
            if request?.id == dismissedID {
                request = nil
                clearItem?()
            }
            onDismiss?()
        }
        sync()
    }
}
