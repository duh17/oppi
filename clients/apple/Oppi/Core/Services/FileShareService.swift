import CoreGraphics
import UIKit
import WebKit

// MARK: - FileShareService

/// Converts file content into shareable formats (image, PDF, source file).
///
/// **Design doc**: `.internal/designs/share-sheet.md`
/// **Architecture**: `docs/ARCHITECTURE.md` → "Share / export system"
///
/// All rendering knobs are in the "Export Configuration" section below.
/// Three render dispatchers (`renderImage`, `renderPDF`, `renderSource`)
/// route each content type to its renderer. Three format selectors
/// (`availableFormats`, `defaultFormat`, `formatDisplayInfo`) control
/// what the user sees in the share picker.
///
/// Rendering strategies:
/// - **CGContext draw** for Mermaid/LaTeX (via DocumentRenderPipeline)
/// - **NSAttributedString.draw()** for Code/JSON/Plain (syntax-highlighted)
/// - **UIView snapshot** for Markdown/Org (AssistantMarkdownContentView)
/// - **WKWebView** for HTML (pdf() or takeSnapshot())
/// - **Pass-through** for image data / PDF data
@MainActor
enum FileShareService {

    // MARK: - Export Configuration
    //
    // All rendering knobs live here. Change these to adjust share output quality.

    /// Image export scale factor. @3x guarantees crisp output on all displays
    /// and produces consistent results regardless of sim vs device.
    /// Cost: 3x point dimensions → e.g. 800pt wide = 2400px. ~200–400KB PNG typical.
    private static let imageScale: CGFloat = 3.0

    /// Layout width for text-based exports (markdown, code, HTML).
    /// This is the point-width of the "page" — content is laid out to fit.
    private static let textLayoutWidth: CGFloat = 800

    /// Minimum image width for graphical exports (mermaid, latex).
    /// Prevents narrow diagrams from looking tiny when shared.
    private static let graphicalMinWidth: CGFloat = 600

    /// Font size for graphical renderers (mermaid, latex) in export.
    private static let graphicalFontSize: CGFloat = 20

    /// Font size for code/JSON/plaintext PDF export.
    private static let codePDFFontSize: CGFloat = 14

    /// Padding around content in image/PDF exports.
    private static let exportPadding: CGFloat = 40

    /// Padding around code content in PDF exports.
    private static let codePDFPadding: CGFloat = 24

    /// Maximum image height before clamping (prevents OOM on huge files).
    private static let maxImageHeight: CGFloat = 8000

    /// Maximum HTML snapshot height.
    private static let maxHTMLHeight: CGFloat = 16000

    // MARK: - Types

    /// Content that can be shared. Maps from FullScreenCodeContent.
    enum ShareableContent {
        case mermaid(String)
        case latex(String)
        case markdown(String)
        case orgMode(String)
        case code(String, language: String?)
        case html(String)
        case json(String)
        case plainText(String)
        case imageData(Data, filename: String)
        case pdfData(Data, filename: String)

        /// Build shareable content from raw text and a file path.
        ///
        /// Detects the file type from the path and maps to the appropriate
        /// content case. Used by hosting views (file browser, touched-file
        /// viewer, review detail) to create share content for the toolbar.
        static func fromText(_ text: String, filePath: String?) -> ShareableContent {
            let fileType = FileType.detect(from: filePath, content: text)
            switch fileType {
            case .markdown: return .markdown(text)
            case .html: return .html(text)
            case .json: return .json(text)
            case .latex: return .latex(text)
            case .orgMode: return .orgMode(text)
            case .mermaid: return .mermaid(text)
            case .graphviz: return .code(text, language: "dot")
            case .code(let lang): return .code(text, language: lang.displayName)
            case .plain: return .plainText(text)
            default: return .plainText(text)
            }
        }
    }

    /// Output format for sharing.
    enum ExportFormat: Equatable, Hashable {
        case image   // PNG via UIActivityViewController
        case pdf     // PDF document
        case source  // Raw source file
    }

    /// Shareable item ready for UIActivityViewController.
    enum ShareItem {
        case image(UIImage)
        case pdf(Data, filename: String)
        case file(URL)

        var activityItems: [Any] {
            switch self {
            case .image(let image):
                return [image]
            case .pdf(let data, let filename):
                return [SharePDFDataProvider(data: data, filename: filename)]
            case .file(let url):
                return [url]
            }
        }
    }

