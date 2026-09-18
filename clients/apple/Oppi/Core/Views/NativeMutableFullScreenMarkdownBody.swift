import UIKit

/// Visible content position carried across the one-way mutable-to-immutable swap.
///
/// Prefer a stable reader segment plus the offset inside that item. Absolute
/// content offset is only the fallback when the live stack cannot be mapped.
struct FullScreenMarkdownViewportAnchor: Equatable {
    var segmentID: MarkdownReaderSegmentID?
    var offsetInItem: CGFloat
    var absoluteOffset: CGFloat
}

/// Viewport intent carried across the one-way mutable-to-immutable Markdown swap.
enum FullScreenMarkdownViewportIntent: Equatable {
    case top
    case tail
    case detached(FullScreenMarkdownViewportAnchor)

    static func capturing(
        scrollView: UIScrollView,
        followsTail: Bool,
        edgeSlop: CGFloat = 28,
        visibleAnchor: FullScreenMarkdownViewportAnchor? = nil
    ) -> Self {
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let y = min(max(scrollView.contentOffset.y, minimumY), maximumY)
        // Attached streams stay on the tail even when the live document still
        // fits the viewport, where y is also the top edge.
        if followsTail {
            return .tail
        }
        if y - minimumY <= edgeSlop {
            return .top
        }
        if maximumY - y <= edgeSlop {
            return .tail
        }
        if let visibleAnchor {
            return .detached(visibleAnchor)
        }
        return .detached(FullScreenMarkdownViewportAnchor(
            segmentID: nil,
            offsetInItem: 0,
            absoluteOffset: y
        ))
    }
}

