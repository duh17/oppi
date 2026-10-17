import AVKit
import Combine
import UIKit

/// Resolves one policy-checked Markdown video reference to the existing
/// bearer-authenticated AVFoundation source.
typealias MarkdownVideoMediaSourceProvider = (
    _ embed: MarkdownVideoEmbed
) async throws -> AuthenticatedMediaSource

enum MarkdownInlineVideoLayout {
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
/// but the final fallback geometry is installed synchronously. Before the user
/// taps play the row is a still frame (or the placeholder when none can be
/// produced) with a play control: no `AVPlayer`, playback session, or
/// `AVPlayerViewController` exists. The tap builds the player and starts
/// playback; byte loading, controls, full-screen, and PiP then belong to
/// AVKit / `AuthenticatedMediaPlaybackSession`. Recycle or removal returns the
/// row to the still frame.
@MainActor
final class NativeMarkdownVideoView: UIView {
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let stillImageView = UIImageView()
    private let playButton = InlineVideoPlayButton()
    private var stillTask: Task<Void, Never>?
    /// The user asked to play; the player is built once a source and a window exist.
    private var isPlayRequested = false
    private var displayWidth: CGFloat = 320
    private var heightConstraint: NSLayoutConstraint?
    /// Slot-sized parent so AVKit chrome follows the cell, not ChatView.
    private var slotController: InlineVideoSlotController?
    private var playerController: AVPlayerViewController?
    private var playerDelegate: InlineVideoPlayerDelegate?
    private var playbackObservation: AnyCancellable?
    private var lastAppliedPlayer: AVPlayer?
    private var lastAppliedFailed = false
    /// Caption label and language control on the player overlay, driven by the
    /// player's clock so fullscreen keeps captions after AVKit detaches this view.
    private let captions = TimedTextCaptionOverlay()
    private let playbackModel = AuthenticatedMediaPlayerModel()
    private var currentSource: AuthenticatedMediaSource?
    private var isPlaybackVisible = true
    private var resolutionTask: Task<Void, Never>?
    private var currentEmbed: MarkdownVideoEmbed?
    private var currentIdentity: String?
    private var hasCommittedRevealGeometry = false
    /// Bumped on identity change and removal so a queued first mount cannot land late.
    private var firstMountGeneration = 0
    private var isFirstMountQueued = false
    private var renderingMode: ContentRenderingMode = .live
    private var sourceProvider: MarkdownVideoMediaSourceProvider?
    private var sidecarProvider: TimedTextSidecarProvider?
    private var sidecarTask: Task<Void, Never>?
    private(set) var reservedHeight: CGFloat = MarkdownInlineVideoLayout.reservedHeight(forWidth: .nan)
    private(set) var isStaticFallback = false
    /// Render-ahead may publish the reserved 16:9 height before reveal.
    var onPreparedGeometry: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    /// Reading the category here makes UIKit re-run this pass when it changes.
    override func updateProperties() {
        super.updateProperties()
        applyDynamicTypeFonts(for: traitCollection.preferredContentSizeCategory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        resolutionTask?.cancel()
        sidecarTask?.cancel()
        stillTask?.cancel()
    }

    /// Recycle / identity-change teardown. Do not call from `willMove(toSuperview:)`;
    /// AVKit detaches this view during fullscreen, PiP, and dismiss.
    func prepareForRemoval() {
        invalidateFirstMount()
        resolutionTask?.cancel()
        resolutionTask = nil
        sidecarTask?.cancel()
        sidecarTask = nil
        stillTask?.cancel()
        stillTask = nil
        captions.setTimedText(.empty)
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
        displayWidth = width

        if identity == currentIdentity {
            applyReservedHeight(nextHeight)
            return
        }

        currentIdentity = identity
        invalidateFirstMount()
        currentEmbed = embed
        self.renderingMode = renderingMode
        self.sourceProvider = sourceProvider
        self.sidecarProvider = sidecarProvider
        captions.setTimedText(.empty)
        sidecarTask?.cancel()
        hasCommittedRevealGeometry = shouldCommitRevealGeometry(renderingMode: renderingMode)
        applyReservedHeight(nextHeight)
        resolutionTask?.cancel()
        stillTask?.cancel()
        stillTask = nil
        stillImageView.image = nil
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
        showPlayPrompt(embed: embed)
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
                // resolved source; the first-mount attempt rechecks visibility.
                self.currentSource = source
                self.loadStillFrameIfNeeded()
                self.scheduleFirstMount()
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            hasCommittedRevealGeometry = true
            if playerController != nil {
                // Mounted player returning from AVKit fullscreen/PiP: reattach now.
                attachPlayerHost()
            } else {
                loadStillFrameIfNeeded()
                scheduleFirstMount()
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
        applyDynamicTypeFonts(for: traitCollection.preferredContentSizeCategory)

        stillImageView.translatesAutoresizingMaskIntoConstraints = false
        stillImageView.contentMode = .scaleAspectFit
        stillImageView.clipsToBounds = true
        stillImageView.isHidden = true
        stillImageView.isAccessibilityElement = false

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.accessibilityIdentifier = "markdown-video-play"
        playButton.isHidden = true
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        addSubview(stillImageView)
        addSubview(statusLabel)
        addSubview(openButton)
        addSubview(playButton)
        let heightConstraint = heightAnchor.constraint(
            equalToConstant: MarkdownInlineVideoLayout.reservedHeight(forWidth: .nan)
        )
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            stillImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stillImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stillImageView.topAnchor.constraint(equalTo: topAnchor),
            stillImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The control is the whole slot so a tap anywhere on the still plays;
            // only the centered disc is drawn.
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            playButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            playButton.topAnchor.constraint(equalTo: topAnchor),
            playButton.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// Pre-tap state: placeholder background (or still frame) plus the play control.
    private func showPlayPrompt(embed: MarkdownVideoEmbed) {
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)
        statusLabel.isHidden = true
        openButton.isHidden = true
        stillImageView.isHidden = stillImageView.image == nil
        playButton.isHidden = false
        playButton.showsProgress = false
        playButton.accessibilityLabel = String(format: String(localized: "Play video: %@"), embed.displayLabel)
        playButton.accessibilityTraits = [.button]
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityTraits = []
    }

    private func showFallback(title: String, detail: String, actionable: Bool) {
        removePlayer()
        playButton.isHidden = true
        stillImageView.isHidden = true
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
        playButton.isHidden = true
        playButton.showsProgress = false
        isAccessibilityElement = false
        accessibilityLabel = nil
        backgroundColor = .clear

        playbackModel.setVisible(isPlaybackVisible)
        // The tap is the playback intent.
        playbackModel.prepare(
            source: source,
            autoplay: true,
            telemetrySource: "markdown_inline_video",
            telemetryMode: "inline",
            telemetrySessionId: embed.reference.sourceSessionID,
            onPresentationSize: nil
        )
        let slot = InlineVideoSlotController()
        slot.view.translatesAutoresizingMaskIntoConstraints = false
        let host = AVPlayerViewController()
        InlineVideoPlayerConfiguration.apply(to: host)
        playerDelegate = InlineVideoPlayerDelegate(
            onFullScreenChange: { [weak self] active in
                guard active else { return }
                self?.playbackModel.setFullScreen(true)
                WorkspaceMediaOverlayPost.begin()
            },
            onFullScreenWillEnd: { [weak self] in self?.playbackModel.handleWillEndFullScreen() },
            onFullScreenDidEnd: { [weak self] attached in
                self?.playbackModel.handleDidEndFullScreen(hostIsAttached: attached)
            },
            onFullScreenTransitionFinished: { WorkspaceMediaOverlayPost.end() },
            onPictureInPictureChange: { [weak self] active in self?.playbackModel.setPictureInPicture(active) },
            onPictureInPictureDidStop: { [weak self] attached in
                self?.playbackModel.handleDidStopPictureInPicture(hostIsAttached: attached)
            }
        )
        host.delegate = playerDelegate
        host.player = playbackModel.player
        // Published values emit before mutation; render on the next main-queue turn.
        playbackObservation = playbackModel.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshPlaybackState() }
        }
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.insetsLayoutMarginsFromSafeArea = false
        slotController = slot
        playerController = host
        currentSource = source
        attachPlayerHost()
        refreshPlaybackState()
        loadSidecar(for: embed)
        NSLayoutConstraint.activate([
            slot.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            slot.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            slot.view.topAnchor.constraint(equalTo: topAnchor),
            slot.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: slot.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: slot.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: slot.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: slot.view.bottomAnchor),
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

        // An already-true flag still has to mount if a probe/async resolve
        // stored a source. Reveal can arrive from cellForItemAt mid-push, so
        // only request the deferred first mount here.
        if currentSource != nil, playerController == nil {
            isPlaybackVisible = true
            loadStillFrameIfNeeded()
            scheduleFirstMount()
            return
        }

        guard !isPlaybackVisible else { return }
        isPlaybackVisible = true
        playbackModel.setVisible(true)
        guard let source = currentSource else { return }
        playbackModel.prepare(
            source: source,
            autoplay: false,
            telemetrySource: "markdown_inline_video",
            telemetryMode: "inline",
            telemetrySessionId: currentEmbed?.reference.sourceSessionID,
            onPresentationSize: nil
        )
    }

    /// A play tap, source-ready, reveal, and window-arrival all funnel here; only
    /// a play request builds the player. Installing
    /// AVKit containment synchronously from a collection-view data-source or
    /// layout pass during a navigation transition aborts in UIKit, so the whole
    /// first install runs later, once, after enclosing transitions settle.
    /// Mounted-player reattachment (fullscreen/PiP return) never comes here.
    private func scheduleFirstMount() {
        guard isPlayRequested, playerController == nil, currentSource != nil, !isFirstMountQueued else { return }
        isFirstMountQueued = true
        let generation = firstMountGeneration
        DispatchQueue.main.async { [weak self] in
            self?.attemptFirstMount(generation: generation)
        }
    }

    private func invalidateFirstMount() {
        firstMountGeneration &+= 1
        isFirstMountQueued = false
    }

    private func attemptFirstMount(generation: Int) {
        guard generation == firstMountGeneration else { return }
        isFirstMountQueued = false
        // Everything is re-read now; nothing captured at schedule time is trusted.
        // A later reveal or window arrival schedules again if any check fails.
        guard isPlayRequested,
              playerController == nil,
              isPlaybackVisible,
              let source = currentSource,
              let embed = currentEmbed,
              let window,
              let parent = nearestViewController(),
              parent.viewIfLoaded?.window === window else { return }
        if let coordinator = activeTransitionCoordinator(from: parent) {
            isFirstMountQueued = true
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                // Completed or cancelled: re-evaluate attachment from scratch.
                guard let self, generation == self.firstMountGeneration else { return }
                self.isFirstMountQueued = false
                self.scheduleFirstMount()
            }
            if !queued {
                // Coordinator is already finishing; retry on a later turn.
                isFirstMountQueued = false
                scheduleFirstMount()
            }
            return
        }
        installPlayer(source: source, embed: embed)
    }

