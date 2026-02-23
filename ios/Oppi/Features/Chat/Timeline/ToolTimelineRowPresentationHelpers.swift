import UIKit

@MainActor
enum ToolTimelineRowPresentationHelpers {
    static func animateInPlaceReveal(_ view: UIView, shouldAnimate: Bool) {
        guard shouldAnimate else {
            resetRevealAppearance(view)
            return
        }

        view.layer.removeAnimation(forKey: "tool.reveal")
        // Keep reveal almost imperceptible: tiny in-place opacity settle only.
        view.alpha = 0.97

        UIView.animate(
            withDuration: ToolRowExpansionAnimation.contentRevealDuration,
            delay: ToolRowExpansionAnimation.contentRevealDelay,
            options: [.allowUserInteraction, .curveLinear, .beginFromCurrentState]
        ) {
            // Pure in-place fade (no transform/translation), so panels feel
            // like they open within the row rather than slide in.
            view.alpha = 1
        }
    }

    static func resetRevealAppearance(_ view: UIView) {
        view.layer.removeAnimation(forKey: "tool.reveal")
        view.alpha = 1
    }

    static func presentFullScreenContent(_ content: FullScreenCodeContent, from sourceView: UIView) {
        guard let presenter = nearestViewController(from: sourceView) else {
            return
        }

        let controller = FullScreenCodeViewController(content: content)
        // Use .overFullScreen to keep the presenting VC in the window hierarchy.
        // .fullScreen removes the presenter's view, which triggers SwiftUI
        // onDisappear/onAppear on the ChatView — causing a full session
        // disconnect + reconnect cycle and potential session routing bugs.
        controller.modalPresentationStyle = .overFullScreen
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

    static func presentFullScreenImage(_ image: UIImage, from sourceView: UIView) {
        guard let presenter = nearestViewController(from: sourceView) else { return }

        let controller = FullScreenImageViewController(image: image)
        // Use .overFullScreen — see presentFullScreenContent() comment.
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: true)
    }

    static func nearestViewController(from sourceView: UIView) -> UIViewController? {
        var responder: UIResponder? = sourceView
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionView and
    /// invalidate its layout so self-sizing cells get re-measured.
    static func invalidateEnclosingCollectionViewLayout(startingAt sourceView: UIView) {
        var view: UIView? = sourceView.superview
        while let current = view {
            if let collectionView = current as? UICollectionView {
                UIView.performWithoutAnimation {
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                }
                return
            }
            view = current.superview
        }
    }
}