/// Full-screen host for append-only Markdown while its source is still changing.
///
/// Parsing and segment reuse stay owned by `AssistantMarkdownContentView`; this
/// type owns only the outer viewport and the one-way handoff to the immutable,
/// render-ahead reader when the stream completes.
final class NativeMutableFullScreenMarkdownBody: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let markdownView = AssistantMarkdownContentView()

    private let themeID: ThemeID
    private let palette: ThemePalette
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var textSelectionEnabled: Bool
    private var serverID: String?
    private var workspaceID: String?
    private var worktreeId: String?
    private var sessionID: String?
    private var routesFileReferencesThroughSession: Bool
    private var serverBaseURL: URL?
    private var sourceFilePath: String?
    private let lineAnchor: SourceLineAnchor?
    private let perfSurface: MarkdownStreamingPerf.Surface?
    private var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    private var fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    private var fetchHostFile: ((_ path: String) async throws -> Data)?
    private var makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?
    private var makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider?
    private var makeMarkdownUSDZFile: MarkdownUSDZFileProvider?
    private var makeTimedTextSidecar: TimedTextSidecarProvider?
    private var audioPlayer: AudioPlayerService?

    private var readerPreferences: FullScreenReaderPreferences
    private var latestContent: String
    private var isStreaming: Bool
    private var immutableBody: NativeFullScreenMarkdownBody?
    private var pendingCompletionContent: String?
    private var pendingCompletionViewportIntent: FullScreenMarkdownViewportIntent?
    private var isTransitioningToImmutable = false
    private var transitionCount = 0
    private var mutableApplyCount = 0

    #if DEBUG
    private var debugViewportInteractionOverride: Bool?
    #endif

    private lazy var viewportOwner = MarkdownReaderViewportOwner(
        scrollView: scrollView,
        followsTail: isStreaming,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(
        content: String,
        isStreaming: Bool = true,
        themeID: ThemeID? = nil,
        palette: ThemePalette,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool = true,
        serverID: String? = nil,
        workspaceID: String? = nil,
        worktreeId: String? = nil,
        sessionID: String? = nil,
        routesFileReferencesThroughSession: Bool = false,
        serverBaseURL: URL? = nil,
        sourceFilePath: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.markdown.defaultPreferences,
        perfSurface: MarkdownStreamingPerf.Surface? = nil,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil,
        fetchHostFile: ((_ path: String) async throws -> Data)? = nil,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider? = nil,
        makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider? = nil,
        makeMarkdownUSDZFile: MarkdownUSDZFileProvider? = nil,
        makeTimedTextSidecar: TimedTextSidecarProvider? = nil,
        audioPlayer: AudioPlayerService? = nil
    ) {
        self.themeID = themeID ?? ThemeRuntimeState.currentThemeID()
        self.palette = palette
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.worktreeId = worktreeId
        self.sessionID = sessionID
        self.routesFileReferencesThroughSession = routesFileReferencesThroughSession
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.lineAnchor = lineAnchor
        self.readerPreferences = readerPreferences
        self.perfSurface = perfSurface
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.fetchHostFile = fetchHostFile
        self.makeMarkdownVideoSource = makeMarkdownVideoSource
        self.makeMarkdownAudioSource = makeMarkdownAudioSource
        self.makeMarkdownUSDZFile = makeMarkdownUSDZFile
        self.makeTimedTextSidecar = makeTimedTextSidecar
        self.audioPlayer = audioPlayer
        self.latestContent = content
        self.isStreaming = isStreaming
        super.init(frame: .zero)

        setupMutableViewport()
        applyMutableContent()
        _ = viewportOwner

        if !self.isStreaming {
            transitionToImmutableIfPossible()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var accessibilityIdentifier: String? {
        didSet {
            scrollView.accessibilityIdentifier = accessibilityIdentifier
            immutableBody?.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard immutableBody == nil else { return }
        viewportOwner.scheduleFollowTail()
        transitionToImmutableIfPossible()
    }

    private func setupMutableViewport() {
        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = UIColor(palette.bgDark)
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.delegate = self
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePanStateChange(_:)))

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.backgroundColor = .clear
        markdownView.fetchWorkspaceFile = fetchWorkspaceFile
        markdownView.fetchSessionFile = fetchSessionFile
        markdownView.fetchHostFile = fetchHostFile
        markdownView.makeMarkdownVideoSource = makeMarkdownVideoSource
        markdownView.makeMarkdownAudioSource = makeMarkdownAudioSource
        markdownView.makeMarkdownUSDZFile = makeMarkdownUSDZFile
        markdownView.makeTimedTextSidecar = makeTimedTextSidecar
        markdownView.audioPlayer = audioPlayer

        addSubview(scrollView)
        scrollView.addSubview(markdownView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            markdownView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            markdownView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            markdownView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            markdownView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            markdownView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -24),
        ])
    }

    func update(content: String, isStreaming: Bool) {
        update(
            content: content,
            isStreaming: isStreaming,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            serverID: serverID,
            workspaceID: workspaceID,
            worktreeId: worktreeId,
            sessionID: sessionID,
            routesFileReferencesThroughSession: routesFileReferencesThroughSession,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile,
            fetchHostFile: fetchHostFile,
            makeMarkdownVideoSource: makeMarkdownVideoSource,
            makeMarkdownAudioSource: makeMarkdownAudioSource,
            makeMarkdownUSDZFile: makeMarkdownUSDZFile,
            makeTimedTextSidecar: makeTimedTextSidecar,
            audioPlayer: audioPlayer
        )
    }

    func update(
        content: String,
        isStreaming: Bool,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        serverID: String?,
        workspaceID: String?,
        worktreeId: String? = nil,
        sessionID: String?,
        routesFileReferencesThroughSession: Bool = false,
        serverBaseURL: URL?,
        sourceFilePath: String?,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?,
        fetchHostFile: ((_ path: String) async throws -> Data)? = nil,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?,
        makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider? = nil,
        makeMarkdownUSDZFile: MarkdownUSDZFileProvider? = nil,
        makeTimedTextSidecar: TimedTextSidecarProvider? = nil,
        audioPlayer: AudioPlayerService? = nil
    ) {
        guard immutableBody == nil else { return }
        let completionIntent = isStreaming ? nil : currentViewportIntent()
        let contentChanged = latestContent != content
        let streamingChanged = self.isStreaming != isStreaming
        let contextChanged = self.reviewCommentSelectionRouter !== reviewCommentSelectionRouter
            || self.reviewCommentSourceContext != reviewCommentSourceContext
            || self.serverID != serverID
            || self.workspaceID != workspaceID
            || self.worktreeId != worktreeId
            || self.sessionID != sessionID
            || self.routesFileReferencesThroughSession != routesFileReferencesThroughSession
            || self.serverBaseURL != serverBaseURL
            || self.sourceFilePath != sourceFilePath

        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.worktreeId = worktreeId
        self.sessionID = sessionID
        self.routesFileReferencesThroughSession = routesFileReferencesThroughSession
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.fetchHostFile = fetchHostFile
        self.makeMarkdownVideoSource = makeMarkdownVideoSource
        self.makeMarkdownAudioSource = makeMarkdownAudioSource
        self.makeMarkdownUSDZFile = makeMarkdownUSDZFile
        self.makeTimedTextSidecar = makeTimedTextSidecar
        self.audioPlayer = audioPlayer
        markdownView.fetchWorkspaceFile = fetchWorkspaceFile
        markdownView.fetchSessionFile = fetchSessionFile
        markdownView.fetchHostFile = fetchHostFile
        markdownView.makeMarkdownVideoSource = makeMarkdownVideoSource
        markdownView.makeMarkdownAudioSource = makeMarkdownAudioSource
        markdownView.makeMarkdownUSDZFile = makeMarkdownUSDZFile
        markdownView.makeTimedTextSidecar = makeTimedTextSidecar
        markdownView.audioPlayer = audioPlayer

        guard contentChanged || streamingChanged || contextChanged else {
            viewportOwner.scheduleFollowTail()
            return
        }

        latestContent = content
        self.isStreaming = isStreaming

        if isStreaming {
            pendingCompletionContent = nil
            pendingCompletionViewportIntent = nil
            // `DeltaCoalescer` already batches live ticks. Apply immediately
            // so this reader does not invent a second clock.
            applyMutableContent()
            // Ordinary append ticks must not re-arm following after the reader
            // has intentionally detached from the live tail.
            viewportOwner.scheduleFollowTail()
        } else {
            applyMutableContent()
            pendingCompletionContent = content
            pendingCompletionViewportIntent = completionIntent
            viewportOwner.streamCompleted()
            transitionToImmutableIfPossible()
        }
    }

    private func applyMutableContent() {
        mutableApplyCount += 1
        markdownView.apply(configuration: .make(
            content: latestContent,
            isStreaming: isStreaming,
            themeID: themeID,
            textSelectionEnabled: textSelectionEnabled,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            serverID: serverID,
            workspaceID: workspaceID,
            worktreeId: worktreeId,
            sessionID: sessionID,
            routesFileReferencesThroughSession: routesFileReferencesThroughSession,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            lineAnchor: lineAnchor,
            readerPreferences: readerPreferences,
            perfSurface: perfSurface,
            renderingMode: .live
        ))
        setNeedsLayout()
    }

    private func transitionToImmutableIfPossible() {
        guard immutableBody == nil,
              !isTransitioningToImmutable,
              !isStreaming,
              let finalContent = pendingCompletionContent ?? Optional(latestContent),
              !isViewportInteracting else { return }

        isTransitioningToImmutable = true
        defer { isTransitioningToImmutable = false }
        let intent = pendingCompletionViewportIntent ?? currentViewportIntent()
        pendingCompletionContent = nil
        pendingCompletionViewportIntent = nil
        layoutIfNeeded()
        let body = NativeFullScreenMarkdownBody(
            content: finalContent,
            themeID: themeID,
            palette: palette,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            textSelectionEnabled: textSelectionEnabled,
            serverID: serverID,
            workspaceID: workspaceID,
            worktreeId: worktreeId,
            sessionID: sessionID,
            routesFileReferencesThroughSession: routesFileReferencesThroughSession,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            lineAnchor: lineAnchor,
            focusLineAnchor: false,
            readerPreferences: readerPreferences,
            perfSurface: perfSurface,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile,
            fetchHostFile: fetchHostFile,
            makeMarkdownVideoSource: makeMarkdownVideoSource,
            makeMarkdownAudioSource: makeMarkdownAudioSource,
            makeMarkdownUSDZFile: makeMarkdownUSDZFile,
            makeTimedTextSidecar: makeTimedTextSidecar,
            audioPlayer: audioPlayer
        )
        body.accessibilityIdentifier = accessibilityIdentifier
        body.translatesAutoresizingMaskIntoConstraints = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            scrollView.removeFromSuperview()
            addSubview(body)
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: leadingAnchor),
                body.trailingAnchor.constraint(equalTo: trailingAnchor),
                body.topAnchor.constraint(equalTo: topAnchor),
                body.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            layoutIfNeeded()
        }
        CATransaction.commit()

        immutableBody = body
        transitionCount += 1
        body.restoreViewportAfterMutableTransition(intent)

        // The immutable reader now owns presentation and source context. Tear
        // down mutable segment views and their async work instead of retaining
        // two full render trees behind the wrapper.
        markdownView.clearContent()
    }

    func currentViewportIntent() -> FullScreenMarkdownViewportIntent {
        .capturing(
            scrollView: scrollView,
            followsTail: viewportOwner.followsTail,
            visibleAnchor: captureVisibleContentAnchor()
        )
    }

    private func captureVisibleContentAnchor() -> FullScreenMarkdownViewportAnchor {
        layoutIfNeeded()
        let y = scrollView.contentOffset.y
        guard let stack = markdownStackView,
              let firstIndex = firstVisibleArrangedSubviewIndex(in: stack)
        else {
            return FullScreenMarkdownViewportAnchor(
                segmentID: nil,
                offsetInItem: 0,
                absoluteOffset: y
            )
        }
        let view = stack.arrangedSubviews[firstIndex]
        let frame = view.convert(view.bounds, to: scrollView)
        let ids = currentReaderSegmentIDs()
        return FullScreenMarkdownViewportAnchor(
            segmentID: ids.indices.contains(firstIndex) ? ids[firstIndex] : nil,
            offsetInItem: y - frame.minY,
            absoluteOffset: y
        )
    }

    private var markdownStackView: UIStackView? {
        markdownView.subviews.compactMap { $0 as? UIStackView }.first
    }

    private func firstVisibleArrangedSubviewIndex(in stack: UIStackView) -> Int? {
        let visibleRect = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        return stack.arrangedSubviews.firstIndex { view in
            view.convert(view.bounds, to: scrollView).intersects(visibleRect)
        }
    }

    private func currentReaderSegmentIDs() -> [MarkdownReaderSegmentID] {
        // Match applyMutableContent() so mixed relative-image paragraphs split
        // the same way as the live stack and the immutable reader.
        let sourceDirectory: String? = {
            guard let sourceFilePath else { return nil }
            let dir = (sourceFilePath as NSString).deletingLastPathComponent
            return dir.isEmpty || dir == "." ? nil : dir
        }()
        let build = FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(latestContent),
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            mergeAdjacentTextSegments: lineAnchor == nil
        )
        return build.identities
    }

    private func mutableOffsetY(for anchor: FullScreenMarkdownViewportAnchor) -> CGFloat? {
        guard let segmentID = anchor.segmentID,
              let stack = markdownStackView else { return nil }
        let ids = currentReaderSegmentIDs()
        let index = ids.firstIndex(of: segmentID)
            ?? ids.firstIndex {
                $0.kind == segmentID.kind && $0.sourceStartLine == segmentID.sourceStartLine
            }
        guard let index, stack.arrangedSubviews.indices.contains(index) else { return nil }
        let view = stack.arrangedSubviews[index]
        let frame = view.convert(view.bounds, to: scrollView)
        return frame.minY + anchor.offsetInItem
    }

    private var isViewportInteracting: Bool {
        isUIKitOwningViewport || viewportOwner.isInteracting
    }

    private var isUIKitOwningViewport: Bool {
        #if DEBUG
        if let debugViewportInteractionOverride { return debugViewportInteractionOverride }
        #endif
        let panState = scrollView.panGestureRecognizer.state
        return scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
            || panState == .began
            || panState == .changed
    }

    func restoreMutableViewport(_ intent: FullScreenMarkdownViewportIntent) {
        guard immutableBody == nil else { return }
        layoutIfNeeded()
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let targetY: CGFloat
        switch intent {
        case .top:
            targetY = minimumY
        case .tail:
            targetY = maximumY
        case .detached(let anchor):
            let rawY = mutableOffsetY(for: anchor) ?? anchor.absoluteOffset
            targetY = min(max(rawY, minimumY), maximumY)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetY),
            animated: false
        )
        CATransaction.commit()

        if intent == .tail {
            viewportOwner.streamStarted()
            viewportOwner.scheduleFollowTail()
        } else {
            viewportOwner.interactionBegan()
            viewportOwner.interactionEnded(isStreaming: isStreaming)
        }
    }

    private func finishInteractionIfPossible() {
        viewportOwner.interactionEnded(isStreaming: isStreaming)
        transitionToImmutableIfPossible()
    }

    @objc private func handlePanStateChange(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            viewportOwner.touchDown()
        case .ended, .cancelled, .failed:
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isUIKitOwningViewport else { return }
                self.finishInteractionIfPossible()
            }
        default:
            break
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        viewportOwner.touchDown()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishInteractionIfPossible() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishInteractionIfPossible()
    }
}

