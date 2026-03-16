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

    static func presentFullScreenContent(
        _ content: FullScreenCodeContent,
        from sourceView: UIView,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSessionId: String? = nil,
        selectedTextSourceLabel: String? = nil,
        fetchFileForRender: FullScreenCodeViewController.FetchFileContent? = nil
    ) {
        guard let presenter = nearestViewController(from: sourceView) else {
            return
        }
        guard !isWithinFullScreenModalContext(presenter) else {
            return
        }

        let controller = FullScreenCodeViewController(
            content: content,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSessionId,
            selectedTextSourceLabel: selectedTextSourceLabel
        )
        controller.fetchFileForRender = fetchFileForRender
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

        let controller = FullScreenImageViewController.makeSlideDownController(image: image)
        presenter.present(controller, animated: true)
    }

    static func presentFullScreenPlot(spec: PlotChartSpec, fallbackText: String?, from sourceView: UIView) {
        guard let presenter = nearestViewController(from: sourceView) else { return }
        guard !isWithinFullScreenModalContext(presenter) else { return }
        guard presenter.presentedViewController == nil else { return }

        let controller = FullScreenPlotViewController(spec: spec, fallbackText: fallbackText)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
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
            if node is FullScreenCodeViewController
                || node is FullScreenImageViewController
                || node is FullScreenPlotViewController {
                return true
            }
            current = node.parent
        }

        var ancestor: UIViewController? = presenter.presentingViewController
        while let node = ancestor {
            if node is FullScreenCodeViewController
                || node is FullScreenImageViewController
                || node is FullScreenPlotViewController {
                return true
            }
            ancestor = node.presentingViewController
        }

        if let presented = presenter.presentedViewController {
            if presented is FullScreenCodeViewController
                || presented is FullScreenImageViewController
                || presented is FullScreenPlotViewController {
                return true
            }
            if let nav = presented as? UINavigationController,
               nav.viewControllers.contains(where: {
                   $0 is FullScreenCodeViewController
                       || $0 is FullScreenImageViewController
                       || $0 is FullScreenPlotViewController
               }) {
                return true
            }
        }

        return false
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionView and
    /// invalidate its layout so self-sizing cells get re-measured.
    ///
    /// Multiple calls targeting the same collection view within a single
    /// runloop tick are coalesced into one `invalidateLayout + layoutIfNeeded`
    /// pass.  This avoids redundant full-layout cascades when several async
    /// blocks (e.g. from `installExpandedEmbeddedView` and the end-of-`apply`
    /// expanding-transition path) land in the same dispatch drain.
    static func invalidateEnclosingCollectionViewLayout(startingAt sourceView: UIView) {
        var view: UIView? = sourceView.superview
        while let current = view {
            guard let collectionView = current as? UICollectionView else {
                view = current.superview
                continue
            }

            if isUserInteracting(with: collectionView) {
                scheduleInvalidationWhenInteractionEnds(for: collectionView)
                return
            }

            scheduleCoalescedInvalidation(for: collectionView)
            return
        }
    }

    // MARK: - Coalesced invalidation

    /// Collection views that already have a coalesced invalidation pending.
    /// Cleared after the async block fires.
    private static var pendingCoalescedInvalidations: Set<ObjectIdentifier> = []

    private static func scheduleCoalescedInvalidation(for collectionView: UICollectionView) {
        let identifier = ObjectIdentifier(collectionView)
        guard pendingCoalescedInvalidations.insert(identifier).inserted else {
            // Already scheduled — this call will be covered by the pending pass.
            return
        }
        DispatchQueue.main.async { [weak collectionView] in
            pendingCoalescedInvalidations.remove(identifier)
            guard let collectionView else { return }
            invalidateCollectionViewLayout(collectionView)
        }
    }

    // MARK: - Interaction-deferred invalidation

    private static var pendingInteractionInvalidations: Set<ObjectIdentifier> = []

    private static func scheduleInvalidationWhenInteractionEnds(for collectionView: UICollectionView) {
        let identifier = ObjectIdentifier(collectionView)
        guard pendingInteractionInvalidations.insert(identifier).inserted else {
            return
        }
        recheckInteractionAndInvalidateWhenIdle(
            collectionView: collectionView,
            identifier: identifier,
            retriesRemaining: 180
        )
    }

    private static func recheckInteractionAndInvalidateWhenIdle(
        collectionView: UICollectionView,
        identifier: ObjectIdentifier,
        retriesRemaining: Int
    ) {
        guard retriesRemaining > 0 else {
            pendingInteractionInvalidations.remove(identifier)
            return
        }

        guard isUserInteracting(with: collectionView) else {
            pendingInteractionInvalidations.remove(identifier)
            invalidateCollectionViewLayout(collectionView)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak collectionView] in
            guard let collectionView else {
                pendingInteractionInvalidations.remove(identifier)
                return
            }
            recheckInteractionAndInvalidateWhenIdle(
                collectionView: collectionView,
                identifier: identifier,
                retriesRemaining: retriesRemaining - 1
            )
        }
    }

    private static func isUserInteracting(with collectionView: UICollectionView) -> Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    private static func invalidateCollectionViewLayout(_ collectionView: UICollectionView) {
        // When an expand/collapse anchor is active, skip the full
        // invalidateLayout(). The snapshot reconfigure + layoutIfNeeded
        // already measured the cell at its correct size. A full
        // invalidateLayout() clears ALL cached cell heights, reverting
        // off-screen cells to .estimated(44pt). This triggers a self-sizing
        // cascade where UIKit re-measures cells one per frame, adjusting
        // contentOffset by ~6pt each time — creating visible drift that
        // the AnchoredCollectionView cannot fully intercept because UIKit
        // applies some offset changes AFTER layoutSubviews() returns.
        // Skip full invalidateLayout() when an anchor is active. The
        // snapshot reconfigure + layoutIfNeeded already measured cells at
        // their correct sizes. A full invalidateLayout() clears ALL cached
        // cell heights, reverting off-screen cells to .estimated(100pt)
        // defaults. This triggers a self-sizing cascade where UIKit
        // re-measures cells one per frame, adjusting contentOffset by
        // ~6pt each time — creating visible drift.
        if let anchoredCV = collectionView as? AnchoredCollectionView,
           anchoredCV.expandCollapseAnchorIP != nil
            || (anchoredCV.isDetachedFromBottom && anchoredCV.detachedAnchorIsActive) {
            return
        }

        UIView.performWithoutAnimation {
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }
}
