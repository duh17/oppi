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
}
