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
    private var serverBaseURL: URL?
    private var sourceFilePath: String?
    private let lineAnchor: SourceLineAnchor?
    private let perfSurface: MarkdownStreamingPerf.Surface?
    private var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    private var fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    private var fetchHostFile: ((_ path: String) async throws -> Data)?
    private var makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?
    private var makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider?
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
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile,
            fetchHostFile: fetchHostFile,
            makeMarkdownVideoSource: makeMarkdownVideoSource,
            makeMarkdownAudioSource: makeMarkdownAudioSource,
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
        serverBaseURL: URL?,
        sourceFilePath: String?,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?,
        fetchHostFile: ((_ path: String) async throws -> Data)? = nil,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?,
        makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider? = nil,
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
            || self.serverBaseURL != serverBaseURL
            || self.sourceFilePath != sourceFilePath

        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.worktreeId = worktreeId
        self.sessionID = sessionID
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.fetchHostFile = fetchHostFile
        self.makeMarkdownVideoSource = makeMarkdownVideoSource
        self.makeMarkdownAudioSource = makeMarkdownAudioSource
        self.makeTimedTextSidecar = makeTimedTextSidecar
        self.audioPlayer = audioPlayer
        markdownView.fetchWorkspaceFile = fetchWorkspaceFile
        markdownView.fetchSessionFile = fetchSessionFile
        markdownView.fetchHostFile = fetchHostFile
        markdownView.makeMarkdownVideoSource = makeMarkdownVideoSource
        markdownView.makeMarkdownAudioSource = makeMarkdownAudioSource
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
final class NativeFullScreenThinkingBody: UIView, UITextViewDelegate {
    private let textView = UITextView(usingTextLayoutManager: true)
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
        textView.text = initialText
        textView.panGestureRecognizer.addTarget(self, action: #selector(handlePanStateChange(_:)))
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

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
        let previousText = textView.text ?? ""
        let previousSelection = textView.selectedRange
        let wasStreaming = isStreaming
        if snapshot.isDone, wasStreaming, pendingCompletion == nil {
            pendingCompletion = PendingCompletion(
                text: snapshot.text,
                viewportIntent: .capturing(
                    scrollView: textView,
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
            textView.text = snapshot.text
            restoreSelection(previousSelection)
        }
        isApplyingSnapshot = false

        if wasStreaming != isStreaming || previousText != snapshot.text {
            setNeedsLayout()
            followTailIfNeeded()
        }
        deliverPendingCompletionIfPossible()
    }

    private func restoreSelection(_ selection: NSRange) {
        guard selection.location != NSNotFound else { return }
        let textLength = (textView.text as NSString?)?.length ?? 0
        let location = min(selection.location, textLength)
        let length = min(selection.length, max(0, textLength - location))
        textView.selectedRange = NSRange(location: location, length: length)
    }

    private func followTailIfNeeded() {
        guard rejectUIKitOwnedInteractionIfNeeded(),
              followPolicy.handle(.requestFollowTail) == .followTail else { return }
        textView.layoutIfNeeded()
        guard rejectUIKitOwnedInteractionIfNeeded() else { return }
        let minimumY = -textView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom
        )
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: maximumY), animated: false)
    }

    var isViewportInteracting: Bool {
        isUIKitOwningViewport || followPolicy.isInteracting
    }

    private var isUIKitOwningViewport: Bool {
        let panState = textView.panGestureRecognizer.state
        return textView.isTracking
            || textView.isDragging
            || textView.isDecelerating
            || panState == .began
            || panState == .changed
            || textView.selectedRange.length > 0
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
            let distance = textView.contentSize.height
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
                - textView.contentOffset.y
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
        setNeedsLayout()
    }
}

#if DEBUG
extension NativeFullScreenThinkingBody {
    var debugTextViewForTesting: UITextView { textView }
    var debugFollowsTailForTesting: Bool { followPolicy.followsTail }
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
