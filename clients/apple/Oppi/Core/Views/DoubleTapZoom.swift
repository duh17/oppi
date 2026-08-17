import UIKit

/// Photos-style double-tap zoom for diagrams, images, and SVG previews.
///
/// HIG standard gestures: double tap zooms in around the tap, or zooms out
/// when already zoomed. Pinch remains the continuous zoom path. Single tap
/// is left for activating controls.
@MainActor
enum DoubleTapZoom {
    static let magnification: CGFloat = 2.5
    static let scaleSlop: CGFloat = 0.01

    static func fitScale(boundsWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        guard boundsWidth > 0, contentWidth > 0 else { return 1 }
        return min(1, boundsWidth / contentWidth)
    }

    static func isZoomedIn(scale: CGFloat, fitScale: CGFloat) -> Bool {
        scale > fitScale + scaleSlop
    }

    static func targetZoomInScale(fitScale: CGFloat, maximumZoomScale: CGFloat) -> CGFloat {
        min(maximumZoomScale, max(fitScale * magnification, fitScale + scaleSlop))
    }

    static func zoomInRect(
        tapInContent: CGPoint,
        viewport: CGSize,
        targetScale: CGFloat
    ) -> CGRect {
        let safeScale = max(targetScale, scaleSlop)
        let size = CGSize(
            width: viewport.width / safeScale,
            height: viewport.height / safeScale
        )
        return CGRect(
            x: tapInContent.x - size.width / 2,
            y: tapInContent.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func shouldAnimate(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) -> Bool {
        !reduceMotion
    }

    /// - Parameter tapInContent: Location in the zoomed content view.
    static func toggle(
        in scrollView: UIScrollView,
        tapInContent: CGPoint,
        fitScale: CGFloat,
        animated: Bool? = nil
    ) {
        let animate = animated ?? shouldAnimate()
        if isZoomedIn(scale: scrollView.zoomScale, fitScale: fitScale) {
            scrollView.setZoomScale(fitScale, animated: animate)
            return
        }

        let targetScale = targetZoomInScale(
            fitScale: fitScale,
            maximumZoomScale: scrollView.maximumZoomScale
        )
        scrollView.zoom(
            to: zoomInRect(
                tapInContent: tapInContent,
                viewport: scrollView.bounds.size,
                targetScale: targetScale
            ),
            animated: animate
        )
    }

    @discardableResult
    static func install(on view: UIView, target: Any, action: Selector) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(target: target, action: action)
        recognizer.numberOfTapsRequired = 2
        view.addGestureRecognizer(recognizer)
        return recognizer
    }
}
