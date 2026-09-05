import CoreGraphics
import SwiftUI
import UIKit
import WebKit

// MARK: - FileShareService

/// Converts file content into shareable formats (image, PDF, source file).
///
/// **Design doc**: `.internal/designs/share-sheet.md`
/// **Architecture**: `.internal/ARCHITECTURE.md` → "Share / export system"
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
/// - **WKWebView PDF pipeline** for HTML (pdf() + rasterization when needed)
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
        case mermaid(String, fileName: String? = nil)
        case latex(String, fileName: String? = nil)
        case markdown(String, fileName: String? = nil)
        case orgMode(String, fileName: String? = nil)
        case code(String, language: String?, fileName: String? = nil)
        case html(String, fileName: String? = nil)
        case json(String, fileName: String? = nil)
        case plainText(String, fileName: String? = nil)
        case diff([WorkspaceReviewDiffHunk], filePath: String)
        case imageData(Data, filename: String)
        case pdfData(Data, filename: String)

        /// Original last-path-component, if this content came from a named file.
        var originalFileName: String? {
            switch self {
            case .mermaid(_, let fileName),
                 .latex(_, let fileName),
                 .markdown(_, let fileName),
                 .orgMode(_, let fileName),
                 .html(_, let fileName),
                 .json(_, let fileName),
                 .plainText(_, let fileName):
                return FileShareService.fileName(fromPath: fileName)
            case .code(_, _, let fileName):
                return FileShareService.fileName(fromPath: fileName)
            case .diff(_, let filePath):
                return FileShareService.fileName(fromPath: filePath)
            case .imageData(_, let filename), .pdfData(_, let filename):
                return FileShareService.fileName(fromPath: filename)
            }
        }

        /// Build shareable content from raw text and a file path.
        ///
        /// Detects the file type from the path and maps to the appropriate
        /// content case. Used by hosting views (file browser, touched-file
        /// viewer, review detail) to create share content for the toolbar.
        static func fromText(_ text: String, filePath: String?) -> ShareableContent {
            let fileType = FileType.detect(from: filePath, content: text)
            let fileName = FileShareService.fileName(fromPath: filePath)
            switch fileType {
            case .markdown: return .markdown(text, fileName: fileName)
            case .html: return .html(text, fileName: fileName)
            case .json: return .json(text, fileName: fileName)
            case .latex: return .latex(text, fileName: fileName)
            case .orgMode: return .orgMode(text, fileName: fileName)
            case .mermaid: return .mermaid(text, fileName: fileName)
            case .graphviz: return .code(text, language: "dot", fileName: fileName)
            case .code(let lang): return .code(text, language: lang.displayName, fileName: fileName)
            case .plain: return .plainText(text, fileName: fileName)
            default: return .plainText(text, fileName: fileName)
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
                // Temp file URL so Save to Files / AirDrop use lastPathComponent.
                return [FileShareService.writeTempData(data: data, filename: filename)]
            case .file(let url):
                return [url]
            }
        }
    }

    // MARK: - Export Registry
    //
    // Single source of truth for what formats each content type supports.
    // All format-selection functions derive from this registry.
    //
    // To add a new content type or change format support:
    //   1. Add/edit the entry in exportSpec(for:)
    //   2. Add rendering logic in renderImage/renderPDF/renderSource
    //   3. Done — all UI surfaces pick up the change automatically.

    /// Declarative specification for how a content type can be exported.
    ///
    /// Captures format availability, defaults, and display metadata in one place.
    /// The rendering strategy (CGContext, attributed string, web view, etc.)
    /// is still in the render functions — this struct only describes *what*
    /// formats exist, not *how* they render.
    struct ContentExportSpec {
        /// The format used when sharing via single tap (no picker).
        let defaultFormat: ExportFormat
        /// All formats available, in display order.
        let formats: [ExportFormat]
        /// User-facing label for the source format (e.g. "Markdown File").
        let sourceLabel: String
        /// Base filename for source export (e.g. "document").
        let sourceBaseName: String
        /// File extension for source export (e.g. "md"). Nil for binary pass-through.
        let sourceExtension: String?
        /// Filename for PDF export (e.g. "document.pdf").
        let pdfFilename: String
    }

    /// Returns the full export spec for any shareable content.
    ///
    /// This is the single lookup for format metadata. All format-selection
    /// and filename functions below delegate here.
    static func exportSpec(for content: ShareableContent) -> ContentExportSpec {
        let original = content.originalFileName
        switch content {
        case .mermaid:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "Mermaid Source",
                genericBase: "diagram",
                sourceExtension: "mmd"
            )
        case .latex:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "LaTeX Source",
                genericBase: "formula",
                sourceExtension: "tex"
            )
        case .markdown:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "Markdown File",
                genericBase: "document",
                sourceExtension: "md"
            )
        case .orgMode:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "Org File",
                genericBase: "document",
                sourceExtension: "org"
            )
        case .code(_, let language, _):
            let ext = fileExtension(for: language) ?? "txt"
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "Source File",
                genericBase: "code",
                sourceExtension: ext
            )
        case .html:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "HTML Source",
                genericBase: "page",
                sourceExtension: "html"
            )
        case .json:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .pdf,
                formats: [.pdf, .image, .source],
                sourceLabel: "JSON File",
                genericBase: "data",
                sourceExtension: "json"
            )
        case .plainText:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .source,
                formats: [.source],
                sourceLabel: "Text File",
                genericBase: "text",
                sourceExtension: "txt"
            )
        case .diff:
            return textExportSpec(
                originalFileName: original,
                defaultFormat: .image,
                formats: [.image, .pdf, .source],
                sourceLabel: "Diff File",
                genericBase: "diff",
                sourceExtension: "diff"
            )
        case .imageData(_, let filename):
            return ContentExportSpec(
                defaultFormat: .image,
                formats: [.image],
                sourceLabel: "Image File",
                sourceBaseName: fileNameStem(filename),
                sourceExtension: (filename as NSString).pathExtension,
                pdfFilename: exportFileName(
                    originalFileName: original,
                    genericBase: "image",
                    ext: "pdf"
                )
            )
        case .pdfData(_, let filename):
            return ContentExportSpec(
                defaultFormat: .pdf,
                formats: [.pdf],
                sourceLabel: "PDF File",
                sourceBaseName: fileNameStem(filename),
                sourceExtension: "pdf",
                pdfFilename: fileName(fromPath: filename) ?? filename
            )
        }
    }

    // MARK: - Format Selection (derived from registry)

    /// Smart default export format for each content type.
    static func defaultFormat(for content: ShareableContent) -> ExportFormat {
        exportSpec(for: content).defaultFormat
    }

    /// Available export formats for a content type, in display order.
    static func availableFormats(for content: ShareableContent) -> [ExportFormat] {
        exportSpec(for: content).formats
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
            let label = content.map { exportSpec(for: $0).sourceLabel } ?? "Source File"
            return (label, "doc.text")
        }
    }

    // MARK: - Rendering

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
        if case .imageData(let data, let filename) = content {
            return .file(writeTempData(data: data, filename: fileName(fromPath: filename) ?? filename))
        }

        let image: UIImage
        switch content {
        case .mermaid(let source, _):
            image = renderMermaidToImage(source)
        case .latex(let source, _):
            image = renderLatexToImage(source)
        case .markdown(let source, _):
            image = renderMarkdownToImage(source)
        case .orgMode(let source, _):
            image = renderOrgModeToImage(source)
        case .code(let source, let language, _):
            image = renderCodeToImage(source, language: language)
        case .html(let source, _):
            image = await renderHTMLToImage(source)
        case .json(let source, _):
            image = renderCodeToImage(source, language: "json")
        case .plainText(let source, _):
            image = renderCodeToImage(source, language: nil)
        case .diff(let hunks, let filePath):
            image = renderDiffToImage(hunks: hunks, filePath: filePath)
        case .imageData:
            image = placeholderImage()
        case .pdfData:
            image = placeholderImage()
        }
        return namedImageShareItem(image, for: content)
    }

    // MARK: - CGContext Renderers (Mermaid, LaTeX)

    private static func renderMermaidToImage(_ source: String) -> UIImage {
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
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

    /// Shared image/PDF markdown export view. Intentionally has no workspace
    /// or session context: relative `![[video]]` embeds must still become the
    /// deterministic static card.
    static var markdownExportContentWidth: CGFloat {
        textLayoutWidth - exportPadding * 2
    }

    static func makeMarkdownExportView(_ source: String) -> AssistantMarkdownContentView {
        let view = AssistantMarkdownContentView()
        view.backgroundColor = currentBackgroundColor
        // Commit video geometry at the snapshot content width so the static
        // card keeps 16:9 instead of a 320pt fallback stretched page-wide.
        view.bounds = CGRect(x: 0, y: 0, width: markdownExportContentWidth, height: 1)
        view.apply(configuration: .make(
            content: source,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: false,
            renderingMode: .export
        ))
        return view
    }

    private static func renderMarkdownToImage(_ source: String) -> UIImage {
        snapshotView(
            makeMarkdownExportView(source),
            width: textLayoutWidth,
            padding: exportPadding,
            backgroundColor: currentBackgroundColor
        )
    }

    private static func renderOrgModeToImage(_ source: String) -> UIImage {
        renderMarkdownToImage(DocumentRenderPipeline.orgToMarkdown(source))
    }

    /// Render HTML image export through the PDF pipeline.
    ///
    /// PDF-first avoids flaky GPU snapshot behavior for offscreen WKWebView and
    /// keeps image/PDF exports consistent.
    private static func renderHTMLToImage(_ source: String) async -> UIImage {
        await rasterizeHTMLViaPDF(source)
    }

    /// Check if an image is effectively blank (solid color).
    ///
    /// Shared by export validation tests and fallback heuristics.
    // periphery:ignore - used by MarkdownTextTests via @testable import
    static func isBlankImage(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
              cgImage.width > 10, cgImage.height > 10 else {
            return true
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let w = cgImage.width, h = cgImage.height
        let insetX = w / 5, insetY = h / 5
        let points: [(Int, Int)] = [
            (w / 2, h / 2),
            (insetX, insetY),
            (w - insetX, insetY),
            (insetX, h - insetY),
            (w - insetX, h - insetY),
        ]

        struct SampleRGBA {
            let r: UInt8
            let g: UInt8
            let b: UInt8
            let a: UInt8
        }

        func samplePixel(x: Int, y: Int) -> SampleRGBA? {
            var pixel: [UInt8] = [0, 0, 0, 0]
            guard let ctx = CGContext(
                data: &pixel,
                width: 1, height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.draw(cgImage, in: CGRect(x: -x, y: -y, width: w, height: h))
            return SampleRGBA(r: pixel[0], g: pixel[1], b: pixel[2], a: pixel[3])
        }

        var blankCount = 0
        for (x, y) in points {
            guard let sample = samplePixel(x: x, y: y) else { continue }
            if sample.a < 10 || (sample.r < 5 && sample.g < 5 && sample.b < 5) {
                blankCount += 1
            }
        }
        return blankCount > points.count / 2
    }

    /// Fallback: render HTML to PDF first, then rasterize the first page.
    private static func rasterizeHTMLViaPDF(_ source: String) async -> UIImage {
        let pdfData = await renderHTMLToPDF(source)
        guard !pdfData.isEmpty else {
            return placeholderImage()
        }

        // PDF parsing + rasterization is pure CPU work — dispatch off the
        // main thread to avoid blocking UI during drawPDFPage (2s+ for
        // large pages at 3x scale).
        let scale = imageScale
        let image = await Task.detached(priority: .userInitiated) {
            Self.rasterizePDFPage(from: pdfData, scale: scale)
        }.value

        return image ?? placeholderImage()
    }

    /// Parse PDF data and rasterize the first page to a UIImage.
    ///
    /// Pure CPU work (CGPDFDocument + UIGraphicsImageRenderer) — safe to
    /// call from any thread. Extracted so callers can dispatch off the
    /// main actor.
    private nonisolated static func rasterizePDFPage(
        from pdfData: Data, scale: CGFloat
    ) -> UIImage? {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let pdfDoc = CGPDFDocument(provider),
              let page = pdfDoc.page(at: 1) else {
            return nil
        }

        let pageRect = page.getBoxRect(.mediaBox)
        let size = CGSize(
            width: pageRect.width * scale,
            height: pageRect.height * scale
        )

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

    // MARK: - Diff Rendering

    /// Render diff to image with full-width line backgrounds and gutter bars.
    ///
    /// Uses NSLayoutManager to get line fragment rects, then draws:
    /// 1. Full-width backgrounds for added/removed/header lines
    /// 2. Left gutter bars for added/removed lines
    /// 3. Word-level highlight backgrounds
    /// 4. Syntax-highlighted glyphs
    private static func renderDiffToImage(
        hunks: [WorkspaceReviewDiffHunk],
        filePath: String
    ) -> UIImage {
        let attrString = DiffAttributedStringBuilder.build(
            hunks: hunks, filePath: filePath, includeStats: true
        )

        let textStorage = NSTextStorage(attributedString: attrString)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let padding = codePDFPadding
        let contentWidth = max(ceil(usedRect.width) + padding * 2, textLayoutWidth)
        let contentHeight = min(ceil(usedRect.height) + padding * 2, maxImageHeight)
        let imageSize = CGSize(width: contentWidth, height: contentHeight)

        let bgColor = currentBackgroundColor
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: exportImageFormat)
        return renderer.image { ctx in
            bgColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))

            let origin = CGPoint(x: padding, y: padding)
            drawDiffLineBackgrounds(
                textStorage: textStorage,
                layoutManager: layoutManager,
                origin: origin,
                fullWidth: contentWidth
            )

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        }
    }

    /// Render diff to PDF with full-width line backgrounds.
    private static func renderDiffToPDF(
        hunks: [WorkspaceReviewDiffHunk],
        filePath: String
    ) -> Data {
        let attrString = DiffAttributedStringBuilder.build(
            hunks: hunks, filePath: filePath, includeStats: true
        )

        let textStorage = NSTextStorage(attributedString: attrString)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let padding = codePDFPadding
        let pageWidth = max(ceil(usedRect.width) + padding * 2, textLayoutWidth)
        let pageHeight = ceil(usedRect.height) + padding * 2
        let pageSize = CGSize(width: pageWidth, height: pageHeight)

        let bgColor = currentBackgroundColor
        let pdfRenderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize)
        )
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            bgColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: pageSize))

            let origin = CGPoint(x: padding, y: padding)
            drawDiffLineBackgrounds(
                textStorage: textStorage,
                layoutManager: layoutManager,
                origin: origin,
                fullWidth: pageWidth
            )

            let glyphRange = layoutManager.glyphRange(for: textContainer)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        }
    }

    /// Draw full-width backgrounds and gutter bars for diff lines.
    /// Shared between image and PDF diff renderers.
    private static func drawDiffLineBackgrounds(
        textStorage: NSTextStorage,
        layoutManager: NSLayoutManager,
        origin: CGPoint,
        fullWidth: CGFloat
    ) {
        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.10))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.08))
        let headerBg = UIColor(Color.themeBgHighlight)
        let addedBar = UIColor(Color.themeDiffAdded)
        let removedBar = UIColor(Color.themeDiffRemoved)
        let barWidth: CGFloat = 2.5

        textStorage.enumerateAttribute(
            diffLineKindAttributeKey,
            in: NSRange(location: 0, length: textStorage.length),
            options: []
        ) { value, attrRange, _ in
            guard let kind = value as? String else { return }
            let bg: UIColor
            let bar: UIColor?
            switch kind {
            case "added": bg = addedBg; bar = addedBar
            case "removed": bg = removedBg; bar = removedBar
            case "header": bg = headerBg; bar = nil
            default: return
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: attrRange, actualCharacterRange: nil
            )
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                var fillRect = rect
                fillRect.origin.x = 0
                fillRect.size.width = fullWidth
                fillRect.origin.y += origin.y
                bg.setFill()
                UIRectFillUsingBlendMode(fillRect, .normal)

                if let bar {
                    var barRect = fillRect
                    barRect.size.width = barWidth
                    bar.setFill()
                    UIRectFillUsingBlendMode(barRect, .normal)
                }
            }
        }
    }

    /// Build unified diff text from structured hunks for source file export.
    private static func buildUnifiedDiffText(_ hunks: [WorkspaceReviewDiffHunk]) -> String {
        hunks.map { hunk in
            var lines = [hunk.headerText]
            lines += hunk.lines.map { line in
                let prefix: String
                switch line.kind {
                case .context: prefix = " "
                case .added: prefix = "+"
                case .removed: prefix = "-"
                }
                return prefix + line.text
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - PDF Rendering

    private static func renderPDF(_ content: ShareableContent) async -> ShareItem {
        let spec = exportSpec(for: content)
        let pdfData: Data

        switch content {
        case .mermaid(let source, _):
            pdfData = renderMermaidToPDF(source)
        case .latex(let source, _):
            pdfData = renderLatexToPDF(source)
        case .html(let source, _):
            pdfData = await renderHTMLToPDF(source)
        case .pdfData(let data, let name):
            return .pdf(data, filename: fileName(fromPath: name) ?? name)
        case .markdown(let source, _):
            pdfData = await renderMarkdownToPDF(source)
        case .orgMode(let source, _):
            pdfData = await renderMarkdownToPDF(DocumentRenderPipeline.orgToMarkdown(source))
        case .code(let source, let language, _):
            pdfData = renderCodeToPDF(source, language: language)
        case .json(let source, _):
            pdfData = renderCodeToPDF(source, language: "json")
        case .plainText(let source, _):
            pdfData = renderCodeToPDF(source, language: nil)
        case .diff(let hunks, let filePath):
            pdfData = renderDiffToPDF(hunks: hunks, filePath: filePath)
        case .imageData(let data, _):
            if let image = UIImage(data: data) {
                pdfData = embedImageInPDF(image)
            } else {
                pdfData = Data()
            }
        }

        return .pdf(pdfData, filename: spec.pdfFilename)
    }

    private static func renderMermaidToPDF(_ source: String) -> Data {
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
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

    private static func attributedCodeWithExportFont(
        _ attributed: NSAttributedString,
        font: UIFont
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }
        mutable.addAttribute(.font, value: font, range: fullRange)
        return mutable
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
            let highlighted = SyntaxHighlighter.highlight(
                source,
                language: syntaxLang,
                themeID: ThemeRuntimeState.currentThemeID()
            )
            return attributedCodeWithExportFont(highlighted, font: font)
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
    /// Creates a temporary web view, loads the HTML through Oppi's locked-down
    /// HTML preview policy, waits for inline resources and JavaScript to settle,
    /// then uses `WKWebView.pdf(configuration:)` for a native PDF export with
    /// selectable text and proper layout. Canvas elements are rasterized to
    /// static images in a library-agnostic pass before PDF capture.
    private static func renderHTMLToPDF(_ source: String) async -> Data {
        let layoutWidth = textLayoutWidth
        let config = HTMLContentSecurity.makeConfiguration()

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
            webView.loadHTMLString(HTMLContentSecurity.injectContentSecurityPolicy(into: source), baseURL: nil)
        }

        guard loaded else { return Data() }

        // Wait for inline resources (images, fonts) to settle and any
        // embedded JavaScript to execute.
        await waitForContentReady(webView: webView)

        // Library-agnostic canvas freeze pass:
        // convert each <canvas> into a static <img> so PDF capture does not
        // depend on runtime GPU-backed canvas state.
        //
        // Optional page hooks:
        // - window.__oppiReadyForCapture: Bool | () -> Bool
        // - window.__oppiPrepareForCapture: () -> Void
        _ = try? await webView.evaluateJavaScript("""
            (function() {
                try {
                    if (typeof window.__oppiReadyForCapture === 'function') {
                        if (window.__oppiReadyForCapture() === false) return false;
                    } else if (window.__oppiReadyForCapture === false) {
                        return false;
                    }

                    if (typeof window.__oppiPrepareForCapture === 'function') {
                        window.__oppiPrepareForCapture();
                    }
                } catch (_) {}

                document.querySelectorAll('canvas').forEach(function(canvas) {
                    try {
                        var dataURL = canvas.toDataURL('image/png');
                        if (!dataURL || dataURL === 'data:,') return;

                        var img = document.createElement('img');
                        var rect = canvas.getBoundingClientRect();
                        img.src = dataURL;
                        img.style.width = rect.width + 'px';
                        img.style.height = rect.height + 'px';
                        img.style.display = 'block';
                        if (canvas.parentNode) {
                            canvas.parentNode.replaceChild(img, canvas);
                        }
                    } catch (_) {}
                });

                return true;
            })();
        """)

        // Let canvas-to-image swap settle
        try? await Task.sleep(for: .milliseconds(100))

        // Measure full content height and resize web view
        let contentHeight = try? await webView.evaluateJavaScript(
            "document.documentElement.scrollHeight"
        ) as? CGFloat
        let fullHeight = max(contentHeight ?? 600, 100)
        let clampedHeight = min(fullHeight, maxHTMLHeight)
        webView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: clampedHeight)

        try? await Task.sleep(for: .milliseconds(50))

        // Generate PDF — omit rect for auto-pagination of full content
        do {
            return try await webView.pdf(configuration: WKPDFConfiguration())
        } catch {
            let image = renderCodeToImage(source, language: "html")
            return embedImageInPDF(image)
        }
    }

    /// Poll the web view until the document and inline resources have loaded.
    /// Waits up to 5 seconds for document completion, web fonts, and inline
    /// images to settle. An optional `window.__oppiReadyForCapture` hook can
    /// return false to delay capture.
    private static func waitForContentReady(webView: WKWebView) async {
        let maxAttempts = 25  // 25 × 200ms = 5 seconds
        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: .milliseconds(200))

            let ready = try? await webView.evaluateJavaScript("""
                (function() {
                    if (document.readyState !== 'complete') return false;

                    if (document.fonts && document.fonts.status !== 'loaded') {
                        return false;
                    }

                    var images = Array.prototype.slice.call(document.images || []);
                    for (var i = 0; i < images.length; i++) {
                        if (!images[i].complete) return false;
                    }

                    try {
                        if (typeof window.__oppiReadyForCapture === 'function') {
                            if (window.__oppiReadyForCapture() === false) return false;
                        } else if (window.__oppiReadyForCapture === false) {
                            return false;
                        }
                    } catch (_) {}

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
        case .mermaid(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .latex(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .markdown(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .orgMode(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .code(let text, _, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .html(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .json(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .plainText(let text, _):
            return .file(writeTempFile(content: text, filename: filename))
        case .diff(let hunks, _):
            return .file(writeTempFile(content: buildUnifiedDiffText(hunks), filename: filename))
        case .imageData(let data, let name):
            return .file(writeTempData(data: data, filename: fileName(fromPath: name) ?? name))
        case .pdfData(let data, let name):
            return .file(writeTempData(data: data, filename: fileName(fromPath: name) ?? name))
        }
    }

    // MARK: - Temp File Management

    private nonisolated static var tempRootDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-share", isDirectory: true)
    }

    private nonisolated static func makeExportTempDirectory() -> URL {
        let root = tempRootDirectoryURL
        let exportDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        return exportDir
    }

    private static func writeTempFile(content: String, filename: String) -> URL {
        let dir = makeExportTempDirectory()
        let url = dir.appendingPathComponent(filename)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    fileprivate nonisolated static func writeTempData(data: Data, filename: String) -> URL {
        let dir = makeExportTempDirectory()
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url)
        return url
    }

    /// Remove all temp files created for sharing. Call from
    /// UIActivityViewController.completionWithItemsHandler.
    static func cleanupTempFiles() {
        try? FileManager.default.removeItem(at: tempRootDirectoryURL)
    }

    // MARK: - Helpers

    private static func sourceFilename(for content: ShareableContent, extension ext: String?) -> String {
        let spec = exportSpec(for: content)
        if let original = content.originalFileName {
            switch content {
            case .diff:
                return exportFileName(
                    originalFileName: original,
                    genericBase: spec.sourceBaseName,
                    ext: spec.sourceExtension ?? "diff"
                )
            default:
                return original
            }
        }
        let resolvedExt = ext ?? spec.sourceExtension ?? "txt"
        return "\(spec.sourceBaseName).\(resolvedExt)"
    }

    /// Last path component of a file path or already-bare file name.
    nonisolated static func fileName(fromPath path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return name
    }

    /// Stem used when swapping a format suffix. Dotfiles whose
    /// `deletingPathExtension` is empty (`.gitignore`) keep the original name.
    nonisolated static func fileNameStem(_ original: String) -> String {
        let deleted = (original as NSString).deletingPathExtension
        return deleted.isEmpty ? original : deleted
    }

    /// Named files keep the original stem and only replace the last extension.
    /// Unnamed content uses `genericBase`.`ext`.
    nonisolated static func exportFileName(
        originalFileName: String?,
        genericBase: String,
        ext: String
    ) -> String {
        guard let original = fileName(fromPath: originalFileName) else {
            return "\(genericBase).\(ext)"
        }
        let ns = original as NSString
        if ns.pathExtension.lowercased() == ext.lowercased() {
            return original
        }
        return "\(fileNameStem(original)).\(ext)"
    }

    private static func textExportSpec(
        originalFileName: String?,
        defaultFormat: ExportFormat,
        formats: [ExportFormat],
        sourceLabel: String,
        genericBase: String,
        sourceExtension: String
    ) -> ContentExportSpec {
        ContentExportSpec(
            defaultFormat: defaultFormat,
            formats: formats,
            sourceLabel: sourceLabel,
            sourceBaseName: originalFileName.map(fileNameStem) ?? genericBase,
            sourceExtension: sourceExtension,
            pdfFilename: exportFileName(
                originalFileName: originalFileName,
                genericBase: genericBase,
                ext: "pdf"
            )
        )
    }

    private static func namedImageShareItem(_ image: UIImage, for content: ShareableContent) -> ShareItem {
        guard let original = content.originalFileName, let data = image.pngData() else {
            return .image(image)
        }
        let filename = exportFileName(originalFileName: original, genericBase: "image", ext: "png")
        return .file(writeTempData(data: data, filename: filename))
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
        case .diff: return "diff"
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
        ThemeRuntimeState.currentRenderTheme()
    }

    /// Current theme's background color for image/PDF export.
    private static var currentBackgroundColor: UIColor {
        UIColor(ThemeRuntimeState.currentPalette().bgDark)
    }

    private static func placeholderImage() -> UIImage {
        DocumentRenderPipeline.placeholderImage()
    }
}

#if DEBUG
extension FileShareService {
    static var debugCodePDFFontSizeForTesting: CGFloat { codePDFFontSize }

    static func debugHighlightedAttributedStringForTesting(
        _ source: String,
        language: String?,
        palette: ThemePalette
    ) -> NSAttributedString {
        buildHighlightedAttributedString(source, language: language, palette: palette)
    }
}
#endif

// MARK: - PDF Navigation Delegate

/// One-shot WKNavigationDelegate that resumes a continuation when loading completes.
private final class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(HTMLContentSecurity.allowsEmbeddedNavigation(to: navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
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

