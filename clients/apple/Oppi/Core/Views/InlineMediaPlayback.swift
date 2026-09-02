import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Image Viewport Sizing

enum ImagePresentationSurface: Equatable {
    case thumbnail
    case inlineProse
    case primaryMedia
    case fullscreen
}

struct ImagePresentationPolicy: Equatable {
    let surface: ImagePresentationSurface
    let minimumHeight: CGFloat
    let placeholderHeight: CGFloat
    let maximumHeight: CGFloat?
    let maxPixelSize: CGFloat

    var allowsNaturalHeight: Bool { maximumHeight == nil || surface == .primaryMedia || surface == .fullscreen }
}

enum ImageViewportSizing {
    enum HeightMode: Equatable {
        case singleScreenFit
        case primaryMedia
        case unrestricted
        case fixed(CGFloat)
    }

    static let minInlineHeight: CGFloat = 80
    static let defaultPlaceholderHeight: CGFloat = 160
    static let maxPrimaryTimelineHeight: CGFloat = 10_000
    private static let maxScreenFraction: CGFloat = 0.66
    private static let maxPrimaryScreenMultiplier: CGFloat = 1.2
    private static let fallbackScreenHeight: CGFloat = 844
    private static let minimumValidHeightToWidthRatio: CGFloat = 1.0 / 50.0
    private static let maximumValidHeightToWidthRatio: CGFloat = 50.0

    static func policy(for surface: ImagePresentationSurface, screenHeight: CGFloat?) -> ImagePresentationPolicy {
        switch surface {
        case .thumbnail:
            return ImagePresentationPolicy(
                surface: surface,
                minimumHeight: 80,
                placeholderHeight: 80,
                maximumHeight: 80,
                maxPixelSize: 512
            )
        case .inlineProse:
            return ImagePresentationPolicy(
                surface: surface,
                minimumHeight: minInlineHeight,
                placeholderHeight: defaultPlaceholderHeight,
                maximumHeight: maxHeight(for: .singleScreenFit, screenHeight: screenHeight),
                maxPixelSize: 1_600
            )
        case .primaryMedia:
            return ImagePresentationPolicy(
                surface: surface,
                minimumHeight: minInlineHeight,
                placeholderHeight: defaultPlaceholderHeight,
                maximumHeight: maxHeight(for: .primaryMedia, screenHeight: screenHeight),
                maxPixelSize: 1_600
            )
        case .fullscreen:
            return ImagePresentationPolicy(
                surface: surface,
                minimumHeight: minInlineHeight,
                placeholderHeight: defaultPlaceholderHeight,
                maximumHeight: nil,
                maxPixelSize: 2_400
            )
        }
    }

    static func validatedHeightToWidthRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio,
              ratio.isFinite,
              ratio >= minimumValidHeightToWidthRatio,
              ratio <= maximumValidHeightToWidthRatio else {
            return nil
        }
        return ratio
    }

    static func validatedHeightToWidthRatio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return validatedHeightToWidthRatio(height / width)
    }

    static func naturalHeight(
        forWidth width: CGFloat,
        heightToWidthRatio: CGFloat
    ) -> CGFloat {
        guard width.isFinite, width > 0,
              let validRatio = validatedHeightToWidthRatio(heightToWidthRatio) else {
            return minInlineHeight
        }

        return max(minInlineHeight, width * validRatio)
    }

    static func fittedHeight(
        forWidth width: CGFloat,
        aspectRatio: CGFloat,
        screenHeight: CGFloat?
    ) -> CGFloat {
        fittedHeight(
            forWidth: width,
            heightToWidthRatio: aspectRatio,
            surface: .inlineProse,
            screenHeight: screenHeight
        )
    }

    static func fittedHeight(
        forWidth width: CGFloat,
        heightToWidthRatio: CGFloat,
        surface: ImagePresentationSurface,
        screenHeight: CGFloat?
    ) -> CGFloat {
        let policy = policy(for: surface, screenHeight: screenHeight)
        let naturalHeight = naturalHeight(forWidth: width, heightToWidthRatio: heightToWidthRatio)
        let minimumHeight = max(minInlineHeight, policy.minimumHeight)
        let height = max(minimumHeight, naturalHeight)
        guard let maximumHeight = policy.maximumHeight else { return height }
        return min(maximumHeight, height)
    }

    static func maxHeight(for mode: HeightMode, screenHeight: CGFloat?) -> CGFloat? {
        switch mode {
        case .singleScreenFit:
            let height = max(320, screenHeight ?? fallbackScreenHeight)
            return max(minInlineHeight, floor(height * maxScreenFraction))
        case .primaryMedia:
            let height = max(320, screenHeight ?? fallbackScreenHeight)
            return min(maxPrimaryTimelineHeight, max(minInlineHeight, floor(height * maxPrimaryScreenMultiplier)))
        case .unrestricted:
            return nil
        case .fixed(let value):
            return max(1, value)
        }
    }
}

