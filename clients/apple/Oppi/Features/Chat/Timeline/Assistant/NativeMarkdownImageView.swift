import OSLog
import SwiftUI
import UIKit
import WebKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "MarkdownImage")

/// UIKit view that loads and displays an image referenced in markdown.
///
/// Supports both workspace-relative paths (loaded via the workspace file API)
/// and absolute http/https URLs (loaded via URLSession).
///
/// Lifecycle: apply(url:alt:fetchWorkspaceFile:) triggers an async load. States:
/// - loading: spinner + alt text label
/// - loaded: image view (tap to fullscreen)
/// - failed: muted placeholder label (alt text when available, otherwise `[image]`)
@MainActor
final class NativeMarkdownImageView: UIView {
    private static let imageCache = NSCache<NSURL, UIImage>()
    private static let svgDataCache = NSCache<NSURL, NSData>()

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let altLabel = UILabel()
    private let imageView = UIImageView()
    private let errorLabel = UILabel()

    /// Web view for rendering SVG and animated images that UIImage doesn't support.
    /// Created lazily on first SVG load to avoid WKWebView overhead for
    /// raster-image-only messages.
    private var svgWebView: PiWKWebView?
    private var svgTapOverlay: UIView?
    private let svgNavigationBlocker = ImagePreviewNavigationBlocker()
    private let svgHTMLTracker = HTMLContentTracker()
    private var svgPreviewData: Data?

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?

    typealias FetchWorkspaceFile = (_ workspaceID: String, _ path: String) async throws -> Data
    typealias FetchSessionFile = (_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Active height constraint — managed explicitly so we can swap between
    /// loading placeholder, loaded aspect-fit media, and error states.
    private var heightConstraint: NSLayoutConstraint?

    /// Placeholder height shown while loading. Ensures the view is visible
    /// in the stack view during async fetches (workspace or URLSession).
    private static let loadingPlaceholderHeight = ImageViewportSizing.policy(
        for: .inlineProse,
        screenHeight: UIScreen.main.bounds.height
    ).placeholderHeight

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        clipsToBounds = true
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        altLabel.translatesAutoresizingMaskIntoConstraints = false
        altLabel.font = .preferredFont(forTextStyle: .caption1)
        altLabel.textAlignment = .center
        altLabel.numberOfLines = 2

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        imageView.isUserInteractionEnabled = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        errorLabel.isHidden = true

        addSubview(imageView)
        addSubview(spinner)
        addSubview(altLabel)
        addSubview(errorLabel)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        imageView.addGestureRecognizer(tapGesture)

        // SVG web view constraints are deferred until the view is lazily created.
        // See ensureSVGWebView().

        // Start with loading placeholder height so stack view allocates space.
        let hc = heightAnchor.constraint(equalToConstant: Self.loadingPlaceholderHeight)
        heightConstraint = hc

        NSLayoutConstraint.activate([
            hc,

            // Loading state: spinner + alt
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),

            altLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
            altLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            altLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            // Image view fills available width
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Error label centered
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            flushSVGIfReady()
        } else {
            svgHTMLTracker.markNotReady()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        flushSVGIfReady()
    }

    func apply(
        url: URL,
        alt: String,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?,
        renderingMode: ContentRenderingMode = .live
    ) {
        guard url != currentURL else { return }
        currentURL = url

        loadTask?.cancel()

        // Check synchronous cache first — works for both live and export modes.
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            showLoadedState(image: cached)
            return
        }
        if let cachedSVGData = Self.svgDataCache.object(forKey: url as NSURL) {
            showSVGLoadedState(data: cachedSVGData as Data)
            return
        }

        switch renderingMode {
        case .export:
            // Export mode: show alt text immediately. No async network load —
            // the snapshot happens right after layout, so a loading spinner
            // would be captured. Alt text is honest and renders instantly.
            showExportPlaceholder(alt: alt)

        case .live:
            showLoadingState(alt: alt)
            loadTask = Task { [weak self] in
                await self?.loadImage(
                    url: url,
                    alt: alt,
                    fetchWorkspaceFile: fetchWorkspaceFile,
                    fetchSessionFile: fetchSessionFile
                )
            }
        }
    }

