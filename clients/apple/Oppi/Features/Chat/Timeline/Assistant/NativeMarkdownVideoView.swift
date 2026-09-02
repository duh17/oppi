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

    /// Wiki-file syntax has no dimensions, so every mount keeps 16:9.
    static func reservedHeight(forWidth width: CGFloat) -> CGFloat {
        let resolvedWidth = width.isFinite && width > 0 ? width : fallbackWidth
        return ceil(resolvedWidth / fallbackAspectRatio)
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
    private var sidecarProvider: TimedTextSidecarProvider?
    private var timedText = TimedText.LoadResult.empty
    private var sidecarTask: Task<Void, Never>?
    private(set) var reservedHeight: CGFloat = MarkdownInlineVideoLayout.reservedHeight(forWidth: .nan)
    private(set) var isStaticFallback = false
    /// Render-ahead may publish the reserved 16:9 height before reveal.
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
        sidecarTask?.cancel()
    }

    /// Recycle / identity-change teardown. Do not call from `willMove(toSuperview:)`;
    /// AVKit detaches this view during fullscreen, PiP, and dismiss.
    func prepareForRemoval() {
        resolutionTask?.cancel()
        resolutionTask = nil
        sidecarTask?.cancel()
        sidecarTask = nil
        timedText = .empty
        currentIdentity = nil
        removePlayer()
    }

    func apply(
        embed: MarkdownVideoEmbed,
        sourceProvider: MarkdownVideoMediaSourceProvider?,
        renderingMode: ContentRenderingMode,
        preferredDisplayWidth: CGFloat?,
        sidecarProvider: TimedTextSidecarProvider? = nil
    ) {
        let width = preferredDisplayWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (bounds.width > 0 ? bounds.width : 320)
        let identity = [
            embed.reference.target,
            embed.reference.fileCandidatePath ?? "",
            String(describing: renderingMode),
        ].joined(separator: "|")
        let nextHeight = MarkdownInlineVideoLayout.reservedHeight(forWidth: width)

        if identity == currentIdentity {
            applyReservedHeight(nextHeight)
            return
        }

        currentIdentity = identity
        currentEmbed = embed
        self.renderingMode = renderingMode
        self.sourceProvider = sourceProvider
        self.sidecarProvider = sidecarProvider
        timedText = .empty
        sidecarTask?.cancel()
        hasCommittedRevealGeometry = shouldCommitRevealGeometry(renderingMode: renderingMode)
        applyReservedHeight(nextHeight)
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
                // Probes and parked cells may still be in a window. Store the
                // resolved source only; setPlaybackVisible(true) owns host mount.
                self.currentSource = source
                guard !Task.isCancelled,
                      self.currentIdentity == identity,
                      self.isPlaybackVisible,
                      self.window != nil else { return }
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
        // AVKit detaches this inline host during fullscreen, PiP, and dismiss.
        // That is not recycle. Recycle and identity changes call prepareForRemoval().
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
        loadSidecar(for: embed)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setPlaybackVisible(_ visible: Bool) {
        if !visible {
            guard isPlaybackVisible else { return }
            // Native fullscreen can make UICollectionView report the row as no
            // longer displayed. Preserve both this flag and the player while
            // AVKit owns presentation; a real later offscreen/recycle callback
            // still tears down through this path or prepareForRemoval().
            guard playbackModel.handleDisappear(source: .timelineVisibility) else { return }
            isPlaybackVisible = false
            return
        }

        // Visibility reveal is the only deferred mount point. An already-true
        // flag still has to install if a probe/async resolve stored a source.
        if let source = currentSource, let embed = currentEmbed,
           hostingController == nil, window != nil {
            isPlaybackVisible = true
            installPlayer(source: source, embed: embed)
            return
        }

        guard !isPlaybackVisible else { return }
        isPlaybackVisible = true
        playbackModel.setVisible(true)
        guard let source = currentSource else { return }
        playbackModel.prepare(
            source: source,
            autoplay: MarkdownInlineVideoLayout.autoplay,
            telemetrySource: "markdown_inline_video",
            telemetryMode: "inline",
            telemetrySessionId: currentEmbed?.reference.sourceSessionID,
            onPresentationSize: nil
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
            telemetrySource: "markdown_inline_video",
            telemetryMode: "inline",
            telemetrySessionId: embed?.reference.sourceSessionID,
            model: playbackModel,
            timedText: timedText
        )
    }

    private func loadSidecar(for embed: MarkdownVideoEmbed) {
        sidecarTask?.cancel()
        guard let sidecarProvider else { return }
        sidecarTask = Task { [weak self] in
            let result = await sidecarProvider(embed.filePath, .video, embed.reference)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.currentEmbed == embed else { return }
                self.timedText = result
                self.refreshPlayerCaptions()
            }
        }
    }

    private func refreshPlayerCaptions() {
        guard let host = hostingController, let source = currentSource else { return }
        host.rootView = makePlayerView(
            source: source,
            embed: currentEmbed,
            isActive: isPlaybackVisible
        )
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

    private func shouldCommitRevealGeometry(renderingMode: ContentRenderingMode) -> Bool {
        renderingMode == .export || renderingMode == .live || window != nil
    }

    private func applyReservedHeight(_ height: CGFloat) {
        guard reservedHeight != height else { return }
        reservedHeight = height
        heightConstraint?.constant = height
        if let host = hostingController, let source = currentSource {
            host.rootView = makePlayerView(
                source: source,
                embed: currentEmbed,
                isActive: isPlaybackVisible
            )
        }
        if !hasCommittedRevealGeometry {
            onPreparedGeometry?(height)
        }
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
    var debugHasCurrentSourceForTesting: Bool { currentSource != nil }
    var debugIsPlaybackVisibleForTesting: Bool { isPlaybackVisible }
    var debugHasActivePlayerForTesting: Bool { playbackModel.player != nil }
    var debugHasCommittedRevealGeometryForTesting: Bool { hasCommittedRevealGeometry }
    var debugHostingControllerForTesting: UIViewController? { hostingController }
    var debugHostingParentForTesting: UIViewController? { hostingController?.parent }
    var debugPlaybackModelForTesting: AuthenticatedMediaPlayerModel { playbackModel }
    var debugFailureHitAreaForTesting: CGSize { openButton.bounds.size }
    var debugStatusLabelAdjustsFontForTesting: Bool { statusLabel.adjustsFontForContentSizeCategory }
    var debugOpenButtonIsHiddenForTesting: Bool { openButton.isHidden }
    var debugOpenButtonAdjustsFontForTesting: Bool {
        openButton.titleLabel?.adjustsFontForContentSizeCategory == true
    }
}
#endif
