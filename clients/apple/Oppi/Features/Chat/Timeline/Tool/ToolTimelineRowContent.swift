import SwiftUI
import TipKit
import UIKit

/// Native UIKit tool row.
///
/// Supports both collapsed and expanded presentation for tool rows, so row
/// expansion uses the same native renderer in both states.
struct ToolTimelineRowConfiguration: UIContentConfiguration {
    let itemID: String
    let title: String
    let preview: String?
    /// Single discriminated union for expanded content rendering.
    /// Replaces the previous 13 boolean/optional fields, making it
    /// impossible to set conflicting rendering modes.
    var expandedContent: ToolPresentationBuilder.ToolExpandedContent?
    let copyCommandText: String?
    let copyOutputText: String?
    let languageBadge: String?
    let trailing: String?
    let titleLineBreakMode: NSLineBreakMode
    let toolNamePrefix: String?
    let toolNameColor: UIColor
    let editAdded: Int?
    let editRemoved: Int?
    /// Base64-encoded image data for collapsed inline thumbnail (read tool, image files).
    let collapsedImageBase64: String?
    let collapsedImageMimeType: String?
    let isExpanded: Bool
    let isDone: Bool
    let isError: Bool
    /// Terminal without canonical tool_end/toolResult (old trace or forced stop).
    var isInterrupted: Bool = false
    /// When the tool call started (live sessions only). Used to tick elapsed time while running.
    let startedAt: Date?
    /// Frozen elapsed seconds for completed tool calls. Takes priority over startedAt.
    let elapsedSeconds: Int?
    /// Pre-rendered attributed title from server segments. When set, takes
    /// priority over the plain `title` + `toolNamePrefix` + `toolNameColor` path.
    let segmentAttributedTitle: NSAttributedString?
    /// Pre-rendered attributed trailing from server result segments.
    let segmentAttributedTrailing: NSAttributedString?
    var audioPlayer: AudioPlayerService? = nil
    var sessionAttachmentFetcher: ((String) async throws -> Data)? = nil
    var sessionAttachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)? = nil
    var sessionFileDataFetcher: ((String) async throws -> Data)? = nil
    var sessionFileMediaSourceProvider: ((String) async throws -> AuthenticatedMediaSource)? = nil
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil
    var reviewCommentSessionId: String? = nil

    func makeContentView() -> any UIView & UIContentView {
        ToolTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }

    func withReviewCommentSelection(router: ReviewCommentSelectionRouter?, sessionId: String?) -> Self {
        var copy = self
        copy.reviewCommentSelectionRouter = router
        copy.reviewCommentSessionId = sessionId
        return copy
    }

    func withAudioPlayer(_ audioPlayer: AudioPlayerService?) -> Self {
        var copy = self
        copy.audioPlayer = audioPlayer
        return copy
    }

    func withSessionAttachmentFetcher(_ fetcher: ((String) async throws -> Data)?) -> Self {
        var copy = self
        copy.sessionAttachmentFetcher = fetcher
        return copy
    }

    func withSessionAttachmentMediaSourceProvider(_ provider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)?) -> Self {
        var copy = self
        copy.sessionAttachmentMediaSourceProvider = provider
        return copy
    }

    func withSessionFileDataFetcher(_ fetcher: ((String) async throws -> Data)?) -> Self {
        var copy = self
        copy.sessionFileDataFetcher = fetcher
        return copy
    }

    func withSessionFileMediaSourceProvider(_ provider: ((String) async throws -> AuthenticatedMediaSource)?) -> Self {
        var copy = self
        copy.sessionFileMediaSourceProvider = provider
        return copy
    }

}

final class ToolTimelineRowContentView: UIView, UIContentView, UIScrollViewDelegate {
    static var activeInlineFeatureTipIDs: Set<String> = []
#if DEBUG
    static var forcesInlineFeatureTipsForTesting = false
    static var featureEducationTipLayoutInvalidationHookForTesting: (() -> Void)?
#endif
    private static let maxValidHeight: CGFloat = 10_000
    static let minOutputViewportHeight: CGFloat = 56
    static let minDiffViewportHeight: CGFloat = 68
    /// Unified max viewport height for all expanded content types.
    /// Keeps tool row expansion visually consistent regardless of content kind.
    static let maxExpandedViewportHeight: CGFloat = 620
    static let maxOutputViewportHeight: CGFloat = maxExpandedViewportHeight
    static let maxDiffViewportHeight: CGFloat = maxExpandedViewportHeight
    /// Fixed viewport height used during streaming. The cell height stays
    /// constant while content grows inside, eliminating the nested-scroll
    /// invalidation cascade (inner content resize → cell height change →
    /// outer collection layout → contentOffset fight). Double-tap opens
    /// full-screen for the complete content. On completion (isDone), the
    /// viewport resizes once to the natural bucketed height.
    static let streamingViewportHeight: CGFloat = 200
    static let outputViewportCloseSafeAreaReserve: CGFloat = 128
    static let diffViewportCloseSafeAreaReserve: CGFloat = 88
    private static let collapsedImagePreviewHeight: CGFloat = 136

    @MainActor
    enum ExpandedViewportMode {
        case none
        case diff
        case code
        case text
    }

    typealias ViewportMode = ToolRowViewportCalculator.ViewportMode

    enum ContextMenuTarget {
        case command
        case output
        case expanded
        case imagePreview
    }

    private let statusImageView = UIImageView()
    private let toolImageView = UIImageView()
    private let titleLabel = UILabel()
    private let trailingStack = UIStackView()
    private let languageBadgeIconView = UIImageView()
    private let audioPlaybackButton = UIButton(type: .system)
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let trailingLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let bodyStack = UIStackView()
    private let previewLabel = UILabel()
    let bashToolRowView = BashToolRowView()
    let expandedContainer = UIView()
    let expandedScrollView = HorizontalPanPassthroughScrollView()
    private let expandedSurfaceHostView = ToolExpandedSurfaceHostView()
    private let compactHostedSurfaceHostView = ToolExpandedSurfaceHostView()
    private let featureTipPresentationOwnerID = UUID()
    private var featureTipView: FeatureEducationTipBannerView?
    private var featureTipID: String?
    let expandedLabel = UITextView()
    private let expandedMarkdownView = AssistantMarkdownContentView()
    private let expandedReadMediaContainer = UIView()
    private let imagePreviewContainer = UIView()
    private let imagePreviewImageView = UIImageView()
    private let borderView = UIView()

    // MARK: - Mirror-reflection forwarding for test compatibility
    // These lazy stored properties alias BashToolRowView's internal surfaces.
    // Stored (not computed) so Mirror(reflecting: self).children finds them by name.

    private lazy var commandContainer: UIView = bashToolRowView.commandContainer
    private lazy var outputContainer: UIView = bashToolRowView.outputContainer
    private lazy var outputScrollView: HorizontalPanPassthroughScrollView = bashToolRowView.outputScrollView
    private lazy var commandLabel: UITextView = bashToolRowView.commandLabel
    private lazy var outputLabel: UITextView = bashToolRowView.outputLabel

    private var currentConfiguration: ToolTimelineRowConfiguration
    private var currentInteractionPolicy: ToolTimelineRowInteractionPolicy?
    private lazy var collapsedAudioController = ToolRowAudioController(button: audioPlaybackButton)
    private var bodyStackCollapsedHeightConstraint: NSLayoutConstraint?
    private var expandedViewportHeightConstraint: NSLayoutConstraint?
    private var expandedLabelWidthConstraint: NSLayoutConstraint?
    private var expandedLabelHeightLockConstraint: NSLayoutConstraint?
    private var expandedMarkdownWidthConstraint: NSLayoutConstraint?
    private var expandedReadMediaWidthConstraint: NSLayoutConstraint?
    private var imagePreviewHeightConstraint: NSLayoutConstraint?
    private var toolLeadingConstraint: NSLayoutConstraint?
    private var toolWidthConstraint: NSLayoutConstraint?
    private var titleLeadingToStatusConstraint: NSLayoutConstraint?
    private var titleLeadingToToolConstraint: NSLayoutConstraint?
    var expandedShouldAutoFollow = true
    private var liveStreamingFollow = LiveStreamingPresentation.ViewportPolicy(followsTail: true)
    var expandedRenderSignature: Int?
    private var expandedUsesViewport = false
    var expandedUsesMarkdownLayout = false
    var expandedUsesReadMediaLayout = false
    private var expandedReadMediaContentView: UIView?
    /// Theme captured by the reusable incremental Markdown viewport.
    private var expandedMarkdownViewportThemeID: ThemeID?
    private var expandedMarkdownUsesIncrementalViewport = false
    private var expandedMarkdownLastContainerWidth: CGFloat?
    private var expandedMarkdownLastViewportHeight: CGFloat?
    private var activeExpandedViewportPolicy: ToolRowViewportPolicy?
    private var expandedReadMediaViewportHeightConstraint: NSLayoutConstraint?
    /// Tracks which base64 image is currently being decoded / displayed.
    private var imagePreviewDecodedKey: String?
    private var imagePreviewDecodeTask: Task<Void, Never>?
    var expandedCodeDeferredHighlightSignature: Int?
    var expandedCodeDeferredHighlightTask: Task<Void, Never>?
    var expandedViewportMode: ExpandedViewportMode = .none
    var expandedRenderedText: String? {
        didSet { expandedWidthEstimateCache.invalidate(); expandedViewportHeightCache.invalidate() }
    }
    private var expandedWidthEstimateCache = ToolTimelineRowWidthEstimateCache()
    private var expandedViewportHeightCache = ToolTimelineRowViewportHeightCache()
    private var expandedPinchDidTriggerFullScreen = false
    private var elapsedTimer: Timer?
    private let fullScreenTerminalStream: TerminalTraceStream
    private let fullScreenSourceStream: SourceTraceStream

    private lazy var commandDoubleTapGesture = DoubleTapCopyGesture.makeGesture(
        target: self,
        action: #selector(handleCommandDoubleTap),
        cancelsTouchesInView: true
    )

    private lazy var outputDoubleTapGesture = DoubleTapCopyGesture.makeGesture(
        target: self,
        action: #selector(handleOutputDoubleTap),
        cancelsTouchesInView: true
    )

    private lazy var expandedDoubleTapGesture = DoubleTapCopyGesture.makeGesture(
        target: self,
        action: #selector(handleExpandedDoubleTap),
        cancelsTouchesInView: true
    )

    private lazy var expandedContainerDoubleTapGesture = DoubleTapCopyGesture.makeGesture(
        target: self,
        action: #selector(handleExpandedDoubleTap),
        cancelsTouchesInView: false
    )