    private func activeTransitionCoordinator(
        from controller: UIViewController
    ) -> (any UIViewControllerTransitionCoordinator)? {
        var node: UIViewController? = controller
        while let current = node {
            if let coordinator = current.transitionCoordinator {
                return coordinator
            }
            node = current.parent ?? current.presentingViewController
        }
        return nil
    }

    private func refreshPlaybackState() {
        guard let playerController else { return }
        if playerController.player !== playbackModel.player {
            playerController.player = playbackModel.player
        }
        let failed = playbackModel.player == nil && playbackModel.errorMessage != nil
        let playerChanged = playbackModel.player !== lastAppliedPlayer
        if failed != lastAppliedFailed || playerChanged {
            lastAppliedFailed = failed
            lastAppliedPlayer = playbackModel.player
            backgroundColor = failed ? UIColor(ThemeRuntimeState.currentPalette().bgHighlight) : .clear
            playerController.view.isHidden = failed
            stillImageView.isHidden = failed || stillImageView.image == nil
            statusLabel.isHidden = !failed
            openButton.isHidden = !failed
            if failed {
                statusLabel.text = String(localized: "Video preview unavailable") + "\n" + (playbackModel.errorMessage ?? "")
                openButton.accessibilityLabel = String(localized: "Open video file")
                openButton.accessibilityHint = String(localized: "Opens the video file")
            }
        }
        if let overlay = playerController.contentOverlayView {
            captions.attach(to: overlay)
        }
        captions.setPlayer(playbackModel.player)
#if DEBUG
        AuthenticatedMediaE2EPlaybackProbe.install(on: playerController, model: playbackModel)
#endif
    }

