import AppKit
import SwiftUI

enum MacMermaidInlineLayout: Sendable {
    static let horizontalCardPadding: CGFloat = 16
    static let maximumRasterWidth: CGFloat = 1_200
    static let rasterWidthSlop: CGFloat = 8

    static func rasterWidth(containerWidth: CGFloat) -> CGFloat? {
        guard containerWidth.isFinite,
              containerWidth > horizontalCardPadding else {
            return nil
        }
        return min(containerWidth - horizontalCardPadding, maximumRasterWidth)
    }

    static func shouldUpdateRasterWidth(current: CGFloat?, candidate: CGFloat) -> Bool {
        guard let current else { return true }
        return abs(current - candidate) > rasterWidthSlop
    }
}

private extension AppTheme {
    var macMermaidRenderTheme: RenderTheme {
        func cgColor(_ color: Color) -> CGColor {
            NSColor(color).usingColorSpace(.sRGB)?.cgColor
                ?? CGColor(gray: 0.5, alpha: 1)
        }

        return RenderTheme(
            foreground: cgColor(text.primary),
            foregroundDim: cgColor(text.secondary),
            background: cgColor(bg.primary),
            backgroundDark: cgColor(bg.secondary),
            comment: cgColor(text.tertiary),
            keyword: cgColor(syntax.keyword),
            string: cgColor(syntax.string),
            number: cgColor(syntax.number),
            function: cgColor(syntax.function),
            type: cgColor(syntax.type),
            link: cgColor(markdown.link),
            heading: cgColor(markdown.heading),
            accentBlue: cgColor(accent.blue),
            accentCyan: cgColor(accent.cyan),
            accentGreen: cgColor(accent.green),
            accentOrange: cgColor(accent.orange),
            accentPurple: cgColor(accent.purple),
            accentRed: cgColor(accent.red),
            accentYellow: cgColor(accent.yellow)
        )
    }
}

/// Timeline mermaid fence: Shared `MermaidParser` + `MermaidRenderer`, not a code listing.
struct MacMermaidDiagramView: View {
    private struct RenderRequest: Equatable, Sendable {
        let code: String
        let rasterWidth: CGFloat
        let renderThemeIdentity: String
    }

    let code: String

    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var naturalSize: CGSize = .zero
    @State private var didFail = false
    @State private var rasterWidth: CGFloat?

    private static let maxInlineHeight: CGFloat = 400

    var body: some View {
        ZStack {
            if let image, naturalSize.width > 0, naturalSize.height > 0 {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(naturalSize.width / naturalSize.height, contentMode: .fit)
                    .frame(maxHeight: Self.maxInlineHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(8)
                    .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Mermaid diagram")
                    .accessibilityAddTraits(.isImage)
            } else if didFail {
                MacCodeOutputPreview(model: MacCodeOutputModel(language: "mermaid", text: code))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .accessibilityLabel("Rendering mermaid diagram")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { containerWidth in
            guard let candidate = MacMermaidInlineLayout.rasterWidth(
                containerWidth: containerWidth
            ), MacMermaidInlineLayout.shouldUpdateRasterWidth(
                current: rasterWidth,
                candidate: candidate
            ) else { return }
            rasterWidth = candidate
        }
        .task(id: renderIdentity) {
            guard let request = renderIdentity else { return }
            await render(request)
        }
    }

    private var renderIdentity: RenderRequest? {
        guard let rasterWidth else { return nil }
        return RenderRequest(
            code: code,
            rasterWidth: rasterWidth,
            renderThemeIdentity: theme.macMermaidRenderTheme.renderIdentity
        )
    }

    private func render(_ request: RenderRequest) async {
        let renderTheme = theme.macMermaidRenderTheme
        let bitmap = await Task.detached(priority: .userInitiated) {
            MacGraphicalDocumentRaster.mermaid(
                code: request.code,
                maxWidth: request.rasterWidth,
                theme: renderTheme
            )
        }.value
        guard !Task.isCancelled, renderIdentity == request else { return }
        if let bitmap {
            image = bitmap.nsImage
            naturalSize = bitmap.size
            didFail = false
        } else {
            image = nil
            didFail = true
        }
    }
}
