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
        guard !isWithinFullScreenModalContext(presenter) else {
            return
        }

        let controller = FullScreenCodeViewController(content: content)
        // .pageSheet keeps the presenting VC in the window hierarchy (unlike
        // .fullScreen which removes it, triggering SwiftUI onDisappear).
        // On iPhone, .pageSheet at .large() detent is visually full-screen
        // and gives free interactive swipe-to-dismiss.
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

    static func presentFullScreenImage(_ image: UIImage, from sourceView: UIView) {
        guard let presenter = nearestViewController(from: sourceView) else { return }
        guard !isWithinFullScreenModalContext(presenter) else { return }

        let controller = FullScreenImageViewController(image: image)
        // .pageSheet — see presentFullScreenContent() comment.
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
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

    private static func isWithinFullScreenModalContext(_ presenter: UIViewController) -> Bool {
        var current: UIViewController? = presenter
        while let node = current {
            if node is FullScreenCodeViewController || node is FullScreenImageViewController {
                return true
            }
            current = node.parent
        }

        var ancestor: UIViewController? = presenter.presentingViewController
        while let node = ancestor {
            if node is FullScreenCodeViewController || node is FullScreenImageViewController {
                return true
            }
            ancestor = node.presentingViewController
        }

        if let presented = presenter.presentedViewController {
            if presented is FullScreenCodeViewController || presented is FullScreenImageViewController {
                return true
            }
            if let nav = presented as? UINavigationController,
               nav.viewControllers.contains(where: { $0 is FullScreenCodeViewController || $0 is FullScreenImageViewController }) {
                return true
            }
        }

        return false
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionView and
    /// invalidate its layout so self-sizing cells get re-measured.
    static func invalidateEnclosingCollectionViewLayout(startingAt sourceView: UIView) {
        var view: UIView? = sourceView.superview
        while let current = view {
            guard let collectionView = current as? UICollectionView else {
                view = current.superview
                continue
            }

            if isUserInteracting(with: collectionView) {
                DispatchQueue.main.async { [weak collectionView] in
                    guard let collectionView else { return }
                    guard !isUserInteracting(with: collectionView) else { return }
                    invalidateCollectionViewLayout(collectionView)
                }
                return
            }

            invalidateCollectionViewLayout(collectionView)
            return
        }
    }

    private static func isUserInteracting(with collectionView: UICollectionView) -> Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    private static func invalidateCollectionViewLayout(_ collectionView: UICollectionView) {
        UIView.performWithoutAnimation {
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }
}
