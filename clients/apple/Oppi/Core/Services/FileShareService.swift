import CoreGraphics
import UIKit
import WebKit

// MARK: - FileShareService

/// Converts file content into shareable formats (image, PDF, source file).
///
/// Renders using the app's current theme. Uses device screen scale for resolution.
///
/// Two rendering strategies:
/// - **CGContext re-render** for Mermaid/LaTeX: fresh render at export quality
/// - **View snapshot** for Markdown/Org/Code: offscreen UIView with current theme palette
@MainActor
enum FileShareService {

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
        case .mermaid, .latex, .markdown, .orgMode, .code, .html, .json:
            return .pdf
        case .plainText:
            return .source
        case .imageData:
            return .image
        case .pdfData:
            return .pdf
        }
    }

    /// Available export formats for a content type.
    static func availableFormats(for content: ShareableContent) -> [ExportFormat] {
        switch content {
        case .mermaid, .latex:
            return [.pdf, .image, .source]
        case .markdown, .orgMode, .code, .html, .json:
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
            result = renderImage(content)
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

    private static func renderImage(_ content: ShareableContent) -> ShareItem {
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
            // HTML falls back to plain code rendering for image export
            image = renderCodeToImage(source, language: "html")
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
        let parser = MermaidParser()
        let renderer = MermaidFlowchartRenderer()
        let diagram = parser.parse(source)
        let config = RenderConfiguration(
            fontSize: 20,
            maxWidth: 800,
            theme: currentRenderTheme,
            displayMode: .document
        )
        let layout = renderer.layout(diagram, configuration: config)
        let contentSize = renderer.boundingBox(layout)

        let padding: CGFloat = 40
        let imageSize = CGSize(
            width: max(contentSize.width + padding * 2, 100),
            height: max(contentSize.height + padding * 2, 100)
        )

        let imageRenderer = UIGraphicsImageRenderer(size: imageSize)
        return imageRenderer.image { ctx in
            currentBackgroundColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            renderer.draw(layout, in: ctx.cgContext, at: CGPoint(x: padding, y: padding))
        }
    }

    private static func renderLatexToImage(_ source: String) -> UIImage {
        let expressions = source
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !expressions.isEmpty else { return placeholderImage() }

        let parser = TeXMathParser()
        let renderer = MathCoreGraphicsRenderer()
        let config = RenderConfiguration(
            fontSize: 20,
            maxWidth: 800,
            theme: currentRenderTheme,
            displayMode: .document
        )

        // Layout all expressions
        var layouts: [(MathCoreGraphicsRenderer.LayoutResult, CGSize)] = []
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        let spacing: CGFloat = 16

        for expr in expressions {
            let nodes = parser.parse(expr)
            let layout = renderer.layout(nodes, configuration: config)
            let size = renderer.boundingBox(layout)
            layouts.append((layout, size))
            totalHeight += size.height
            maxWidth = max(maxWidth, size.width)
        }

        totalHeight += spacing * CGFloat(max(0, layouts.count - 1))

        let padding: CGFloat = 40
        let imageSize = CGSize(
            width: max(maxWidth + padding * 2, 100),
            height: max(totalHeight + padding * 2, 100)
        )

        let imageRenderer = UIGraphicsImageRenderer(size: imageSize)
        return imageRenderer.image { ctx in
            currentBackgroundColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))

            var yOffset = padding
            for (layout, size) in layouts {
                renderer.draw(layout, in: ctx.cgContext, at: CGPoint(x: padding, y: yOffset))
                yOffset += size.height + spacing
            }
        }
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
        return snapshotView(view, width: 800, padding: 40, backgroundColor: currentBackgroundColor)
    }

    private static func renderOrgModeToImage(_ source: String) -> UIImage {
        // Convert org → markdown, then render as markdown
        let parser = OrgParser()
        let orgBlocks = parser.parse(source)
        let mdBlocks = OrgToMarkdownConverter.convert(orgBlocks)
        let markdownText = MarkdownBlockSerializer.serialize(mdBlocks)
        return renderMarkdownToImage(markdownText)
    }

    private static func renderCodeToImage(_ source: String, language: String?) -> UIImage {
        let palette = ThemeRuntimeState.currentPalette()
        let body = NativeFullScreenCodeBody(
            content: source,
            language: language,
            startLine: 1,
            palette: palette,
            alwaysBounceVertical: false,
            selectedTextPiRouter: nil,
            selectedTextSourceContext: nil
        )
        return snapshotView(
            body,
            width: 800,
            padding: 0,
            backgroundColor: UIColor(palette.bgDark)
        )
    }

    /// Snapshot a UIView at the given width with padding.
    private static func snapshotView(
        _ view: UIView,
        width: CGFloat,
        padding: CGFloat,
        backgroundColor: UIColor
    ) -> UIImage {
        let contentWidth = width - padding * 2

        // Size to content
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

        // Cap at a reasonable maximum to avoid massive images
        let maxHeight: CGFloat = 8000
        let clampedHeight = min(contentHeight, maxHeight)

        let imageSize = CGSize(
            width: width,
            height: clampedHeight + padding * 2
        )

        let renderer = UIGraphicsImageRenderer(size: imageSize)
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
        default:
            // For text-based content, render image and embed in PDF
            let imageItem = renderImage(content)
            guard case .image(let image) = imageItem else {
                return .pdf(Data(), filename: "document.pdf")
            }
            filename = sourceFilename(for: content, extension: "pdf")
            pdfData = embedImageInPDF(image)
        }

        return .pdf(pdfData, filename: filename)
    }

    private static func renderMermaidToPDF(_ source: String) -> Data {
        let parser = MermaidParser()
        let renderer = MermaidFlowchartRenderer()
        let diagram = parser.parse(source)
        let config = RenderConfiguration(
            fontSize: 20,
            maxWidth: 800,
            theme: currentRenderTheme,
            displayMode: .document
        )
        let layout = renderer.layout(diagram, configuration: config)
        let contentSize = renderer.boundingBox(layout)

        let padding: CGFloat = 40
        let pageSize = CGSize(
            width: max(contentSize.width + padding * 2, 100),
            height: max(contentSize.height + padding * 2, 100)
        )

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            currentBackgroundColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: pageSize))
            renderer.draw(layout, in: ctx.cgContext, at: CGPoint(x: padding, y: padding))
        }
    }

    private static func renderLatexToPDF(_ source: String) -> Data {
        let expressions = source
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !expressions.isEmpty else { return Data() }

        let parser = TeXMathParser()
        let renderer = MathCoreGraphicsRenderer()
        let config = RenderConfiguration(
            fontSize: 20,
            maxWidth: 800,
            theme: currentRenderTheme,
            displayMode: .document
        )

        var layouts: [(MathCoreGraphicsRenderer.LayoutResult, CGSize)] = []
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        let spacing: CGFloat = 16

        for expr in expressions {
            let nodes = parser.parse(expr)
            let layout = renderer.layout(nodes, configuration: config)
            let size = renderer.boundingBox(layout)
            layouts.append((layout, size))
            totalHeight += size.height
            maxWidth = max(maxWidth, size.width)
        }

        totalHeight += spacing * CGFloat(max(0, layouts.count - 1))

        let padding: CGFloat = 40
        let pageSize = CGSize(
            width: max(maxWidth + padding * 2, 100),
            height: max(totalHeight + padding * 2, 100)
        )

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            currentBackgroundColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: pageSize))

            var yOffset = padding
            for (layout, size) in layouts {
                renderer.draw(layout, in: ctx.cgContext, at: CGPoint(x: padding, y: yOffset))
                yOffset += size.height + spacing
            }
        }
    }

    /// Render HTML to PDF using an offscreen WKWebView.
    ///
    /// Creates a temporary web view, loads the HTML, waits for rendering,
    /// then uses `WKWebView.pdf(configuration:)` for a native PDF export
    /// with selectable text and proper layout.
    private static func renderHTMLToPDF(_ source: String) async -> Data {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.isOpaque = false

        // Load HTML and wait for navigation to complete
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = PDFNavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            // Store delegate to prevent deallocation
            objc_setAssociatedObject(webView, &PDFNavigationDelegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(source, baseURL: nil)
        }

        guard loaded else { return Data() }

        // Brief delay for any async CSS/layout to settle
        try? await Task.sleep(for: .milliseconds(100))

        // Generate PDF
        let pdfConfig = WKPDFConfiguration()
        // Use standard US Letter page size
        pdfConfig.rect = CGRect(x: 0, y: 0, width: 612, height: 792)

        do {
            return try await webView.pdf(configuration: pdfConfig)
        } catch {
            // Fallback: render as code image embedded in PDF
            let image = renderCodeToImage(source, language: "html")
            return embedImageInPDF(image)
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

    /// Current theme's RenderTheme for CGContext renderers.
    /// Maps the app's ThemeID color scheme to the matching RenderTheme.
    private static var currentRenderTheme: RenderTheme {
        let themeID = ThemeRuntimeState.currentThemeID()
        return themeID.preferredColorScheme == .light ? .light : .fallback
    }

    /// Current theme's background color for image export.
    private static var currentBackgroundColor: UIColor {
        UIColor(ThemeRuntimeState.currentPalette().bgDark)
    }

    private static func placeholderImage() -> UIImage {
        let size = CGSize(width: 200, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
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
