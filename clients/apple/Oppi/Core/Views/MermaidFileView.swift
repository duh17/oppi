import SwiftUI
import UIKit

/// Rendered Mermaid diagram with source toggle.
///
/// All chrome handled by ``RenderableDocumentView``.
struct MermaidFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.themeID) private var themeID
    @State private var customThemeRevision = 0

    var body: some View {
        let _ = customThemeRevision
        let palette = themeID.palette

        RenderableDocumentWrapper(
            config: .mermaid,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .mermaid(content: content, filePath: filePath),
            hostIdentity: MermaidFileDocumentIdentity(
                content: content,
                filePath: filePath,
                usesInlineChrome: presentation.usesInlineChrome
            ),
            renderIdentity: MermaidFileRenderIdentity(themeID: themeID, palette: palette),
            renderPalette: palette,
            renderedViewUpdater: { view in
                guard let graphical = view as? ZoomableGraphicalView else { return false }
                let layout = Self.layout(content: content, palette: palette)
                graphical.update(size: layout.size, draw: layout.draw)
                return true
            },
            renderedViewFactory: {
                let layout = Self.layout(content: content, palette: palette)
                return ZoomableGraphicalView(size: layout.size, draw: layout.draw)
            }
        )
        // Re-importing the active custom theme keeps the same ThemeID. Its
        // UserDefaults write still needs to re-resolve the palette for this
        // already-mounted file view.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            customThemeRevision &+= 1
        }
    }

    private static func layout(
        content: String,
        palette: ThemePalette
    ) -> DocumentRenderPipeline.GraphicalLayout {
        DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: content,
            config: RenderConfiguration(
                fontSize: 14,
                maxWidth: 600,
                theme: palette.renderTheme,
                displayMode: .document
            )
        )
    }
}

struct MermaidFileDocumentIdentity: Hashable {
    let content: String
    let filePath: String?
    let usesInlineChrome: Bool
}

struct MermaidFileRenderIdentity: Hashable {
    let themeID: ThemeID
    let renderThemeIdentity: String
    let surfaceIdentity: String

    init(themeID: ThemeID, palette: ThemePalette) {
        self.themeID = themeID
        renderThemeIdentity = palette.renderTheme.renderIdentity
        surfaceIdentity = Self.identity(of: UIColor(palette.bgHighlight).cgColor)
    }

    private static func identity(of color: CGColor) -> String {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = color.converted(to: colorSpace, intent: .defaultIntent, options: nil),
            let components = converted.components,
            components.count >= 3
        else { return "?" }
        let alpha = components.count > 3 ? components[3] : 1
        return String(
            format: "%.3f,%.3f,%.3f,%.3f",
            components[0], components[1], components[2], alpha
        )
    }
}
