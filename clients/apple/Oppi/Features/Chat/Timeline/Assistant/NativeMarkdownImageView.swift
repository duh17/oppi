import OSLog
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
/// - failed: bracketed alt text in comment color
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
    private let svgHTMLTracker = HTMLContentTracker()

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
    /// loading placeholder (80pt), loaded (aspect-fit), and error (collapsed) states.
    private var heightConstraint: NSLayoutConstraint?

    /// Placeholder height shown while loading. Ensures the view is visible
    /// in the stack view during async fetches (workspace or URLSession).
    private static let loadingPlaceholderHeight: CGFloat = 80

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
        errorLabel.font = .preferredFont(forTextStyle: .body)
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
                if let image = UIImage(data: data) {
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
                if let image = UIImage(data: data) {
                    Self.imageCache.setObject(image, forKey: url as NSURL)
                    showLoadedState(image: image)
                    return
                }
                // UIImage failed — try SVG via web view.
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

            if let image = UIImage(data: data) {
                Self.imageCache.setObject(image, forKey: url as NSURL)
                showLoadedState(image: image)
                return
            }

            // UIImage failed — try SVG via web view.
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

    /// Export mode: show alt text in a styled box. No spinner, no async load.
    /// If the image was previously viewed, the cache check above already
    /// handled it. This path is for uncached images only.
    private func showExportPlaceholder(alt: String) {
        let palette = ThemeRuntimeState.currentPalette()
        backgroundColor = UIColor(palette.bgHighlight)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = alt.isEmpty ? "[image]" : alt

        heightConstraint?.constant = alt.isEmpty ? 30 : 40
        isHidden = false

        spinner.stopAnimating()
        altLabel.isHidden = false
        imageView.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
    }

    private func showLoadingState(alt: String) {
        let palette = ThemeRuntimeState.currentPalette()
        backgroundColor = UIColor(palette.bgHighlight)
        spinner.color = UIColor(palette.comment)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = alt.isEmpty ? nil : alt

        // Ensure loading placeholder height is active.
        heightConstraint?.constant = Self.loadingPlaceholderHeight
        isHidden = false

        spinner.startAnimating()
        altLabel.isHidden = alt.isEmpty
        imageView.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
    }

    private func showLoadedState(image: UIImage) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true

        let aspectRatio = image.size.height / max(image.size.width, 1)
        let displayWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? 360)
        let displayHeight = ImageViewportSizing.fittedHeight(
            forWidth: displayWidth,
            aspectRatio: aspectRatio,
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

        if let aspectRatio {
            let displayHeight = ImageViewportSizing.fittedHeight(
                forWidth: displayWidth,
                aspectRatio: 1.0 / aspectRatio,
                screenHeight: window?.windowScene?.screen.bounds.height
            )
            heightConstraint?.constant = max(displayHeight, Self.loadingPlaceholderHeight)
        } else {
            // No viewBox — use a square-ish fallback, still capped by the shared inline image policy.
            let cappedHeight = ImageViewportSizing.maxHeight(
                for: .singleScreenFit,
                screenHeight: window?.windowScene?.screen.bounds.height
            ) ?? displayWidth
            heightConstraint?.constant = min(displayWidth, cappedHeight)
        }

        let webView = ensureSVGWebView()
        webView.isHidden = false
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

    /// Lazily create and configure the WKWebView for SVG rendering.
    private func ensureSVGWebView() -> PiWKWebView {
        if let existing = svgWebView {
            return existing
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = PiWKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
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
        imageView.isHidden = true
        svgWebView?.isHidden = true

        if alt.isEmpty {
            heightConstraint?.constant = 0
            isHidden = true
            invalidateTimelineLayout()
            return
        }

        let palette = ThemeRuntimeState.currentPalette()
        errorLabel.textColor = UIColor(palette.comment)
        errorLabel.text = "[\(alt)]"
        errorLabel.isHidden = false
        // Shrink to fit the error label instead of holding loading placeholder height.
        heightConstraint?.constant = 40
        backgroundColor = .clear
        invalidateTimelineLayout()
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    @objc private func handleTap() {
        guard let image = imageView.image else { return }
        FullScreenImageViewController.present(image: image)
    }
}