// MARK: - MIME Helpers

enum MediaMimeType {
    static func normalized(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let trimmed = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ";", maxSplits: 1).first.map(String.init)
    }

    /// Detect SVG content by checking the first non-whitespace bytes for an
    /// `<svg` tag, with or without an XML preamble.
    static func isSVGData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let prefix = data.prefix(4096)
        guard let start = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        let trimmed = start.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<svg") {
            return true
        }
        if trimmed.hasPrefix("<?xml") {
            return trimmed.contains("<svg")
        }
        return false
    }

    /// True only when the data looks like a complete SVG document, not a
    /// truncated read-tool prefix that would fail in WebKit.
    static func isCompleteSVGData(_ data: Data) -> Bool {
        guard isSVGData(data),
              let content = String(data: data, encoding: .utf8) else { return false }
        return content.range(of: "</svg>", options: .caseInsensitive) != nil
    }

    /// Reject image byte prefixes that ImageIO can partially decode by filling
    /// missing JPEG scanlines with gray. Unknown formats are left to ImageIO.
    static func isCompleteImageData(_ data: Data, mimeType: String?) -> Bool {
        guard !data.isEmpty else { return false }

        switch normalized(mimeType) {
        case "image/jpeg", "image/jpg":
            return !hasPrefix(data, [0xFF, 0xD8]) || hasSuffix(data, [0xFF, 0xD9])
        case "image/png":
            return !hasPrefix(data, pngSignature) || hasSuffix(data, pngIENDTrailer)
        case "image/gif":
            return !isGIFData(data) || hasSuffix(data, [0x3B])
        case "image/webp":
            return !isRIFFWebPData(data) || hasCompleteRIFFLength(data)
        case "image/svg+xml":
            return !isSVGData(data) || isCompleteSVGData(data)
        default:
            if hasPrefix(data, [0xFF, 0xD8]) {
                return hasSuffix(data, [0xFF, 0xD9])
            }
            if hasPrefix(data, pngSignature) {
                return hasSuffix(data, pngIENDTrailer)
            }
            if isGIFData(data) {
                return hasSuffix(data, [0x3B])
            }
            if isRIFFWebPData(data) {
                return hasCompleteRIFFLength(data)
            }
            if isSVGData(data) {
                return isCompleteSVGData(data)
            }
            return true
        }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let pngIENDTrailer: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        data.count >= bytes.count && Array(data.prefix(bytes.count)) == bytes
    }

    private static func hasSuffix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        data.count >= bytes.count && Array(data.suffix(bytes.count)) == bytes
    }

    private static func isGIFData(_ data: Data) -> Bool {
        hasPrefix(data, Array("GIF87a".utf8)) || hasPrefix(data, Array("GIF89a".utf8))
    }

    private static func isRIFFWebPData(_ data: Data) -> Bool {
        data.count >= 12
            && hasPrefix(data, Array("RIFF".utf8))
            && Array(data.dropFirst(8).prefix(4)) == Array("WEBP".utf8)
    }

    private static func hasCompleteRIFFLength(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let header = Array(data.prefix(8))
        let declaredSize = Int(header[4])
            | (Int(header[5]) << 8)
            | (Int(header[6]) << 16)
            | (Int(header[7]) << 24)
        return declaredSize >= 4 && data.count >= declaredSize + 8
    }

    /// Extract the SVG aspect ratio from the root `viewBox` when present,
    /// otherwise fall back to root `width` / `height` attributes.
    static func extractSVGViewBoxAspectRatio(_ data: Data) -> CGFloat? {
        guard let content = String(data: data.prefix(8_192), encoding: .utf8),
              let start = content.range(of: "<svg", options: .caseInsensitive)?.lowerBound,
              let end = content[start...].firstIndex(of: ">") else {
            return nil
        }

        let openingTag = String(content[start...end])
        if let ratio = extractSVGViewBoxAspectRatio(fromOpeningTag: openingTag) {
            return ratio
        }

        guard let widthValue = svgAttribute("width", in: openingTag),
              let heightValue = svgAttribute("height", in: openingTag),
              let width = svgLength(widthValue), width > 0,
              let height = svgLength(heightValue), height > 0 else {
            return nil
        }

        return width / height
    }

    private static func extractSVGViewBoxAspectRatio(fromOpeningTag openingTag: String) -> CGFloat? {
        let pattern = /viewBox\s*=\s*["']?[-\d.]+\s+[-\d.]+\s+([-\d.]+)\s+([-\d.]+)/
        guard let match = openingTag.firstMatch(of: pattern),
              let width = Double(match.output.1), width > 0,
              let height = Double(match.output.2), height > 0 else {
            return nil
        }
        return CGFloat(width / height)
    }

    private static func svgAttribute(_ name: String, in openingTag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)(?:^|\\s)\(escapedName)\\s*=\\s*(['\"])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let searchRange = NSRange(openingTag.startIndex..., in: openingTag)
        guard let match = regex.firstMatch(in: openingTag, range: searchRange),
              let valueRange = Range(match.range(at: 2), in: openingTag) else {
            return nil
        }
        return String(openingTag[valueRange])
    }

    private static func svgLength(_ rawValue: String) -> CGFloat? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("%") else { return nil }

        let scanner = Scanner(string: trimmed)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let value = scanner.scanDouble(), value > 0 else { return nil }
        return CGFloat(value)
    }

    static func isSupportedImageMimeType(_ mimeType: String?) -> Bool {
        switch normalized(mimeType) {
        case "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
             "image/bmp", "image/tiff", "image/svg+xml", "image/x-icon",
             "image/vnd.microsoft.icon":
            return true
        default:
            return false
        }
    }

    static func safeImageMimeType(_ mimeType: String?, fallback: String = "image/png") -> String {
        let normalizedMimeType = normalized(mimeType)
        return isSupportedImageMimeType(normalizedMimeType) ? normalizedMimeType ?? fallback : fallback
    }

    static func imageMimeType(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        default: return nil
        }
    }

    static func audioMimeType(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aif", "aiff", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        case "opus": return "audio/opus"
        default: return nil
        }
    }

    static func videoMimeType(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        default: return nil
        }
    }

    static func preferredFileExtension(forAudio mimeType: String?, fallbackPathExtension: String? = nil) -> String {
        if let fallback = sanitizedPathExtension(fallbackPathExtension) {
            return fallback
        }

        switch normalized(mimeType) {
        case "audio/mpeg": return "mp3"
        case "audio/wav": return "wav"
        case "audio/aiff": return "aiff"
        case "audio/x-caf": return "caf"
        case "audio/ogg": return "ogg"
        case "audio/flac": return "flac"
        case "audio/opus": return "opus"
        default: return "m4a"
        }
    }

    static func preferredFileExtension(forVideo mimeType: String?, fallbackPathExtension: String? = nil) -> String {
        if let fallback = sanitizedPathExtension(fallbackPathExtension) {
            return fallback
        }

        switch normalized(mimeType) {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-msvideo": return "avi"
        default: return "mp4"
        }
    }

    private static func sanitizedPathExtension(_ pathExtension: String?) -> String? {
        guard let pathExtension else { return nil }
        let trimmed = pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Image Inspection

enum ImageMediaInspector {
    struct Info {
        let normalizedMimeType: String?
        let isAnimated: Bool
        let pixelSize: CGSize?

        var aspectRatio: CGFloat? {
            guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
            return pixelSize.width / pixelSize.height
        }

        var prefersWebRenderer: Bool {
            isAnimated || normalizedMimeType == "image/svg+xml"
        }
    }

    static func inspect(data: Data, mimeType: String?) -> Info {
        let hintedMimeType = MediaMimeType.normalized(mimeType)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            // CoreGraphics doesn't understand this format. Check whether it's
            // SVG (which needs a WebKit renderer) or truly undecodable.
            let isSVG = MediaMimeType.isSVGData(data)
            return Info(
                normalizedMimeType: isSVG ? "image/svg+xml" : hintedMimeType,
                isAnimated: false,
                pixelSize: nil
            )
        }

        // Image URLs are not reliable type evidence: session-file names live
        // in a query item, caches retain bytes only, and remote URLs may have
        // no extension. Prefer ImageIO's byte-derived UTI, then normalize its
        // MIME through UniformTypeIdentifiers before falling back to the hint.
        let detectedMimeType = CGImageSourceGetType(source).flatMap { sourceType in
            UTType(sourceType as String)?.preferredMIMEType
        }
        let normalizedMimeType = MediaMimeType.normalized(detectedMimeType) ?? hintedMimeType
        let frameCount = CGImageSourceGetCount(source)
        let pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0,
           height > 0 {
            pixelSize = CGSize(width: width, height: height)
        } else {
            pixelSize = nil
        }

        return Info(
            normalizedMimeType: normalizedMimeType,
            isAnimated: frameCount > 1,
            pixelSize: pixelSize
        )
    }

    static func downsampledImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded())),
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }

        return UIImage(data: data)
    }
}

