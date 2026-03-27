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

    func configure(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        contentSize = size
        drawBlock = draw
        backgroundColor = .clear
        isOpaque = false
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

/// UIScrollView wrapper that adds pinch-to-zoom and panning to a
/// `GraphicalRendererUIView`. Used for diagrams and LaTeX math.
final class ZoomableGraphicalView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let contentView = GraphicalRendererUIView()
    private var contentWidthConstraint: NSLayoutConstraint?
    private var contentHeightConstraint: NSLayoutConstraint?

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

    override func layoutSubviews() {
        super.layoutSubviews()
        fitContentIfNeeded()
    }

    /// Scale down to fit width if content is wider than the view, otherwise show at 1x.
    private func fitContentIfNeeded() {
        guard let widthC = contentWidthConstraint,
              bounds.width > 0, widthC.constant > 0 else { return }
        let fitScale = min(1.0, bounds.width / widthC.constant)
        if abs(scrollView.zoomScale - fitScale) > 0.01 {
            scrollView.zoomScale = fitScale
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }
}

// MARK: - SwiftUI Wrappers

/// SwiftUI wrapper for the basic (non-zoomable) graphical view.
struct GraphicalRendererSwiftUIView: UIViewRepresentable {
    let size: CGSize
    let drawBlock: (CGContext, CGPoint) -> Void

    func makeUIView(context: Context) -> GraphicalRendererUIView {
        let view = GraphicalRendererUIView()
        view.configure(size: size, draw: drawBlock)
        return view
    }

    func updateUIView(_ view: GraphicalRendererUIView, context: Context) {
        view.configure(size: size, draw: drawBlock)
    }
}

/// SwiftUI wrapper for zoomable graphical rendering (diagrams, math).
struct ZoomableGraphicalSwiftUIView: UIViewRepresentable {
    let size: CGSize
    let drawBlock: (CGContext, CGPoint) -> Void

    func makeUIView(context: Context) -> ZoomableGraphicalView {
        ZoomableGraphicalView(size: size, draw: drawBlock)
    }

    func updateUIView(_ view: ZoomableGraphicalView, context: Context) {
        // Content is set at init time; no live updates needed.
    }
}