    private func loadImage(
        url: URL,
        alt: String,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?
    ) async {
        // Try session-scoped file path first for absolute markdown paths.
        if let components = SessionFileURL.parse(url), let fetchSessionFile {
            do {
                let data = try await fetchSessionFile(
                    components.workspaceID,
                    components.sessionID,
                    components.filePath
                )
                guard !Task.isCancelled else { return }
                if let image = await Self.decodeRasterImage(data: data) {
                    Self.imageCache.setObject(image, forKey: url as NSURL)
                    showLoadedState(image: image)
                    return
                }
                if MediaMimeType.isSVGData(data)
                    || components.filePath.lowercased().hasSuffix(".svg") {
                    Self.svgDataCache.setObject(data as NSData, forKey: url as NSURL)
                    showSVGLoadedState(data: data)
                    return
                }
                logger.error("Session file is not a valid image: \(components.filePath) (\(data.count) bytes)")
            } catch {
                logger.error("Session image load failed: \(error.localizedDescription) path=\(components.filePath)")
                guard !Task.isCancelled else { return }
            }
        }

        // Try workspace file path next.
        if let components = WorkspaceFileURL.parse(url), let fetchWorkspaceFile {
            do {
                let data = try await fetchWorkspaceFile(components.workspaceID, components.filePath)
                guard !Task.isCancelled else { return }
                if let image = await Self.decodeRasterImage(data: data) {
                    Self.imageCache.setObject(image, forKey: url as NSURL)
                    showLoadedState(image: image)
                    return
                }
                // Raster decode failed — try SVG via web view.
                if MediaMimeType.isSVGData(data)
                    || components.filePath.lowercased().hasSuffix(".svg") {
                    Self.svgDataCache.setObject(data as NSData, forKey: url as NSURL)
                    showSVGLoadedState(data: data)
                    return
                }
                logger.error("Workspace file is not a valid image: \(components.filePath) (\(data.count) bytes)")
            } catch {
                logger.error("Workspace image load failed: \(error.localizedDescription) path=\(components.filePath)")
                guard !Task.isCancelled else { return }
            }
        }

        // Fall back to direct URL fetch (http/https).
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            showErrorState(alt: alt)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }

            // Validate HTTP response.
            if let httpResponse = response as? HTTPURLResponse,
               !(200 ..< 300).contains(httpResponse.statusCode) {
                showErrorState(alt: alt)
                return
            }

            if let image = await Self.decodeRasterImage(data: data) {
                Self.imageCache.setObject(image, forKey: url as NSURL)
                showLoadedState(image: image)
                return
            }

            // Raster decode failed — try SVG via web view.
            if MediaMimeType.isSVGData(data) || url.pathExtension.lowercased() == "svg" {
                Self.svgDataCache.setObject(data as NSData, forKey: url as NSURL)
                showSVGLoadedState(data: data)
                return
            }

