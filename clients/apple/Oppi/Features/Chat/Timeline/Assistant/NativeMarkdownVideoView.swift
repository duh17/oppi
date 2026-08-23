import SwiftUI
import UIKit

/// Resolves one policy-checked Markdown video reference to the existing
/// bearer-authenticated AVFoundation source.
typealias MarkdownVideoMediaSourceProvider = (
    _ embed: MarkdownVideoEmbed
) async throws -> AuthenticatedMediaSource

enum MarkdownInlineVideoLayout {
    static let autoplay = false
    static let fallbackAspectRatio: CGFloat = 16.0 / 9.0
    private static let fallbackWidth: CGFloat = 320

    /// Revealed embeds keep one height. Metadata may size only not-yet-revealed
    /// prepared geometry; after reveal the fallback or first reserved ratio stays.
    static func reservedHeight(
        forWidth width: CGFloat,
        metadataAspectRatio: CGFloat? = nil
    ) -> CGFloat {
        let resolvedWidth = width.isFinite && width > 0 ? width : fallbackWidth
        let aspectRatio = metadataAspectRatio.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? fallbackAspectRatio
        return ceil(resolvedWidth / aspectRatio)
    }
}

/// Native inline player host for Oppi wiki-file video embeds.
///
/// Source resolution can run in the full-screen reader's render-ahead runway,
/// but the final fallback geometry is installed synchronously. Playback remains
/// user initiated and delegates byte loading, controls, full-screen, and PiP to
/// `AuthenticatedMediaPlayerView` / `AuthenticatedMediaPlaybackSession`.
@MainActor
final class NativeMarkdownVideoView: UIView {
    /// AVPlayer metadata learned from an earlier prepared presentation can size
    /// a later mount before reveal. The current mount never resizes after its
    /// geometry is chosen. Bounded so a long session cannot grow this forever.
    private static let metadataCacheLimit = 64
    private static var metadataAspectRatioByReference: [ResourceReference: CGFloat] = [:]
    private static var metadataInsertionOrder: [ResourceReference] = []

    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint?
    private var hostingController: UIHostingController<AuthenticatedMediaPlayerView>?
    private let playbackModel = AuthenticatedMediaPlayerModel()
    private var currentSource: AuthenticatedMediaSource?
    private var isPlaybackVisible = true
    private var resolutionTask: Task<Void, Never>?
    private var currentEmbed: MarkdownVideoEmbed?
    private var currentIdentity: String?
    private var hasCommittedRevealGeometry = false
    private var renderingMode: ContentRenderingMode = .live
    private var sourceProvider: MarkdownVideoMediaSourceProvider?
    private(set) var reservedHeight: CGFloat = MarkdownInlineVideoLayout.reservedHeight(forWidth: .nan)
    private(set) var isStaticFallback = false
    /// Render-ahead may publish a metadata-backed height before reveal.
    var onPreparedGeometry: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.applyDynamicTypeFonts()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        resolutionTask?.cancel()
    }

    func prepareForRemoval() {
        removePlayer()
    }

    func apply(
        embed: MarkdownVideoEmbed,
        sourceProvider: MarkdownVideoMediaSourceProvider?,
        renderingMode: ContentRenderingMode,
        preferredDisplayWidth: CGFloat?
    ) {
        let width = preferredDisplayWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (bounds.width > 0 ? bounds.width : 320)
        let identity = [
            embed.reference.target,
            embed.reference.fileCandidatePath ?? "",
            String(describing: renderingMode),
        ].joined(separator: "|")
        let metadataAspectRatio = canUseMetadata(renderingMode: renderingMode)
            ? Self.metadataAspectRatioByReference[embed.reference]
            : nil
        let nextHeight = MarkdownInlineVideoLayout.reservedHeight(
            forWidth: width,
            metadataAspectRatio: metadataAspectRatio
        )

        if identity == currentIdentity {
            if !hasCommittedRevealGeometry {
                updatePreparedHeight(nextHeight)
            }
            return
        }

        currentIdentity = identity
        currentEmbed = embed
        self.renderingMode = renderingMode
        self.sourceProvider = sourceProvider
        hasCommittedRevealGeometry = shouldCommitRevealGeometry(renderingMode: renderingMode)
        reservedHeight = nextHeight
        heightConstraint?.constant = nextHeight
        if !hasCommittedRevealGeometry {
            onPreparedGeometry?(nextHeight)
        }
        resolutionTask?.cancel()
        removePlayer()

        if renderingMode == .export {
            isStaticFallback = true
            showFallback(
                title: String(localized: "Video"),
                detail: embed.displayLabel,
                actionable: false
            )
            return
        }

        isStaticFallback = false
        showLoading(embed: embed)
        guard let sourceProvider else {
            showFallback(
                title: String(localized: "Video unavailable"),
                detail: embed.displayLabel,
                actionable: true
            )
            return
        }

        resolutionTask = Task { [weak self] in
            do {
                let source = try await sourceProvider(embed)
                guard let self, !Task.isCancelled, self.currentIdentity == identity else { return }
                self.installPlayer(source: source, embed: embed)
            } catch {
                guard let self, !Task.isCancelled, self.currentIdentity == identity else { return }
                self.showFallback(
                    title: String(localized: "Unable to load video"),
                    detail: embed.displayLabel,
                    actionable: true
                )
            }
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            prepareForRemoval()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            hasCommittedRevealGeometry = true
            if let hostingController {
                attachPlayerHost(hostingController)
            }
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)
        layer.cornerRadius = 8
        clipsToBounds = true
        accessibilityIdentifier = "markdown-video"

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = UIColor(ThemeRuntimeState.currentPalette().comment)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3

        var buttonConfiguration = UIButton.Configuration.bordered()
        buttonConfiguration.title = String(localized: "Open video file")
        buttonConfiguration.image = UIImage(systemName: "film")
        buttonConfiguration.imagePadding = 6
        buttonConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            return outgoing
        }
        openButton.configuration = buttonConfiguration
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.titleLabel?.adjustsFontForContentSizeCategory = true
        openButton.titleLabel?.numberOfLines = 2
        openButton.accessibilityIdentifier = "markdown-video-open"
        openButton.addTarget(self, action: #selector(openReference), for: .touchUpInside)
        applyDynamicTypeFonts()

        addSubview(statusLabel)
        addSubview(openButton)
        let heightConstraint = heightAnchor.constraint(
            equalToConstant: MarkdownInlineVideoLayout.reservedHeight(forWidth: .nan)
        )
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -22),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            openButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            openButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func showLoading(embed: MarkdownVideoEmbed) {
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)
        statusLabel.text = String(format: String(localized: "Preparing video: %@"), embed.displayLabel)
        statusLabel.isHidden = false
        openButton.isHidden = true
        isAccessibilityElement = true
        accessibilityLabel = String(format: String(localized: "Preparing video: %@"), embed.displayLabel)
        accessibilityTraits = [.updatesFrequently]
    }

    private func showFallback(title: String, detail: String, actionable: Bool) {
        removePlayer()
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)
        statusLabel.text = "\(title)\n\(detail)"
        statusLabel.isHidden = false
        openButton.isHidden = !actionable
        let summary = "\(title), \(detail)"
        if actionable {
            isAccessibilityElement = false
            accessibilityLabel = nil
            openButton.isAccessibilityElement = true
            openButton.accessibilityLabel = summary
            openButton.accessibilityHint = String(localized: "Opens the video file")
            openButton.accessibilityTraits = [.button]
        } else {
            isAccessibilityElement = true
            accessibilityLabel = summary
            accessibilityTraits = []
            openButton.isAccessibilityElement = false
        }
    }

    private func installPlayer(source: AuthenticatedMediaSource, embed: MarkdownVideoEmbed) {
        statusLabel.isHidden = true
        openButton.isHidden = true
        isAccessibilityElement = false
        accessibilityLabel = nil
        backgroundColor = .clear

        let player = makePlayerView(
            source: source,
            embed: embed,
            isActive: isPlaybackVisible
        )
        let host = UIHostingController(rootView: player)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        hostingController = host
        currentSource = source
        attachPlayerHost(host)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setPlaybackVisible(_ visible: Bool) {
        guard isPlaybackVisible != visible else { return }
        isPlaybackVisible = visible
        playbackModel.setVisible(visible)
        guard visible, let source = currentSource else { return }
        playbackModel.prepare(
            source: source,
            autoplay: MarkdownInlineVideoLayout.autoplay,
            telemetrySource: "markdown_inline_video",
            telemetryMode: "inline",
            telemetrySessionId: currentEmbed?.reference.sourceSessionID,
            onPresentationSize: presentationSizeHandler(for: currentEmbed)
        )
    }

    private func makePlayerView(
        source: AuthenticatedMediaSource,
        embed: MarkdownVideoEmbed?,
        isActive: Bool
    ) -> AuthenticatedMediaPlayerView {
        AuthenticatedMediaPlayerView(
            source: source,
            height: reservedHeight,
            cornerRadius: 8,
            autoplay: MarkdownInlineVideoLayout.autoplay,
            isActive: isActive,
            unavailableTitle: String(localized: "Video preview unavailable"),
            unavailableSystemImage: "film",
            failureActionTitle: String(localized: "Open video file"),
            onFailureAction: { [weak self] in self?.openReference() },
            onPresentationSize: presentationSizeHandler(for: embed),
            telemetrySource: "markdown_inline_video",
            telemetryMode: "inline",
            telemetrySessionId: embed?.reference.sourceSessionID,
            model: playbackModel
        )
    }

    private func presentationSizeHandler(
        for embed: MarkdownVideoEmbed?
    ) -> @MainActor @Sendable (CGSize) -> Void {
        { [weak self] size in
            guard size.width > 0, size.height > 0,
                  let self,
                  let reference = embed?.reference ?? self.currentEmbed?.reference else { return }
            let aspectRatio = size.width / size.height
            guard aspectRatio.isFinite, aspectRatio > 0 else { return }
            Self.storeMetadata(aspectRatio, for: reference)
            // Metadata may refine prepared geometry only before reveal.
            guard !self.hasCommittedRevealGeometry else { return }
            let width = self.bounds.width > 0 ? self.bounds.width : 320
            self.updatePreparedHeight(
                MarkdownInlineVideoLayout.reservedHeight(
                    forWidth: width,
                    metadataAspectRatio: aspectRatio
                )
            )
        }
    }

    private func removePlayer() {
        playbackModel.teardown()
        if let host = hostingController {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        hostingController = nil
        currentSource = nil
    }

    private func attachPlayerHost(_ host: UIHostingController<AuthenticatedMediaPlayerView>) {
        if host.parent == nil, let parent = nearestViewController() {
            parent.addChild(host)
            if host.view.superview != self {
                insertSubview(host.view, at: 0)
            }
            host.didMove(toParent: parent)
        } else if host.view.superview != self {
            insertSubview(host.view, at: 0)
        }
    }

    private static func storeMetadata(_ aspectRatio: CGFloat, for reference: ResourceReference) {
        if metadataAspectRatioByReference[reference] != nil {
            metadataAspectRatioByReference[reference] = aspectRatio
            return
        }
        metadataAspectRatioByReference[reference] = aspectRatio
        metadataInsertionOrder.append(reference)
        while metadataInsertionOrder.count > metadataCacheLimit {
            let evicted = metadataInsertionOrder.removeFirst()
            metadataAspectRatioByReference.removeValue(forKey: evicted)
        }
    }

    private func canUseMetadata(renderingMode: ContentRenderingMode) -> Bool {
        renderingMode != .export && !hasCommittedRevealGeometry
    }

    private func shouldCommitRevealGeometry(renderingMode: ContentRenderingMode) -> Bool {
        renderingMode == .export || renderingMode == .live || window != nil
    }

    private func updatePreparedHeight(_ height: CGFloat) {
        guard !hasCommittedRevealGeometry, reservedHeight != height else { return }
        reservedHeight = height
        heightConstraint?.constant = height
        onPreparedGeometry?(height)
    }

    private func applyDynamicTypeFonts() {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        statusLabel.font = font
        statusLabel.adjustsFontForContentSizeCategory = true
        openButton.titleLabel?.font = font
        openButton.titleLabel?.adjustsFontForContentSizeCategory = true
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

    @objc private func openReference() {
        guard let reference = currentEmbed?.reference else { return }
        NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
    }
}

#if DEBUG
extension NativeMarkdownVideoView {
    var debugIsStaticFallbackForTesting: Bool { isStaticFallback }
    var debugReservedHeightForTesting: CGFloat { reservedHeight }
    var debugHasPlayerForTesting: Bool { hostingController != nil }
    var debugIsPlaybackVisibleForTesting: Bool { isPlaybackVisible }
    var debugHasActivePlayerForTesting: Bool { playbackModel.player != nil }
    var debugHasCommittedRevealGeometryForTesting: Bool { hasCommittedRevealGeometry }
    var debugHostingControllerForTesting: UIViewController? { hostingController }
    var debugHostingParentForTesting: UIViewController? { hostingController?.parent }
    var debugFailureHitAreaForTesting: CGSize { openButton.bounds.size }
    var debugStatusLabelAdjustsFontForTesting: Bool { statusLabel.adjustsFontForContentSizeCategory }
    var debugOpenButtonIsHiddenForTesting: Bool { openButton.isHidden }
    var debugOpenButtonAdjustsFontForTesting: Bool {
        openButton.titleLabel?.adjustsFontForContentSizeCategory == true
    }

    static func debugSeedMetadataForTesting(_ reference: ResourceReference, _ aspectRatio: CGFloat) {
        storeMetadata(aspectRatio, for: reference)
    }

    static func debugClearMetadataForTesting() {
        metadataAspectRatioByReference.removeAll()
        metadataInsertionOrder.removeAll()
    }

    static func debugMetadataCountForTesting() -> Int {
        metadataAspectRatioByReference.count
    }
}
#endif
