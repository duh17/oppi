import CoreGraphics
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Double-tap zoom")
struct DoubleTapZoomTests {

    // MARK: - Zoom math

    @Test(arguments: [
        (boundsWidth: 390.0, contentWidth: 1_200.0, expected: 390.0 / 1_200.0),
        (boundsWidth: 390.0, contentWidth: 200.0, expected: 1.0),
        (boundsWidth: 0.0, contentWidth: 1_200.0, expected: 1.0),
        (boundsWidth: 390.0, contentWidth: 0.0, expected: 1.0),
    ])
    func fitScaleMatchesWidthLimitedPhotosFit(
        boundsWidth: CGFloat,
        contentWidth: CGFloat,
        expected: CGFloat
    ) {
        #expect(abs(DoubleTapZoom.fitScale(boundsWidth: boundsWidth, contentWidth: contentWidth) - expected) < 0.0001)
    }

    @Test func scaleJustAboveFitCountsAsZoomedIn() {
        #expect(!DoubleTapZoom.isZoomedIn(scale: 0.40, fitScale: 0.40))
        #expect(!DoubleTapZoom.isZoomedIn(scale: 0.405, fitScale: 0.40))
        #expect(DoubleTapZoom.isZoomedIn(scale: 0.42, fitScale: 0.40))
    }

    @Test func zoomInTargetIsOnePhotosStepFromFitAndClampedToMax() {
        #expect(abs(DoubleTapZoom.targetZoomInScale(fitScale: 0.4, maximumZoomScale: 4) - 1.0) < 0.0001)
        #expect(abs(DoubleTapZoom.targetZoomInScale(fitScale: 1.0, maximumZoomScale: 5) - 2.5) < 0.0001)
        #expect(abs(DoubleTapZoom.targetZoomInScale(fitScale: 1.0, maximumZoomScale: 2.0) - 2.0) < 0.0001)
    }

    @Test func zoomInRectIsCenteredOnTheTap() {
        let rect = DoubleTapZoom.zoomInRect(
            tapInContent: CGPoint(x: 900, y: 80),
            viewport: CGSize(width: 390, height: 700),
            targetScale: 1.0
        )

        #expect(abs(rect.midX - 900) < 0.001)
        #expect(abs(rect.midY - 80) < 0.001)
        #expect(abs(rect.width - 390) < 0.001)
        #expect(abs(rect.height - 700) < 0.001)
    }

    @Test func reducedMotionDisablesTheZoomAnimation() {
        #expect(DoubleTapZoom.shouldAnimate(reduceMotion: false))
        #expect(!DoubleTapZoom.shouldAnimate(reduceMotion: true))
    }

    // MARK: - Diagram viewer

    @Test func diagramStartsAtFitScale() {
        let hosted = makeDiagram()

        #expect(abs(hosted.diagram.debugZoomScaleForTesting - hosted.diagram.debugFitScaleForTesting) < 0.02)
        #expect(hosted.diagram.debugFitScaleForTesting < 0.5)
    }

    @Test func diagramDoubleTapZoomsInThenBackToFit() {
        let hosted = makeDiagram()
        let fit = hosted.diagram.debugFitScaleForTesting

        hosted.diagram.debugToggleZoomForTesting(at: CGPoint(x: 900, y: 80))
        #expect(hosted.diagram.debugZoomScaleForTesting > fit + 0.05)

        hosted.diagram.debugToggleZoomForTesting(at: CGPoint(x: 900, y: 80))
        #expect(abs(hosted.diagram.debugZoomScaleForTesting - fit) < 0.02)
    }

    @Test func diagramLayoutDoesNotResetAUserZoom() {
        let hosted = makeDiagram()

        hosted.diagram.debugToggleZoomForTesting(at: CGPoint(x: 600, y: 120))
        let zoomed = hosted.diagram.debugZoomScaleForTesting
        #expect(zoomed > hosted.diagram.debugFitScaleForTesting + 0.05)

        hosted.diagram.setNeedsLayout()
        hosted.diagram.layoutIfNeeded()
        #expect(abs(hosted.diagram.debugZoomScaleForTesting - zoomed) < 0.02)
    }

    @Test func diagramUsesDoubleTapNotSingleTapForZoom() {
        let hosted = makeDiagram()

        #expect(hosted.diagram.debugDoubleTapRecognizerCountForTesting == 1)
        #expect(hosted.diagram.debugSingleTapRecognizerCountForTesting == 0)
    }

    // MARK: - Fullscreen image and SVG

    @Test func fullscreenImageDoubleTapZoomsInThenBackToFit() throws {
        let controller = FullScreenImageViewController(image: makeTestImage())
        let hosted = try attachFullscreenViewer(controller)

        #expect(doubleTapRecognizerCount(on: hosted.scrollView) == 1)
        #expect(abs(hosted.scrollView.zoomScale - 1.0) < 0.01)

        controller.debugToggleZoomForTesting(at: CGPoint(x: 80, y: 60))
        #expect(hosted.scrollView.zoomScale > 1.2)

        controller.debugToggleZoomForTesting(at: CGPoint(x: 80, y: 60))
        #expect(abs(hosted.scrollView.zoomScale - 1.0) < 0.02)
    }

    @Test func fullscreenSVGDoubleTapZoomsInThenBackToFit() throws {
        let controller = FullScreenImageDataPreviewViewController(
            data: Self.svgData,
            mimeType: "image/svg+xml",
            title: "Preview"
        )
        let hosted = try attachFullscreenViewer(controller)

        #expect(doubleTapRecognizerCount(on: hosted.scrollView) == 1)
        #expect(abs(hosted.scrollView.zoomScale - 1.0) < 0.01)

        controller.debugToggleZoomForTesting(at: CGPoint(x: 80, y: 60))
        #expect(hosted.scrollView.zoomScale > 1.2)

        controller.debugToggleZoomForTesting(at: CGPoint(x: 80, y: 60))
        #expect(abs(hosted.scrollView.zoomScale - 1.0) < 0.02)
    }

    // MARK: - Fixtures

    private struct HostedDiagram {
        let host: UIView
        let diagram: ZoomableGraphicalView
    }

    private struct HostedViewer {
        let window: UIWindow
        let scrollView: UIScrollView
    }

    private func makeDiagram() -> HostedDiagram {
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        let diagram = ZoomableGraphicalView(size: CGSize(width: 1_200, height: 400)) { _, _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        diagram.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(diagram)
        NSLayoutConstraint.activate([
            diagram.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            diagram.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            diagram.topAnchor.constraint(equalTo: host.topAnchor),
            diagram.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return HostedDiagram(host: host, diagram: diagram)
    }

    private func attachFullscreenViewer(_ controller: UIViewController) throws -> HostedViewer {
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let scrollView = try #require(
            timelineAllViews(in: controller.view)
                .compactMap { $0 as? UIScrollView }
                .first { $0.maximumZoomScale > 1 }
        )
        return HostedViewer(window: window, scrollView: scrollView)
    }

    private func doubleTapRecognizerCount(on view: UIView) -> Int {
        (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 2 }
            .count
    }

    private func makeTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120))
        return renderer.image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
    }

    private static let svgData = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" width="320" height="180">
      <rect width="320" height="180" fill="#111827"/>
    </svg>
    """.utf8)
}