            showErrorState(alt: alt)
        } catch {
            guard !Task.isCancelled else { return }
            showErrorState(alt: alt)
        }
    }

    private static func decodeRasterImage(data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            ImageMediaInspector.downsampledImage(data: data, maxPixelSize: 1_600)
        }.value
    }

    private func normalizedAltText(_ alt: String) -> String? {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bracketedFallbackText(for alt: String) -> String {
        guard let alt = normalizedAltText(alt) else { return "[image]" }
        return "[\(alt)]"
    }

    /// Export mode: show alt text in a styled box. No spinner, no async load.
    /// If the image was previously viewed, the cache check above already
    /// handled it. This path is for uncached images only.
    private func showExportPlaceholder(alt: String) {
        let palette = ThemeRuntimeState.currentPalette()
        let placeholderText = normalizedAltText(alt) ?? "[image]"
        backgroundColor = UIColor(palette.bgHighlight)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = placeholderText

        heightConstraint?.constant = placeholderText == "[image]" ? 30 : 40
        isHidden = false

        spinner.stopAnimating()
        altLabel.isHidden = false
        imageView.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
    }

    private func showLoadingState(alt: String) {
        let palette = ThemeRuntimeState.currentPalette()
        let normalizedAlt = normalizedAltText(alt)
        backgroundColor = UIColor(palette.bgHighlight)
        spinner.color = UIColor(palette.comment)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = normalizedAlt

        // Ensure loading placeholder height is active.
        heightConstraint?.constant = Self.loadingPlaceholderHeight
        isHidden = false

        spinner.startAnimating()
        altLabel.isHidden = normalizedAlt == nil
        imageView.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
    }

    private func showLoadedState(image: UIImage) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true

        let heightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(
            width: image.size.width,
            height: image.size.height
        ) ?? 1
        let displayWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)
        let displayHeight = ImageViewportSizing.fittedHeight(
            forWidth: displayWidth,
            heightToWidthRatio: heightToWidthRatio,
            surface: .inlineProse,
            screenHeight: window?.windowScene?.screen.bounds.height
        )

        heightConstraint?.constant = max(displayHeight, Self.loadingPlaceholderHeight)

        imageView.image = image
        imageView.isHidden = false
        backgroundColor = .clear

        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        invalidateTimelineLayout()
    }

    /// Render SVG data in a WKWebView. Called when `UIImage(data:)` fails
    /// but the content is detected as SVG.
    private func showSVGLoadedState(data: Data) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true
        imageView.isHidden = true

        let aspectRatio = MediaMimeType.extractSVGViewBoxAspectRatio(data)
        let displayWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)

        if let aspectRatio,
           let heightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(1.0 / aspectRatio) {
            let displayHeight = ImageViewportSizing.fittedHeight(
                forWidth: displayWidth,
                heightToWidthRatio: heightToWidthRatio,
                surface: .inlineProse,
                screenHeight: window?.windowScene?.screen.bounds.height
            )
            heightConstraint?.constant = max(displayHeight, Self.loadingPlaceholderHeight)
        } else {
            heightConstraint?.constant = Self.loadingPlaceholderHeight
        }

        svgPreviewData = data
        let webView = ensureSVGWebView()
        webView.isHidden = false
        ensureSVGTapOverlay().isHidden = false
        if let html = svgHTMLTracker.setContent(makeSVGHTML(data: data)) {
            webView.loadHTMLString(html, baseURL: nil)
        }

        backgroundColor = .clear
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        invalidateTimelineLayout()
    }

    /// Create an HTML document that embeds SVG data for WKWebView rendering.
    /// Uses a data URI via `<img>` for simplicity and consistency with
    /// `AnimatedImageWebContainerView`.
    private func makeSVGHTML(data: Data) -> String {
        let base64 = data.base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(ImagePreviewWebSecurity.contentSecurityPolicy)">
          <style>
            html, body {
              margin: 0; padding: 0;
              background: transparent;
              overflow: hidden;
              width: 100%; height: 100%;
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
              height: auto;
            }
          </style>
        </head>
        <body>
          <img src="data:image/svg+xml;base64,\(base64)" />
        </body>
        </html>
        """
    }

    private func flushSVGIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0,
              let webView = svgWebView else { return }
        if let html = svgHTMLTracker.markReady() {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func ensureSVGTapOverlay() -> UIView {
        if let existing = svgTapOverlay {
            return existing
        }

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = true
        overlay.accessibilityIdentifier = "markdown-image.svg.tap-overlay"
        overlay.accessibilityLabel = "Open image preview"
        overlay.accessibilityTraits = [.image, .button]
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSVGTap))
        overlay.addGestureRecognizer(tapGesture)

        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        svgTapOverlay = overlay
        return overlay
    }

    /// Lazily create and configure the WKWebView for SVG rendering.
    private func ensureSVGWebView() -> PiWKWebView {
        if let existing = svgWebView {
            return existing
        }
        let webView = PiWKWebView(frame: .zero, configuration: ImagePreviewWebSecurity.makeConfiguration())
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = svgNavigationBlocker
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSVGTap))
        tapGesture.cancelsTouchesInView = false
        webView.addGestureRecognizer(tapGesture)
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }
        webView.isHidden = true

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        svgWebView = webView
        return webView
    }

    private func showErrorState(alt: String) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        imageView.isHidden = true
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true

        let palette = ThemeRuntimeState.currentPalette()
        errorLabel.textColor = UIColor(palette.comment)
        errorLabel.text = bracketedFallbackText(for: alt)
        errorLabel.isHidden = false
        heightConstraint?.constant = Self.loadingPlaceholderHeight
        backgroundColor = UIColor(palette.bgHighlight)
        isHidden = false

        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        invalidateTimelineLayout()
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    @objc private func handleTap() {
        guard let image = imageView.image else { return }
        FullScreenImageViewController.present(image: image)
    }

    @objc private func handleSVGTap() {
        guard let data = svgPreviewData,
              let presenter = nearestViewController() else { return }

        FullScreenImageDataPreviewPresenter.present(data: data, mimeType: "image/svg+xml", from: presenter)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

private struct FullScreenMarkdownImageDataPreview: View {
    let data: Data
    let mimeType: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                DataImagePreviewView(
                    data: data,
                    mimeType: mimeType,
                    maxPixelSize: 2_400,
                    heightMode: .unrestricted,
                    allowsFullscreenStaticImage: true
                )
                .padding()
            }
            .background(Color.themeBg)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