    /// The control stays visible, spinning, until `installPlayer` succeeds, so a
    /// mount that is deferred (transition, no window yet) or does not land can be
    /// retried by tapping again.
    @objc private func playTapped() {
        guard !isStaticFallback, playerController == nil, currentEmbed != nil else { return }
        isPlayRequested = true
        playButton.showsProgress = true
        scheduleFirstMount()
    }

    /// Pixel box the still is downsampled to: the 16:9 slot at this screen's scale,
    /// width quantized so a row re-entering at a marginally different width still
    /// hits the cache.
    private func stillPixelSize(scale: CGFloat) -> CGSize {
        let measured = bounds.width > 0 ? bounds.width : displayWidth
        let width = max(16, (measured / 16).rounded() * 16)
        return CGSize(
            width: (width * scale).rounded(),
            height: (MarkdownInlineVideoLayout.reservedHeight(forWidth: width) * scale).rounded()
        )
    }

    /// Fetches (or finds cached) the pre-tap still once the row is on screen.
    /// Failure keeps the placeholder background; it is never an error state.
    private func loadStillFrameIfNeeded() {
        guard stillImageView.image == nil,
              stillTask == nil,
              playerController == nil,
              !isStaticFallback,
              let window,
              let source = currentSource,
              let identity = currentIdentity else { return }
        let size = stillPixelSize(scale: window.screen.scale)
        let store = InlineVideoStillFrameStore.shared
        if let cached = store.cachedImage(for: source, maxPixelSize: size) {
            applyStill(cached)
            return
        }
        stillTask = Task { [weak self] in
            let image = await store.image(for: source, maxPixelSize: size)
            guard let self, !Task.isCancelled, self.currentIdentity == identity else { return }
            self.stillTask = nil
            if let image { self.applyStill(image) }
        }
    }

