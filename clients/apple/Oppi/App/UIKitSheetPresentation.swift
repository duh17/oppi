import SwiftUI
import UIKit

extension View {
    /// A modal sheet that UIKit presents instead of SwiftUI's `.sheet`.
    ///
    /// The presented hosting controller gets the app root services from
    /// `AppRootEnvironment` explicitly, so its content never depends on SwiftUI
    /// bridging the presenter's environment into the sheet. That bridge dropped
    /// `ConnectionCoordinator` for the iOS app on Mac and crashed build 54.
    ///
    /// Same contract as `.sheet(item:onDismiss:content:)`: setting the item
    /// presents, clearing it dismisses, a new id replaces the open sheet, and
    /// `onDismiss` runs after every dismissal, including swipe-down and the
    /// content's own `dismiss()`.
    func uiKitSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        background {
            UIKitSheetAnchor(item: item, onDismiss: onDismiss, sheetContent: content)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Boolean form of `uiKitSheet(item:onDismiss:content:)`.
    func uiKitSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        uiKitSheet(
            item: Binding<UIKitSheetPresentedFlag?>(
                get: { isPresented.wrappedValue ? UIKitSheetPresentedFlag() : nil },
                set: { isPresented.wrappedValue = $0 != nil }
            ),
            onDismiss: onDismiss
        ) { _ in
            content()
        }
    }
}

private struct UIKitSheetPresentedFlag: Identifiable {
    var id: Int { 0 }
}

private struct UIKitSheetAnchor<Item: Identifiable, SheetContent: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent
    @Environment(\.appRootEnvironment) private var root

    func makeCoordinator() -> UIKitSheetPresenter {
        UIKitSheetPresenter()
    }

    func makeUIViewController(context: Context) -> UIKitSheetAnchorController {
        let anchor = UIKitSheetAnchorController()
        anchor.onAttach = { [weak presenter = context.coordinator] in
            presenter?.sync()
        }
        return anchor
    }

    func updateUIViewController(_ anchor: UIKitSheetAnchorController, context: Context) {
        let presenter = context.coordinator
        presenter.anchor = anchor
        presenter.onDismiss = onDismiss
        let binding = $item
        presenter.clearItem = { binding.wrappedValue = nil }
        if let item {
            guard let root else {
                preconditionFailure("uiKitSheet needs appRootEnvironment above its presenter")
            }
            let content = sheetContent
            presenter.request = UIKitSheetPresenter.Request(id: AnyHashable(item.id)) {
                AnyView(content(item).appRootEnvironment(root))
            }
        } else {
            presenter.request = nil
        }
        presenter.sync()
    }

    static func dismantleUIViewController(_ anchor: UIKitSheetAnchorController, coordinator: UIKitSheetPresenter) {
        coordinator.request = nil
        coordinator.sync()
    }
}

/// Zero-size controller that marks where the presenting SwiftUI view lives.
final class UIKitSheetAnchorController: UIViewController {
    var onAttach: (() -> Void)?

    override func loadView() {
        view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAttach?()
    }
}

/// Reconciles one anchor's requested sheet with what UIKit has on screen.
@MainActor
final class UIKitSheetPresenter {
    struct Request {
        let id: AnyHashable
        let makeRootView: () -> AnyView
    }

    weak var anchor: UIViewController?
    var request: Request?
    var onDismiss: (() -> Void)?
    var clearItem: (() -> Void)?

    private var host: UIKitSheetHostingController?
    private var presentedID: AnyHashable?

    func sync() {
        if let host {
            if host.isBeingDismissed { return }
            if let request, request.id == presentedID {
                host.rootView = request.makeRootView()
                return
            }
            // Cleared, or replaced by another item: dismiss first. The
            // replacement presents from `hostDidDismiss` once UIKit is done.
            host.dismiss(animated: true)
            return
        }
        guard let request, let presenter = topPresenter() else { return }

        let controller = UIKitSheetHostingController(rootView: request.makeRootView())
        controller.modalPresentationStyle = .formSheet
        controller.onDismissed = { [weak self, weak controller] in
            guard let self, let controller, controller === self.host else { return }
            self.hostDidDismiss()
        }
        host = controller
        presentedID = request.id
        presenter.present(controller, animated: true)
    }

    private func hostDidDismiss() {
        let dismissedID = presentedID
        host = nil
        presentedID = nil
        // Swipe-down and the content's own dismiss() leave the binding set.
        if request?.id == dismissedID {
            request = nil
            clearItem?()
        }
        onDismiss?()
        sync()
    }

    /// The front-most controller in the anchor's window, the one UIKit lets present.
    private func topPresenter() -> UIViewController? {
        guard let window = anchor?.viewIfLoaded?.window,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

final class UIKitSheetHostingController: UIHostingController<AnyView> {
    var onDismissed: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismissed?()
        }
    }
}
