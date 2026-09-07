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
    private var naturalSize: CGSize = .zero
    private var hasUserAdjustedZoom = false
    private let readingScale: CGFloat?
    private var needsInitialReadingScale: Bool
    private let zoomControl = UISegmentedControl(items: ["Fit", "Readable"])

    /// Reading scale is a viewport preference, never a second graph layout.
    /// Omit it for other graphical documents that do not need diagram controls.
    init(size: CGSize, readingScale: CGFloat? = nil, draw: @escaping (CGContext, CGPoint) -> Void) {
        self.readingScale = readingScale
        needsInitialReadingScale = readingScale.map { abs($0 - 1) > 0.01 } ?? false
        super.init(frame: .zero)
        setup(size: size, draw: draw)
        if readingScale != nil {
            zoomControl.accessibilityIdentifier = "diagram.zoom"
            zoomControl.selectedSegmentIndex = 0
            zoomControl.backgroundColor = .secondarySystemBackground
            zoomControl.addTarget(self, action: #selector(selectZoom), for: .valueChanged)
            zoomControl.translatesAutoresizingMaskIntoConstraints = false
            addSubview(zoomControl)
            NSLayoutConstraint.activate([
                zoomControl.centerXAnchor.constraint(equalTo: centerXAnchor),
                zoomControl.bottomAnchor.constraint(
                    equalTo: safeAreaLayoutGuide.bottomAnchor,
                    constant: -(FullScreenFloatingControlChrome.bottomPadding
                        + (FullScreenFloatingControlChrome.controlSize - 44) / 2)
                ),
                zoomControl.widthAnchor.constraint(lessThanOrEqualToConstant: 184),
                zoomControl.widthAnchor.constraint(
                    lessThanOrEqualTo: widthAnchor,
                    constant: -2 * (FullScreenFloatingControlChrome.controlSize
                        + FullScreenFloatingControlChrome.leadingPadding + 8)
                ),
                zoomControl.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
    }

    @objc private func selectZoom() {
        let fit = currentFitScale()
        let target = zoomControl.selectedSegmentIndex == 0
            ? fit : min(scrollView.maximumZoomScale, max(fit, readingScale ?? 1))
        hasUserAdjustedZoom = target > fit + DoubleTapZoom.scaleSlop
        let center = contentView.convert(
            CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), from: scrollView
        )
        scrollView.zoom(to: DoubleTapZoom.zoomInRect(
            tapInContent: center, viewport: scrollView.bounds.size, targetScale: target
        ), animated: UIView.areAnimationsEnabled
            && DoubleTapZoom.shouldAnimate(reduceMotion: UIAccessibility.isReduceMotionEnabled))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setup(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        backgroundColor = .clear

        scrollView.delegate = self
        if readingScale != nil { scrollView.contentInsetAdjustmentBehavior = .never }
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
        // UIScrollView owns the zoom transform. Pinning this canvas to its
        // contentLayoutGuide lets later sheet layouts move the transformed
        // frame a second time. Keep natural geometry explicit instead.
        naturalSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        contentView.frame = CGRect(origin: .zero, size: naturalSize)
        scrollView.addSubview(contentView)
        scrollView.contentSize = naturalSize

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Keep the fit overview clear of the reader's floating chrome.
            // Other graphical viewers retain their existing edge-to-edge viewport.
            scrollView.topAnchor.constraint(
                equalTo: readingScale == nil ? topAnchor : safeAreaLayoutGuide.topAnchor,
                constant: readingScale == nil ? 0
                    : FullScreenFloatingControlChrome.controlSize + FullScreenFloatingControlChrome.leadingPadding
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: readingScale == nil ? bottomAnchor : safeAreaLayoutGuide.bottomAnchor,
                constant: readingScale == nil ? 0
                    : -(FullScreenFloatingControlChrome.bottomPadding + FullScreenFloatingControlChrome.controlSize + 10)
            ),

        ])
    }

    /// Update content size and draw block after initial creation.
    ///
    /// Called from `UIViewRepresentable.updateUIView` when SwiftUI
    /// detects property changes. A theme-only redraw preserves the user zoom.
    func update(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        contentView.configure(size: size, draw: draw)
        let newWidth = max(size.width, 1)
        let newHeight = max(size.height, 1)
        let sizeChanged = abs(naturalSize.width - newWidth) > 0.5
            || abs(naturalSize.height - newHeight) > 0.5
        if sizeChanged {
            scrollView.zoomScale = 1
            naturalSize = CGSize(width: newWidth, height: newHeight)
            contentView.frame = CGRect(origin: .zero, size: naturalSize)
            scrollView.contentSize = naturalSize
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
        if needsInitialReadingScale, scrollView.bounds.width > 0, scrollView.bounds.height > 0 {
            needsInitialReadingScale = false
            scrollView.zoomScale = min(scrollView.maximumZoomScale, max(fitScale, readingScale ?? 1))
            hasUserAdjustedZoom = scrollView.zoomScale > fitScale + DoubleTapZoom.scaleSlop
        }
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
        let widthFit = DoubleTapZoom.fitScale(
            boundsWidth: scrollView.bounds.width,
            contentWidth: naturalSize.width
        )
        guard readingScale != nil, scrollView.bounds.height > 0,
              naturalSize.height > 0 else { return widthFit }
        return min(widthFit, scrollView.bounds.height / naturalSize.height)
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        hasUserAdjustedZoom = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        hasUserAdjustedZoom = DoubleTapZoom.isZoomedIn(scale: scale, fitScale: currentFitScale())
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        let fit = currentFitScale()
        if abs(scrollView.zoomScale - fit) < DoubleTapZoom.scaleSlop {
            zoomControl.selectedSegmentIndex = 0
        } else if abs(scrollView.zoomScale - max(fit, readingScale ?? 1)) < DoubleTapZoom.scaleSlop {
            zoomControl.selectedSegmentIndex = 1
        } else {
            zoomControl.selectedSegmentIndex = UISegmentedControl.noSegment
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    /// Center content on either axis when it is smaller than the viewport.
    private func centerContent() {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        // Anchor the overview after viewport changes instead of preserving a
        // stale offset from the previous zoom or sheet size.
        if readingScale != nil, !hasUserAdjustedZoom,
           abs(scrollView.zoomScale - currentFitScale()) < DoubleTapZoom.scaleSlop {
            scrollView.contentOffset = CGPoint(x: -offsetX, y: -offsetY)
        }
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