/// Plain-text fullscreen thinking surface. Thinking bypasses CommonMark and
/// receives the already-coalesced snapshots directly, sharing only the common
/// attached/detached viewport policy with other live surfaces.
final class NativeFullScreenThinkingBody: UIView,
    UITextViewDelegate,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout
{
    /// Above this size, mounting the complete live trace in TextKit makes every
    /// coalesced delta pay the layout cost of the entire document.
    private static let singleTextViewUTF8Limit = 128 * 1024
    private static let chunkUTF16Limit = 32 * 1024

    private struct Chunk {
        var text: String
        var lineUTF16Counts: [Int]
        var sourceStartLine: Int
        var lineBreakCount: Int

        var utf16Count: Int { (text as NSString).length }
    }

    private final class ChunkTextView: UITextView, ReviewCommentSourceLineRangeResolving {
        var sourceLineRangeResolver: ((NSRange) -> ClosedRange<Int>?)?

        func reviewCommentSourceLineRange(for range: NSRange) -> ClosedRange<Int>? {
            sourceLineRangeResolver?(range)
        }
    }

    private final class ChunkCell: UICollectionViewCell {
        static let reuseIdentifier = "FullScreenThinkingChunkCell"
        let textView = ChunkTextView(usingTextLayoutManager: true)

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.backgroundColor = .clear
            textView.isEditable = false
            textView.isSelectable = true
            textView.isScrollEnabled = false
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.lineBreakMode = .byWordWrapping
            contentView.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                textView.topAnchor.constraint(equalTo: contentView.topAnchor),
                textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func prepareForReuse() {
            super.prepareForReuse()
            textView.delegate = nil
            textView.text = nil
            textView.sourceLineRangeResolver = nil
        }
    }

    private let textView = UITextView(usingTextLayoutManager: true)
    private let chunkLayout = UICollectionViewFlowLayout()
    private lazy var chunkCollectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: chunkLayout
    )
    private let stream: ThinkingTraceStream?
    private let palette: ThemePalette
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private let onCompletion: ((NativeFullScreenThinkingBody, String, FullScreenMarkdownViewportIntent) -> Void)?
    private var readerPreferences: FullScreenReaderPreferences
    private struct PendingCompletion {
        let text: String
        let viewportIntent: FullScreenMarkdownViewportIntent
    }

    private var streamObserverID: UUID?
    private var isStreaming: Bool
    private var completionDelivered = false
    private var pendingCompletion: PendingCompletion?
    private var isApplyingSnapshot = false
    private var followPolicy: LiveStreamingPresentation.ViewportPolicy
    private var renderedText = ""
    private var chunks: [Chunk] = []
    private var isVirtualized = false
    private var lastMutatedUTF16Count = 0
    private var wholeTextReplacementCount = 0
    private var lastBatchReloadedItemCount = 0
    private var lastBatchInsertedItemCount = 0

    init(
        content: String,
        stream: ThinkingTraceStream?,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        onCompletion: ((NativeFullScreenThinkingBody, String, FullScreenMarkdownViewportIntent) -> Void)? = nil
    ) {
        let snapshot = stream?.snapshot
        let initialText = snapshot?.text ?? content
        let isStreaming = snapshot.map { !$0.isDone } ?? false
        self.stream = stream
        self.palette = palette
        self.readerPreferences = readerPreferences
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.onCompletion = onCompletion
        self.isStreaming = isStreaming
        self.followPolicy = LiveStreamingPresentation.ViewportPolicy(followsTail: isStreaming)
        super.init(frame: .zero)

        backgroundColor = UIColor(palette.bgDark)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.textColor = UIColor(palette.fg)
        textView.font = thinkingFont
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.delegate = self
        textView.panGestureRecognizer.addTarget(self, action: #selector(handlePanStateChange(_:)))

        chunkLayout.minimumLineSpacing = 0
        chunkLayout.minimumInteritemSpacing = 0
        chunkLayout.scrollDirection = .vertical
        chunkCollectionView.translatesAutoresizingMaskIntoConstraints = false
        chunkCollectionView.backgroundColor = .clear
        chunkCollectionView.alwaysBounceVertical = true
        chunkCollectionView.showsVerticalScrollIndicator = true
        chunkCollectionView.dataSource = self
        chunkCollectionView.delegate = self
        chunkCollectionView.isHidden = true
        chunkCollectionView.contentInset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        chunkCollectionView.panGestureRecognizer.addTarget(self, action: #selector(handlePanStateChange(_:)))
        chunkCollectionView.register(
            ChunkCell.self,
            forCellWithReuseIdentifier: ChunkCell.reuseIdentifier
        )

        addSubview(textView)
        addSubview(chunkCollectionView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            chunkCollectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chunkCollectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chunkCollectionView.topAnchor.constraint(equalTo: topAnchor),
            chunkCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render(initialText)

        if let stream {
            streamObserverID = stream.addObserver(deliverImmediately: false) { [weak self] snapshot in
                self?.apply(snapshot)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        guard let streamObserverID else { return }
        let stream = stream
        Task { @MainActor in
            stream?.removeObserver(streamObserverID)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        followTailIfNeeded()
    }

    private var thinkingFont: UIFont {
        FullScreenCodeTypography.scaledFont(AppFont.messageBody, scale: readerPreferences.textScale)
    }

    private func apply(_ snapshot: ThinkingTraceStream.Snapshot) {
        let previousText = renderedText
        let wasStreaming = isStreaming
        if snapshot.isDone, wasStreaming, pendingCompletion == nil {
            pendingCompletion = PendingCompletion(
                text: snapshot.text,
                viewportIntent: .capturing(
                    scrollView: activeScrollView,
                    followsTail: followPolicy.followsTail
                )
            )
        }

        isApplyingSnapshot = true
        isStreaming = !snapshot.isDone
        _ = followPolicy.applyStreamTick(
            isStreaming: isStreaming,
            shouldRerender: previousText != snapshot.text,
            wasVisible: true,
            previousText: previousText,
            currentText: snapshot.text
        )
        if previousText != snapshot.text {
            render(snapshot.text)
        }
        isApplyingSnapshot = false

        if wasStreaming != isStreaming || previousText != snapshot.text {
            setNeedsLayout()
            followTailIfNeeded()
        }
        deliverPendingCompletionIfPossible()
    }

    private func render(_ text: String) {
        let previous = renderedText
        let previousUTF16Count = (previous as NSString).length
        let isAppend = !previous.isEmpty
            && (text as NSString).length >= previousUTF16Count
            && text.hasPrefix(previous)

        if !isVirtualized, text.utf8.count <= Self.singleTextViewUTF8Limit {
            let selection = textView.selectedRange
            if isAppend {
                let appended = (text as NSString).substring(from: previousUTF16Count)
                textView.textStorage.replaceCharacters(
                    in: NSRange(location: textView.textStorage.length, length: 0),
                    with: appended
                )
                lastMutatedUTF16Count = (appended as NSString).length
            } else {
                textView.text = text
                wholeTextReplacementCount += previous.isEmpty ? 0 : 1
                lastMutatedUTF16Count = (text as NSString).length
            }
            renderedText = text
            restoreSelection(selection, in: textView)
            return
        }

        if !isVirtualized {
            enterVirtualizedMode(text)
        } else if isAppend {
            appendVirtualizedText(
                (text as NSString).substring(from: previousUTF16Count)
            )
        } else {
            rebuildVirtualizedText(text)
        }
        renderedText = text
    }

    private func enterVirtualizedMode(_ text: String) {
        isVirtualized = true
        chunks = Self.makeChunks(text)
        lastMutatedUTF16Count = chunks.map(\.utf16Count).max() ?? 0
        textView.text = nil
        textView.isHidden = true
        chunkCollectionView.isHidden = false
        chunkCollectionView.reloadData()
        chunkLayout.invalidateLayout()
    }

    private func rebuildVirtualizedText(_ text: String) {
        chunks = Self.makeChunks(text)
        lastMutatedUTF16Count = chunks.map(\.utf16Count).max() ?? 0
        wholeTextReplacementCount += 1
        chunkCollectionView.reloadData()
        chunkLayout.invalidateLayout()
    }

    private func appendVirtualizedText(_ suffix: String) {
        guard !suffix.isEmpty, let retainedChunk = chunks.last else { return }
        let oldCount = chunks.count
        let changedIndex = oldCount - 1
        let selection = (chunkCollectionView.cellForItem(
            at: IndexPath(item: changedIndex, section: 0)
        ) as? ChunkCell)?.textView.selectedRange
        let replacement = Self.makeChunks(
            retainedChunk.text + suffix,
            sourceStartLine: retainedChunk.sourceStartLine
        )
        let updatedChunks = Array(chunks.dropLast()) + replacement
        let inserted = max(0, updatedChunks.count - oldCount)
        let insertedPaths = (oldCount..<updatedChunks.count).map {
            IndexPath(item: $0, section: 0)
        }
        let changedPath = IndexPath(item: changedIndex, section: 0)

        lastMutatedUTF16Count = replacement.map(\.utf16Count).max() ?? 0
        lastBatchReloadedItemCount = 1
        lastBatchInsertedItemCount = inserted
        UIView.performWithoutAnimation {
            chunkCollectionView.performBatchUpdates { [self] in
                chunks = updatedChunks
                chunkCollectionView.reloadItems(at: [changedPath])
                if !insertedPaths.isEmpty {
                    chunkCollectionView.insertItems(at: insertedPaths)
                }
            } completion: { [weak self] _ in
                guard let self else { return }
                if let cell = self.chunkCollectionView.cellForItem(at: changedPath) as? ChunkCell {
                    self.configure(cell, at: changedIndex)
                    if let selection {
                        self.restoreSelection(selection, in: cell.textView)
                    }
                }
                self.chunkLayout.invalidateLayout()
                self.setNeedsLayout()
                self.followTailIfNeeded()
            }
        }
    }

    private static func makeChunks(
        _ text: String,
        sourceStartLine: Int = 1
    ) -> [Chunk] {
        let source = text as NSString
        guard source.length > 0 else {
            return [makeChunk("", sourceStartLine: sourceStartLine)]
        }
        var result: [Chunk] = []
        var location = 0
        var nextSourceLine = sourceStartLine
        while location < source.length {
            let proposedEnd = min(source.length, location + chunkUTF16Limit)
            var end = NSMaxRange(source.rangeOfComposedCharacterSequences(
                for: NSRange(location: location, length: proposedEnd - location)
            ))
            if end < source.length {
                let newline = source.range(
                    of: "\n",
                    options: .backwards,
                    range: NSRange(location: location, length: end - location)
                )
                if newline.location != NSNotFound, newline.location > location {
                    end = NSMaxRange(newline)
                }
            }
            end = max(location + 1, end)
            let chunk = makeChunk(
                source.substring(with: NSRange(location: location, length: end - location)),
                sourceStartLine: nextSourceLine
            )
            result.append(chunk)
            nextSourceLine += chunk.lineBreakCount
            location = end
        }
        return result
    }

    private static func makeChunk(_ text: String, sourceStartLine: Int) -> Chunk {
        let source = text as NSString
        var counts: [Int] = []
        var lineBreakCount = 0
        var start = 0
        while start < source.length {
            let line = source.lineRange(for: NSRange(location: start, length: 0))
            let lineText = source.substring(with: line)
            if lineText.hasSuffix("\n") { lineBreakCount += 1 }
            counts.append(max(0, line.length - (lineText.hasSuffix("\n") ? 1 : 0)))
            start = NSMaxRange(line)
        }
        if counts.isEmpty { counts.append(0) }
        return Chunk(
            text: text,
            lineUTF16Counts: counts,
            sourceStartLine: sourceStartLine,
            lineBreakCount: lineBreakCount
        )
    }

    private func restoreSelection(_ selection: NSRange, in textView: UITextView) {
        guard selection.location != NSNotFound else { return }
        let textLength = textView.textStorage.length
        let location = min(selection.location, textLength)
        let length = min(selection.length, max(0, textLength - location))
        textView.selectedRange = NSRange(location: location, length: length)
    }

    private var activeScrollView: UIScrollView {
        isVirtualized ? chunkCollectionView : textView
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        chunks.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ChunkCell.reuseIdentifier,
            for: indexPath
        ) as? ChunkCell else { return UICollectionViewCell() }
        configure(cell, at: indexPath.item)
        return cell
    }

    private func configure(_ cell: ChunkCell, at index: Int) {
        guard chunks.indices.contains(index) else { return }
        let chunk = chunks[index]
        let textView = cell.textView
        textView.delegate = self
        textView.font = thinkingFont
        textView.textColor = UIColor(palette.fg)
        textView.sourceLineRangeResolver = { [weak textView] range in
            guard let textView,
                  let local = ReviewCommentSelectionEditMenuSupport.textLineRange(
                      in: textView.textStorage.string,
                      range: range
                  ) else { return nil }
            return (chunk.sourceStartLine + local.lowerBound - 1)...(
                chunk.sourceStartLine + local.upperBound - 1
            )
        }
        textView.text = chunk.text
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = max(1, collectionView.bounds.width
            - collectionView.adjustedContentInset.left
            - collectionView.adjustedContentInset.right)
        guard chunks.indices.contains(indexPath.item) else {
            return CGSize(width: width, height: thinkingFont.lineHeight)
        }
        let glyphWidth = max(1, ("M" as NSString).size(withAttributes: [.font: thinkingFont]).width)
        let columns = max(1, Int(width / glyphWidth))
        let visualLines = chunks[indexPath.item].lineUTF16Counts.reduce(into: 0) { count, lineLength in
            count += max(1, (lineLength + columns - 1) / columns)
        }
        return CGSize(width: width, height: CGFloat(visualLines) * thinkingFont.lineHeight)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === activeScrollView,
              scrollView.isDragging || scrollView.isDecelerating else { return }
        beginInteraction()
    }

    private func followTailIfNeeded() {
        guard rejectUIKitOwnedInteractionIfNeeded(),
              followPolicy.handle(.requestFollowTail) == .followTail else { return }
        let scrollView = activeScrollView
        scrollView.layoutIfNeeded()
        guard rejectUIKitOwnedInteractionIfNeeded() else { return }
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: maximumY), animated: false)
    }

    var isViewportInteracting: Bool {
        isUIKitOwningViewport || followPolicy.isInteracting
    }

    private var isUIKitOwningViewport: Bool {
        let scrollView = activeScrollView
        let panState = scrollView.panGestureRecognizer.state
        let hasSelection = isVirtualized
            ? chunkCollectionView.visibleCells
                .compactMap { ($0 as? ChunkCell)?.textView }
                .contains { $0.selectedRange.length > 0 }
            : textView.selectedRange.length > 0
        return scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
            || panState == .began
            || panState == .changed
            || hasSelection
    }

    /// Transfers viewport ownership to UIKit before every automatic offset
    /// write, including layout-driven writes that race touch-down or selection.
    @discardableResult
    private func rejectUIKitOwnedInteractionIfNeeded() -> Bool {
        guard !isUIKitOwningViewport else {
            beginInteraction()
            return false
        }
        return true
    }

    private func beginInteraction() {
        _ = followPolicy.handle(.interactionBegan)
    }

    private func finishInteractionIfPossible() {
        guard !isUIKitOwningViewport else { return }
        if followPolicy.isInteracting {
            let scrollView = activeScrollView
            let distance = scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
                - scrollView.contentOffset.y
            let intent = followPolicy.handle(.interactionEnded(
                isNearBottom: distance <= 28,
                isStreaming: isStreaming
            ))
            if intent == .followTail { followTailIfNeeded() }
        }
        deliverPendingCompletionIfPossible()
    }

    private func deliverPendingCompletionIfPossible() {
        guard !completionDelivered,
              !isViewportInteracting,
              let pendingCompletion else { return }
        completionDelivered = true
        self.pendingCompletion = nil
        onCompletion?(self, pendingCompletion.text, pendingCompletion.viewportIntent)
    }

    @objc private func handlePanStateChange(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginInteraction()
        case .ended, .cancelled, .failed:
            DispatchQueue.main.async { [weak self] in
                self?.finishInteractionIfPossible()
            }
        default:
            break
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        beginInteraction()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishInteractionIfPossible() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishInteractionIfPossible()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isApplyingSnapshot else { return }
        if textView.selectedRange.length > 0 {
            beginInteraction()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.finishInteractionIfPossible()
            }
        }
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        // Copy and review-comment actions own the current selection. Detach
        // before presenting either action so live layout cannot move it.
        beginInteraction()
        return buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

extension NativeFullScreenThinkingBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        textView.font = thinkingFont
        textView.setNeedsLayout()
        for cell in chunkCollectionView.visibleCells.compactMap({ $0 as? ChunkCell }) {
            cell.textView.font = thinkingFont
        }
        chunkLayout.invalidateLayout()
        setNeedsLayout()
    }
}

#if DEBUG
extension NativeFullScreenThinkingBody {
    struct VirtualizationDiagnostics {
        let retainedSourceUTF16Count: Int
        let chunkCount: Int
        let mountedChunkCount: Int
        let mountedUTF16Count: Int
        let lastMutatedUTF16Count: Int
        let wholeTextReplacementCount: Int
        let lastBatchReloadedItemCount: Int
        let lastBatchInsertedItemCount: Int
    }

    var debugTextViewForTesting: UITextView { textView }
    var debugFollowsTailForTesting: Bool { followPolicy.followsTail }
    var debugActiveScrollViewForTesting: UIScrollView { activeScrollView }
    var debugVisibleChunkTextViewForTesting: UITextView? {
        chunkCollectionView.visibleCells.compactMap { ($0 as? ChunkCell)?.textView }.first
    }

    var debugVirtualizationDiagnosticsForTesting: VirtualizationDiagnostics? {
        guard isVirtualized else { return nil }
        let mounted = chunkCollectionView.visibleCells.compactMap { ($0 as? ChunkCell)?.textView }
        return VirtualizationDiagnostics(
            retainedSourceUTF16Count: (renderedText as NSString).length,
            chunkCount: chunks.count,
            mountedChunkCount: mounted.count,
            mountedUTF16Count: mounted.reduce(into: 0) { $0 += $1.textStorage.length },
            lastMutatedUTF16Count: lastMutatedUTF16Count,
            wholeTextReplacementCount: wholeTextReplacementCount,
            lastBatchReloadedItemCount: lastBatchReloadedItemCount,
            lastBatchInsertedItemCount: lastBatchInsertedItemCount
        )
    }
}
#endif

extension NativeMutableFullScreenMarkdownBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        if let immutableBody {
            immutableBody.applyReaderPreferences(preferences)
        } else {
            applyMutableContent()
        }
    }
}

#if DEBUG
extension NativeMutableFullScreenMarkdownBody {
    var debugIsShowingImmutableReaderForTesting: Bool { immutableBody != nil }
    var debugTransitionCountForTesting: Int { transitionCount }
    var debugMutableApplyCountForTesting: Int { mutableApplyCount }
    var debugMutableScrollViewForTesting: UIScrollView { scrollView }
    var debugMarkdownViewForTesting: AssistantMarkdownContentView { markdownView }

    func debugSetViewportInteractingForTesting(_ interacting: Bool?) {
        debugViewportInteractionOverride = interacting
        if interacting == true {
            viewportOwner.interactionBegan()
        } else if interacting == false {
            viewportOwner.interactionEnded(isStreaming: isStreaming)
            transitionToImmutableIfPossible()
        }
    }
}
#endif
