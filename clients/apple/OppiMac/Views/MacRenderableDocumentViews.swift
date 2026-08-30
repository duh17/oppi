import AppKit
import CoreGraphics
import SwiftUI

struct MacOrgDocumentPreview: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Org", systemImage: "doc.richtext")
                .font(.caption)
                .fontWeight(.semibold)
            MacAttributedDocumentTextView(attributedText: Self.render(content))
                .frame(minHeight: 120, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private static func render(_ content: String) -> NSAttributedString {
        let document = OrgParser().parse(content)
        let configuration = RenderConfiguration(
            fontSize: 13,
            maxWidth: 700,
            theme: .fallback,
            displayMode: .inline
        )
        return OrgAttributedStringRenderer().renderAttributedString(document, configuration: configuration)
    }
}

/// Rasterizes Shared graphical layouts (Mermaid, LaTeX) to a bitmap.
///
/// Layout coordinates are UIKit Y-down. The bitmap context is flipped to match
/// before `GraphicalDocumentRenderer.draw`.
enum MacGraphicalDocumentRaster: Sendable {
    struct Bitmap: @unchecked Sendable {
        let cgImage: CGImage
        let size: CGSize

        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: size)
        }
    }

    nonisolated static func mermaid(
        code: String,
        maxWidth: CGFloat,
        theme: RenderTheme
    ) -> Bitmap? {
        let parser = MermaidParser()
        let renderer = MermaidRenderer()
        let document = parser.parse(code)
        let configuration = RenderConfiguration(
            fontSize: 13,
            maxWidth: maxWidth,
            theme: theme,
            displayMode: .inline
        )
        let layout = renderer.layout(document, configuration: configuration)
        let size = renderer.boundingBox(layout)
        return image(size: size) { context, origin in
            renderer.draw(layout, in: context, at: origin)
        }
    }

    nonisolated static func latex(
        code: String,
        maxWidth: CGFloat,
        theme: RenderTheme,
        fontSize: CGFloat
    ) -> Bitmap? {
        let parsed = TeXMathParser().parseValidated(code)
        guard parsed.isRenderable else { return nil }
        let renderer = MathCoreGraphicsRenderer()
        let configuration = RenderConfiguration(
            fontSize: fontSize,
            maxWidth: maxWidth,
            theme: theme,
            displayMode: .document
        )
        let layout = renderer.layout(parsed.nodes, configuration: configuration)
        let size = renderer.boundingBox(layout)
        return image(size: size) { context, origin in
            renderer.draw(layout, in: context, at: origin)
        }
    }

    nonisolated static func image(
        size: CGSize,
        scale: CGFloat = 2,
        draw: (CGContext, CGPoint) -> Void
    ) -> Bitmap? {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        let pixelWidth = max(1, Int(ceil(size.width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        draw(context, .zero)
        guard let cgImage = context.makeImage() else { return nil }
        return Bitmap(cgImage: cgImage, size: size)
    }
}

private struct MacAttributedDocumentTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedText)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }
}
