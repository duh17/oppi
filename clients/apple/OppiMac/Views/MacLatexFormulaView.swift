import AppKit
import SwiftUI

/// Timeline LaTeX / TeX / math fence and display math: Shared `TeXMathParser`
/// + `MathCoreGraphicsRenderer`, not a monospace dump.
struct MacLatexFormulaView: View {
    let code: String
    var isInline: Bool = false

    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var naturalSize: CGSize = .zero
    @State private var didFail = false

    private static let maxBlockHeight: CGFloat = 400
    private static let maxInlineHeight: CGFloat = 72

    var body: some View {
        Group {
            if let image, naturalSize.width > 0, naturalSize.height > 0 {
                ScrollView(.horizontal, showsIndicators: true) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(
                            width: naturalSize.width,
                            height: min(naturalSize.height, maxHeight)
                        )
                }
                .frame(maxHeight: min(naturalSize.height, maxHeight))
                .frame(maxWidth: .infinity, alignment: isInline ? .leading : .center)
                .padding(isInline ? 0 : 8)
                .background(
                    isInline ? Color.clear : theme.bg.highlight,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .accessibilityLabel(code)
                .accessibilityAddTraits(.isImage)
            } else if didFail {
                MacCodeOutputPreview(model: MacCodeOutputModel(language: "latex", text: code))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: isInline ? 24 : 44)
                    .accessibilityLabel("Rendering formula")
            }
        }
        .task(id: renderIdentity) {
            await render()
        }
    }

    private var maxHeight: CGFloat {
        isInline ? Self.maxInlineHeight : Self.maxBlockHeight
    }

    private var renderIdentity: String {
        "\(isInline ? "i" : "b")|" + code + ThemeRuntimeState.currentPalette().renderTheme.renderIdentity
    }

    private func render() async {
        let theme = ThemeRuntimeState.currentPalette().renderTheme
        let fontSize = NSFont.preferredFont(forTextStyle: isInline ? .body : .title1).pointSize
        let source = code
        let bitmap = await Task.detached(priority: .userInitiated) {
            MacGraphicalDocumentRaster.latex(
                code: source,
                maxWidth: 640,
                theme: theme,
                fontSize: fontSize
            )
        }.value
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