    // MARK: - Format Selection

    /// Smart default export format for each content type.
    static func defaultFormat(for content: ShareableContent) -> ExportFormat {
        switch content {
        case .html:
            // HTML uses PDF via WKWebView.pdf(configuration:) — the native API
            // produces selectable text and proper layout. Canvas elements are
            // converted to static images before capture (see renderHTMLToPDF).
            return .pdf
        case .mermaid, .latex, .markdown, .orgMode, .code, .json:
            return .pdf
        case .plainText:
            return .source
        case .imageData:
            return .image
        case .pdfData:
            return .pdf
        }
    }

    /// Display info for an export format in the context of specific content.
    ///
    /// Returns a user-facing label and SF Symbol name. Used by both
    /// ``FileShareButton`` (SwiftUI) and ``FullScreenCodeViewController`` (UIKit)
    /// so format picker labels stay consistent across surfaces.
    static func formatDisplayInfo(
        _ format: ExportFormat,
        for content: ShareableContent?
    ) -> (label: String, icon: String) {
        switch format {
        case .image:
            return ("Image", "photo")
        case .pdf:
            return ("PDF", "doc.richtext")
        case .source:
            return (sourceFormatLabel(for: content), "doc.text")
        }
    }

    /// Content-aware label for the source export option.
    private static func sourceFormatLabel(for content: ShareableContent?) -> String {
        guard let content else { return "Source File" }
        switch content {
        case .markdown: return "Markdown File"
        case .orgMode: return "Org File"
        case .mermaid: return "Mermaid Source"
        case .latex: return "LaTeX Source"
        case .html: return "HTML Source"
        case .json: return "JSON File"
        case .code: return "Source File"
        case .plainText: return "Text File"
        case .imageData: return "Image File"
        case .pdfData: return "PDF File"
        }
    }

    /// Available export formats for a content type.
    static func availableFormats(for content: ShareableContent) -> [ExportFormat] {
        switch content {
        case .mermaid, .latex:
            return [.pdf, .image, .source]
        case .html:
            return [.image, .pdf, .source]
        case .markdown, .orgMode, .code, .json:
            return [.pdf, .image, .source]
        case .plainText:
            return [.source]
        case .imageData:
            return [.image]
        case .pdfData:
            return [.pdf]
        }
    }

    // MARK: - Rendering

    /// Render content using the smart default format.
    static func renderDefault(_ content: ShareableContent) async -> ShareItem {
        let format = defaultFormat(for: content)
        return await render(content, as: format)
    }

    /// Render content to a specific format.
    static func render(_ content: ShareableContent, as format: ExportFormat) async -> ShareItem {
        let startNs = ChatTimelinePerf.timestampNs()
        let result: ShareItem
        switch format {
        case .image:
            result = await renderImage(content)
        case .pdf:
            result = await renderPDF(content)
        case .source:
            result = renderSource(content)
        }
        let durationMs = ChatTimelinePerf.elapsedMs(since: startNs)
        if durationMs >= 1 {
            let formatTag = exportFormatTag(format)
            let contentTag = contentTypeTag(content)
            Task.detached(priority: .utility) {
                await ChatMetricsService.shared.record(
                    metric: .shareExportMs,
                    value: Double(durationMs),
                    unit: .ms,
                    tags: [
                        "format": formatTag,
                        "content_type": contentTag,
                    ]
                )
            }
        }
        return result
    }

    // MARK: - Image Rendering

    private static func renderImage(_ content: ShareableContent) async -> ShareItem {
        let image: UIImage
        switch content {
        case .mermaid(let source):
            image = renderMermaidToImage(source)
        case .latex(let source):
            image = renderLatexToImage(source)
        case .markdown(let source):
            image = renderMarkdownToImage(source)
        case .orgMode(let source):
            image = renderOrgModeToImage(source)
        case .code(let source, let language):
            image = renderCodeToImage(source, language: language)
        case .html(let source):
            image = await renderHTMLToImage(source)
        case .json(let source):
            image = renderCodeToImage(source, language: "json")
        case .plainText(let source):
            image = renderCodeToImage(source, language: nil)
        case .imageData(let data, _):
            image = UIImage(data: data) ?? placeholderImage()
        case .pdfData:
            image = placeholderImage()
        }
        return .image(image)
    }