    private lazy var expandedPinchGesture: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleExpandedPinch(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    private lazy var commandSingleTapBlocker = makeTapBlocker(requiringFailureOf: commandDoubleTapGesture)
    private lazy var outputSingleTapBlocker = makeTapBlocker(requiringFailureOf: outputDoubleTapGesture)
    private lazy var expandedSingleTapBlocker = makeTapBlocker(requiringFailureOf: expandedDoubleTapGesture)

    init(configuration: ToolTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        self.fullScreenTerminalStream = TerminalTraceStream(
            output: configuration.copyOutputText ?? "",
            command: configuration.copyCommandText,
            isDone: configuration.isDone
        )
        self.fullScreenSourceStream = SourceTraceStream(
            text: "",
            filePath: nil,
            isDone: configuration.isDone,
            finalContent: nil
        )
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        imagePreviewDecodeTask?.cancel()
        expandedCodeDeferredHighlightTask?.cancel()
        if let featureTipID {
            let ownerID = featureTipPresentationOwnerID
            Task { @MainActor in
                Self.activeInlineFeatureTipIDs.remove(featureTipID)
                FeatureEducationTipPresentationCoordinator.shared.release(
                    tipID: featureTipID,
                    ownerID: ownerID
                )
            }
        }
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? ToolTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter? {
        currentConfiguration.reviewCommentSelectionRouter
    }

    private var reviewCommentSessionId: String? {
        currentConfiguration.reviewCommentSessionId
    }

    private var reviewCommentSelectionContext: ReviewCommentSelectionContext? {
        ReviewCommentSelectionContext(
            router: reviewCommentSelectionRouter,
            sessionId: reviewCommentSessionId,
            sourceLabel: currentConfiguration.title,
            timelineItemId: currentConfiguration.itemID,
            sourceSurfaceOverride: .toolExpandedText
        )
    }

    private var perfSessionId: String? {
        currentConfiguration.reviewCommentSessionId
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let fitted = super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
        return Self.sanitizedFittingSize(fitted, fallbackWidth: targetSize.width)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            clearInlineFeatureEducationTip()
            return
        }
        scheduleFeatureEducationTipIfNeeded(
            configuration: currentConfiguration,
            showExpanded: !expandedContainer.isHidden,
            showOutput: !bashToolRowView.outputContainer.isHidden
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if ToolTimelineRowDisplayState.updateCollapsedFileTitleForCurrentWidth(
            configuration: currentConfiguration,
            titleLabel: titleLabel,
            availableWidth: collapsedTitleAvailableWidth()
        ) {
            super.layoutSubviews()
        }
        bashToolRowView.updateOutputLabelWidthIfNeeded()
        updateExpandedLabelWidthIfNeeded()
        updateExpandedMarkdownWidthIfNeeded()
        updateExpandedReadMediaWidthIfNeeded()
        updateViewportHeightsIfNeeded()
        ToolTimelineRowUIHelpers.clampScrollOffsetIfNeeded(outputScrollView)
        ToolTimelineRowUIHelpers.clampScrollOffsetIfNeeded(expandedScrollView)

        // Deferred follow-tail: settle the inner scroll view's content size,
        // then scroll to the bottom. A plain scrollToBottom() here can lag one
        // update behind because UITextView contentSize has not necessarily
        // caught up to the newly assigned text yet.
        if expandedPendingScrollToBottom {
            let contentView: UIView = expandedUsesReadMediaLayout
                ? expandedReadMediaContainer
                : (expandedUsesMarkdownLayout ? expandedMarkdownView : expandedLabel)
            expandedPendingScrollToBottom = false
            ToolTimelineRowUIHelpers.followTail(
                in: expandedScrollView,
                contentLabel: contentView
            )
        }
        bashToolRowView.flushDeferredScrollToBottom()
    }

    private func collapsedTitleAvailableWidth() -> CGFloat {
        let containerWidth = max(borderView.bounds.width, bounds.width)
        let titleMinX = titleLabel.frame.minX
        let rightLimit: CGFloat
        if trailingStack.isHidden {
            rightLimit = containerWidth - 14
        } else {
            let fittingWidth = trailingStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            let trailingWidth = max(trailingStack.bounds.width, fittingWidth)
            rightLimit = containerWidth - 8 - trailingWidth - 6
        }
        return max(0, rightLimit - titleMinX)
    }

    private func updateViewportHeightsIfNeeded() {
        let isStreaming = !currentConfiguration.isDone
        let geometry = currentGeometryContext

        if bashToolRowView.outputUsesViewport,
           let outputViewportHeightConstraint = bashToolRowView.outputViewportHeightConstraint {
            let outputPolicy = ToolRowViewportPolicy.bashOutput
            let mode = outputPolicy.viewportCalculatorMode
            if isStreaming {
                outputViewportHeightConstraint.constant = ToolRowViewportCalculator.streamingConstrainedHeight(
                    for: mode, geometry: geometry
                )
            } else {
                outputViewportHeightConstraint.constant = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
                    cache: &bashToolRowView.outputViewportHeightCache,
                    signature: bashToolRowView.outputRenderSignature,
                    widthBucket: Int(bashToolRowView.outputContainer.bounds.width.rounded()),
                    mode: mode,
                    inputBytes: bashToolRowView.outputRenderedText?.utf8.count ?? 0,
                    profile: currentOutputViewportProfile,
                    availableHeight: ToolRowViewportCalculator.availableViewportHeight(for: mode, geometry: geometry),
                    sessionId: perfSessionId
                ) {
                    ToolRowViewportCalculator.preferredViewportHeight(
                        for: self.bashToolRowView.outputLabel,
                        in: self.bashToolRowView.outputContainer,
                        mode: mode,
                        expandedScrollView: self.expandedScrollView,
                        expandedLabelWidthConstraint: self.expandedLabelWidthConstraint,
                        outputScrollView: self.outputScrollView,
                        outputUsesUnwrappedLayout: self.bashToolRowView.outputUsesUnwrappedLayout,
                        outputLabelWidthConstraint: self.bashToolRowView.outputLabelWidthConstraint,
                        geometry: geometry
                    )
                }
            }
        }

        if let policy = activeExpandedViewportPolicy,
           !policy.usesExpandedViewport,
           let expandedViewportHeightConstraint {
            expandedViewportHeightConstraint.constant = compactExpandedViewportHeight(for: policy)
            return
        }

        if expandedUsesViewport,
           let expandedViewportHeightConstraint {
            let policy = activeExpandedViewportPolicy ?? fallbackExpandedViewportPolicy()
            updateExpandedViewportHeight(
                expandedViewportHeightConstraint,
                policy: policy,
                isStreaming: isStreaming,
                geometry: geometry
            )
        }
    }

    private func updateExpandedViewportHeight(
        _ constraint: NSLayoutConstraint,
        policy: ToolRowViewportPolicy,
        isStreaming: Bool,
        geometry: ToolRowViewportCalculator.GeometryContext
    ) {
        let setHeight: (CGFloat) -> Void = { [weak self] height in
            guard let self else {
                constraint.constant = height
                return
            }
            let previousHeight = self.expandedMarkdownLastViewportHeight
            constraint.constant = height
            guard self.activeExpandedViewportPolicy?.surface == .markdownViewport,
                  self.expandedUsesMarkdownLayout
                    || self.expandedReadMediaContentView is NativeFullScreenMarkdownBody else {
                self.expandedMarkdownLastViewportHeight = nil
                return
            }
            if let previousHeight,
               abs(previousHeight - height) > 0.5 {
                // The fixed streaming height can still change when the
                // available geometry changes. Treat that as a real outer
                // geometry transition, not as Markdown content churn.
                ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
            }
            self.expandedMarkdownLastViewportHeight = height
        }

        switch policy.heightBehavior {
        case .voiceReadMedia(let minHeight, let maxHeight):
            setHeight(measuredHostedReadMediaHeight(minHeight: minHeight, maxHeight: maxHeight))

        case .compactMeasured:
            setHeight(compactExpandedViewportHeight(for: policy))

        case .markdownViewport(let maxHeight):
            let mode = policy.viewportCalculatorMode
            if isStreaming {
                setHeight(ToolRowViewportCalculator.streamingConstrainedHeight(
                    for: mode,
                    geometry: geometry
                ))
            } else {
                let availableHeight = ToolRowViewportCalculator.availableViewportHeight(
                    for: mode,
                    geometry: geometry
                )
                let hasSettledWidth = bounds.width > 10 && expandedContainer.bounds.width > 10
                let targetHeight = hasSettledWidth ? maxHeight : Self.streamingViewportHeight
                setHeight(min(availableHeight, max(mode.minHeight, targetHeight)))
            }

        case .naturalReadMedia(let minHeight, let maxHeight):
            if isStreaming {
                setHeight(ToolRowViewportCalculator.streamingConstrainedHeight(
                    for: policy.viewportCalculatorMode,
                    geometry: geometry
                ))
            } else {
                setHeight(measuredHostedReadMediaHeight(minHeight: minHeight, maxHeight: maxHeight))
            }

        case .cachedMeasured(let mode):
            if isStreaming {
                setHeight(ToolRowViewportCalculator.streamingConstrainedHeight(
                    for: mode,
                    geometry: geometry
                ))
            } else {
                setHeight(cachedExpandedViewportHeight(mode: mode, geometry: geometry))
            }
        }
    }

    private func measuredHostedReadMediaHeight(minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let measurementView = expandedReadMediaContentView ?? expandedReadMediaContainer
        let width = max(100, expandedContainer.bounds.width)
        let measured = ToolRowViewportCalculator.measuredExpandedContentHeight(
            for: measurementView,
            width: width
        )
        return min(maxHeight, max(minHeight, measured))
    }

    private func compactExpandedViewportHeight(for policy: ToolRowViewportPolicy) -> CGFloat {
        guard case .compactMeasured(let minHeight, let maxHeight) = policy.heightBehavior else {
            return 1
        }
        let fallbackWidth = window?.windowScene?.screen.bounds.width ?? superview?.bounds.width ?? 375
        let width = max(1, bounds.width > 0 ? bounds.width - 16 : fallbackWidth - 48)
        let measured = ToolRowViewportCalculator.measuredExpandedContentHeight(
            for: expandedReadMediaContentView ?? expandedReadMediaContainer,
            width: width
        )
        let lowerBounded = max(minHeight, ceil(measured))
        guard let maxHeight else { return lowerBounded }
        return min(maxHeight, lowerBounded)
    }

    private func cachedExpandedViewportHeight(
        mode: ViewportMode,
        geometry: ToolRowViewportCalculator.GeometryContext
    ) -> CGFloat {
        let expandedContentView = expandedUsesMarkdownLayout ? expandedMarkdownView : expandedLabel
        let widthBucket = Int(expandedContainer.bounds.width.rounded())
        let signature = expandedRenderSignature

        return ToolTimelineRowLayoutPerformance.resolveViewportHeight(
            cache: &expandedViewportHeightCache,
            signature: signature,
            widthBucket: widthBucket,
            mode: mode,
            inputBytes: expandedRenderedText?.utf8.count ?? 0,
            profile: currentExpandedViewportProfile,
            availableHeight: ToolRowViewportCalculator.availableViewportHeight(for: mode, geometry: geometry),
            sessionId: perfSessionId
        ) {
            ToolRowViewportCalculator.preferredViewportHeight(
                for: expandedContentView,
                in: self.expandedContainer,
                mode: mode,
                expandedScrollView: self.expandedScrollView,
                expandedLabelWidthConstraint: self.expandedLabelWidthConstraint,
                outputScrollView: self.outputScrollView,
                outputUsesUnwrappedLayout: self.bashToolRowView.outputUsesUnwrappedLayout,
                outputLabelWidthConstraint: self.bashToolRowView.outputLabelWidthConstraint,
                geometry: geometry
            )
        }
    }

    private func fallbackExpandedViewportPolicy() -> ToolRowViewportPolicy {
        switch expandedViewportMode {
        case .diff:
            return .diff
        case .code:
            return .code
        case .text, .none:
            return .text
        }
    }

    func updateExpandedLabelWidthIfNeeded() {
        guard let expandedLabelWidthConstraint else { return }

        switch expandedViewportMode {
        case .diff, .code:
            // Horizontal-scroll modes need a hard width to keep lines unwrapped.
            expandedLabelWidthConstraint.priority = .required
            guard let expandedRenderedText else { return }
            expandedLabelWidthConstraint.constant = expandedLabelWidthConstant(for: expandedRenderedText)

        case .text, .none:
            // Wrapped text modes can arrive before frameLayoutGuide has a real
            // width. Keep this at high priority so fitting width can win.
            expandedLabelWidthConstraint.priority = .defaultHigh
            expandedLabelWidthConstraint.constant = -12
        }
    }

    private func expandedLabelWidthConstant(for renderedText: String) -> CGFloat {
        let metricMode: String = switch expandedViewportMode {
        case .code: "expanded.code"
        case .diff: "expanded.diff"
        case .text, .none: "expanded.text"
        }
        return ToolTimelineRowLayoutPerformance.monospaceWidthConstant(
            frameWidth: max(1, expandedScrollView.bounds.width),
            renderedText: renderedText,
            cache: &expandedWidthEstimateCache,
            metricMode: metricMode,
            sessionId: perfSessionId
        )
    }

    private func updateExpandedMarkdownWidthIfNeeded() {
        guard let expandedMarkdownWidthConstraint else { return }
        expandedMarkdownWidthConstraint.constant = -12

        guard activeExpandedViewportPolicy?.surface == .markdownViewport,
              expandedUsesMarkdownLayout
                || expandedReadMediaContentView is NativeFullScreenMarkdownBody else {
            expandedMarkdownLastContainerWidth = nil
            return
        }

        let width = expandedUsesMarkdownLayout
            ? expandedMarkdownView.bounds.width
            : expandedReadMediaContainer.bounds.width
        guard width > 0 else { return }

        if let previousWidth = expandedMarkdownLastContainerWidth,
           abs(previousWidth - width) > 0.5 {
            // Markdown content stays inside a fixed-height viewport, but a
            // width change can alter wrapping and the outer cell's geometry.
            // Request one outer pass for that geometry change only.
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
        }
        expandedMarkdownLastContainerWidth = width
    }

    private func updateExpandedReadMediaWidthIfNeeded() {
        guard let expandedReadMediaWidthConstraint else { return }
        expandedReadMediaWidthConstraint.constant = 0
    }

    func setExpandedVerticalLockEnabled(_ enabled: Bool) {
        expandedLabelHeightLockConstraint?.isActive = enabled
    }

    private var currentOutputViewportProfile: ToolTimelineRowViewportProfile? {
        guard bashToolRowView.outputUsesViewport else { return nil }
        return ToolTimelineRowViewportProfile(kind: .bashOutput, text: bashToolRowView.outputRenderedText)
    }

    private var currentExpandedViewportProfile: ToolTimelineRowViewportProfile? {
        guard expandedUsesViewport else { return nil }

        let kind: ToolTimelineRowViewportKind
        if expandedUsesMarkdownLayout {
            kind = .markdown
        } else if expandedUsesReadMediaLayout {
            kind = .readMedia
        } else {
            kind = switch expandedViewportMode {
            case .diff: .diff
            case .code: .code
            case .text, .none: .text
            }
        }

        return ToolTimelineRowViewportProfile(kind: kind, text: expandedRenderedText)
    }

    /// Build the geometry context from the current view hierarchy for viewport calculations.
    private var currentGeometryContext: ToolRowViewportCalculator.GeometryContext {
        let windowHeight = window?.bounds.height
            ?? superview?.bounds.height
            ?? max(bounds.height, 600)
        let safeInsets = window?.safeAreaInsets ?? .zero
        let cellWidth = bounds.width > 10
            ? bounds.width
            : (window?.bounds.width ?? 375)
        return ToolRowViewportCalculator.GeometryContext(
            windowHeight: windowHeight,
            safeAreaInsets: safeInsets,
            cellWidth: cellWidth
        )
    }

    private static func sanitizedFittingSize(_ size: CGSize, fallbackWidth: CGFloat) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : max(1, fallbackWidth)

        let rawHeight: CGFloat
        if size.height.isFinite {
            rawHeight = max(1, size.height)
        } else {
            rawHeight = 44
        }

        let height = min(rawHeight, Self.maxValidHeight)
        return CGSize(width: width, height: height)
    }

