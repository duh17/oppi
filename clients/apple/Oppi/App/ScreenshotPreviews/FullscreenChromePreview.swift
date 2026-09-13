#if DEBUG
import SwiftUI
import UIKit

// MARK: - Fullscreen Chrome Previews

struct FullscreenMermaidChromePreview: View {
    var body: some View {
        FullScreenCodeView(
            content: .mermaid(
                content: """
                flowchart TD
                    Inspect[Inspect diagram] --> Annotate[Annotate]
                    Annotate --> Share[Share]
                """,
                filePath: "flow.mmd"
            )
        )
        .ignoresSafeArea()
        .accessibilityIdentifier("screenshot.ready")
    }
}


struct FullscreenHTMLChromePreview: View {
    var body: some View {
        FullScreenCodeView(
            content: .html(
                content: "<h1>Note</h1><p>Annotate this page.</p>",
                filePath: "note.html"
            )
        )
        .ignoresSafeArea()
        .accessibilityIdentifier("screenshot.ready")
    }
}


struct FullscreenSVGChromePreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
          <rect width="200" height="200" fill="#1a9b9b"/>
          <circle cx="100" cy="100" r="60" fill="white"/>
        </svg>
        """.utf8)
        let viewer = FullScreenImageDataPreviewViewController(
            data: svg,
            mimeType: "image/svg+xml",
            title: "Preview"
        )
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.view.backgroundColor = UIColor(ThemeRuntimeState.currentThemeID().palette.bgDark)
        navigation.view.accessibilityIdentifier = "screenshot.ready"
        return navigation
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}


struct FullscreenImageChromePreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let image = Self.makePreviewImage()
        let viewer = FullScreenImageViewController(image: image)
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.view.backgroundColor = UIColor(ThemeRuntimeState.currentThemeID().palette.bgDark)
        navigation.view.accessibilityIdentifier = "screenshot.ready"
        return navigation
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private static func makePreviewImage() -> UIImage {
        let size = CGSize(width: 800, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 250, y: 150, width: 300, height: 300)).fill()
        }
    }
}
#endif
