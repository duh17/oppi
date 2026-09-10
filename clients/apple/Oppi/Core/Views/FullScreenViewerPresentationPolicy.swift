import UIKit

@MainActor
enum FullScreenViewerPresentationPolicy {
    static func prefersFullScreenOverlay(for traitCollection: UITraitCollection) -> Bool {
        traitCollection.horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    static func configureLargePresentation(
        _ controller: UIViewController,
        traitCollection: UITraitCollection
    ) {
        if prefersFullScreenOverlay(for: traitCollection) {
            controller.modalPresentationStyle = .overFullScreen
            controller.modalTransitionStyle = .coverVertical
            return
        }

        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    /// Presented document overlay that would hide workspace `NavigationStack`
    /// pushes. Walks the presented chain only. The overlay is a
    /// ``FullScreenCodeViewController`` or a presented host (SwiftUI
    /// sheet/fullScreenCover) that contains one in its children or navigation
    /// stack. Embedded pushed viewers are not selected.
    static func coveringPresentedDocumentOverlay(
        from root: UIViewController
    ) -> UIViewController? {
        var current: UIViewController? = root.presentedViewController
        while let presented = current {
            if containsFullScreenCodeViewer(presented) {
                return presented
            }
            current = presented.presentedViewController
        }
        return nil
    }

    /// Dismiss the covering document overlay, then run `navigate` if
    /// `shouldNavigate` is still true. Session and file resource opens share
    /// this seam so a wiki/file/session tap cannot push under a modal reader.
    static func dismissCoveringOverlayThenNavigate(
        from root: UIViewController? = nil,
        animated: Bool = true,
        shouldNavigate: () -> Bool = { true },
        navigate: () -> Void
    ) async {
        await dismissCoveringPresentedDocumentOverlay(from: root, animated: animated)
        guard shouldNavigate() else { return }
        navigate()
    }

    private static func containsFullScreenCodeViewer(_ controller: UIViewController) -> Bool {
        if controller is FullScreenCodeViewController {
            return true
        }
        if let navigation = controller as? UINavigationController {
            if navigation.viewControllers.contains(where: containsFullScreenCodeViewer) {
                return true
            }
        }
        return controller.children.contains(where: containsFullScreenCodeViewer)
    }

    private static func dismissCoveringPresentedDocumentOverlay(
        from root: UIViewController?,
        animated: Bool
    ) async {
        let rootController = root ?? keyWindowRootViewController()
        guard let rootController,
              let overlay = coveringPresentedDocumentOverlay(from: rootController),
              let presenter = overlay.presentingViewController else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            presenter.dismiss(animated: animated) {
                continuation.resume()
            }
        }
    }

    private static func keyWindowRootViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return nil
        }
        return root
    }
}