    private func installExpandedAudioMessageView(
        text: String,
        attachmentId: String,
        mimeType: String,
        playbackBehavior: AudioPlaybackBehavior?,
        suppressAutoplay: Bool,
        durationSeconds: TimeInterval?
    ) {
        let native: NativeAudioMessageView
        if let existing = expandedReadMediaContentView as? NativeAudioMessageView {
            native = existing
        } else {
            clearExpandedReadMediaView()
            native = NativeAudioMessageView()
            installExpandedEmbeddedView(native)
        }

        if attachmentId.isEmpty {
            native.apply(
                id: currentConfiguration.itemID,
                message: text,
                attachmentId: attachmentId,
                mimeType: mimeType,
                playbackBehavior: playbackBehavior,
                sessionId: currentConfiguration.reviewCommentSessionId,
                audioPlayer: currentConfiguration.audioPlayer,
                attachmentFetcher: nil,
                attachmentMediaSourceProvider: nil,
                palette: ThemeRuntimeState.currentPalette(),
                suppressAutoplay: suppressAutoplay,
                durationSeconds: durationSeconds
            )
        } else {
            native.apply(
                id: currentConfiguration.itemID,
                message: text,
                attachmentId: attachmentId,
                mimeType: mimeType,
                playbackBehavior: playbackBehavior,
                sessionId: currentConfiguration.reviewCommentSessionId,
                audioPlayer: currentConfiguration.audioPlayer,
                attachmentFetcher: currentConfiguration.sessionAttachmentFetcher,
                attachmentMediaSourceProvider: currentConfiguration.sessionAttachmentMediaSourceProvider,
                palette: ThemeRuntimeState.currentPalette(),
                suppressAutoplay: suppressAutoplay,
                durationSeconds: durationSeconds
            )
        }
        native.setNeedsLayout()
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func installExpandedMarkdownViewport(
        text: String,
        isStreaming: Bool,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool
    ) {
        let themeID = ThemeRuntimeState.currentThemeID()
        let liveViewportIntent = (!isStreaming && expandedMarkdownUsesIncrementalViewport)
            ? FullScreenMarkdownViewportIntent.capturing(
                scrollView: expandedScrollView,
                followsTail: expandedShouldAutoFollow
            )
            : nil
        expandedMarkdownUsesIncrementalViewport = isStreaming

        if isStreaming {
            clearExpandedReadMediaView()
            expandedMarkdownViewportThemeID = themeID
            expandedMarkdownView.accessibilityIdentifier = "chat.timeline.row.\(currentConfiguration.itemID).markdownViewport"
            expandedMarkdownView.apply(configuration: .make(
                content: text,
                isStreaming: true,
                themeID: themeID,
                textSelectionEnabled: textSelectionEnabled,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                reviewCommentSourceContext: reviewCommentSourceContext,
                perfSurface: .toolExpanded,
                renderingMode: .live
            ))
            expandedMarkdownView.setNeedsLayout()
            setNeedsLayout()
            return
        }

        clearExpandedMarkdownContent()
        if expandedMarkdownViewportThemeID == themeID,
           expandedRenderedText == text,
           expandedReadMediaContentView is NativeFullScreenMarkdownBody {
            return
        }
        clearExpandedReadMediaView()
        let native = NativeFullScreenMarkdownBody(
            content: text,
            themeID: themeID,
            palette: themeID.palette,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            textSelectionEnabled: textSelectionEnabled,
            readerPreferences: FullScreenReaderContentFamily.markdown.defaultPreferences,
            perfSurface: .toolExpanded,
            allowsVerticalBounce: false,
            allowsVerticalScrolling: false
        )
        expandedMarkdownViewportThemeID = themeID
        native.accessibilityIdentifier = "chat.timeline.row.\(currentConfiguration.itemID).markdownViewport"
        installExpandedEmbeddedView(native, invalidatesOuterLayout: false)
        expandedReadMediaViewportHeightConstraint?.isActive = false
        let heightConstraint = expandedReadMediaContainer.heightAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.heightAnchor
        )
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        expandedReadMediaViewportHeightConstraint = heightConstraint
        if let liveViewportIntent {
            native.restoreViewportAfterMutableTransition(liveViewportIntent)
        }
        native.setNeedsLayout()
        setNeedsLayout()
    }

    private func installExpandedReadMediaView(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int,
        attachments: [ToolPresentationBuilder.ToolMediaAttachment]
    ) {
        let native: NativeExpandedReadMediaView
        if let existing = expandedReadMediaContentView as? NativeExpandedReadMediaView {
            native = existing
        } else {
            clearExpandedReadMediaView()
            native = NativeExpandedReadMediaView()
            installExpandedEmbeddedView(native)
        }

        native.apply(
            output: output,
            isError: isError,
            filePath: filePath,
            startLine: startLine,
            attachments: attachments,
            themeID: ThemeRuntimeState.currentThemeID(),
            audioPlayer: currentConfiguration.audioPlayer,
            sessionId: perfSessionId,
            attachmentFetcher: currentConfiguration.sessionAttachmentFetcher,
            attachmentMediaSourceProvider: currentConfiguration.sessionAttachmentMediaSourceProvider,
            sessionFileDataFetcher: currentConfiguration.sessionFileDataFetcher,
            sessionFileMediaSourceProvider: currentConfiguration.sessionFileMediaSourceProvider
        )
    }