    // MARK: - CGContext Renderers (Mermaid, LaTeX)

    private static func renderMermaidToImage(_ source: String) -> UIImage {
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidFlowchartRenderer(),
            text: source,
            config: exportConfig
        )
        return DocumentRenderPipeline.renderGraphicalToImage(
            size: layout.size,
            draw: layout.draw,
            backgroundColor: currentBackgroundColor,
            padding: exportPadding,
            minWidth: graphicalMinWidth,
            format: exportImageFormat
        )
    }

    private static func renderLatexToImage(_ source: String) -> UIImage {
        let layout = DocumentRenderPipeline.layoutLatexExpressions(
            text: source, config: exportConfig
        )
        return DocumentRenderPipeline.renderLatexExpressionsToImage(
            layout: layout,
            backgroundColor: currentBackgroundColor,
            padding: exportPadding,
            minWidth: graphicalMinWidth,
            format: exportImageFormat
        )
    }

    // MARK: - Text View Snapshots (Markdown, Org, Code)

    private static func renderMarkdownToImage(_ source: String) -> UIImage {
        let view = AssistantMarkdownContentView()
        view.backgroundColor = currentBackgroundColor
        view.apply(configuration: .init(
            content: source,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: false,
            plainTextFallbackThreshold: nil
        ))
        return snapshotView(view, width: textLayoutWidth, padding: exportPadding, backgroundColor: currentBackgroundColor)
    }

    private static func renderOrgModeToImage(_ source: String) -> UIImage {
        renderMarkdownToImage(DocumentRenderPipeline.orgToMarkdown(source))
    }

    /// Render HTML to a full-page screenshot using WKWebView.
    ///
    /// Briefly attaches an offscreen web view to the window hierarchy so the
    /// GPU renders <canvas> elements (Chart.js, D3, etc.), then takes a
    /// full-height snapshot via takeSnapshot(). Removes the web view after.
    private static func renderHTMLToImage(_ source: String) async -> UIImage {
        let layoutWidth = textLayoutWidth
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: layoutWidth, height: 1),
            configuration: config
        )
        webView.isOpaque = false

        // Attach to window at z=0 (behind all other views) so GPU compositing
        // is active. Can't use isHidden, alpha=0, or off-screen positioning —
        // all three prevent the GPU from rendering, making takeSnapshot black.
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first
        webView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: 1)
        webView.overrideUserInterfaceStyle = .light
        window?.insertSubview(webView, at: 0)

        defer {
            webView.removeFromSuperview()
        }

        // Load HTML
        let loaded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let delegate = PDFNavigationDelegate(continuation: cont)
            webView.navigationDelegate = delegate
            objc_setAssociatedObject(webView, &PDFNavigationDelegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(source, baseURL: nil)
        }

        guard loaded else { return placeholderImage() }

        // Wait for external resources (Chart.js, Leaflet, fonts)
        await waitForContentReady(webView: webView)

        // Measure full content height
        let contentHeight = try? await webView.evaluateJavaScript(
            "document.documentElement.scrollHeight"
        ) as? CGFloat
        let fullHeight = max(contentHeight ?? 600, 100)

        // Cap at reasonable max to avoid memory issues
        let maxHeight = maxHTMLHeight
        let clampedHeight = min(fullHeight, maxHeight)

        // Resize to full content
        webView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: clampedHeight)
        try? await Task.sleep(for: .milliseconds(300))

        // Take full-page snapshot
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(x: 0, y: 0, width: layoutWidth, height: clampedHeight)

        do {
            let snapshot = try await webView.takeSnapshot(configuration: snapshotConfig)
            // Verify the snapshot isn't blank (all-black or all-white).
            // Offscreen WKWebView on iOS 26 can produce empty snapshots
            // when GPU compositing doesn't activate in time.
            if isBlankImage(snapshot) {
                return await rasterizeHTMLViaPDF(source)
            }
            return snapshot
        } catch {
            return await rasterizeHTMLViaPDF(source)
        }
    }

    /// Check if an image is effectively blank (solid color).
    ///
    /// Samples a few pixels to detect all-black or all-white snapshots
    /// from failed WKWebView GPU compositing.
    static func isBlankImage(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              cgImage.width > 10, cgImage.height > 10 else {
            return true
        }

        // Sample center pixel via a 1x1 bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }

        let cx = cgImage.width / 2
        let cy = cgImage.height / 2
        ctx.draw(cgImage, in: CGRect(x: -cx, y: -cy, width: cgImage.width, height: cgImage.height))

        let r = pixel[0], g = pixel[1], b = pixel[2], a = pixel[3]
        // Blank if transparent or near-black or near-white
        if a < 10 { return true }
        if r < 5 && g < 5 && b < 5 { return true }
        if r > 250 && g > 250 && b > 250 { return true }
        return false
    }

    /// Fallback: render HTML to PDF first, then rasterize the first page.
    private static func rasterizeHTMLViaPDF(_ source: String) async -> UIImage {
        let pdfData = await renderHTMLToPDF(source)
        guard !pdfData.isEmpty,
              let provider = CGDataProvider(data: pdfData as CFData),
              let pdfDoc = CGPDFDocument(provider),
              let page = pdfDoc.page(at: 1) else {
            return placeholderImage()
        }

        let pageRect = page.getBoxRect(.mediaBox)
        let scale = imageScale
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let cgCtx = ctx.cgContext
            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: scale, y: -scale)
            cgCtx.drawPDFPage(page)
        }
    }

    /// Render code/JSON/plaintext to image using NSAttributedString drawing.
    ///
    /// Bypasses UITextView entirely — no window needed. Uses the same
    /// syntax highlighting as the full-screen viewer.
    private static func renderCodeToImage(_ source: String, language: String?) -> UIImage {
        let palette = ThemeRuntimeState.currentPalette()
        let attrString = buildHighlightedAttributedString(source, language: language, palette: palette)
        let drawWidth = textLayoutWidth - codePDFPadding * 2

        let textRect = attrString.boundingRect(
            with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        let imageSize = CGSize(
            width: textLayoutWidth,
            height: min(ceil(textRect.height) + codePDFPadding * 2, maxImageHeight)
        )

        let renderer = UIGraphicsImageRenderer(size: imageSize, format: exportImageFormat)
        return renderer.image { ctx in
            UIColor(palette.bgDark).setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            attrString.draw(with: CGRect(
                x: codePDFPadding, y: codePDFPadding,
                width: drawWidth, height: textRect.height
            ), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    /// Snapshot a UIView at the given width with padding.
    ///
    /// Used for markdown/org snapshots via AssistantMarkdownContentView
    /// which layout correctly offscreen. Code/JSON use attributed string
    /// drawing instead (see renderCodeToImage).
    private static func snapshotView(
        _ view: UIView,
        width: CGFloat,
        padding: CGFloat,
        backgroundColor: UIColor
    ) -> UIImage {
        let contentWidth = width - padding * 2

        view.translatesAutoresizingMaskIntoConstraints = false
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: contentWidth, height: 10000))
        hostView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            view.topAnchor.constraint(equalTo: hostView.topAnchor),
        ])
        hostView.layoutIfNeeded()

        let contentHeight = view.bounds.height
        guard contentHeight > 0 else { return placeholderImage() }

        let clampedHeight = min(contentHeight, maxImageHeight)

        let imageSize = CGSize(
            width: width,
            height: clampedHeight + padding * 2
        )

        let renderer = UIGraphicsImageRenderer(size: imageSize, format: exportImageFormat)
        return renderer.image { ctx in
            backgroundColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            ctx.cgContext.translateBy(x: padding, y: padding)
            view.layer.render(in: ctx.cgContext)
        }
    }

    // MARK: - PDF Rendering

    private static func renderPDF(_ content: ShareableContent) async -> ShareItem {
        let filename: String
        let pdfData: Data

        switch content {
        case .mermaid(let source):
            filename = "diagram.pdf"
            pdfData = renderMermaidToPDF(source)
        case .latex(let source):
            filename = "formula.pdf"
            pdfData = renderLatexToPDF(source)
        case .html(let source):
            filename = "page.pdf"
            pdfData = await renderHTMLToPDF(source)
        case .pdfData(let data, let name):
            return .pdf(data, filename: name)
        case .markdown(let source):
            filename = "document.pdf"
            pdfData = await renderMarkdownToPDF(source)
        case .orgMode(let source):
            filename = "document.pdf"
            pdfData = await renderMarkdownToPDF(DocumentRenderPipeline.orgToMarkdown(source))
        case .code(let source, let language):
            filename = sourceFilename(for: content, extension: "pdf")
            pdfData = renderCodeToPDF(source, language: language)
        case .json(let source):
            filename = "data.pdf"
            pdfData = renderCodeToPDF(source, language: "json")
        case .plainText(let source):
            filename = "text.pdf"
            pdfData = renderCodeToPDF(source, language: nil)
        case .imageData(let data, _):
            filename = "image.pdf"
            if let image = UIImage(data: data) {
                pdfData = embedImageInPDF(image)
            } else {
                pdfData = Data()
            }
        }

        return .pdf(pdfData, filename: filename)
    }

    private static func renderMermaidToPDF(_ source: String) -> Data {
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidFlowchartRenderer(),
            text: source,
            config: exportConfig
        )
        return DocumentRenderPipeline.renderGraphicalToPDF(
            size: layout.size,
            draw: layout.draw,
            backgroundColor: currentBackgroundColor
        )
    }

    private static func renderLatexToPDF(_ source: String) -> Data {
        let layout = DocumentRenderPipeline.layoutLatexExpressions(
            text: source, config: exportConfig
        )
        return DocumentRenderPipeline.renderLatexExpressionsToPDF(
            layout: layout, backgroundColor: currentBackgroundColor
        )
    }

    /// Render code/JSON/plaintext to PDF using NSAttributedString drawing.
    ///
    /// Bypasses UITextView — no window needed. Uses the same syntax highlighting
    /// as the full-screen viewer. Font size from `codePDFFontSize`.
    private static func renderCodeToPDF(_ source: String, language: String?) -> Data {
        let palette = ThemeRuntimeState.currentPalette()
        let attrString = buildHighlightedAttributedString(source, language: language, palette: palette)
        let drawWidth = textLayoutWidth - codePDFPadding * 2

        let textRect = attrString.boundingRect(
            with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let pageHeight = ceil(textRect.height) + codePDFPadding * 2
        let pageSize = CGSize(width: textLayoutWidth, height: pageHeight)

        let pdfRenderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize)
        )
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            UIColor(palette.bgDark).setFill()
            UIRectFill(CGRect(origin: .zero, size: pageSize))
            attrString.draw(with: CGRect(
                x: codePDFPadding, y: codePDFPadding,
                width: drawWidth, height: textRect.height
            ), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    /// Build a syntax-highlighted NSAttributedString for code export.
    /// Shared between image and PDF code renderers.
    private static func buildHighlightedAttributedString(
        _ source: String,
        language: String?,
        palette: ThemePalette
    ) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: codePDFFontSize, weight: .regular)
        let syntaxLang = language.map { SyntaxLanguage.detect($0) }
        if let syntaxLang, syntaxLang != .unknown {
            return FullScreenCodeHighlighter.buildHighlightedText(source, language: syntaxLang)
        }
        return NSAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: UIColor(palette.fg),
            ]
        )
    }

    /// Render markdown to PDF by snapshotting AssistantMarkdownContentView.
    ///
    /// AssistantMarkdownContentView layouts correctly offscreen (unlike code views
    /// which need NSTextLayoutManager + window). Creates the view, snapshots to image,
    /// then embeds in PDF for proper page sizing.
    private static func renderMarkdownToPDF(_ source: String) async -> Data {
        let image = renderMarkdownToImage(source)
        // If markdown image is valid, embed it. Otherwise return empty.
        guard image.size.width > 10, image.size.height > 10 else { return Data() }
        return embedImageInPDF(image)
    }

    /// Render HTML to PDF using an offscreen WKWebView.
    ///
    /// Creates a temporary web view, loads the HTML, waits for all resources
    /// (CDN scripts, fonts, images) to load and JavaScript to execute, then
    /// uses `WKWebView.pdf(configuration:)` for a native PDF export with
    /// selectable text and proper layout. Chart.js canvases are converted
    /// to static images before capture to survive PDF rendering.
    private static func renderHTMLToPDF(_ source: String) async -> Data {
        let layoutWidth = textLayoutWidth
        let config = WKWebViewConfiguration()
        // Ephemeral data store — no persistent cookies/cache from export renders.
        // CDN fetches still work, just without disk cache (fine for one-shot export).
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: layoutWidth, height: 1),
            configuration: config
        )
        webView.isOpaque = false

        // Load HTML and wait for navigation to complete
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = PDFNavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            objc_setAssociatedObject(webView, &PDFNavigationDelegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(source, baseURL: nil)
        }

        guard loaded else { return Data() }

        // Wait for external resources (Chart.js, Leaflet, fonts) to load
        // and JavaScript to execute. Poll document.readyState + check for
        // Chart.js canvases that need time to animate and render.
        await waitForContentReady(webView: webView)

        // Offscreen WKWebView doesn't trigger GPU canvas rendering, so
        // Chart.js canvases are blank despite JS executing. Use Chart.js's
        // toBase64Image() API which reads from the internal render state,
        // then replace canvases with static <img> tags for PDF capture.
        try? await webView.evaluateJavaScript("""
            (function() {
                if (!window.Chart || !Chart.instances) return;
                var keys = Object.keys(Chart.instances);
                keys.forEach(function(k) {
                    var chart = Chart.instances[k];
                    // Disable animation and force a synchronous internal render
                    chart.options.animation = false;
                    chart.resize();
                    chart.update('none');

                    // Use Chart.js API to get rendered image
                    var dataURL = chart.toBase64Image('image/png', 1);
                    if (!dataURL || dataURL === 'data:,') return;

                    var canvas = chart.canvas;
                    var img = document.createElement('img');
                    img.src = dataURL;
                    img.style.width = canvas.offsetWidth + 'px';
                    img.style.height = canvas.offsetHeight + 'px';
                    img.style.display = 'block';
                    if (canvas.parentNode) {
                        canvas.parentNode.replaceChild(img, canvas);
                    }
                });

                // Also handle any non-Chart.js canvases (e.g. Leaflet)
                document.querySelectorAll('canvas').forEach(function(canvas) {
                    try {
                        var dataURL = canvas.toDataURL('image/png');
                        if (!dataURL || dataURL === 'data:,') return;
                        var img = document.createElement('img');
                        img.src = dataURL;
                        img.style.width = canvas.offsetWidth + 'px';
                        img.style.height = canvas.offsetHeight + 'px';
                        img.style.display = 'block';
                        canvas.parentNode.replaceChild(img, canvas);
                    } catch(e) {}
                });
            })();
        """)

        // Let canvas-to-image swap settle
        try? await Task.sleep(for: .milliseconds(100))

        // Measure full content height and resize web view
        let contentHeight = try? await webView.evaluateJavaScript(
            "document.documentElement.scrollHeight"
        ) as? CGFloat
        let fullHeight = max(contentHeight ?? 600, 100)
        webView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: fullHeight)

        try? await Task.sleep(for: .milliseconds(50))

        // Generate PDF — omit rect for auto-pagination of full content
        do {
            return try await webView.pdf(configuration: WKPDFConfiguration())
        } catch {
            let image = renderCodeToImage(source, language: "html")
            return embedImageInPDF(image)
        }
    }

    /// Poll the web view until document and external resources have loaded.
    /// Waits up to 5 seconds for `document.readyState === 'complete'` and
    /// any Chart.js instances to be registered.
    private static func waitForContentReady(webView: WKWebView) async {
        let maxAttempts = 25  // 25 × 200ms = 5 seconds
        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: .milliseconds(200))

            let ready = try? await webView.evaluateJavaScript("""
                (function() {
                    if (document.readyState !== 'complete') return false;
                    // If Chart.js is loaded, wait until instances are created
                    if (typeof Chart !== 'undefined' && Chart.instances) {
                        var keys = Object.keys(Chart.instances);
                        // Charts exist in source but none created yet
                        if (document.querySelectorAll('canvas').length > 0 && keys.length === 0) return false;
                    }
                    return true;
                })();
            """) as? Bool

            if ready == true { return }
        }
    }

    /// Embed a UIImage in a single-page PDF.
    private static func embedImageInPDF(_ image: UIImage) -> Data {
        let imageSize = image.size
        let pdfRenderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: imageSize)
        )
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            image.draw(at: .zero)
        }
    }

    // MARK: - Source File Export

    private static func renderSource(_ content: ShareableContent) -> ShareItem {
        let filename = sourceFilename(for: content, extension: nil)
        switch content {
        case .mermaid(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .latex(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .markdown(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .orgMode(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .code(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .html(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .json(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .plainText(let text):
            return .file(writeTempFile(content: text, filename: filename))
        case .imageData(let data, let name):
            return .file(writeTempData(data: data, filename: name))
        case .pdfData(let data, let name):
            return .file(writeTempData(data: data, filename: name))
        }
    }

    // MARK: - Temp File Management

    private static let tempDirectoryName = "oppi-share"

    private static func writeTempFile(content: String, filename: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(tempDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func writeTempData(data: Data, filename: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(tempDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url)
        return url
    }

    /// Remove all temp files created for sharing. Call from
    /// UIActivityViewController.completionWithItemsHandler.
    static func cleanupTempFiles() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(tempDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private static func sourceFilename(for content: ShareableContent, extension ext: String?) -> String {
        switch content {
        case .mermaid: return "diagram.\(ext ?? "mmd")"
        case .latex: return "formula.\(ext ?? "tex")"
        case .markdown: return "document.\(ext ?? "md")"
        case .orgMode: return "document.\(ext ?? "org")"
        case .code(_, let language):
            let fileExt = ext ?? fileExtension(for: language) ?? "txt"
            return "code.\(fileExt)"
        case .html: return "page.\(ext ?? "html")"
        case .json: return "data.\(ext ?? "json")"
        case .plainText: return "text.\(ext ?? "txt")"
        case .imageData(_, let name): return name
        case .pdfData(_, let name): return name
        }
    }

    private static func fileExtension(for language: String?) -> String? {
        guard let language else { return nil }
        switch language.lowercased() {
        case "swift": return "swift"
        case "python": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "rust": return "rs"
        case "go": return "go"
        case "ruby": return "rb"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "java": return "java"
        case "kotlin": return "kt"
        case "shell", "bash", "sh": return "sh"
        case "html": return "html"
        case "css": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yml"
        case "toml": return "toml"
        case "xml": return "xml"
        case "sql": return "sql"
        case "markdown", "md": return "md"
        case "dot": return "dot"
        case "latex", "tex": return "tex"
        case "mermaid": return "mmd"
        case "org": return "org"
        default: return nil
        }
    }

    private static func exportFormatTag(_ format: ExportFormat) -> String {
        switch format {
        case .image: return "image"
        case .pdf: return "pdf"
        case .source: return "source"
        }
    }

    private static func contentTypeTag(_ content: ShareableContent) -> String {
        switch content {
        case .mermaid: return "mermaid"
        case .latex: return "latex"
        case .markdown: return "markdown"
        case .orgMode: return "org"
        case .code: return "code"
        case .html: return "html"
        case .json: return "json"
        case .plainText: return "text"
        case .imageData: return "image"
        case .pdfData: return "pdf"
        }
    }

    // MARK: - Derived Config (from constants above)

    /// Render config for graphical renderers (mermaid, latex).
    private static var exportConfig: RenderConfiguration {
        RenderConfiguration(
            fontSize: graphicalFontSize,
            maxWidth: textLayoutWidth,
            theme: currentRenderTheme,
            displayMode: .document
        )
    }

    /// Image renderer format at fixed export scale.
    private static var exportImageFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = imageScale
        return format
    }

    /// Current theme's RenderTheme for CGContext renderers.
    private static var currentRenderTheme: RenderTheme {
        let themeID = ThemeRuntimeState.currentThemeID()
        return themeID.preferredColorScheme == .light ? .light : .fallback
    }

    /// Current theme's background color for image/PDF export.
    private static var currentBackgroundColor: UIColor {
        UIColor(ThemeRuntimeState.currentPalette().bgDark)
    }

    private static func placeholderImage() -> UIImage {
        DocumentRenderPipeline.placeholderImage()
    }
}

// MARK: - PDF Navigation Delegate

/// One-shot WKNavigationDelegate that resumes a continuation when loading completes.
private final class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    // swiftlint:disable no_force_unwrap_production
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: true)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(returning: false)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(returning: false)
        continuation = nil
    }
    // swiftlint:enable no_force_unwrap_production
}

// MARK: - PDF Data Provider

/// Provides PDF data to UIActivityViewController with a suggested filename.
final class SharePDFDataProvider: NSObject, UIActivityItemSource {
    private let data: Data
    private let filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        data
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        data
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        "com.adobe.pdf"
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        filename
    }
}
