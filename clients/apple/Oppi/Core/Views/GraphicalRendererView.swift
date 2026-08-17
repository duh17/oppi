import CoreGraphics
import SwiftUI
import UIKit

/// UIView that draws a `GraphicalDocumentRenderer` output via Core Graphics.
///
/// Computes layout once from the parser output, sizes itself to the bounding box,
/// and draws into its `CGContext` on `draw(_:)`.
final class GraphicalRendererUIView: UIView {
    private var drawBlock: ((CGContext, CGPoint) -> Void)?
    private var contentSize: CGSize = .zero

    func configure(
        size: CGSize,
        draw: @escaping (CGContext, CGPoint) -> Void,
        accessibilityLabel: String? = nil
    ) {
        contentSize = size
        drawBlock = draw
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
        accessibilityTraits = accessibilityLabel == nil ? [] : [.image]
        semanticContentAttribute = accessibilityLabel == nil ? .unspecified : .forceLeftToRight
        // Enable high-quality scaling when zoomed.
        contentMode = .redraw
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize { contentSize }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawBlock?(ctx, .zero)
    }
}

// MARK: - Zoomable Scroll Container

/// UIScrollView wrapper that adds pinch-to-zoom, panning, and Photos-style
/// double-tap zoom to a `GraphicalRendererUIView`. Used for diagrams and LaTeX math.
final class ZoomableGraphicalView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let contentView = GraphicalRendererUIView()
    private var contentWidthConstraint: NSLayoutConstraint?
    private var contentHeightConstraint: NSLayoutConstraint?
    private var hasUserAdjustedZoom = false

    init(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        super.init(frame: .zero)
        setup(size: size, draw: draw)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setup(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.25
        scrollView.maximumZoomScale = 4.0
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        DoubleTapZoom.install(on: scrollView, target: self, action: #selector(handleDoubleTap(_:)))

        contentView.configure(size: size, draw: draw)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        let widthC = contentView.widthAnchor.constraint(equalToConstant: max(size.width, 1))
        let heightC = contentView.heightAnchor.constraint(equalToConstant: max(size.height, 1))
        contentWidthConstraint = widthC
        contentHeightConstraint = heightC

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            widthC,
            heightC,
        ])
    }

    /// Update content size and draw block after initial creation.
    ///
    /// Called from `UIViewRepresentable.updateUIView` when SwiftUI
    /// detects property changes. Adjusts constraints and triggers redraw.
    func update(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        contentView.configure(size: size, draw: draw)
        let newWidth = max(size.width, 1)
        let newHeight = max(size.height, 1)
        let sizeChanged = abs((contentWidthConstraint?.constant ?? 0) - newWidth) > 0.5
            || abs((contentHeightConstraint?.constant ?? 0) - newHeight) > 0.5
        contentWidthConstraint?.constant = newWidth
        contentHeightConstraint?.constant = newHeight
        if sizeChanged {
            hasUserAdjustedZoom = false
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFitScaleIfNeeded()
        centerContent()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        toggleZoom(at: gesture.location(in: contentView))
    }

    private func toggleZoom(at pointInContent: CGPoint, animated: Bool? = nil) {
        let fitScale = currentFitScale()
        let zoomingIn = !DoubleTapZoom.isZoomedIn(scale: scrollView.zoomScale, fitScale: fitScale)
        if zoomingIn {
            hasUserAdjustedZoom = true
        }
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: pointInContent,
            fitScale: fitScale,
            animated: animated
        )
        if !zoomingIn {
            hasUserAdjustedZoom = false
        }
    }

    /// Fit to width on first layout and after rotation, but keep a user zoom.
    private func applyFitScaleIfNeeded() {
        let fitScale = currentFitScale()
        guard fitScale > 0 else { return }
        scrollView.minimumZoomScale = fitScale
        if hasUserAdjustedZoom {
            if scrollView.zoomScale < fitScale {
                scrollView.zoomScale = fitScale
            }
            return
        }
        if abs(scrollView.zoomScale - fitScale) > DoubleTapZoom.scaleSlop {
            scrollView.zoomScale = fitScale
        }
    }

    private func currentFitScale() -> CGFloat {
        DoubleTapZoom.fitScale(
            boundsWidth: bounds.width,
            contentWidth: contentWidthConstraint?.constant ?? 0
        )
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        hasUserAdjustedZoom = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        hasUserAdjustedZoom = DoubleTapZoom.isZoomedIn(scale: scale, fitScale: currentFitScale())
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    /// Center content on either axis when it is smaller than the viewport.
    private func centerContent() {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

#if DEBUG
    var debugZoomScaleForTesting: CGFloat { scrollView.zoomScale }
    var debugFitScaleForTesting: CGFloat { currentFitScale() }
    var debugDoubleTapRecognizerCountForTesting: Int {
        (scrollView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 2 }
            .count
    }
    var debugSingleTapRecognizerCountForTesting: Int {
        (scrollView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 1 }
            .count
    }

    func debugToggleZoomForTesting(at pointInContent: CGPoint) {
        toggleZoom(at: pointInContent, animated: false)
    }
#endif
}
