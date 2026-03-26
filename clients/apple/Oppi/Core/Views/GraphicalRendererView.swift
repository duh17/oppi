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
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize { contentSize }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawBlock?(ctx, .zero)
    }
}

/// SwiftUI wrapper for `GraphicalRendererUIView`.
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
