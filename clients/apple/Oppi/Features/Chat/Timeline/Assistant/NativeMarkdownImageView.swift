import Darwin
import Network
import OSLog
import SwiftUI
import UIKit
import WebKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "MarkdownImage")

/// UIKit view that loads and displays an image referenced in markdown.
///
/// Supports workspace/session paths loaded through Oppi's file APIs, plus
/// explicit tap-to-load for public HTTPS markdown image URLs.
///
/// Lifecycle: apply(url:alt:fetchWorkspaceFile:) triggers an async load for
/// trusted Oppi file URLs. Direct remote URLs first show a prompt. States:
/// - loading: spinner + alt text label
/// - remote prompt: alt text + Load remote image button
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
    private let remotePromptStack = UIStackView()
    private let remotePromptLabel = UILabel()
    private let remoteLoadButton = UIButton(type: .system)

    /// Web view for rendering SVG and animated images that UIImage doesn't support.
    /// Created lazily on first SVG load to avoid WKWebView overhead for
    /// raster-image-only messages.
    private var svgWebView: ReviewCommentWKWebView?
    private var svgTapOverlay: UIView?
    private let svgNavigationBlocker = ImagePreviewNavigationBlocker()
    private let svgHTMLTracker = HTMLContentTracker()
    private var svgPreviewData: Data?

    private var currentURL: URL?
    private var pendingRemoteLoad: PendingImageLoad?
    private var loadTask: Task<Void, Never>?

    typealias FetchWorkspaceFile = (_ workspaceID: String, _ path: String) async throws -> Data
    typealias FetchSessionFile = (_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data
    typealias FetchRemoteImage = (_ url: URL) async throws -> Data

    var fetchRemoteImage: FetchRemoteImage = { url in
        try await RemoteMarkdownImageFetcher.fetch(url)
    }

    private struct PendingImageLoad {
        let url: URL
        let alt: String
        let fetchWorkspaceFile: FetchWorkspaceFile?
        let fetchSessionFile: FetchSessionFile?
    }

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

        remotePromptStack.translatesAutoresizingMaskIntoConstraints = false
        remotePromptStack.axis = .vertical
        remotePromptStack.alignment = .center
        remotePromptStack.spacing = 8
        remotePromptStack.isHidden = true

        remotePromptLabel.translatesAutoresizingMaskIntoConstraints = false
        remotePromptLabel.font = .preferredFont(forTextStyle: .caption1)
        remotePromptLabel.textAlignment = .center
        remotePromptLabel.numberOfLines = 2

        var buttonConfig = UIButton.Configuration.bordered()
        buttonConfig.title = "Load remote image"
        buttonConfig.image = UIImage(systemName: "arrow.down.circle")
        buttonConfig.imagePadding = 6
        remoteLoadButton.configuration = buttonConfig
        remoteLoadButton.addTarget(self, action: #selector(handleRemoteLoadTap), for: .touchUpInside)

        remotePromptStack.addArrangedSubview(remotePromptLabel)
        remotePromptStack.addArrangedSubview(remoteLoadButton)

        addSubview(imageView)
        addSubview(spinner)
        addSubview(altLabel)
        addSubview(errorLabel)
        addSubview(remotePromptStack)

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

            // Remote images require an explicit tap before network fetch.
            remotePromptStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            remotePromptStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            remotePromptStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            remotePromptStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
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
            switch RemoteMarkdownImagePolicy.decision(for: url) {
            case .internalImageURL, .unsupported:
                startImageLoad(url: url, alt: alt, fetchWorkspaceFile: fetchWorkspaceFile, fetchSessionFile: fetchSessionFile)
            case .loadableRemote:
                pendingRemoteLoad = PendingImageLoad(
                    url: url,
                    alt: alt,
                    fetchWorkspaceFile: fetchWorkspaceFile,
                    fetchSessionFile: fetchSessionFile
                )
                showRemoteLoadPrompt(alt: alt)
            case .blockedRemote:
                pendingRemoteLoad = nil
                showBlockedRemoteState(alt: alt)
            }
        }
    }

    private func startImageLoad(
        url: URL,
        alt: String,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?
    ) {
        pendingRemoteLoad = nil
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

    @objc private func handleRemoteLoadTap() {
        guard let pending = pendingRemoteLoad else { return }
        loadTask?.cancel()
        startImageLoad(
            url: pending.url,
            alt: pending.alt,
            fetchWorkspaceFile: pending.fetchWorkspaceFile,
            fetchSessionFile: pending.fetchSessionFile
        )
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

        // Fall back to direct remote fetch only after the user explicitly taps
        // the remote-image prompt. Direct remote loads use a constrained,
        // ephemeral session and reject unsafe targets.
        switch RemoteMarkdownImagePolicy.decision(for: url) {
        case .loadableRemote:
            break
        case .blockedRemote:
            showBlockedRemoteState(alt: alt)
            return
        case .internalImageURL, .unsupported:
            showErrorState(alt: alt)
            return
        }

        do {
            let data = try await fetchRemoteImage(url)
            guard !Task.isCancelled else { return }

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
            logger.error("Remote image load failed: \(error.localizedDescription) host=\(url.host(percentEncoded: false) ?? "unknown")")
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

    private func hideRemotePrompt() {
        remotePromptStack.isHidden = true
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
        hideRemotePrompt()
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
    }

    private func showRemoteLoadPrompt(alt: String) {
        let palette = ThemeRuntimeState.currentPalette()
        let normalizedAlt = normalizedAltText(alt)
        backgroundColor = UIColor(palette.bgHighlight)
        remotePromptLabel.textColor = UIColor(palette.comment)
        remotePromptLabel.text = normalizedAlt.map { "Remote image: \($0)" } ?? "Remote image"
        heightConstraint?.constant = Self.loadingPlaceholderHeight
        isHidden = false

        spinner.stopAnimating()
        altLabel.isHidden = true
        imageView.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
        remotePromptStack.isHidden = false

        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        invalidateTimelineLayout()
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
        hideRemotePrompt()
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
    }

    private func showLoadedState(image: UIImage) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true
        hideRemotePrompt()
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
        hideRemotePrompt()
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
    private func ensureSVGWebView() -> ReviewCommentWKWebView {
        if let existing = svgWebView {
            return existing
        }
        let webView = ReviewCommentWKWebView(frame: .zero, configuration: ImagePreviewWebSecurity.makeConfiguration())
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
        showMessageState(text: bracketedFallbackText(for: alt))
    }

    private func showBlockedRemoteState(alt: String) {
        let text: String
        if let alt = normalizedAltText(alt) {
            text = "[\(alt) — remote image blocked]"
        } else {
            text = "[remote image blocked]"
        }
        showMessageState(text: text)
    }

    private func showMessageState(text: String) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        imageView.isHidden = true
        hideRemotePrompt()
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true

        let palette = ThemeRuntimeState.currentPalette()
        errorLabel.textColor = UIColor(palette.comment)
        errorLabel.text = text
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

enum RemoteMarkdownImagePolicy {
    enum Decision: Equatable {
        case internalImageURL
        case loadableRemote
        case blockedRemote
        case unsupported
    }

    typealias ResolveHost = @Sendable (_ host: String) async throws -> [String]

    static func decision(for url: URL) -> Decision {
        if SessionFileURL.parse(url) != nil || WorkspaceFileURL.parse(url) != nil {
            return .internalImageURL
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unsupported
        }

        guard scheme == "https" else {
            return .blockedRemote
        }

        guard let host = normalizedHost(for: url), isPublicNetworkHost(host) else {
            return .blockedRemote
        }

        return .loadableRemote
    }

    static func resolvedDecision(
        for url: URL,
        resolveHost: ResolveHost = RemoteMarkdownImageHostResolver.resolve
    ) async -> Decision {
        let initialDecision = decision(for: url)
        guard initialDecision == .loadableRemote,
              let host = normalizedHost(for: url) else {
            return initialDecision
        }

        do {
            let addresses = try await resolveHost(host)
            guard !addresses.isEmpty else { return .blockedRemote }
            return addresses.allSatisfy(isResolvedPublicAddress) ? .loadableRemote : .blockedRemote
        } catch {
            return .blockedRemote
        }
    }

    private static func normalizedHost(for url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        host = host.lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }

    private static func isResolvedPublicAddress(_ address: String) -> Bool {
        if let ipv4 = IPv4Address(address) {
            return !isBlockedIPv4(Array(ipv4.rawValue))
        }

        if let ipv6 = IPv6Address(address) {
            return !isBlockedIPv6(Array(ipv6.rawValue))
        }

        return false
    }

    private static func isPublicNetworkHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return false
        }

        if let ipv4 = IPv4Address(host) {
            return !isBlockedIPv4(Array(ipv4.rawValue))
        }

        if let ipv6 = IPv6Address(host) {
            return !isBlockedIPv6(Array(ipv6.rawValue))
        }

        // Unqualified names are commonly local-network hosts. Requiring a dot
        // keeps direct remote markdown images on public DNS names unless the
        // URL is one of Oppi's workspace/session file API URLs handled above.
        return host.contains(".")
    }

    private static func isBlockedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        switch bytes[0] {
        case 0, 10, 127:
            return true
        case 100:
            return (bytes[1] & 0b1100_0000) == 0b0100_0000 // 100.64.0.0/10
        case 169:
            return bytes[1] == 254 // link-local
        case 172:
            return (16 ... 31).contains(bytes[1])
        case 192:
            return bytes[1] == 168
        case 198:
            return bytes[1] == 18 || bytes[1] == 19 // benchmarking
        case 224 ... 255:
            return true // multicast and reserved ranges
        default:
            return false
        }
    }

    private static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true } // unspecified
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true } // loopback
        if bytes[0] == 0xfe && (bytes[1] & 0b1100_0000) == 0b1000_0000 { return true } // fe80::/10
        if (bytes[0] & 0b1111_1110) == 0b1111_1100 { return true } // fc00::/7
        if bytes[0] == 0xff { return true } // multicast
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return true } // docs

        let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        if isIPv4Mapped {
            return isBlockedIPv4(Array(bytes[12 ... 15]))
        }

        return false
    }
}

private enum RemoteMarkdownImageLoadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidContentType(String?)
    case contentTooLarge(Int64)
    case blockedResolvedHost(String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Remote image response was invalid."
        case .httpStatus(let status):
            return "Remote image request failed with HTTP \(status)."
        case .invalidContentType(let contentType):
            return "Remote image content type is not allowed: \(contentType ?? "unknown")."
        case .contentTooLarge(let size):
            return "Remote image is too large: \(size) bytes."
        case .blockedResolvedHost(let host):
            return "Remote image resolved to a blocked address: \(host ?? "unknown")."
        }
    }
}

private enum RemoteMarkdownImageHostResolutionError: Error {
    case getaddrinfoFailed(Int32)
}

private enum RemoteMarkdownImageHostResolver {
    static func resolve(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var infoPointer: UnsafeMutablePointer<addrinfo>?
            let result = getaddrinfo(host, nil, &hints, &infoPointer)
            guard result == 0, let first = infoPointer else {
                throw RemoteMarkdownImageHostResolutionError.getaddrinfoFailed(result)
            }
            defer { freeaddrinfo(first) }

            var addresses: Set<String> = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let current = cursor {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let err = getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if err == 0 {
                    addresses.insert(String(cString: hostBuffer))
                }
                cursor = current.pointee.ai_next
            }
            return Array(addresses)
        }.value
    }
}