    private func installExpandedEmbeddedView(
        _ view: UIView,
        invalidatesOuterLayout: Bool = true
    ) {
        view.translatesAutoresizingMaskIntoConstraints = false
        expandedReadMediaContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: expandedReadMediaContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: expandedReadMediaContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: expandedReadMediaContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: expandedReadMediaContainer.bottomAnchor),
        ])

        expandedReadMediaContentView = view

        // Coalesced invalidation defers the layout pass to the end of the
        // current runloop tick, so all synchronous changes from the enclosing
        // apply() settle before one single layoutIfNeeded fires.
        setNeedsLayout()
        if invalidatesOuterLayout {
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
        }
    }

    // MARK: - Collapsed Image Preview

    private func applyImagePreview(configuration: ToolTimelineRowConfiguration) {
        // Show only when collapsed and base64 data is available.
        guard !configuration.isExpanded,
              let base64 = configuration.collapsedImageBase64,
              !base64.isEmpty else {
            imagePreviewDecodeTask?.cancel()
            imagePreviewDecodeTask = nil
            imagePreviewDecodedKey = nil
            imagePreviewImageView.image = nil
            imagePreviewContainer.isHidden = true
            return
        }

        imagePreviewContainer.isHidden = false

        // Stable key uses both prefix and suffix to avoid collisions.
        let key = ImageDecodeCache.decodeKey(for: base64, maxPixelSize: 720)
        guard key != imagePreviewDecodedKey else { return }
        imagePreviewDecodedKey = key

        // Keep a stable placeholder height until decode completes.
        imagePreviewHeightConstraint?.constant = Self.collapsedImagePreviewHeight

        // Cancel previous decode task if still running.
        imagePreviewDecodeTask?.cancel()
        imagePreviewImageView.image = nil

        let currentKey = key
        imagePreviewDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let image = ImageDecodeCache.decode(base64: base64, maxPixelSize: 720)
            await MainActor.run { [weak self] in
                guard let self, self.imagePreviewDecodedKey == currentKey else { return }
                self.imagePreviewImageView.image = image
                if let image,
                   image.size.width > 0,
                   image.size.height > 0 {
                    self.layoutIfNeeded()
                    let availableWidth = max(1, self.imagePreviewContainer.bounds.width - 12)
                    let targetHeight = Self.collapsedPreviewHeight(
                        for: image.size,
                        availableWidth: availableWidth,
                        windowHeight: self.window?.bounds.height
                    )
                    self.imagePreviewHeightConstraint?.constant = targetHeight
                    self.setNeedsLayout()
                    ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
                }
            }
        }
    }

    private static func collapsedPreviewHeight(
        for imageSize: CGSize,
        availableWidth: CGFloat,
        windowHeight: CGFloat?
    ) -> CGFloat {
        ImageViewportSizing.fittedHeight(
            forWidth: availableWidth,
            aspectRatio: imageSize.height / imageSize.width,
            screenHeight: windowHeight
        ) + 12
    }

    private func clearExpandedReadMediaView() {
        expandedReadMediaViewportHeightConstraint?.isActive = false
        expandedMarkdownViewportThemeID = nil
        expandedMarkdownLastContainerWidth = nil
        expandedMarkdownLastViewportHeight = nil
        expandedReadMediaViewportHeightConstraint = nil
        expandedReadMediaContentView?.removeFromSuperview()
        expandedReadMediaContentView = nil
    }

    /// Reset the markdown view so it no longer contributes intrinsic size.
    ///
    /// Called when switching away from markdown mode. The markdown view's
    /// constraints still bind to the scroll view's content layout guide,
    /// so stale content would conflict with the active view's constraints.
    /// Uses `clearContent()` instead of `apply(configuration:)` to bypass
    /// the equality guard and cache pipeline for guaranteed cleanup.
    private func clearExpandedMarkdownContent() {
        expandedMarkdownView.clearContent()
    }

    // MARK: - Expanded Content Helpers

    /// Prepare for label-based expanded content (diff, code, plain text).
    func showExpandedLabel() {
        compactHostedSurfaceHostView.clearActiveSurface()
        compactHostedSurfaceHostView.isHidden = true
        expandedScrollView.isHidden = false
        expandedSurfaceHostView.activateSurfaceView(expandedLabel)
        expandedMarkdownView.isHidden = true
        expandedLabel.isHidden = false
        expandedReadMediaContainer.isHidden = true
        expandedUsesMarkdownLayout = false
        expandedUsesReadMediaLayout = false
        clearExpandedReadMediaView()
        // Clear stale markdown content to prevent constraint conflicts.
        // All three expanded subviews pin to the same contentLayoutGuide
        // edges at required priority. If the markdown view retains content
        // from a previous cell reuse cycle, its intrinsic height conflicts
        // with the label's, and Auto Layout may zero out the label frame.
        clearExpandedMarkdownContent()
    }

    private func showExpandedMarkdownViewport() {
        compactHostedSurfaceHostView.clearActiveSurface()
        compactHostedSurfaceHostView.isHidden = true
        expandedScrollView.isHidden = false
        expandedSurfaceHostView.activateSurfaceView(expandedMarkdownView)
        expandedLabel.attributedText = nil
        expandedLabel.text = nil
        expandedLabel.isHidden = true
        expandedMarkdownView.isHidden = false
        expandedReadMediaContainer.isHidden = true
        expandedUsesMarkdownLayout = true
        expandedUsesReadMediaLayout = false
        expandedLabelWidthConstraint?.priority = .defaultHigh
        expandedLabelWidthConstraint?.constant = -12
        setExpandedContainerGestureInterceptionEnabled(true)
    }

    /// Prepare for embedded expanded content.
    private func showExpandedHostedView() {
        compactHostedSurfaceHostView.clearActiveSurface()
        compactHostedSurfaceHostView.isHidden = true
        expandedScrollView.isHidden = false
        expandedSurfaceHostView.activateSurfaceView(expandedReadMediaContainer, contentInsets: .zero)
        expandedLabel.attributedText = nil
        expandedLabel.text = nil
        expandedLabel.isHidden = true
        expandedMarkdownView.isHidden = true
        expandedReadMediaContainer.isHidden = false
        expandedUsesMarkdownLayout = false
        expandedUsesReadMediaLayout = true
        clearExpandedMarkdownContent()
        // Reset the label width constraint from code/diff mode to prevent
        // the hidden label from dominating contentLayoutGuide width.
        expandedLabelWidthConstraint?.priority = .defaultHigh
        expandedLabelWidthConstraint?.constant = -12
        updateExpandedReadMediaWidthIfNeeded()
        setExpandedContainerGestureInterceptionEnabled(false)
    }

    private func showCompactHostedView() {
        expandedSurfaceHostView.clearActiveSurface()
        expandedScrollView.isHidden = true
        compactHostedSurfaceHostView.isHidden = false
        compactHostedSurfaceHostView.activateSurfaceView(expandedReadMediaContainer, contentInsets: .zero)
        expandedLabel.attributedText = nil
        expandedLabel.text = nil
        expandedLabel.isHidden = true
        expandedMarkdownView.isHidden = true
        expandedReadMediaContainer.isHidden = false
        expandedUsesMarkdownLayout = false
        expandedUsesReadMediaLayout = true
        clearExpandedMarkdownContent()
        expandedLabelWidthConstraint?.priority = .defaultHigh
        expandedLabelWidthConstraint?.constant = -12
        setExpandedContainerGestureInterceptionEnabled(false)
    }

    /// Activate the expanded viewport height constraint.
    func showExpandedViewport(policy: ToolRowViewportPolicy? = nil) {
        let policy = policy ?? activeExpandedViewportPolicy ?? fallbackExpandedViewportPolicy()
        expandedViewportHeightConstraint?.priority = policy.constraintPriority
        expandedViewportHeightConstraint?.isActive = true
        expandedUsesViewport = policy.usesExpandedViewport
    }

    /// Reset expanded container to hidden/default state.
    private func hideExpandedContainer(outputColor: UIColor) {
        cancelDeferredCodeHighlight()
        expandedSurfaceHostView.clearActiveSurface()
        compactHostedSurfaceHostView.clearActiveSurface()
        expandedLabel.attributedText = nil
        expandedLabel.text = nil
        expandedLabel.textColor = outputColor
        expandedLabel.textContainer.lineBreakMode = .byCharWrapping
        expandedLabel.isHidden = true
        expandedMarkdownView.isHidden = true
        expandedReadMediaContainer.isHidden = true
        expandedUsesMarkdownLayout = false
        expandedUsesReadMediaLayout = false
        clearExpandedReadMediaView()
        expandedScrollView.isHidden = false
        compactHostedSurfaceHostView.isHidden = true
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedScrollView.isScrollEnabled = false
        setExpandedVerticalLockEnabled(false)
        expandedViewportMode = .none
        activeExpandedViewportPolicy = nil
        expandedRenderedText = nil
        expandedRenderSignature = nil
        updateExpandedLabelWidthIfNeeded()
        expandedViewportHeightConstraint?.isActive = false
        expandedUsesViewport = false
        expandedShouldAutoFollow = true
        liveStreamingFollow = LiveStreamingPresentation.ViewportPolicy(followsTail: true)
        ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
    }

    private func setupViews() {
        backgroundColor = .clear

        ToolTimelineRowViewStyler.styleBorderView(borderView)

        addSubview(borderView)

        ToolTimelineRowViewStyler.styleHeader(
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            trailingStack: trailingStack,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel
        )
        ToolTimelineRowViewStyler.stylePreviewLabel(previewLabel)
        ToolTimelineRowViewStyler.styleExpanded(
            expandedContainer: expandedContainer,
            expandedScrollView: expandedScrollView,
            expandedLabel: expandedLabel,
            expandedMarkdownView: expandedMarkdownView,
            expandedReadMediaContainer: expandedReadMediaContainer,
            delegate: self
        )

        // Bash views (commandLabel/outputLabel) are styled by BashToolRowView.
        // Set UITextViewDelegate here for selected-text edit-menu integration.
        commandLabel.delegate = self
        outputLabel.delegate = self
        expandedLabel.delegate = self

        ToolTimelineRowViewStyler.styleImagePreview(
            imagePreviewContainer: imagePreviewContainer,
            imagePreviewImageView: imagePreviewImageView
        )
        imagePreviewContainer.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleImagePreviewTap))
        )
        imagePreviewContainer.addInteraction(UIContextMenuInteraction(delegate: self))
        imagePreviewContainer.addSubview(imagePreviewImageView)

        bodyStackCollapsedHeightConstraint = ToolTimelineRowViewStyler.styleBodyStack(bodyStack)

        audioPlaybackButton.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.addArrangedSubview(audioPlaybackButton)
        trailingStack.addArrangedSubview(elapsedLabel)
        trailingStack.addArrangedSubview(addedLabel)
        trailingStack.addArrangedSubview(removedLabel)
        trailingStack.addArrangedSubview(trailingLabel)
        trailingStack.addArrangedSubview(languageBadgeIconView)

        // This scroll view is nested inside a self-sizing timeline cell. Automatic
        // safe-area insets can shift the entire media surface and its overlays.
        expandedScrollView.contentInsetAdjustmentBehavior = .never
        expandedContainer.addSubview(expandedScrollView)
        expandedContainer.addSubview(compactHostedSurfaceHostView)

        NSLayoutConstraint.activate(
            ToolTimelineRowLayoutBuilder.makeLanguageBadgeConstraints(
                languageBadgeIconView: languageBadgeIconView
            ) + [
                audioPlaybackButton.widthAnchor.constraint(equalToConstant: 32),
                audioPlaybackButton.heightAnchor.constraint(equalToConstant: 32),
                compactHostedSurfaceHostView.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
                compactHostedSurfaceHostView.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
                compactHostedSurfaceHostView.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
                compactHostedSurfaceHostView.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),
            ]
        )

        expandedScrollView.addSubview(expandedSurfaceHostView)
        expandedSurfaceHostView.prepareSurfaceView(expandedLabel)
        expandedSurfaceHostView.prepareSurfaceView(expandedMarkdownView)
        expandedSurfaceHostView.prepareSurfaceView(expandedReadMediaContainer)
        compactHostedSurfaceHostView.isHidden = true
        bodyStack.addArrangedSubview(previewLabel)
        bodyStack.addArrangedSubview(imagePreviewContainer)
        bodyStack.addArrangedSubview(bashToolRowView)
        bodyStack.addArrangedSubview(expandedContainer)

        // Gesture recognizers for bash containers (accessed via lazy vars).
        commandContainer.isUserInteractionEnabled = true
        outputContainer.isUserInteractionEnabled = true
        expandedContainer.isUserInteractionEnabled = true

        commandContainer.addGestureRecognizer(commandDoubleTapGesture)
        outputContainer.addGestureRecognizer(outputDoubleTapGesture)
        expandedScrollView.addGestureRecognizer(expandedDoubleTapGesture)
        expandedContainerDoubleTapGesture.require(toFail: expandedDoubleTapGesture)
        expandedSingleTapBlocker.require(toFail: expandedContainerDoubleTapGesture)
        expandedContainer.addGestureRecognizer(expandedContainerDoubleTapGesture)
        expandedScrollView.addGestureRecognizer(expandedPinchGesture)

        commandContainer.addGestureRecognizer(commandSingleTapBlocker)
        outputContainer.addGestureRecognizer(outputSingleTapBlocker)
        expandedContainer.addGestureRecognizer(expandedSingleTapBlocker)

        commandContainer.addInteraction(UIContextMenuInteraction(delegate: self))
        outputContainer.addInteraction(UIContextMenuInteraction(delegate: self))
        expandedContainer.addInteraction(UIContextMenuInteraction(delegate: self))

        borderView.addSubview(statusImageView)
        borderView.addSubview(toolImageView)
        borderView.addSubview(titleLabel)
        borderView.addSubview(trailingStack)
        borderView.addSubview(bodyStack)

        let layout = ToolTimelineRowLayoutBuilder.makeConstraints(
            containerView: self,
            borderView: borderView,
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            trailingStack: trailingStack,
            bodyStack: bodyStack,
            expandedContainer: expandedContainer,
            expandedScrollView: expandedScrollView,
            expandedSurfaceHostView: expandedSurfaceHostView,
            expandedLabel: expandedLabel,
            expandedMarkdownView: expandedMarkdownView,
            expandedReadMediaContainer: expandedReadMediaContainer,
            imagePreviewContainer: imagePreviewContainer,
            imagePreviewImageView: imagePreviewImageView,
            minDiffViewportHeight: Self.minDiffViewportHeight,
            collapsedImagePreviewHeight: Self.collapsedImagePreviewHeight
        )

        toolLeadingConstraint = layout.toolLeading
        toolWidthConstraint = layout.toolWidth
        titleLeadingToStatusConstraint = layout.titleLeadingToStatus
        titleLeadingToToolConstraint = layout.titleLeadingToTool
        expandedLabelWidthConstraint = layout.expandedLabelWidth
        expandedLabelHeightLockConstraint = layout.expandedLabelHeightLock
        expandedMarkdownWidthConstraint = layout.expandedMarkdownWidth
        expandedReadMediaWidthConstraint = layout.expandedReadMediaWidth
        imagePreviewHeightConstraint = layout.imagePreviewHeight
        expandedViewportHeightConstraint = layout.expandedViewportHeight

        // During the first self-sizing measurement pass, scroll view frame
        // layout guides can still report width=0. Keep markdown/hosted width
        // constraints below required priority so systemLayoutSizeFitting can
        // provide a temporary fitting width instead of measuring at 0px.
        expandedMarkdownWidthConstraint?.priority = .defaultHigh
        expandedReadMediaWidthConstraint?.priority = .defaultHigh

        NSLayoutConstraint.activate(layout.all)
    }

    private func apply(configuration: ToolTimelineRowConfiguration) {
        // 1. Save previous state
        let previousConfiguration = currentConfiguration
        let isExpandingTransition = !previousConfiguration.isExpanded && configuration.isExpanded
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        ToolTimelineRowViewStyler.applyTheme(
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel,
            previewLabel: previewLabel,
            expandedContainer: expandedContainer
        )
        bashToolRowView.applyTheme(palette)

        let terminalStreamOutput: String
        if case .text(let text, _) = configuration.expandedContent {
            // The stream drives full-screen display; keep its ANSI payload and
            // strip only when the controller builds clipboard text.
            terminalStreamOutput = text
        } else {
            terminalStreamOutput = configuration.copyOutputText ?? ""
        }
        fullScreenTerminalStream.update(
            output: terminalStreamOutput,
            command: configuration.copyCommandText,
            isDone: configuration.isDone
        )

        // 2. Header: title, icon, badge, trailing, preview
        let showPreview = applyHeader(configuration: configuration)

        // Collapsed image thumbnail for read tool image files
        applyImagePreview(configuration: configuration)

        // 3. Build render plan and dispatch expanded content
        let outputColor = configuration.isError ? UIColor(Color.themeRed) : UIColor(Color.themeFg)
        let renderPlan = ToolRowPlanBuilder.build(configuration: configuration)
        let wasExpandedVisible = !expandedContainer.isHidden
        let wasCommandVisible = !commandContainer.isHidden
        let wasOutputVisible = !outputContainer.isHidden

        expandedNeedsFollowTail = false
        setExpandedContainerGestureInterceptionEnabled(true)
        currentInteractionPolicy = renderPlan.interactionPolicy
        updateFullScreenSourceStream(configuration: configuration)

        var showExpanded = false
        var showCommand = false
        var showOutput = false
        var activeExpandedContent: ToolPresentationBuilder.ToolExpandedContent?

        if configuration.isExpanded, let expandedContent = configuration.expandedContent {
            activeExpandedContent = expandedContent

            if case .bash(let command, let output, let unwrapped) = expandedContent {
                cancelDeferredCodeHighlight()
                hideExpandedContainer(outputColor: outputColor)

                let input = BashRenderInput(
                    command: command,
                    output: output,
                    unwrapped: unwrapped,
                    isError: configuration.isError,
                    isStreaming: !configuration.isDone,
                    sessionId: perfSessionId
                )
                let result = bashToolRowView.apply(
                    input: input,
                    outputColor: outputColor,
                    wasOutputVisible: wasOutputVisible
                )

                if result.showOutput {
                    bashToolRowView.setOutputVerticalLockEnabled(bashToolRowView.outputUsesUnwrappedLayout)
                    bashToolRowView.updateOutputLabelWidthIfNeeded()
                } else {
                    bashToolRowView.setOutputVerticalLockEnabled(false)
                }

                showCommand = result.showCommand
                showOutput = result.showOutput
            } else if shouldRenderExpandedContent(expandedContent) {
                let output = makeExpandedRenderOutput(
                    expandedContent: expandedContent,
                    configuration: configuration,
                    renderPlan: renderPlan,
                    outputColor: outputColor,
                    wasExpandedVisible: wasExpandedVisible
                )
                applyExpandedRenderOutput(output, isExpandingTransition: isExpandingTransition)
                showExpanded = true
            } else {
                hideExpandedContainer(outputColor: outputColor)
            }
        }

        // 4. Container visibility
        applyContainerVisibility(
            showExpanded: showExpanded,
            showCommand: showCommand,
            showOutput: showOutput,
            isExpandingTransition: isExpandingTransition,
            wasExpandedVisible: wasExpandedVisible,
            wasCommandVisible: wasCommandVisible,
            wasOutputVisible: wasOutputVisible,
            outputColor: outputColor
        )

        // 5. Interactions, review comments, viewport updates, follow-tail
        applyInteractionsAndScrolling(
            plan: renderPlan,
            showCommand: showCommand,
            showOutput: showOutput,
            showExpanded: showExpanded,
            showPreview: showPreview,
            expandedContent: activeExpandedContent,
            configuration: configuration,
            isExpandingTransition: isExpandingTransition
        )

        // 6. Status appearance
        ToolTimelineRowDisplayState.applyStatusAppearance(
            isDone: configuration.isDone,
            isError: configuration.isError,
            isInterrupted: configuration.isInterrupted,
            statusImageView: statusImageView,
            borderView: borderView
        )

        // 7. Elapsed timer
        updateElapsedTimer(configuration: configuration)

        // 8. Contextual education for hidden row gestures.
        scheduleFeatureEducationTipIfNeeded(
            configuration: configuration,
            showExpanded: showExpanded,
            showOutput: showOutput
        )
    }

    // MARK: - apply() decomposition

    /// Apply header elements: title, tool icon, language badge, trailing labels, preview.
    /// Returns whether the preview label is visible.
    private func applyHeader(configuration: ToolTimelineRowConfiguration) -> Bool {
        ToolTimelineRowDisplayState.applyTitle(
            configuration: configuration,
            titleLabel: titleLabel
        )
        applyToolIcon(
            toolNamePrefix: configuration.toolNamePrefix,
            toolNameColor: configuration.toolNameColor
        )

        ToolTimelineRowDisplayState.applyLanguageBadge(
            badge: configuration.languageBadge,
            languageBadgeIconView: languageBadgeIconView
        )

        ToolTimelineRowDisplayState.applyTrailing(
            configuration: configuration,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel
        )
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: configuration.startedAt,
            elapsedSeconds: configuration.elapsedSeconds,
            isDone: configuration.isDone,
            elapsedLabel: elapsedLabel
        )
        collapsedAudioController.apply(configuration: configuration)
        ToolTimelineRowDisplayState.updateTrailingVisibility(
            trailingStack: trailingStack,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel
        )
        if !audioPlaybackButton.isHidden {
            trailingStack.isHidden = false
        }

        if ToolTimelineRowDisplayState.updateCollapsedFileTitleForCurrentWidth(
            configuration: configuration,
            titleLabel: titleLabel,
            availableWidth: collapsedTitleAvailableWidth()
        ) {
            setNeedsLayout()
        }

        return ToolTimelineRowDisplayState.applyPreview(
            configuration: configuration,
            previewLabel: previewLabel
        )
    }

    private func scheduleFeatureEducationTipIfNeeded(
        configuration: ToolTimelineRowConfiguration,
        showExpanded: Bool,
        showOutput: Bool
    ) {
        if shouldShowToolDetailsTip(configuration: configuration) {
            showInlineFeatureEducationTip(
                FeatureEducationTips.OpenToolDetailsTip(),
                descriptor: FeatureEducationTips.openToolDetails,
                before: previewLabel
            )
            return
        }

        if shouldShowToolOutputShortcutsTip(
            configuration: configuration,
            showExpanded: showExpanded,
            showOutput: showOutput
        ) {
            showInlineFeatureEducationTip(
                FeatureEducationTips.ToolOutputShortcutsTip(),
                descriptor: FeatureEducationTips.toolOutputShortcuts,
                before: showExpanded ? expandedContainer : bashToolRowView
            )
            return
        }

        clearInlineFeatureEducationTip()
    }

    private func showInlineFeatureEducationTip<TipType: Tip>(
        _ tip: TipType,
        descriptor: FeatureEducationTipDescriptor,
        before arrangedView: UIView
    ) {
#if DEBUG
        let force = Self.forcesInlineFeatureTipsForTesting
            || ProcessInfo.processInfo.arguments.contains("--show-feature-tips-for-testing")
        let shouldDisplay = tip.shouldDisplay || force
#else
        let force = false
        let shouldDisplay = tip.shouldDisplay
#endif
        guard shouldDisplay else {
            if featureTipID == descriptor.id { clearInlineFeatureEducationTip() }
            return
        }
        if featureTipID == descriptor.id, featureTipView?.superview === bodyStack { return }
        guard !Self.activeInlineFeatureTipIDs.contains(descriptor.id) else { return }
        guard FeatureEducationTipPresentationCoordinator.shared.claim(
            tipID: descriptor.id,
            ownerID: featureTipPresentationOwnerID,
            force: force
        ) else { return }

        clearInlineFeatureEducationTip()

        let tipView = FeatureEducationTipBannerView()
        let tipToClose = tip
        tipView.configure(descriptor: descriptor) { [weak self] in
            tipToClose.invalidate(reason: .tipClosed)
            self?.clearInlineFeatureEducationTip()
        }
        tipView.translatesAutoresizingMaskIntoConstraints = false
        featureTipView = tipView
        featureTipID = descriptor.id
        Self.activeInlineFeatureTipIDs.insert(descriptor.id)

        let index = bodyStack.arrangedSubviews.firstIndex(of: arrangedView) ?? 0
        bodyStack.insertArrangedSubview(tipView, at: index)
        invalidateLayoutForFeatureEducationTipSizeChange()
    }

    func dismissFeatureEducationTipForAction() {
        clearInlineFeatureEducationTip()
    }

    private func clearInlineFeatureEducationTip() {
        guard let featureTipView else { return }
        bodyStack.removeArrangedSubview(featureTipView)
        featureTipView.removeFromSuperview()
        if let featureTipID {
            Self.activeInlineFeatureTipIDs.remove(featureTipID)
            FeatureEducationTipPresentationCoordinator.shared.release(
                tipID: featureTipID,
                ownerID: featureTipPresentationOwnerID
            )
        }
        self.featureTipView = nil
        featureTipID = nil
        invalidateLayoutForFeatureEducationTipSizeChange()
    }

    private func invalidateLayoutForFeatureEducationTipSizeChange() {
#if DEBUG
        Self.featureEducationTipLayoutInvalidationHookForTesting?()
#endif
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func shouldShowToolDetailsTip(configuration: ToolTimelineRowConfiguration) -> Bool {
        guard configuration.isDone, !configuration.isExpanded else { return false }
        return configuration.toolNamePrefix?.localizedCaseInsensitiveCompare("ask") != .orderedSame
    }

    private func shouldShowToolOutputShortcutsTip(
        configuration: ToolTimelineRowConfiguration,
        showExpanded: Bool,
        showOutput: Bool
    ) -> Bool {
        guard configuration.isExpanded, showExpanded || showOutput else { return false }
        return canShowFullScreenContent || outputCopyText != nil
    }

    private func shouldRenderExpandedContent(_ content: ToolPresentationBuilder.ToolExpandedContent) -> Bool {
        switch content {
        case .audioMessage(let text, let attachmentId, _, _, _):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentId.isEmpty
        case .bash, .diff, .code, .markdown, .readMedia, .status, .text:
            return true
        }
    }

    /// Show/hide containers based on which content is active.
    private func applyContainerVisibility(
        showExpanded: Bool,
        showCommand: Bool,
        showOutput: Bool,
        isExpandingTransition: Bool,
        wasExpandedVisible: Bool,
        wasCommandVisible: Bool,
        wasOutputVisible: Bool,
        outputColor: UIColor
    ) {
        if !showExpanded {
            hideExpandedContainer(outputColor: outputColor)
        }
        ToolTimelineRowDisplayState.applyContainerVisibility(
            expandedContainer,
            shouldShow: showExpanded,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasExpandedVisible
        )

        if !showCommand {
            bashToolRowView.resetCommandState()
        }
        ToolTimelineRowDisplayState.applyContainerVisibility(
            commandContainer,
            shouldShow: showCommand,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasCommandVisible
        )

        if !showOutput {
            bashToolRowView.resetOutputState(outputColor: outputColor)
            bashToolRowView.updateOutputLabelWidthIfNeeded()
            outputScrollView.isScrollEnabled = false
            bashToolRowView.setOutputVerticalLockEnabled(false)
        }
        bashToolRowView.isHidden = !showCommand && !showOutput
        ToolTimelineRowDisplayState.applyContainerVisibility(
            outputContainer,
            shouldShow: showOutput,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasOutputVisible
        )

        let containerVisibilityChanged = wasExpandedVisible != showExpanded
            || wasCommandVisible != showCommand
            || wasOutputVisible != showOutput
        if containerVisibilityChanged {
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
        }
    }

    /// Apply interaction policy, review comment selection, viewport heights, and follow-tail.
    private func applyInteractionsAndScrolling(
        plan: ToolRowRenderPlan,
        showCommand: Bool,
        showOutput: Bool,
        showExpanded: Bool,
        showPreview: Bool,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent?,
        configuration: ToolTimelineRowConfiguration,
        isExpandingTransition: Bool
    ) {
        if let policy = currentInteractionPolicy,
           showExpanded || showOutput {
            applyInteractionPolicy(
                policy,
                spec: plan.interactionSpec,
                showOutputContainer: showOutput
            )
        } else {
            setExpandedContainerGestureInterceptionEnabled(true)
            expandedScrollView.isScrollEnabled = false
            outputScrollView.isScrollEnabled = false
        }

        updateReviewCommentSelectionIntegration(
            plan: plan,
            showCommandContainer: showCommand,
            showOutputContainer: showOutput,
            showExpandedContainer: showExpanded,
            expandedContent: expandedContent
        )

        let showImagePreview = !imagePreviewContainer.isHidden
        let showBody = showPreview || showImagePreview || showExpanded || showCommand || showOutput
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody
        updateViewportHeightsIfNeeded()

        flushPendingFollowTail()
    }

    // MARK: - Elapsed Timer

    private func updateElapsedTimer(configuration: ToolTimelineRowConfiguration) {
        let needsTimer = configuration.startedAt != nil && !configuration.isDone

        if needsTimer, let startedAt = configuration.startedAt {
            // Timer already running — just update the label (apply already called applyElapsed)
            if elapsedTimer != nil { return }

            // Start a 1s timer to tick the elapsed label while the tool runs.
            // Captures startedAt by value — stable for the lifetime of this tool call.
            // Timer fires on main RunLoop; [weak self] ensures no work after dealloc.
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ToolTimelineRowDisplayState.applyElapsed(
                        startedAt: startedAt,
                        elapsedSeconds: nil,
                        isDone: false,
                        elapsedLabel: self.elapsedLabel
                    )
                }
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    // MARK: - Expanded render dispatch + apply

    private func makeExpandedRenderOutput(
        expandedContent: ToolPresentationBuilder.ToolExpandedContent,
        configuration: ToolTimelineRowConfiguration,
        renderPlan: ToolRowRenderPlan,
        outputColor: UIColor,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderOutput {
        let isStreaming = !configuration.isDone
        let viewportPolicy = ToolRowViewportPolicy.forExpandedContent(
            expandedContent,
            toolNamePrefix: configuration.toolNamePrefix
        )

        switch expandedContent {
        case .bash:
            // Bash is handled inline in apply() — should never reach here.
            fatalError("Bash mode must not route through makeExpandedRenderOutput")

        case .diff(let lines, let path):
            return ToolRowDiffRenderStrategy.render(
                lines: lines,
                path: path,
                isStreaming: isStreaming,
                expandedLabel: expandedLabel,
                expandedScrollView: expandedScrollView,
                previousSignature: expandedRenderSignature,
                previousRenderedText: expandedRenderedText,
                previousAutoFollow: expandedShouldAutoFollow,
                isCurrentModeDiff: expandedViewportMode == .diff,
                wasExpandedVisible: wasExpandedVisible,
                sessionId: perfSessionId,
                viewportPolicy: viewportPolicy
            )

        case .code(let text, let language, let startLine, _):
            return ToolRowCodeRenderStrategy.render(
                text: text,
                language: language,
                startLine: startLine,
                isStreaming: isStreaming,
                expandedLabel: expandedLabel,
                expandedScrollView: expandedScrollView,
                previousSignature: expandedRenderSignature,
                previousRenderedText: expandedRenderedText,
                previousAutoFollow: expandedShouldAutoFollow,
                isCurrentModeCode: expandedViewportMode == .code,
                wasExpandedVisible: wasExpandedVisible,
                sessionId: perfSessionId,
                viewportPolicy: viewportPolicy
            )

        case .markdown(let text):
            let markdownSelectionEnabled = renderPlan.interactionSpec.markdownSelectionEnabled
            let reviewCommentSourceContext = reviewCommentSessionId.flatMap { sessionId in
                ToolTimelineRowReviewCommentSelectionSupport.sourceContext(
                    surface: .expandedMarkdown,
                    expandedContent: .markdown(text: text),
                    sessionId: sessionId,
                    sourceLabel: configuration.title,
                    timelineItemId: configuration.itemID,
                    expandedLabelText: nil
                )
            }
            return ToolRowMarkdownRenderStrategy.render(
                text: text,
                isStreaming: isStreaming,
                expandedScrollView: expandedScrollView,
                previousSignature: expandedRenderSignature,
                previousRenderedText: expandedRenderedText,
                previousAutoFollow: expandedShouldAutoFollow,
                wasExpandedVisible: wasExpandedVisible,
                isUsingMarkdownViewportLayout: expandedUsesMarkdownLayout
                    || expandedReadMediaContentView is NativeFullScreenMarkdownBody,
                isThemeChanged: expandedMarkdownViewportThemeID != ThemeRuntimeState.currentThemeID(),
                reviewCommentSelectionRouter: markdownSelectionEnabled ? reviewCommentSelectionRouter : nil,
                reviewCommentSourceContext: markdownSelectionEnabled ? reviewCommentSourceContext : nil,
                textSelectionEnabled: markdownSelectionEnabled,
                viewportPolicy: viewportPolicy
            )

        case .readMedia(let output, let filePath, let startLine, let attachments):
            return ToolRowReadMediaRenderStrategy.render(
                output: output,
                filePath: filePath,
                startLine: startLine,
                attachments: attachments,
                isError: configuration.isError,
                hasAttachmentFetcher: configuration.sessionAttachmentFetcher != nil,
                hasAttachmentMediaSourceProvider: configuration.sessionAttachmentMediaSourceProvider != nil,
                hasSessionFileDataFetcher: configuration.sessionFileDataFetcher != nil,
                hasSessionFileMediaSourceProvider: configuration.sessionFileMediaSourceProvider != nil,
                previousSignature: expandedRenderSignature,
                isUsingReadMediaLayout: expandedUsesReadMediaLayout,
                hasExpandedReadMediaContentView: expandedReadMediaContentView != nil,
                viewportPolicy: viewportPolicy
            )

        case .audioMessage(let text, let attachmentId, let mimeType, let durationSeconds, let playbackBehavior):
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var hasher = Hasher()
            hasher.combine(trimmedText)
            hasher.combine(attachmentId)
            hasher.combine(mimeType)
            hasher.combine(durationSeconds)
            return ExpandedRenderOutput(
                renderSignature: hasher.finalize(),
                renderedText: trimmedText,
                shouldAutoFollow: false,
                viewportPolicy: viewportPolicy,
                verticalLock: false,
                scrollBehavior: .preserve,
                lineBreakMode: .byWordWrapping,
                horizontalScroll: false,
                deferredHighlight: nil,
                invalidateLayout: true,
                installAction: .audioMessage(
                    text: trimmedText,
                    attachmentId: attachmentId,
                    mimeType: mimeType,
                    durationSeconds: durationSeconds,
                    playbackBehavior: playbackBehavior
                )
            )

        case .status(let message):
            return ToolRowTextRenderStrategy.render(
                text: message,
                language: nil,
                isError: configuration.isError,
                isStreaming: isStreaming,
                outputColor: outputColor,
                expandedLabel: expandedLabel,
                expandedScrollView: expandedScrollView,
                previousSignature: expandedRenderSignature,
                previousRenderedText: expandedRenderedText,
                previousAutoFollow: expandedShouldAutoFollow,
                wasExpandedVisible: wasExpandedVisible,
                isCurrentModeText: expandedViewportMode == .text,
                isUsingMarkdownLayout: expandedUsesMarkdownLayout,
                isUsingReadMediaLayout: expandedUsesReadMediaLayout,
                sessionId: perfSessionId,
                viewportPolicy: viewportPolicy
            )

        case .text(let text, let language):
            return ToolRowTextRenderStrategy.render(
                text: text,
                language: language,
                isError: configuration.isError,
                isStreaming: isStreaming,
                outputColor: outputColor,
                expandedLabel: expandedLabel,
                expandedScrollView: expandedScrollView,
                previousSignature: expandedRenderSignature,
                previousRenderedText: expandedRenderedText,
                previousAutoFollow: expandedShouldAutoFollow,
                wasExpandedVisible: wasExpandedVisible,
                isCurrentModeText: expandedViewportMode == .text,
                isUsingMarkdownLayout: expandedUsesMarkdownLayout,
                isUsingReadMediaLayout: expandedUsesReadMediaLayout,
                sessionId: perfSessionId,
                viewportPolicy: viewportPolicy
            )
        }
    }

    private func applyExpandedRenderOutput(_ output: ExpandedRenderOutput, isExpandingTransition: Bool) {
        let wasMarkdownViewport = expandedUsesMarkdownLayout
            || expandedReadMediaContentView is NativeFullScreenMarkdownBody

        // Execute view-installation intent before surface switch so the
        // hosted view is in the hierarchy when showExpandedHostedView() runs.
        switch output.installAction {
        case .none:
            break
        case .readMedia(let mediaOutput, let isError, let filePath, let startLine, let attachments):
            installExpandedReadMediaView(output: mediaOutput, isError: isError, filePath: filePath, startLine: startLine, attachments: attachments)
        case .audioMessage(let text, let attachmentId, let mimeType, let durationSeconds, let playbackBehavior):
            let suppressVoiceAutoplay = isExpandingTransition || playbackBehavior == .playNow
            installExpandedAudioMessageView(
                text: text,
                attachmentId: attachmentId,
                mimeType: mimeType,
                playbackBehavior: playbackBehavior,
                suppressAutoplay: suppressVoiceAutoplay,
                durationSeconds: durationSeconds
            )
        case .markdownViewport(
            let text,
            let isStreaming,
            let reviewCommentSelectionRouter,
            let reviewCommentSourceContext,
            let textSelectionEnabled
        ):
            installExpandedMarkdownViewport(
                text: text,
                isStreaming: isStreaming,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                reviewCommentSourceContext: reviewCommentSourceContext,
                textSelectionEnabled: textSelectionEnabled
            )
        }

        switch output.surface {
        case .label: showExpandedLabel()
        case .hostedView: showExpandedHostedView()
        case .compactHostedView: showCompactHostedView()
        case .markdownViewport:
            expandedMarkdownUsesIncrementalViewport
                ? showExpandedMarkdownViewport()
                : showExpandedHostedView()
        }

        if output.surface == .markdownViewport {
            _ = liveStreamingFollow.applyStreamTick(
                isStreaming: !currentConfiguration.isDone,
                shouldRerender: output.scrollBehavior != .preserve,
                wasVisible: wasMarkdownViewport,
                previousText: expandedRenderedText,
                currentText: output.renderedText ?? ""
            )
            expandedShouldAutoFollow = liveStreamingFollow.followsTail
        } else {
            expandedShouldAutoFollow = output.shouldAutoFollow
        }
        expandedRenderSignature = output.renderSignature
        expandedRenderedText = output.renderedText
        activeExpandedViewportPolicy = output.viewportPolicy
        expandedViewportMode = output.viewportMode

        expandedLabel.textContainer.lineBreakMode = output.lineBreakMode
        expandedScrollView.alwaysBounceHorizontal = output.horizontalScroll
        expandedScrollView.showsHorizontalScrollIndicator = output.horizontalScroll

        setExpandedVerticalLockEnabled(output.verticalLock)
        updateExpandedLabelWidthIfNeeded()
        applyExpandedViewportPolicy(output.viewportPolicy)

        if let deferred = output.deferredHighlight {
            scheduleDeferredCodeHighlightIfNeeded(deferred, sessionId: perfSessionId)
        } else {
            cancelDeferredCodeHighlight()
        }

        switch output.scrollBehavior {
        case .followTail: scheduleExpandedAutoScrollToBottomIfNeeded()
        case .resetToTop: ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
        case .preserve: break
        }

        let markdownViewportWasRemoved = wasMarkdownViewport && output.surface != .markdownViewport
        if output.invalidateLayout || markdownViewportWasRemoved {
            setNeedsLayout()
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
        }
    }

    private func applyExpandedViewportPolicy(_ policy: ToolRowViewportPolicy) {
        if policy.usesExpandedViewport {
            showExpandedViewport(policy: policy)
        } else {
            expandedUsesViewport = false
            expandedViewportHeightConstraint?.priority = policy.constraintPriority
            expandedViewportHeightConstraint?.constant = compactExpandedViewportHeight(for: policy)
            expandedViewportHeightConstraint?.isActive = true
        }

        if policy.surface == .markdownViewport {
            expandedScrollView.isScrollEnabled = expandedMarkdownUsesIncrementalViewport
            expandedScrollView.alwaysBounceVertical = false
            expandedScrollView.bounces = false
            setExpandedContainerGestureInterceptionEnabled(true)
        }
    }

    private func updateReviewCommentSelectionIntegration(
        plan: ToolRowRenderPlan,
        showCommandContainer: Bool,
        showOutputContainer: Bool,
        showExpandedContainer: Bool,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent?
    ) {
        let hasSession = reviewCommentSelectionRouter != nil && reviewCommentSessionId != nil
        let hasExpandedContext = hasSession && {
            guard let sessionId = reviewCommentSessionId else { return false }
            return ToolTimelineRowReviewCommentSelectionSupport.sourceContext(
                surface: .expandedLabel,
                expandedContent: expandedContent,
                sessionId: sessionId,
                sourceLabel: currentConfiguration.title,
                timelineItemId: currentConfiguration.itemID,
                expandedLabelText: expandedLabel.text ?? expandedLabel.attributedText?.string
            ) != nil
        }()

        let flags = ToolTimelineRowReviewCommentSelectionSupport.selectionFlags(
            spec: plan.interactionSpec,
            showCommand: showCommandContainer,
            showOutput: showOutputContainer,
            showExpanded: showExpandedContainer,
            hasCommandContext: hasSession,
            hasOutputContext: hasSession,
            hasExpandedContext: hasExpandedContext,
            hasMarkdownContext: hasSession,
            isMarkdownLayout: expandedUsesMarkdownLayout,
            isReadMediaLayout: expandedUsesReadMediaLayout
        )

        commandLabel.isSelectable = flags.commandSelectable
        commandDoubleTapGesture.isEnabled = !flags.commandSelectable
        commandSingleTapBlocker.isEnabled = !flags.commandSelectable

        outputLabel.isSelectable = flags.outputSelectable
        outputDoubleTapGesture.isEnabled = !flags.outputSelectable
        outputSingleTapBlocker.isEnabled = !flags.outputSelectable

        expandedLabel.isSelectable = flags.expandedLabelSelectable

        if flags.disableGestureInterception {
            setExpandedContainerTapCopyGestureEnabled(false)
            expandedPinchGesture.isEnabled = false
        }
    }

    private func resolveReviewCommentSourceContext(for textView: UITextView) -> ReviewCommentSourceContext? {
        guard let sessionId = reviewCommentSessionId,
              reviewCommentSelectionRouter != nil else {
            return nil
        }
        let surface: ToolTimelineRowReviewCommentSelectionSupport.Surface
        if textView === commandLabel { surface = .command } else if textView === outputLabel { surface = .output } else if textView === expandedLabel { surface = .expandedLabel } else { return nil }
        return toolReviewCommentSourceContext(
            surface: surface,
            expandedContent: currentConfiguration.expandedContent,
            sessionId: sessionId,
            expandedLabelText: expandedLabel.text ?? expandedLabel.attributedText?.string
        )
    }

    private func toolReviewCommentSourceContext(
        surface: ToolTimelineRowReviewCommentSelectionSupport.Surface,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent?,
        sessionId: String,
        expandedLabelText: String?
    ) -> ReviewCommentSourceContext? {
        ToolTimelineRowReviewCommentSelectionSupport.sourceContext(
            surface: surface,
            expandedContent: expandedContent,
            sessionId: sessionId,
            sourceLabel: currentConfiguration.title,
            timelineItemId: currentConfiguration.itemID,
            expandedLabelText: expandedLabelText
        )
    }

    private func applyInteractionPolicy(
        _ policy: ToolTimelineRowInteractionPolicy,
        spec: TimelineInteractionSpec,
        showOutputContainer: Bool
    ) {
        setExpandedContainerTapCopyGestureEnabled(spec.enablesTapCopyGesture)
        expandedPinchGesture.isEnabled = spec.enablesPinchGesture

        expandedScrollView.alwaysBounceHorizontal = policy.allowsHorizontalScroll
        expandedScrollView.showsHorizontalScrollIndicator = policy.allowsHorizontalScroll
        expandedScrollView.isScrollEnabled = policy.allowsHorizontalScroll

        if showOutputContainer, case .bash(let unwrapped) = policy.mode {
            outputScrollView.alwaysBounceHorizontal = spec.allowsHorizontalScroll
            outputScrollView.showsHorizontalScrollIndicator = spec.allowsHorizontalScroll
            outputScrollView.isScrollEnabled = unwrapped
            bashToolRowView.setOutputVerticalLockEnabled(unwrapped)
        } else {
            outputScrollView.isScrollEnabled = false
            bashToolRowView.setOutputVerticalLockEnabled(false)
        }
    }

    private func setExpandedContainerGestureInterceptionEnabled(_ enabled: Bool) {
        setExpandedContainerTapCopyGestureEnabled(enabled)
        expandedPinchGesture.isEnabled = enabled
    }

    private func setExpandedContainerTapCopyGestureEnabled(_ enabled: Bool) {
        expandedDoubleTapGesture.isEnabled = enabled
        expandedContainerDoubleTapGesture.isEnabled = enabled
        expandedSingleTapBlocker.isEnabled = enabled
    }

    #if DEBUG
    enum ActiveExpandedSurfaceKindForTesting: String {
        case none
        case label
        case markdown
        case hosted
    }

    // periphery:ignore - used by ToolRowContentViewTests via @testable import
    var expandedTapCopyGestureEnabledForTesting: Bool {
        expandedDoubleTapGesture.isEnabled
            && expandedContainerDoubleTapGesture.isEnabled
            && expandedSingleTapBlocker.isEnabled
    }

    // periphery:ignore - used by ToolExpandedSurfaceHostTests via @testable import
    var activeExpandedSurfaceKindForTesting: ActiveExpandedSurfaceKindForTesting {
        switch expandedSurfaceHostView.activeView {
        case expandedLabel:
            .label
        case expandedMarkdownView:
            .markdown
        case expandedReadMediaContainer:
            expandedReadMediaContentView is NativeFullScreenMarkdownBody ? .markdown : .hosted
        default:
            .none
        }
    }

    // periphery:ignore - used by ToolExpandedSurfaceHostTests via @testable import
    var expandedMarkdownViewportThemeIDForTesting: ThemeID? {
        expandedMarkdownViewportThemeID
    }
    #endif

    /// Creates a target-less tap recognizer that consumes single taps so the
    /// collection view's row-selection tap doesn't fire through gesture-enabled
    /// containers. Waits for the paired double-tap to fail before recognizing.
    private func makeTapBlocker(
        requiringFailureOf doubleTap: UITapGestureRecognizer
    ) -> UITapGestureRecognizer {
        let r = UITapGestureRecognizer()
        r.require(toFail: doubleTap)
        return r
    }

    @objc private func handleCommandDoubleTap() {
        guard let text = commandCopyText else { return }
        copy(text: text, feedbackView: bashToolRowView.commandContainer)
    }

    @objc private func handleImagePreviewTap() {
        _ = presentCollapsedImagePreviewIfAvailable()
    }

    @discardableResult
    func presentCollapsedImagePreviewIfAvailable() -> Bool {
        // Requires a presenter in the responder chain. UI test harnesses that
        // attach collection views directly to windows may intentionally skip
        // modal presentation and fall back to default row expansion behavior.
        guard ToolTimelineRowPresentationHelpers.nearestViewController(from: self) != nil else {
            return false
        }

        if let image = imagePreviewImageView.image {
            ToolTimelineRowPresentationHelpers.presentFullScreenImage(image, from: self)
            return true
        }

        guard let base64 = currentConfiguration.collapsedImageBase64,
              !base64.isEmpty,
              let image = ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600) else {
            return false
        }

        ToolTimelineRowPresentationHelpers.presentFullScreenImage(image, from: self)
        return true
    }

    @objc private func handleExpandedPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard canShowFullScreenContent else { return }

        switch recognizer.state {
        case .began:
            expandedPinchDidTriggerFullScreen = false

        case .changed:
            guard !expandedPinchDidTriggerFullScreen,
                  recognizer.scale >= 1.10 else {
                return
            }

            expandedPinchDidTriggerFullScreen = true
            showFullScreenContent()
            FeatureEducationTips.markToolOutputShortcutUsed()
            dismissFeatureEducationTipForAction()

        case .ended, .cancelled, .failed:
            expandedPinchDidTriggerFullScreen = false

        default:
            break
        }
    }

    private var commandCopyText: String? {
        let explicit = currentConfiguration.copyCommandText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        return nil
    }

    var outputCopyText: String? {
        if let explicit = currentConfiguration.copyOutputText,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        return nil
    }

    private func updateFullScreenSourceStream(configuration: ToolTimelineRowConfiguration) {
        guard let policy = currentInteractionPolicy,
              policy.supportsFullScreenPreview,
              let snapshot = ToolTimelineRowFullScreenSupport.liveSourceSnapshot(
                configuration: configuration,
                outputCopyText: outputCopyText
              ) else {
            fullScreenSourceStream.update(
                text: "",
                filePath: nil,
                isDone: true,
                finalContent: nil
            )
            return
        }

        let finalContent: FullScreenCodeContent?
        if configuration.isDone {
            finalContent = ToolTimelineRowFullScreenSupport.staticFullScreenContent(
                configuration: configuration,
                outputCopyText: outputCopyText,
                terminalStream: nil
            )
        } else {
            finalContent = snapshot.finalContent
        }

        fullScreenSourceStream.update(
            text: snapshot.text,
            filePath: snapshot.filePath,
            isDone: configuration.isDone,
            finalContent: finalContent
        )
    }

    private var fullScreenContent: FullScreenCodeContent? {
        ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: currentConfiguration,
            outputCopyText: outputCopyText,
            interactionPolicy: currentInteractionPolicy,
            terminalStream: fullScreenTerminalStream,
            sourceStream: fullScreenSourceStream
        )
    }

    var canShowFullScreenContent: Bool {
        fullScreenContent != nil
    }

    func showFullScreenContent() {
        guard let content = fullScreenContent else {
            return
        }

        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            content,
            from: self,
            reviewCommentSelectionContext: reviewCommentSelectionContext
        )
    }

    private func fullScreenSourceContext(for content: FullScreenCodeContent) -> ReviewCommentSourceContext? {
        guard let reviewCommentSelectionContext else { return nil }

        switch content {
        case .code(_, let language, let filePath, _):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenCode,
                filePath: filePath,
                languageHint: language
            )

        case .plainText(_, let filePath):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenSource,
                filePath: filePath
            )

        case .diff(let document):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenDiff,
                filePath: document.filePath
            )

        case .markdown(_, let filePath, _):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenMarkdown,
                filePath: filePath
            )

        case .terminal(_, let command, _):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenTerminal,
                sourceLabel: command ?? currentConfiguration.title
            )

        case .liveSource(let snapshot, _):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenSource,
                filePath: snapshot.filePath
            )

        case .html(_, let filePath):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenSource,
                filePath: filePath
            )

        case .thinking:
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenThinking,
                sourceLabel: "Thinking"
            )

        case .latex(_, let filePath), .orgMode(_, let filePath), .mermaid(_, let filePath), .graphviz(_, let filePath):
            return reviewCommentSelectionContext.sourceContextIgnoringSurfaceOverride(
                surface: .fullScreenCode,
                filePath: filePath
            )
        }
    }

    func contextMenu(for target: ContextMenuTarget) -> UIMenu? {
        let command = commandCopyText
        let output = outputCopyText

        return ToolTimelineRowContextMenuBuilder.menu(
            target: target,
            hasCommand: command != nil,
            hasOutput: output != nil,
            canShowFullScreenContent: canShowFullScreenContent,
            hasPreviewImage: imagePreviewImageView.image != nil,
            onCopyCommand: { [weak self] copyTarget in
                guard let self, let command else { return }
                let feedbackView = ToolTimelineRowContextMenuTargeting.feedbackView(
                    for: copyTarget,
                    commandContainer: self.commandContainer,
                    outputContainer: self.outputContainer,
                    expandedContainer: self.expandedContainer,
                    imagePreviewContainer: self.imagePreviewContainer
                )
                self.copy(text: command, feedbackView: feedbackView)
            },
            onCopyOutput: { [weak self] copyTarget in
                guard let self, let output else { return }
                let feedbackView = ToolTimelineRowContextMenuTargeting.feedbackView(
                    for: copyTarget,
                    commandContainer: self.commandContainer,
                    outputContainer: self.outputContainer,
                    expandedContainer: self.expandedContainer,
                    imagePreviewContainer: self.imagePreviewContainer
                )
                self.copy(text: output, feedbackView: feedbackView)
                FeatureEducationTips.markToolOutputShortcutUsed()
                self.dismissFeatureEducationTipForAction()
            },
            onOpenFullScreenContent: { [weak self] in
                self?.showFullScreenContent()
                FeatureEducationTips.markToolOutputShortcutUsed()
                self?.dismissFeatureEducationTipForAction()
            },
            onViewFullScreenImage: { [weak self] in
                guard let self, let image = self.imagePreviewImageView.image else { return }
                ToolTimelineRowPresentationHelpers.presentFullScreenImage(image, from: self)
            },
            onCopyImage: { [weak self] in
                guard let image = self?.imagePreviewImageView.image else { return }
                UIPasteboard.general.image = image
            },
            onSaveImage: { [weak self] in
                guard let image = self?.imagePreviewImageView.image else { return }
                PhotoLibrarySaver.save(image)
            }
        )
    }

    func copy(text: String, feedbackView: UIView) {
        TimelineCopyFeedback.copy(text, feedbackView: feedbackView)
    }

    /// Flags set by render strategies during apply(). Consumed at the end of
    /// apply() after container visibility is established and bounds are valid.
    private var expandedNeedsFollowTail = false

    func scheduleExpandedAutoScrollToBottomIfNeeded() {
        guard expandedShouldAutoFollow else { return }
        expandedNeedsFollowTail = true
    }

    /// Called at the end of apply() after containers are visible and have bounds.
    ///
    /// Defers the expensive TextKit2 layout + scroll-to-bottom to the next
    /// `layoutSubviews()` pass. The old approach forced `layoutIfNeeded()`
    /// synchronously during cell reconfiguration, triggering a full TextKit2
    /// viewport layout (adding/removing subviews for text fragments). By
    /// deferring, the layout happens once during the collection view's natural
    /// layout pass instead of redundantly during the batch update.
    private func flushPendingFollowTail() {
        bashToolRowView.flushFollowTail()
        if expandedNeedsFollowTail, !expandedContainer.isHidden {
            let label: UIView = expandedUsesMarkdownLayout ? expandedMarkdownView : expandedLabel
            label.invalidateIntrinsicContentSize()
            expandedScrollView.setNeedsLayout()
            expandedPendingScrollToBottom = true
            setNeedsLayout()
            expandedNeedsFollowTail = false
        }
    }

    /// Whether a deferred scroll-to-bottom is pending for the expanded content.
    private var expandedPendingScrollToBottom = false

    #if DEBUG
    // Whether the tail of the expanded content is visible in the viewport.
    //
    // Used by tests to assert auto-follow behavior without coupling to
    // internal scroll offsets or dispatch timing.
    // periphery:ignore - used by StreamingAutoFollowTests via @testable import
    var isShowingExpandedTailForTesting: Bool {
        guard expandedShouldAutoFollow,
              !expandedContainer.isHidden,
              expandedScrollView.bounds.height > 0 else {
            return expandedContainer.isHidden || expandedShouldAutoFollow
        }

        expandedScrollView.layoutIfNeeded()
        return ToolTimelineRowUIHelpers.isNearBottom(expandedScrollView)
    }
    #endif

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === expandedScrollView, expandedUsesMarkdownLayout else { return }
        _ = liveStreamingFollow.handle(.interactionBegan)
        expandedShouldAutoFollow = liveStreamingFollow.followsTail
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === expandedScrollView, expandedUsesMarkdownLayout, !decelerate else { return }
        finishMarkdownLiveFollowInteraction()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === expandedScrollView, expandedUsesMarkdownLayout else { return }
        finishMarkdownLiveFollowInteraction()
    }

    private func finishMarkdownLiveFollowInteraction() {
        let intent = liveStreamingFollow.handle(.interactionEnded(
            isNearBottom: ToolTimelineRowUIHelpers.isNearBottom(expandedScrollView),
            isStreaming: !currentConfiguration.isDone
        ))
        expandedShouldAutoFollow = liveStreamingFollow.followsTail
        if intent == .followTail {
            scheduleExpandedAutoScrollToBottomIfNeeded()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // outputScrollView scroll events are handled by BashToolRowView (its own delegate).
        if scrollView === expandedScrollView {
            if expandedLabelHeightLockConstraint?.isActive == true {
                let lockedY = -expandedScrollView.adjustedContentInset.top
                if abs(expandedScrollView.contentOffset.y - lockedY) > 0.5 {
                    expandedScrollView.contentOffset.y = lockedY
                }
            }
            if expandedUsesMarkdownLayout { return }
            expandedShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(expandedScrollView)
        }
    }

    private func applyToolIcon(toolNamePrefix: String?, toolNameColor: UIColor) {
        guard let symbolName = ToolTimelineRowUIHelpers.toolSymbolName(for: toolNamePrefix),
              let baseImage = UIImage(systemName: symbolName) else {
            toolImageView.image = nil
            toolImageView.isHidden = true
            toolLeadingConstraint?.constant = 0
            toolWidthConstraint?.constant = 0
            titleLeadingToToolConstraint?.isActive = false
            titleLeadingToStatusConstraint?.isActive = true
            return
        }

        let configuredImage = baseImage.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )

        toolImageView.image = configuredImage
        toolImageView.tintColor = toolNameColor
        toolImageView.isHidden = false
        toolLeadingConstraint?.constant = 5
        toolWidthConstraint?.constant = 12
        titleLeadingToStatusConstraint?.isActive = false
        titleLeadingToToolConstraint?.isActive = true
    }

}

extension ToolTimelineRowContentView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: resolveReviewCommentSourceContext(for: textView)
        )
    }
}

extension ToolTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let target = ToolTimelineRowContextMenuTargeting.target(
            for: interaction.view,
            commandContainer: commandContainer,
            outputContainer: outputContainer,
            expandedContainer: expandedContainer,
            imagePreviewContainer: imagePreviewContainer
        ),
              contextMenu(for: target) != nil else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: target)
        }
    }
}
