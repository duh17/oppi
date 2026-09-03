import Darwin
import ImageIO
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

    private enum PreparedImageArtifact {
        case raster(image: UIImage, pixelSize: CGSize)
        case web(data: Data, mimeType: String, aspectRatio: CGFloat?)
    }

    private struct PreparedImageResult {
        let artifact: PreparedImageArtifact
        let filePath: String
    }

    /// One joined operation owns fetch, metadata inspection, raster decode, or
    /// web-rendered image preparation. Every runway/display waiter receives the
    /// same artifact instead of repeating work after a joined fetch.
    private struct InFlightLoad {
        let id: UUID
        let task: Task<PreparedImageResult, Error>
        var rasterPixelSize: CGSize?
        var metadataWaiters: [UUID: (CGSize) -> Void]
    }

    private static var inFlightLoads: [URL: InFlightLoad] = [:]
    #if DEBUG
    private static var debugPreparedOperationCount = 0
    static var debugRasterDecodeGateForTesting: (() async -> Void)?
    #endif

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let altLabel = UILabel()
    private let imageView = UIImageView()
    private let errorLabel = UILabel()
    private let remotePromptStack = UIStackView()
    private let remotePromptLabel = UILabel()
    private let remoteLoadButton = UIButton(type: .system)

    /// Web view for rendering SVG and animated images that UIImage doesn't support.
    /// Created lazily on first web-rendered image load to avoid WKWebView
    /// overhead for raster-image-only messages.
    private var svgWebView: ReviewCommentWKWebView?
    private var svgTapOverlay: UIControl?
    private let svgHTMLTracker = HTMLContentTracker()
    private var svgPreviewData: Data?
    private var svgPreviewMimeType: String?

    private struct RequestIdentity: Equatable {
        let url: URL
        let displayWidth: CGFloat?
        let preparationScope: ChatTimelinePreparationRunway.Scope?
        let preparationItemID: String?
        let preparationTarget: ChatTimelinePreparationRunway.ImageTarget?
    }

    private var currentURL: URL?
    private var currentRequestIdentity: RequestIdentity?
    private var currentAltText = ""
    private var preferredDisplayWidth: CGFloat?
    private var preparesForDisplay = true
    private var pendingRemoteLoad: PendingImageLoad?
    private var loadTask: Task<Void, Never>?
    private let visiblePreparationDemandID = UUID()
    private var currentPreparationContext: TimelineImagePreparationContext?
    private var usesCanonicalLoadingForCurrentRequest = false

    typealias FetchWorkspaceFile = (_ workspaceID: String, _ path: String) async throws -> Data
    typealias FetchSessionFile = (_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data
    typealias FetchHostFile = (_ path: String) async throws -> Data
    typealias FetchRemoteImage = (_ url: URL) async throws -> Data

    var fetchRemoteImage: FetchRemoteImage = { url in
        try await RemoteMarkdownImageFetcher.fetch(url)
    }

    /// Reader hosts use this to reserve the final item height and keep the
    /// viewport still. When set, async size changes do not invalidate the
    /// enclosing collection layout themselves.
    var onDisplayHeightChange: ((CGFloat) -> Void)?

    /// Reader render-ahead uses this distinct signal to commit geometry only
    /// after internal raster metadata/decode or SVG viewBox preparation has
    /// completed. Loading-placeholder changes are intentionally excluded.
    var onPreparedGeometry: ((CGFloat) -> Void)?
    #if DEBUG
    /// Height published from pixel metadata before the bitmap decode finishes.
    private(set) var debugPixelReservedHeightForTesting: CGFloat?
    #endif

    private struct PendingImageLoad {
        let url: URL
        let alt: String
        let fetchWorkspaceFile: FetchWorkspaceFile?
        let fetchSessionFile: FetchSessionFile?
        let fetchHostFile: FetchHostFile?
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            cancelPreparationDemand()
        }
    }

    /// Active height constraint — managed explicitly so we can swap between
    /// loading placeholder, loaded aspect-fit media, and error states.
    private var heightConstraint: NSLayoutConstraint?

    /// Placeholder height shown while loading. Ensures the view is visible
    /// in the stack view during async fetches (workspace or URLSession).
    private static let loadingPlaceholderHeight = ImageViewportSizing.defaultPlaceholderHeight

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
        if window != nil, preparesForDisplay {
            activatePreparedDisplay()
        } else if window == nil {
            svgHTMLTracker.markNotReady()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if preparesForDisplay {
            activatePreparedDisplay()
        }
    }

    func apply(
        url: URL,
        alt: String,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?,
        fetchHostFile: FetchHostFile? = nil,
        renderingMode: ContentRenderingMode = .live,
        preferredDisplayWidth: CGFloat? = nil,
        preparesForDisplay: Bool = true,
        preparationContext: TimelineImagePreparationContext? = nil
    ) {
        let canonicalWidth = preferredDisplayWidth.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        let identity = RequestIdentity(
            url: url,
            displayWidth: canonicalWidth,
            preparationScope: preparationContext?.scope,
            preparationItemID: preparationContext?.itemID,
            preparationTarget: preparationContext?.target
        )
        currentAltText = alt
        if identity == currentRequestIdentity {
            self.preparesForDisplay = self.preparesForDisplay || preparesForDisplay
            if usesCanonicalLoadingForCurrentRequest {
                refreshLoadedAccessibilityIfNeeded()
                if self.preparesForDisplay { activatePreparedDisplay() }
                return
            }
            currentPreparationContext = preparationContext
            if consumeTimelinePreparationIfAvailable(
                context: preparationContext,
                url: url,
                alt: alt
            ) {
                return
            }
            usesCanonicalLoadingForCurrentRequest = true
        } else {
            cancelPreparationDemand()
            currentRequestIdentity = identity
            currentURL = url
            self.preferredDisplayWidth = canonicalWidth
            self.preparesForDisplay = preparesForDisplay
            currentPreparationContext = preparationContext
            usesCanonicalLoadingForCurrentRequest = false
            svgPreviewData = nil
            svgPreviewMimeType = nil
            svgHTMLTracker.resetLoadedContent()
            #if DEBUG
            debugPixelReservedHeightForTesting = nil
            #endif

            loadTask?.cancel()

            if consumeTimelinePreparationIfAvailable(
                context: preparationContext,
                url: url,
                alt: alt
            ) {
                return
            }
            usesCanonicalLoadingForCurrentRequest = true
        }

        // Check synchronous cache first — works for markdown surfaces that do
        // not use the timeline's destination-size broker.
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            showLoadedState(image: cached)
            return
        }
        if let cachedSVGData = Self.svgDataCache.object(forKey: url as NSURL),
           let artifact = Self.preparedWebArtifact(
               data: cachedSVGData as Data,
               filePath: url.path
           ) {
            presentPreparedImage(artifact, url: url)
            return
        }

        switch renderingMode {
        case .export:
            // Export mode: show alt text immediately. No async network load —
            // the snapshot happens right after layout, so a loading spinner
            // would be captured. Alt text is honest and renders instantly.
            showExportPlaceholder(alt: alt)

        case .live, .staticReader:
            switch RemoteMarkdownImagePolicy.decision(for: url) {
            case .internalImageURL, .unsupported:
                startImageLoad(
                    url: url,
                    alt: alt,
                    fetchWorkspaceFile: fetchWorkspaceFile,
                    fetchSessionFile: fetchSessionFile,
                    fetchHostFile: fetchHostFile
                )
            case .loadableRemote:
                pendingRemoteLoad = PendingImageLoad(
                    url: url,
                    alt: alt,
                    fetchWorkspaceFile: fetchWorkspaceFile,
                    fetchSessionFile: fetchSessionFile,
                    fetchHostFile: fetchHostFile
                )
                showRemoteLoadPrompt(alt: alt)
            case .blockedRemote:
                pendingRemoteLoad = nil
                showBlockedRemoteState(alt: alt)
            }
        }
    }

    func cancelPreparationDemand() {
        guard let currentURL, let currentPreparationContext else { return }
        currentPreparationContext.cancel(
            url: currentURL,
            visibleDemandID: visiblePreparationDemandID
        )
        self.currentPreparationContext = nil
    }

    private func consumeTimelinePreparationIfAvailable(
        context: TimelineImagePreparationContext?,
        url: URL,
        alt: String
    ) -> Bool {
        guard let context,
              RemoteMarkdownImagePolicy.decision(for: url) == .internalImageURL else {
            return false
        }
        if let prepared = context.preparedImage(for: url) {
            showPreparedTimelineRaster(prepared)
            return true
        }

        switch context.request(url: url, visibleDemandID: visiblePreparationDemandID) {
        case .ready:
            guard let prepared = context.preparedImage(for: url) else { return false }
            showPreparedTimelineRaster(prepared)
        case .inFlight:
            showLoadingState(alt: alt)
        case .neverRequested:
            currentPreparationContext = nil
            return false
        }
        return true
    }

    private func showPreparedTimelineRaster(_ prepared: TimelinePreparedRasterImage) {
        applyFittedDisplayHeight(
            width: prepared.sourcePixelSize.width,
            height: prepared.sourcePixelSize.height
        )
        imageView.image = prepared.image
        showLoadedState(image: prepared.image)
    }

    private func startImageLoad(
        url: URL,
        alt: String,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?,
        fetchHostFile: FetchHostFile?
    ) {
        pendingRemoteLoad = nil
        showLoadingState(alt: alt)
        loadTask = Task { [weak self] in
            await self?.loadImage(
                url: url,
                alt: alt,
                fetchWorkspaceFile: fetchWorkspaceFile,
                fetchSessionFile: fetchSessionFile,
                fetchHostFile: fetchHostFile
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
            fetchSessionFile: pending.fetchSessionFile,
            fetchHostFile: pending.fetchHostFile
        )
    }

    private enum JoinedLoadError: LocalizedError {
        case unavailable

        var errorDescription: String? { "No permitted image loader is available" }
    }

    private func loadImage(
        url: URL,
        alt: String,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?,
        fetchHostFile: FetchHostFile?
    ) async {
        do {
            let prepared = try await joinedPreparedImage(
                url: url,
                fetchWorkspaceFile: fetchWorkspaceFile,
                fetchSessionFile: fetchSessionFile,
                fetchHostFile: fetchHostFile,
                onRasterMetadata: { [weak self] pixelSize in
                    self?.publishChatRasterMetadataIfNeeded(pixelSize)
                }
            )
            guard !Task.isCancelled, currentURL == url else { return }
            presentPreparedImage(prepared.artifact, url: url)
        } catch {
            guard !Task.isCancelled, currentURL == url else { return }
            logger.error("Markdown image load failed: \(error.localizedDescription) url=\(url.absoluteString)")
            if RemoteMarkdownImagePolicy.decision(for: url) == .blockedRemote {
                showBlockedRemoteState(alt: alt)
            } else {
                showErrorState(alt: alt)
            }
        }
    }

    private func joinedPreparedImage(
        url: URL,
        fetchWorkspaceFile: FetchWorkspaceFile?,
        fetchSessionFile: FetchSessionFile?,
        fetchHostFile: FetchHostFile?,
        onRasterMetadata: @escaping (CGSize) -> Void
    ) async throws -> PreparedImageResult {
        let waiterID = UUID()
        if var existing = Self.inFlightLoads[url] {
            if let pixelSize = existing.rasterPixelSize {
                onRasterMetadata(pixelSize)
            } else {
                existing.metadataWaiters[waiterID] = onRasterMetadata
                Self.inFlightLoads[url] = existing
            }
            return try await existing.task.value
        }

        let id = UUID()
        let remoteFetch = fetchRemoteImage
        let task = Task { @MainActor () throws -> PreparedImageResult in
            let data: Data
            let filePath: String
            if let components = SessionFileURL.parse(url), let fetchSessionFile {
                data = try await fetchSessionFile(
                    components.workspaceID,
                    components.sessionID,
                    components.filePath
                )
                filePath = components.filePath
            } else if let components = WorkspaceFileURL.parse(url), let fetchWorkspaceFile {
                data = try await fetchWorkspaceFile(
                    components.workspaceID,
                    components.filePath
                )
                filePath = components.filePath
            } else if let hostPath = HostFileURL.parse(url), let fetchHostFile {
                data = try await fetchHostFile(hostPath)
                filePath = hostPath
            } else {
                guard RemoteMarkdownImagePolicy.decision(for: url) == .loadableRemote else {
                    throw JoinedLoadError.unavailable
                }
                data = try await remoteFetch(url)
                filePath = url.path
            }

            #if DEBUG
            Self.debugPreparedOperationCount += 1
            #endif
            if let artifact = Self.preparedWebArtifact(data: data, filePath: filePath) {
                return PreparedImageResult(artifact: artifact, filePath: filePath)
            }
            let pixelSize = Self.pixelSize(of: data)
            if let pixelSize {
                Self.publishRasterMetadata(pixelSize, for: url, operationID: id)
            }
            guard let image = await Self.decodeRasterImage(data: data) else {
                logger.error("Fetched file is not a valid image: \(filePath) (\(data.count) bytes)")
                throw JoinedLoadError.unavailable
            }
            return PreparedImageResult(
                artifact: .raster(image: image, pixelSize: pixelSize ?? image.size),
                filePath: filePath
            )
        }
        Self.inFlightLoads[url] = InFlightLoad(
            id: id,
            task: task,
            rasterPixelSize: nil,
            metadataWaiters: [waiterID: onRasterMetadata]
        )

        do {
            let result = try await task.value
            if Self.inFlightLoads[url]?.id == id {
                Self.inFlightLoads.removeValue(forKey: url)
            }
            return result
        } catch {
            if Self.inFlightLoads[url]?.id == id {
                Self.inFlightLoads.removeValue(forKey: url)
            }
            throw error
        }
    }

    private static func publishRasterMetadata(
        _ pixelSize: CGSize,
        for url: URL,
        operationID: UUID
    ) {
        guard var load = inFlightLoads[url], load.id == operationID else { return }
        load.rasterPixelSize = pixelSize
        let waiters = load.metadataWaiters.values
        load.metadataWaiters.removeAll(keepingCapacity: false)
        inFlightLoads[url] = load
        for waiter in waiters {
            waiter(pixelSize)
        }
    }

    private static func decodeRasterImage(data: Data) async -> UIImage? {
        #if DEBUG
        if let debugRasterDecodeGateForTesting {
            await debugRasterDecodeGateForTesting()
        }
        #endif
        return await Task.detached(priority: .userInitiated) {
            ImageMediaInspector.downsampledImage(data: data, maxPixelSize: 1_600)
        }.value
    }

    private static func preparedWebArtifact(
        data: Data,
        filePath: String
    ) -> PreparedImageArtifact? {
        let pathMimeType = MediaMimeType.imageMimeType(
            forPathExtension: (filePath as NSString).pathExtension
        )
        let inspection = ImageMediaInspector.inspect(data: data, mimeType: pathMimeType)
        guard inspection.prefersWebRenderer else { return nil }
        let mimeType = MediaMimeType.safeImageMimeType(
            inspection.normalizedMimeType,
            fallback: MediaMimeType.isSVGData(data) ? "image/svg+xml" : "image/gif"
        )
        return .web(
            data: data,
            mimeType: mimeType,
            aspectRatio: inspection.aspectRatio
                ?? MediaMimeType.extractSVGViewBoxAspectRatio(data)
        )
    }

    /// Timeline rows preserve their historical async reflow behavior by using
    /// cheap ImageIO dimensions as soon as fetch completes. Reader probes have
    /// `onPreparedGeometry` installed and wait for the joined decode artifact
    /// before committing durable geometry.
    private func publishChatRasterMetadataIfNeeded(_ pixelSize: CGSize) {
        guard onPreparedGeometry == nil else { return }
        applyFittedDisplayHeight(width: pixelSize.width, height: pixelSize.height)
        #if DEBUG
        debugPixelReservedHeightForTesting = heightConstraint?.constant
        #endif
    }

    private func presentPreparedImage(_ artifact: PreparedImageArtifact, url: URL) {
        switch artifact {
        case .raster(let image, let pixelSize):
            Self.imageCache.setObject(image, forKey: url as NSURL)
            applyFittedDisplayHeight(width: pixelSize.width, height: pixelSize.height)
            #if DEBUG
            debugPixelReservedHeightForTesting = heightConstraint?.constant
            #endif
            showLoadedState(image: image)
        case .web(let data, let mimeType, let aspectRatio):
            Self.svgDataCache.setObject(data as NSData, forKey: url as NSURL)
            showSVGLoadedState(
                data: data,
                mimeType: mimeType,
                aspectRatio: aspectRatio
            )
        }
    }

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let size = CGSize(width: width.doubleValue, height: height.doubleValue)
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private func reserveHeightIfPixelSizeKnown(in data: Data) {
        guard let pixelSize = Self.pixelSize(of: data) else { return }
        applyFittedDisplayHeight(width: pixelSize.width, height: pixelSize.height)
        #if DEBUG
        debugPixelReservedHeightForTesting = heightConstraint?.constant
        #endif
    }

    private func applyFittedDisplayHeight(width: CGFloat, height: CGFloat) {
        let heightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(
            width: width,
            height: height
        ) ?? 1
        let displayWidth = preferredDisplayWidth
            ?? (bounds.width > 0
                ? bounds.width
                : (window?.windowScene?.screen.bounds.width ?? 360))
        let displayHeight = ImageViewportSizing.fittedHeight(
            forWidth: displayWidth,
            heightToWidthRatio: heightToWidthRatio,
            surface: .inlineProse,
            screenHeight: window?.windowScene?.screen.bounds.height
        )
        setDisplayHeight(max(displayHeight, Self.loadingPlaceholderHeight))
    }

    private func setDisplayHeight(_ height: CGFloat) {
        let next = max(1, height)
        guard abs((heightConstraint?.constant ?? 0) - next) > 0.5 else { return }
        heightConstraint?.constant = next
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        publishDisplayHeightChange()
    }

    private func publishDisplayHeightChange() {
        if let onDisplayHeightChange {
            onDisplayHeightChange(heightConstraint?.constant ?? 0)
            return
        }
        invalidateTimelineLayout()
    }

    private func normalizedAltText(_ alt: String) -> String? {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bracketedFallbackText(for alt: String) -> String {
        guard let alt = normalizedAltText(alt) else { return "[image]" }
        return "[\(alt)]"
    }

    private func configureLoadedAccessibility() {
        isAccessibilityElement = true
        accessibilityIdentifier = "markdown-image.open"
        accessibilityLabel = normalizedAltText(currentAltText) ?? String(localized: "Image")
        accessibilityHint = String(localized: "Opens image full screen")
        accessibilityTraits = [.image, .button]
        // The container owns the rendered media semantics. WebKit, the tap
        // overlay, and UIImageView must not become duplicate VoiceOver stops.
        accessibilityElementsHidden = true
    }

    private func clearLoadedAccessibility() {
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityTraits = []
        accessibilityElementsHidden = false
    }

    private func refreshLoadedAccessibilityIfNeeded() {
        let rasterIsVisible = !imageView.isHidden && imageView.image != nil
        let svgIsVisible = svgTapOverlay.map { !$0.isHidden } ?? false
        if rasterIsVisible || svgIsVisible {
            configureLoadedAccessibility()
        }
    }

    private func hideRemotePrompt() {
        remotePromptStack.isHidden = true
    }

    /// Export mode: show alt text in a styled box. No spinner, no async load.
    /// If the image was previously viewed, the cache check above already
    /// handled it. This path is for uncached images only.
    private func showExportPlaceholder(alt: String) {
        clearLoadedAccessibility()
        let palette = ThemeRuntimeState.currentPalette()
        let placeholderText = normalizedAltText(alt) ?? "[image]"
        backgroundColor = UIColor(palette.bgHighlight)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = placeholderText

        setDisplayHeight(placeholderText == "[image]" ? 30 : 40)
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
        clearLoadedAccessibility()
        let palette = ThemeRuntimeState.currentPalette()
        let normalizedAlt = normalizedAltText(alt)
        backgroundColor = UIColor(palette.bgHighlight)
        remotePromptLabel.textColor = UIColor(palette.comment)
        remotePromptLabel.text = normalizedAlt.map { "Remote image: \($0)" } ?? "Remote image"
        setDisplayHeight(Self.loadingPlaceholderHeight)
        isHidden = false

        spinner.stopAnimating()
        altLabel.isHidden = true
        imageView.isHidden = true
        errorLabel.isHidden = true
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
        remotePromptStack.isHidden = false
    }

    private func showLoadingState(alt: String) {
        clearLoadedAccessibility()
        let palette = ThemeRuntimeState.currentPalette()
        let normalizedAlt = normalizedAltText(alt)
        backgroundColor = UIColor(palette.bgHighlight)
        spinner.color = UIColor(palette.comment)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = normalizedAlt

        // Ensure loading placeholder height is active.
        setDisplayHeight(Self.loadingPlaceholderHeight)
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

        applyFittedDisplayHeight(width: image.size.width, height: image.size.height)

        imageView.image = image
        imageView.isHidden = false
        backgroundColor = .clear
        configureLoadedAccessibility()
        publishPreparedGeometry()
    }

    /// Commit web-rendered image geometry and retain prepared data. Runway
    /// probes stop here: WKWebView is created and loaded only after a real
    /// display cell activates this view.
    private func showSVGLoadedState(
        data: Data,
        mimeType: String,
        aspectRatio: CGFloat?
    ) {
        showSVGLoadingWebState()

        if let aspectRatio,
           let heightToWidthRatio = ImageViewportSizing.validatedHeightToWidthRatio(
               1.0 / aspectRatio
           ) {
            applyFittedDisplayHeight(width: 1, height: heightToWidthRatio)
        } else {
            setDisplayHeight(Self.loadingPlaceholderHeight)
        }

        svgPreviewData = data
        svgPreviewMimeType = mimeType
        publishPreparedGeometry()
        if preparesForDisplay {
            activatePreparedDisplay()
        }
    }

    /// Called when a prepared runway view moves into a real collection cell.
    func activatePreparedDisplay() {
        preparesForDisplay = true
        guard let data = svgPreviewData,
              let mimeType = svgPreviewMimeType else { return }
        let webView = ensureSVGWebView()
        webView.isHidden = true
        ensureSVGTapOverlay().isHidden = true
        queueSVGHTML(makeSVGHTML(data: data, mimeType: mimeType), in: webView)
        flushSVGIfReady()
    }

    /// Create an HTML document that embeds image data for WKWebView rendering.
    /// Uses a data URI via `<img>` for simplicity and consistency with
    /// `AnimatedImageWebContainerView`.
    private func makeSVGHTML(data: Data, mimeType: String) -> String {
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
          <img src="data:\(mimeType);base64,\(base64)" />
        </body>
        </html>
        """
    }

    private func flushSVGIfReady() {
        guard let webView = svgWebView else { return }
        guard canLoadSVGHTML(in: webView) else {
            svgHTMLTracker.markNotReady()
            return
        }
        if let html = svgHTMLTracker.markReady() {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func queueSVGHTML(_ html: String, in webView: ReviewCommentWKWebView) {
        let canLoad = canLoadSVGHTML(in: webView)
        if !canLoad {
            svgHTMLTracker.markNotReady()
        }
        if let html = svgHTMLTracker.setContent(html) {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        if canLoad, let html = svgHTMLTracker.markReady() {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func canLoadSVGHTML(in webView: ReviewCommentWKWebView) -> Bool {
        window != nil
            && bounds.width > 0
            && bounds.height > 0
            && webView.bounds.width > 0
            && webView.bounds.height > 0
    }

    private func ensureSVGTapOverlay() -> UIControl {
        if let existing = svgTapOverlay {
            return existing
        }

        let overlay = UIControl()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = true
        overlay.accessibilityIdentifier = "markdown-image.svg.tap-overlay"
        overlay.isAccessibilityElement = false
        overlay.addTarget(self, action: #selector(handleSVGTap), for: .touchUpInside)

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
        webView.navigationDelegate = self
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

    private func showSVGLoadingWebState() {
        clearLoadedAccessibility()
        let palette = ThemeRuntimeState.currentPalette()
        backgroundColor = UIColor(palette.bgHighlight)
        spinner.color = UIColor(palette.comment)
        spinner.startAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true
        imageView.isHidden = true
        hideRemotePrompt()
        svgWebView?.isHidden = true
        svgTapOverlay?.isHidden = true
        isHidden = false
    }

    private func finishSVGWebLoad() {
        guard svgPreviewData != nil else { return }
        spinner.stopAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true
        hideRemotePrompt()
        imageView.isHidden = true
        svgWebView?.isHidden = false
        svgTapOverlay?.isHidden = false
        backgroundColor = .clear
        configureLoadedAccessibility()
    }

    private func recoverSVGWebLoad() {
        guard svgPreviewData != nil else { return }
        showSVGLoadingWebState()
        svgHTMLTracker.markProcessTerminated()
        flushSVGIfReady()
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
        clearLoadedAccessibility()
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
        setDisplayHeight(Self.loadingPlaceholderHeight)
        backgroundColor = UIColor(palette.bgHighlight)
        isHidden = false
        publishPreparedGeometry()
    }

    private func publishPreparedGeometry() {
        onPreparedGeometry?(heightConstraint?.constant ?? Self.loadingPlaceholderHeight)
    }

    private func invalidateTimelineLayout() {
        // Image decode commonly completes while the user is scrolled up and
        // detached from bottom. Soft invalidation is skipped in that state and
        // can leave the assistant row cut off until another interaction.
        // Force-invalidate so self-sizing adopts the loaded image height now.
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    override func accessibilityActivate() -> Bool {
        guard isAccessibilityElement else { return false }
        if !imageView.isHidden {
            return openRasterPreview()
        }
        if svgTapOverlay.map({ !$0.isHidden }) == true {
            return openSVGPreview()
        }
        return false
    }

    @objc private func handleTap() {
        _ = openRasterPreview()
    }

    @discardableResult
    private func openRasterPreview() -> Bool {
        guard let image = imageView.image, !imageView.isHidden else { return false }
        if let presenter = nearestViewController() {
            FullScreenImageViewController.present(image: image, from: presenter)
        } else {
            FullScreenImageViewController.present(image: image)
        }
        return true
    }

    @objc private func handleSVGTap() {
        _ = openSVGPreview()
    }

    @discardableResult
    private func openSVGPreview() -> Bool {
        guard let data = svgPreviewData,
              svgTapOverlay.map({ !$0.isHidden }) == true,
              let presenter = nearestViewController() else { return false }

        FullScreenImageDataPreviewPresenter.present(
            data: data,
            mimeType: svgPreviewMimeType,
            from: presenter
        )
        return true
    }

    private func nearestViewController() -> UIViewController? {
        if var active = window?.rootViewController {
            while let presented = active.presentedViewController {
                active = presented
            }
            if active is FullScreenCodeViewController {
                return active
            }
        }

        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                var ancestor: UIViewController? = viewController
                while let node = ancestor {
                    if node is FullScreenCodeViewController {
                        return node
                    }
                    ancestor = node.parent
                }
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

#if DEBUG
extension NativeMarkdownImageView {
    var debugHasRasterPreviewForTesting: Bool {
        imageView.image != nil && !imageView.isHidden
    }

    var debugDataPreviewMimeTypeForTesting: String? {
        svgPreviewMimeType
    }

    var debugWebRendererSettledForTesting: Bool {
        guard svgPreviewData != nil,
              let svgWebView else { return false }
        return !svgWebView.isLoading && !svgWebView.isHidden
    }

    var debugWebRendererForTesting: WKWebView? {
        svgWebView
    }

    var debugDataPreviewTapTargetForTesting: UIControl? {
        svgTapOverlay
    }

    func debugOpenRasterPreviewForTesting() {
        handleTap()
    }

    var debugPreparedDisplayWidthForTesting: CGFloat? { preferredDisplayWidth }
    var debugHasPreparedArtifactForTesting: Bool {
        imageView.image != nil || svgPreviewData != nil
    }
    var debugHasSVGWebViewForTesting: Bool { svgWebView != nil }
    var debugIsSVGArtifactForTesting: Bool {
        svgPreviewData != nil && svgPreviewMimeType == "image/svg+xml"
    }

    static var debugPreparedOperationCountForTesting: Int {
        debugPreparedOperationCount
    }

    static func debugResetPreparedArtifactsForTesting() {
        imageCache.removeAllObjects()
        svgDataCache.removeAllObjects()
        inFlightLoads.values.forEach { $0.task.cancel() }
        inFlightLoads.removeAll()
        debugPreparedOperationCount = 0
        debugRasterDecodeGateForTesting = nil
    }
}
#endif

extension NativeMarkdownImageView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if HTMLContentSecurity.isHostRawFileURL(navigationAction.request.url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishSVGWebLoad()
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        recoverSVGWebLoad()
    }

    // swiftlint:disable:next no_force_unwrap_production
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        recoverSVGWebLoad()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recoverSVGWebLoad()
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
        if SessionFileURL.parse(url) != nil
            || WorkspaceFileURL.parse(url) != nil
            || HostFileURL.parse(url) != nil {
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
                    let hostBytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    if let host = String(bytes: hostBytes, encoding: .utf8) {
                        addresses.insert(host)
                    }
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