// MARK: - Image Preview Web Security

enum ImagePreviewWebSecurity {
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; media-src data:"

    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }
        return configuration
    }
}

// MARK: - Animated Image Web View

final class ImagePreviewNavigationBlocker: NSObject, WKNavigationDelegate {
    var onDidFinish: (() -> Void)?
    var onDidFail: ((any Error) -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if HTMLContentSecurity.isHostRawFileURL(navigationAction.request.url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onDidFinish?()
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        onDidFail?(error)
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        onDidFail?(error)
    }
}

final class AnimatedImageWebContainerView: UIView {
    private let webView: ReviewCommentWKWebView
    private let navigationBlocker = ImagePreviewNavigationBlocker()
    private var currentSignature: Int?
    private var loadedSignature: Int?
    private var pendingDataURLString: String?
    private(set) var isRenderReady = false
    var onRenderStateChange: (() -> Void)?

    override init(frame: CGRect) {
        self.webView = ReviewCommentWKWebView(frame: .zero, configuration: ImagePreviewWebSecurity.makeConfiguration())
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        loadPendingContentIfReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        loadPendingContentIfReady()
    }

    func snapshotRenderedImage() async throws -> UIImage {
        guard isRenderReady else {
            throw PaperMarkupCanvasSession.SnapshotError.notReady
        }
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                continuation.resume(with: PaperMarkupCanvasSession.renderedSnapshot(image: image, error: error))
            }
        }
    }

    func markRenderReadyForTesting() {
        setRenderReady(true)
    }

    func apply(dataURLString: String) {
        var hasher = Hasher()
        hasher.combine(dataURLString.count)
        hasher.combine(dataURLString.prefix(128))
        hasher.combine(dataURLString.suffix(128))
        let signature = hasher.finalize()
        guard signature != currentSignature else {
            loadPendingContentIfReady()
            return
        }
        currentSignature = signature
        loadedSignature = nil
        pendingDataURLString = dataURLString
        setRenderReady(false)
        loadPendingContentIfReady()
    }

    private func setRenderReady(_ ready: Bool) {
        guard isRenderReady != ready else { return }
        isRenderReady = ready
        onRenderStateChange?()
    }

    private func loadPendingContentIfReady() {
        guard window != nil,
              bounds.width > 0,
              bounds.height > 0,
              webView.bounds.width > 0,
              webView.bounds.height > 0,
              let dataURLString = pendingDataURLString,
              let currentSignature,
              loadedSignature != currentSignature else {
            return
        }

        loadedSignature = currentSignature
        setRenderReady(false)
        webView.loadHTMLString(Self.makeHTML(dataURLString: dataURLString), baseURL: nil)
    }

    private static func makeHTML(dataURLString: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover\">
          <meta http-equiv="Content-Security-Policy" content="\(ImagePreviewWebSecurity.contentSecurityPolicy)">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              overflow: hidden;
              width: 100%;
              height: 100%;
            }
            body {
              display: flex;
              align-items: center;
              justify-content: center;
            }
            img {
              display: block;
              max-width: 100%;
              max-height: 100%;
              width: 100%;
              height: 100%;
              object-fit: contain;
            }
          </style>
        </head>
        <body>
          <img src=\"\(dataURLString)\" />
        </body>
        </html>
        """
    }

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = navigationBlocker
        navigationBlocker.onDidFinish = { [weak self] in
            self?.setRenderReady(true)
        }
        navigationBlocker.onDidFail = { [weak self] _ in
            self?.setRenderReady(false)
        }
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

struct AnimatedImageWebView: UIViewRepresentable {
    let dataURLString: String

    func makeUIView(context: Context) -> AnimatedImageWebContainerView {
        AnimatedImageWebContainerView()
    }

    func updateUIView(_ uiView: AnimatedImageWebContainerView, context: Context) {
        uiView.apply(dataURLString: dataURLString)
    }
}

// MARK: - Fullscreen Data Image Preview

@MainActor
enum FullScreenImageDataPreviewPresenter {
    static func present(data: Data, mimeType: String?, title: String = "Preview") {
        guard let presenter = activePresenter() else { return }
        present(data: data, mimeType: mimeType, title: title, from: presenter)
    }

    static func present(data: Data, mimeType: String?, title: String = "Preview", from presenter: UIViewController) {
        // Resolve before presenting. The sheet's later presenter chain is not
        // a reliable path back to the chat composer destination.
        let destination = ComposerCanvasDestinationResolver.resolve(from: presenter)
        ImagePreviewPresentationCoordinator.present(
            FullScreenImageDataPreviewViewController.makeSlideDownController(
                data: data,
                mimeType: mimeType,
                title: title,
                prefersFullScreenOverlay: FullScreenViewerPresentationPolicy.prefersFullScreenOverlay(
                    for: presenter.traitCollection
                ),
                addToChatDestination: destination
            ),
            from: presenter
        )
    }

    private static func activePresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

final class FullScreenImageDataPreviewViewController: UIViewController, UIScrollViewDelegate {
    private let data: Data
    private let mimeType: String?
    private let previewTitle: String
    private let addToChatDestination: ComposerCanvasDestination?
    private let palette: ThemePalette
    private let scrollView = UIScrollView()
    private let containerView = AnimatedImageWebContainerView()
    private var swipeDismissHandler: HorizontalBackSwipeGestureInstaller?
    private var annotateButton: UIButton?
    private var isSnapshotting = false
    private(set) var didDismissAfterCanvasDeliveryForTesting = false

    init(
        data: Data,
        mimeType: String?,
        title: String,
        addToChatDestination: ComposerCanvasDestination? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.previewTitle = title
        self.addToChatDestination = addToChatDestination
        self.palette = ThemeRuntimeState.currentThemeID().palette
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(palette.bgDark)
        view.accessibilityLabel = previewTitle
        setupNavigationChrome()
        setupSwipeDismiss()
        setupScrollView()
        setupPreviewView()
        setupFloatingAnnotateButton()
        setupDoubleTap()
        loadPreview()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        containerView
    }

    private func setupNavigationChrome() {
        navigationItem.leftBarButtonItem = FullScreenViewerNavigationChrome.makeDismissButton(
            mode: .modal,
            target: self,
            action: #selector(dismissTapped),
            palette: palette,
            accessibilityIdentifier: "fullscreen-image-data.dismiss"
        )
        containerView.onRenderStateChange = { [weak self] in
            self?.updateAnnotateAvailability()
        }
    }

    private func setupFloatingAnnotateButton() {
        if let annotateButton {
            FullScreenFloatingControlChrome.updateStandaloneButton(annotateButton, palette: palette)
            updateAnnotateAvailability()
            return
        }
        let button = FullScreenFloatingControlChrome.makeStandaloneButton(
            systemImage: PaperMarkupCanvasSession.AnnotateAction.systemImage,
            accessibilityLabel: PaperMarkupCanvasSession.AnnotateAction.title,
            accessibilityIdentifier: PaperMarkupCanvasSession.AnnotateAction.dataViewerIdentifier,
            palette: palette
        )
        button.addTarget(self, action: #selector(annotateTapped), for: .touchUpInside)
        annotateButton = button
        view.addSubview(button)
        FullScreenFloatingControlChrome.pinStandaloneButton(button, to: view, leading: true)
        view.bringSubviewToFront(button)
        updateAnnotateAvailability()
    }

    private func setupSwipeDismiss() {
        let handler = HorizontalBackSwipeGestureInstaller(
            onBack: { [weak self] in
                self?.dismiss(animated: true)
            },
            direction: FullScreenViewerNavigationChrome.DismissMode.modal.gestureDirection
        )
        handler.install(on: view)
        swipeDismissHandler = handler
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = UIColor(palette.bgDark)
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupPreviewView() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            containerView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            containerView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    private func setupDoubleTap() {
        DoubleTapZoom.install(on: scrollView, target: self, action: #selector(handleDoubleTap(_:)))
    }

    private func loadPreview() {
        let normalizedMimeType = MediaMimeType.safeImageMimeType(mimeType, fallback: "image/svg+xml")
        let dataURLString = "data:\(normalizedMimeType);base64,\(data.base64EncodedString())"
        containerView.apply(dataURLString: dataURLString)
    }

    @objc private func dismissTapped() {
        dismiss(animated: true)
    }

    @objc private func annotateTapped() {
        guard containerView.isRenderReady, !isSnapshotting else { return }
        isSnapshotting = true
        updateAnnotateAvailability()
        Task { @MainActor in
            defer {
                isSnapshotting = false
                updateAnnotateAvailability()
            }
            do {
                let image = try await containerView.snapshotRenderedImage()
                PaperMarkupCanvasHostController.present(
                    background: .image(PaperMarkupCanvasSession.copiedImage(from: image)),
                    from: self,
                    destination: addToChatDestination,
                    onDeliveryAccepted: { [weak self] in
                        self?.handleAnnotateDeliveryAccepted()
                    }
                )
            } catch {
                presentPaperMarkupSnapshotFailure(error)
            }
        }
    }

    private func updateAnnotateAvailability() {
        annotateButton?.isEnabled = containerView.isRenderReady && !isSnapshotting
    }

    var annotateSourceForTesting: PaperMarkupCanvasSession.AnnotateSource {
        PaperMarkupCanvasSession.annotateSource(for: .svg)
    }

    var floatingAnnotateButtonForTesting: UIButton? {
        annotateButton
    }

    func makeAnnotateHostForTesting() -> PaperMarkupCanvasHostController {
        PaperMarkupCanvasHostController.makeFullScreenController(
            background: .blank,
            destination: addToChatDestination,
            onDeliveryAccepted: { [weak self] in
                self?.handleAnnotateDeliveryAccepted()
            }
        )
    }

    private func handleAnnotateDeliveryAccepted() {
        didDismissAfterCanvasDeliveryForTesting = true
        presentingViewController?.dismiss(animated: true)
    }

    var isShowingSnapshotProgressForTesting: Bool { isSnapshotting }

    func markRenderReadyForTesting() {
        containerView.markRenderReadyForTesting()
        updateAnnotateAvailability()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        toggleZoom(at: gesture.location(in: containerView))
    }

    private func toggleZoom(at pointInPreview: CGPoint, animated: Bool? = nil) {
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: pointInPreview,
            fitScale: scrollView.minimumZoomScale,
            animated: animated
        )
    }

#if DEBUG
    func debugToggleZoomForTesting(at pointInPreview: CGPoint) {
        toggleZoom(at: pointInPreview, animated: false)
    }
#endif
}

extension FullScreenImageDataPreviewViewController {
    static func makeSlideDownController(
        data: Data,
        mimeType: String?,
        title: String,
        prefersFullScreenOverlay: Bool = false,
        addToChatDestination: ComposerCanvasDestination? = nil
    ) -> UIViewController {
        let themeID = ThemeRuntimeState.currentThemeID()
        let viewer = FullScreenImageDataPreviewViewController(
            data: data,
            mimeType: mimeType,
            title: title,
            addToChatDestination: addToChatDestination
        )
        let navigation = ImagePreviewNavigationController(rootViewController: viewer)
        navigation.view.backgroundColor = UIColor(themeID.palette.bgDark)

        if prefersFullScreenOverlay {
            navigation.modalPresentationStyle = .overFullScreen
            navigation.modalTransitionStyle = .coverVertical
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
        }

        navigation.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        return navigation
    }
}

// MARK: - SwiftUI Image Preview

struct DataImagePreviewView: View {
    private enum Phase {
        case loading
        case staticImage(UIImage, CGFloat?)
        case animated(String, CGFloat?, Data, String?)
        case failure
    }

    let data: Data
    let mimeType: String?
    var maxPixelSize: CGFloat = 1_600
    var heightMode: ImageViewportSizing.HeightMode = .singleScreenFit
    var allowsFullscreenStaticImage = true

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: placeholderHeight)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            case .failure:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: placeholderHeight)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                            Text("Image preview unavailable")
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                        }
                    }
            case .staticImage(let image, let aspectRatio):
                renderedImage(
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onTapGesture {
                            guard allowsFullscreenStaticImage else { return }
                            let fullResolutionImage = UIImage(data: data) ?? image
                            FullScreenImageViewController.present(image: fullResolutionImage)
                        },
                    aspectRatio: aspectRatio
                )
            case .animated(let dataURLString, let aspectRatio, let data, let mimeType):
                renderedImage(
                    AnimatedImageWebView(dataURLString: dataURLString)
                        .onTapGesture {
                            FullScreenImageDataPreviewPresenter.present(data: data, mimeType: mimeType)
                        },
                    aspectRatio: aspectRatio
                )
            }
        }
        .task(id: cacheKey) {
            phase = await Task.detached(priority: .userInitiated) {
                let info = ImageMediaInspector.inspect(data: data, mimeType: mimeType)
                let aspectRatio = info.aspectRatio ?? MediaMimeType.extractSVGViewBoxAspectRatio(data)
                if info.prefersWebRenderer {
                    let normalizedMimeType = MediaMimeType.safeImageMimeType(info.normalizedMimeType, fallback: "image/gif")
                    let dataURLString = "data:\(normalizedMimeType);base64,\(data.base64EncodedString())"
                    return Phase.animated(dataURLString, aspectRatio, data, normalizedMimeType)
                }

                if let image = ImageMediaInspector.downsampledImage(data: data, maxPixelSize: maxPixelSize) {
                    return Phase.staticImage(image, aspectRatio)
                }

                if MediaMimeType.isSupportedImageMimeType(info.normalizedMimeType) {
                    let normalizedMimeType = MediaMimeType.safeImageMimeType(info.normalizedMimeType)
                    let dataURLString = "data:\(normalizedMimeType);base64,\(data.base64EncodedString())"
                    return Phase.animated(dataURLString, aspectRatio, data, normalizedMimeType)
                }

                return .failure
            }.value
        }
    }

    private var cacheKey: String {
        let mime = MediaMimeType.normalized(mimeType) ?? "image/unknown"
        return "\(mime)-\(data.count)-\(data.prefix(32))-\(data.suffix(32))-\(maxPixelSize)-\(cacheHeightModeKey)"
    }

    private var placeholderHeight: CGFloat {
        switch heightMode {
        case .fixed(let value):
            return max(1, value)
        case .singleScreenFit, .primaryMedia, .unrestricted:
            return ImageViewportSizing.defaultPlaceholderHeight
        }
    }

    private var cacheHeightModeKey: String {
        switch heightMode {
        case .singleScreenFit:
            return "fit"
        case .primaryMedia:
            return "primary"
        case .unrestricted:
            return "full"
        case .fixed(let value):
            return "fixed-\(Int(value.rounded()))"
        }
    }

    @ViewBuilder
    private func renderedImage<Content: View>(_ content: Content, aspectRatio: CGFloat?) -> some View {
        let base = content
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)

        let maxHeight = ImageViewportSizing.maxHeight(for: heightMode, screenHeight: nil)
        if let aspectRatio {
            if let maxHeight {
                base
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxHeight: maxHeight)
            } else {
                base.aspectRatio(aspectRatio, contentMode: .fit)
            }
        } else if let maxHeight {
            base.frame(maxHeight: maxHeight)
        } else {
            base.frame(minHeight: 160)
        }
    }
}

/// AVKit's transition completion is MainActor-isolated; the delegate method is
/// not. This box lets the completion call back without a sendability error.
enum MediaPlaybackFullScreenResumePolicy {
    /// AVKit pauses on dismiss. Resume only when the inline host is still
    /// attached; a detached or cancelled player must not keep playing audio.
    static func shouldResumePlayback(
        cancelled: Bool,
        isPlayingNow: Bool,
        hostIsAttached: Bool
    ) -> Bool {
        !cancelled && isPlayingNow && hostIsAttached
    }

    /// Committed dismiss with a detached host must stop audio even if AVKit
    /// never paused and teardown is waiting on a later hide.
    static func shouldPausePlayback(
        cancelled: Bool,
        hostIsAttached: Bool
    ) -> Bool {
        !cancelled && !hostIsAttached
    }
}

struct FullScreenEndHandoff: @unchecked Sendable {
    let onDidEnd: ((Bool) -> Void)?
    let onTransitionFinished: (() -> Void)?

    func complete(cancelled: Bool, player: AVPlayer?, isPlayingNow: Bool, hostIsAttached: Bool) {
        if WorkspaceMediaOverlayNavigationPolicy.shouldEndOverlay(cancelled: cancelled) {
            onTransitionFinished?()
            onDidEnd?(hostIsAttached)
        }
        if MediaPlaybackFullScreenResumePolicy.shouldResumePlayback(
            cancelled: cancelled,
            isPlayingNow: isPlayingNow,
            hostIsAttached: hostIsAttached
        ) {
            player?.play()
        } else if MediaPlaybackFullScreenResumePolicy.shouldPausePlayback(
            cancelled: cancelled,
            hostIsAttached: hostIsAttached
        ) {
            player?.pause()
        }
    }
}

struct AVPlayerViewControllerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    var captionText: String? = nil
    var onFullScreenChange: ((Bool) -> Void)?
    var onFullScreenWillEnd: (() -> Void)?
    var onFullScreenDidEnd: ((Bool) -> Void)?
    var onFullScreenTransitionFinished: (() -> Void)?
    var onPictureInPictureChange: ((Bool) -> Void)?
    var onPictureInPictureDidStop: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFullScreenChange: onFullScreenChange,
            onFullScreenWillEnd: onFullScreenWillEnd,
            onFullScreenDidEnd: onFullScreenDidEnd,
            onFullScreenTransitionFinished: onFullScreenTransitionFinished,
            onPictureInPictureChange: onPictureInPictureChange,
            onPictureInPictureDidStop: onPictureInPictureDidStop
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        configure(controller)
        controller.player = player
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onFullScreenChange = onFullScreenChange
        context.coordinator.onFullScreenWillEnd = onFullScreenWillEnd
        context.coordinator.onFullScreenDidEnd = onFullScreenDidEnd
        context.coordinator.onFullScreenTransitionFinished = onFullScreenTransitionFinished
        context.coordinator.onPictureInPictureChange = onPictureInPictureChange
        context.coordinator.onPictureInPictureDidStop = onPictureInPictureDidStop
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        uiViewController.delegate = context.coordinator
        configure(uiViewController)
        applyCaption(captionText, to: uiViewController)
    }

    private func configure(_ controller: AVPlayerViewController) {
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.view.accessibilityIdentifier = "videoPlayer.native"
        // Overlay captions instead of injecting AVPlayer closed captions.
        applyCaption(captionText, to: controller)
    }

    private func applyCaption(_ text: String?, to controller: AVPlayerViewController) {
        let tag = 0x0C4D
        guard let overlay = controller.contentOverlayView else { return }
        let label: UILabel
        if let existing = overlay.viewWithTag(tag) as? UILabel {
            label = existing
        } else {
            label = UILabel()
            label.tag = tag
            label.numberOfLines = 3
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -16),
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -52),
            ])
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        label.text = trimmed.isEmpty ? nil : "  \(trimmed)  "
        label.isHidden = trimmed.isEmpty
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onFullScreenChange: ((Bool) -> Void)?
        var onFullScreenWillEnd: (() -> Void)?
        var onFullScreenDidEnd: ((Bool) -> Void)?
        var onFullScreenTransitionFinished: (() -> Void)?
        var onPictureInPictureChange: ((Bool) -> Void)?
        var onPictureInPictureDidStop: ((Bool) -> Void)?
        private var wasPlayingBeforeFullScreen = false

        init(
            onFullScreenChange: ((Bool) -> Void)?,
            onFullScreenWillEnd: (() -> Void)?,
            onFullScreenDidEnd: ((Bool) -> Void)?,
            onFullScreenTransitionFinished: (() -> Void)?,
            onPictureInPictureChange: ((Bool) -> Void)?,
            onPictureInPictureDidStop: ((Bool) -> Void)?
        ) {
            self.onFullScreenChange = onFullScreenChange
            self.onFullScreenWillEnd = onFullScreenWillEnd
            self.onFullScreenDidEnd = onFullScreenDidEnd
            self.onFullScreenTransitionFinished = onFullScreenTransitionFinished
            self.onPictureInPictureChange = onPictureInPictureChange
            self.onPictureInPictureDidStop = onPictureInPictureDidStop
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            wasPlayingBeforeFullScreen = playerViewController.player?.timeControlStatus == .playing
                || playerViewController.player?.rate ?? 0 > 0
            onFullScreenChange?(true)
            if wasPlayingBeforeFullScreen {
                playerViewController.player?.play()
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            // Keep ownership through the dismiss animation. AVKit still holds
            // the player until this coordinator completes.
            onFullScreenWillEnd?()
            let handoff = FullScreenEndHandoff(
                onDidEnd: onFullScreenDidEnd,
                onTransitionFinished: onFullScreenTransitionFinished
            )
            MainActor.assumeIsolated {
                let isPlayingNow = playerViewController.player?.timeControlStatus == .playing
                    || playerViewController.player?.rate ?? 0 > 0
                let player = playerViewController.player
                let animated = coordinator.animate(alongsideTransition: nil) { context in
                    let hostIsAttached = playerViewController.view.window != nil
                        || playerViewController.view.superview != nil
                    handoff.complete(
                        cancelled: context.isCancelled,
                        player: player,
                        isPlayingNow: isPlayingNow,
                        hostIsAttached: hostIsAttached
                    )
                }
                if !animated {
                    let hostIsAttached = playerViewController.view.window != nil
                        || playerViewController.view.superview != nil
                    handoff.complete(
                        cancelled: false,
                        player: player,
                        isPlayingNow: isPlayingNow,
                        hostIsAttached: hostIsAttached
                    )
                }
            }
        }

        func playerViewControllerWillStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            onPictureInPictureChange?(true)
        }

        func playerViewControllerDidStopPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            let hostIsAttached = playerViewController.view.window != nil
                || playerViewController.view.superview != nil
            onPictureInPictureDidStop?(hostIsAttached)
        }
    }
}

@MainActor
enum SystemVideoPlaybackPresenter {
    static func present(
        source: AuthenticatedMediaSource,
        from presenter: UIViewController,
        telemetrySource: String = "authenticated_media",
        telemetrySessionId: String? = nil,
        startedNs: UInt64? = nil
    ) {
        let controller = AuthenticatedMediaPlayerViewController()
        controller.configure(
            source: source,
            autoplay: false,
            telemetrySource: telemetrySource,
            telemetrySessionId: telemetrySessionId,
            startedNs: startedNs
        )
        controller.modalPresentationStyle = .fullScreen
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true) {
            controller.player?.play()
        }
    }
}