private final class RemoteMarkdownImageRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let resolveHost: RemoteMarkdownImagePolicy.ResolveHost

    init(resolveHost: @escaping RemoteMarkdownImagePolicy.ResolveHost) {
        self.resolveHost = resolveHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }

        Task {
            let decision = await RemoteMarkdownImagePolicy.resolvedDecision(for: url, resolveHost: resolveHost)
            completionHandler(decision == .loadableRemote ? request : nil)
        }
    }
}

private enum RemoteMarkdownImageFetcher {
    private static let maxBytes = 8 * 1_024 * 1_024

    static func fetch(
        _ url: URL,
        resolveHost: @escaping RemoteMarkdownImagePolicy.ResolveHost = RemoteMarkdownImageHostResolver.resolve
    ) async throws -> Data {
        guard await RemoteMarkdownImagePolicy.resolvedDecision(for: url, resolveHost: resolveHost) == .loadableRemote else {
            throw RemoteMarkdownImageLoadError.blockedResolvedHost(url.host(percentEncoded: false))
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "image/avif,image/webp,image/png,image/jpeg,image/gif,image/svg+xml;q=0.9,*/*;q=0.1",
            forHTTPHeaderField: "Accept"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false

        let delegate = RemoteMarkdownImageRedirectDelegate(resolveHost: resolveHost)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response)

        var data = Data()
        let expectedLength = response.expectedContentLength
        if expectedLength > 0 {
            data.reserveCapacity(min(Int(expectedLength), maxBytes))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                throw RemoteMarkdownImageLoadError.contentTooLarge(Int64(data.count))
            }
        }
        return data
    }

    private static func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteMarkdownImageLoadError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw RemoteMarkdownImageLoadError.httpStatus(httpResponse.statusCode)
        }
        let expectedLength = response.expectedContentLength
        if expectedLength > Int64(maxBytes) {
            throw RemoteMarkdownImageLoadError.contentTooLarge(expectedLength)
        }
        guard isAllowedContentType(response.mimeType) else {
            throw RemoteMarkdownImageLoadError.invalidContentType(response.mimeType)
        }
    }

    private static func isAllowedContentType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased(), !mimeType.isEmpty else {
            return false
        }
        return mimeType == "image/png"
            || mimeType == "image/jpeg"
            || mimeType == "image/jpg"
            || mimeType == "image/gif"
            || mimeType == "image/webp"
            || mimeType == "image/svg+xml"
            || mimeType == "image/avif"
    }
}