    private func applyStill(_ image: UIImage) {
        guard playerController == nil else { return }
        stillImageView.image = image
        stillImageView.isHidden = false
        backgroundColor = .black
    }

    private func loadSidecar(for embed: MarkdownVideoEmbed) {
        sidecarTask?.cancel()
        guard let sidecarProvider else { return }
        sidecarTask = Task { [weak self] in
            let result = await sidecarProvider(embed.filePath, .video, embed.reference)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.currentEmbed == embed else { return }
                self.captions.setTimedText(result)
            }
        }
    }

    private func removePlayer() {
        isPlayRequested = false
        playButton.showsProgress = false
        playbackObservation = nil
        captions.setPlayer(nil)
        playbackModel.teardown()
        if let host = playerController {
            host.player = nil
            host.delegate = nil
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        if let slot = slotController {
            slot.willMove(toParent: nil)
            slot.view.removeFromSuperview()
            slot.removeFromParent()
        }
        playerController = nil
        slotController = nil
        lastAppliedPlayer = nil
        lastAppliedFailed = false
        currentSource = nil
        playerDelegate = nil
    }

    private func attachPlayerHost() {
        guard let slot = slotController, let host = playerController else { return }
        // The player sits above the still frame, which stays visible until AVKit
        // paints the first video frame, and below the status and play controls.
        if slot.parent == nil, let parent = nearestViewController() {
            parent.addChild(slot)
            if slot.view.superview != self {
                insertSubview(slot.view, aboveSubview: stillImageView)
            }
            slot.didMove(toParent: parent)
        } else if slot.view.superview != self {
            insertSubview(slot.view, aboveSubview: stillImageView)
        }
        if host.parent == nil {
            slot.addChild(host)
            if host.view.superview != slot.view {
                slot.view.addSubview(host.view)
            }
            host.didMove(toParent: slot)
        } else if host.view.superview != slot.view {
            slot.view.addSubview(host.view)
        }
    }

    private func shouldCommitRevealGeometry(renderingMode: ContentRenderingMode) -> Bool {
        renderingMode == .export || renderingMode == .live || window != nil
    }

    private func applyReservedHeight(_ height: CGFloat) {
        guard reservedHeight != height else { return }
        reservedHeight = height
        heightConstraint?.constant = height
        if !hasCommittedRevealGeometry {
            onPreparedGeometry?(height)
        }
    }

    private func applyDynamicTypeFonts(for category: UIContentSizeCategory) {
        let font = UIFont.preferredFont(
            forTextStyle: .caption1,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
        statusLabel.font = font
        statusLabel.adjustsFontForContentSizeCategory = true
        openButton.titleLabel?.font = font
        openButton.titleLabel?.adjustsFontForContentSizeCategory = true
    }

    /// UIKit requires the slot's parent to be the controller that owns the
    /// nearest ancestor view. Skipping up to an outer container (e.g. the
    /// reader's `FullScreenCodeViewController` above its content controller)
    /// throws `UIViewControllerHierarchyInconsistency` when the slot view
    /// enters the window.
    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let viewController = current as? UIViewController {
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

/// Full-slot play control: a tap anywhere on the still plays, and only a centered
/// disc is drawn. Accessibility activation takes the same path as a touch, so
/// VoiceOver / automation and a finger share one owner action.
private final class InlineVideoPlayButton: UIControl {
    private let disc = UIView()
    private let glyph = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// Spinner in the disc while the player is being built after a tap.
    var showsProgress = false {
        didSet {
            glyph.isHidden = showsProgress
            if showsProgress { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.isUserInteractionEnabled = false
        disc.backgroundColor = UIColor.black.withAlphaComponent(0.6)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .title1, scale: .large)
        )
        glyph.adjustsImageSizeForAccessibilityContentSizeCategory = true

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true

        addSubview(disc)
        disc.addSubview(glyph)
        disc.addSubview(spinner)
        NSLayoutConstraint.activate([
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            disc.widthAnchor.constraint(equalTo: disc.heightAnchor),
            glyph.topAnchor.constraint(equalTo: disc.topAnchor, constant: 14),
            glyph.bottomAnchor.constraint(equalTo: disc.bottomAnchor, constant: -14),
            glyph.leadingAnchor.constraint(equalTo: disc.leadingAnchor, constant: 14),
            glyph.trailingAnchor.constraint(equalTo: disc.trailingAnchor, constant: -14),
            spinner.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.layer.cornerRadius = disc.bounds.height / 2
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

/// AVKit lays out playback chrome against its parent view controller.
/// That parent must be this slot, whose view lives in the timeline cell.
/// Parenting `AVPlayerViewController` to ChatView pins the picture to the
/// screen while the bubble scrolls.
private final class InlineVideoSlotController: UIViewController {
    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.insetsLayoutMarginsFromSafeArea = false
        self.view = view
    }
}

#if DEBUG
extension NativeMarkdownVideoView {
    var debugIsStaticFallbackForTesting: Bool { isStaticFallback }
    var debugReservedHeightForTesting: CGFloat { reservedHeight }
    var debugHasPlayerForTesting: Bool { playerController != nil }
    var debugHasCurrentSourceForTesting: Bool { currentSource != nil }
    var debugIsPlaybackVisibleForTesting: Bool { isPlaybackVisible }
    var debugHasActivePlayerForTesting: Bool { playbackModel.player != nil }
    var debugHasCommittedRevealGeometryForTesting: Bool { hasCommittedRevealGeometry }
    var debugPlayerControllerForTesting: AVPlayerViewController? { playerController }
    var debugPlayerParentForTesting: UIViewController? { playerController?.parent }
    var debugPlayerSlotForTesting: UIViewController? { slotController }
    var debugPlaybackModelForTesting: AuthenticatedMediaPlayerModel { playbackModel }
    var debugPlayButtonForTesting: UIControl { playButton }
    var debugIsPlayProgressShownForTesting: Bool { playButton.showsProgress }
    /// Drives the play control's own touch action, the same owner an accessibility
    /// activation reaches.
    func debugTapPlayForTesting() { playButton.sendActions(for: .touchUpInside) }
    var debugStillImageForTesting: UIImage? { stillImageView.image }
    /// A player below the still would be hidden by it for the whole playback.
    var debugIsPlayerAboveStillForTesting: Bool {
        guard let slot = slotController,
              let slotIndex = subviews.firstIndex(of: slot.view),
              let stillIndex = subviews.firstIndex(of: stillImageView) else { return false }
        return slotIndex > stillIndex
    }
    var debugIsPlayRequestedForTesting: Bool { isPlayRequested }
    var debugFailureHitAreaForTesting: CGSize { openButton.bounds.size }
    var debugStatusLabelAdjustsFontForTesting: Bool { statusLabel.adjustsFontForContentSizeCategory }
    var debugOpenButtonIsHiddenForTesting: Bool { openButton.isHidden }
    var debugOpenButtonAdjustsFontForTesting: Bool {
        openButton.titleLabel?.adjustsFontForContentSizeCategory == true
    }
}
#endif
