import UIKit

/// Viewport intent carried across the one-way mutable-to-immutable Markdown swap.
enum FullScreenMarkdownViewportIntent: Equatable {
    case top
    case tail
    case detached(progress: CGFloat)
}

/// Full-screen host for append-only Markdown while its source is still changing.
///
/// Parsing and segment reuse stay owned by `AssistantMarkdownContentView`; this
/// type owns only the outer viewport and the one-way handoff to the immutable,
/// render-ahead reader when the stream completes.
final class NativeMutableFullScreenMarkdownBody: UIView, UIScrollViewDelegate {
    /// Live Markdown is readable at this cadence without making TextKit and
    /// block renderers react to every token. Completion always bypasses it.
    private static let mutableApplyInterval: Duration = .milliseconds(75)

    private let scrollView = UIScrollView()
    private let markdownView = AssistantMarkdownContentView()

    private var stream: ThinkingTraceStream?
    private let themeID: ThemeID
    private let palette: ThemePalette
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var textSelectionEnabled: Bool
    private var serverID: String?
    private var workspaceID: String?
    private var sessionID: String?
    private var serverBaseURL: URL?
    private var sourceFilePath: String?
    private let lineAnchor: SourceLineAnchor?
    private let perfSurface: MarkdownStreamingPerf.Surface?
    private var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    private var fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?

    private var readerPreferences: FullScreenReaderPreferences
    private var latestContent: String
    private var isStreaming: Bool
    private var streamObserverID: UUID?
    private var immutableBody: NativeFullScreenMarkdownBody?
    private var pendingCompletionContent: String?
    private var pendingCompletionViewportIntent: FullScreenMarkdownViewportIntent?
    private var isTransitioningToImmutable = false
    private var transitionCount = 0
    private var pendingMutableApplyTask: Task<Void, Never>?
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
        stream: ThinkingTraceStream? = nil,
        isStreaming: Bool = true,
        themeID: ThemeID? = nil,
        palette: ThemePalette,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool = true,
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceFilePath: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.markdown.defaultPreferences,
        perfSurface: MarkdownStreamingPerf.Surface? = nil,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil
    ) {
        let initialSnapshot = stream?.snapshot
        self.stream = stream
        self.themeID = themeID ?? ThemeRuntimeState.currentThemeID()
        self.palette = palette
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.lineAnchor = lineAnchor
        self.readerPreferences = readerPreferences
        self.perfSurface = perfSurface
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.latestContent = initialSnapshot?.text ?? content
        self.isStreaming = initialSnapshot.map { !$0.isDone } ?? isStreaming
        super.init(frame: .zero)

        setupMutableViewport()
        applyMutableContent()
        _ = viewportOwner

        if let stream {
            streamObserverID = stream.addObserver(deliverImmediately: false) { [weak self] snapshot in
                self?.update(content: snapshot.text, isStreaming: !snapshot.isDone)
            }
        }

        if !self.isStreaming {
            transitionToImmutableIfPossible()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        pendingMutableApplyTask?.cancel()
        if let streamObserverID {
            let stream = stream
            Task { @MainActor in
                stream?.removeObserver(streamObserverID)
            }
        }
    }

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
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile
        )
    }

    func update(
        content: String,
        isStreaming: Bool,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceFilePath: String?,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    ) {
        guard immutableBody == nil else { return }
        let completionIntent = isStreaming ? nil : currentViewportIntent()
        let contentChanged = latestContent != content
        let streamingChanged = self.isStreaming != isStreaming
        let contextChanged = self.reviewCommentSelectionRouter !== reviewCommentSelectionRouter
            || self.reviewCommentSourceContext != reviewCommentSourceContext
            || self.serverID != serverID
            || self.workspaceID != workspaceID
            || self.sessionID != sessionID
            || self.serverBaseURL != serverBaseURL
            || self.sourceFilePath != sourceFilePath

        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        markdownView.fetchWorkspaceFile = fetchWorkspaceFile
        markdownView.fetchSessionFile = fetchSessionFile

        guard contentChanged || streamingChanged || contextChanged else {
            viewportOwner.scheduleFollowTail()
            return
        }

        latestContent = content
        self.isStreaming = isStreaming

        if isStreaming {
            pendingCompletionContent = nil
            pendingCompletionViewportIntent = nil
            scheduleMutableApply()
            // Ordinary append ticks must not re-arm following after the reader
            // has intentionally detached from the live tail.
            viewportOwner.scheduleFollowTail()
        } else {
            // Completion bypasses cadence so final bytes and context are never
            // stranded behind a scheduled live update.
            pendingMutableApplyTask?.cancel()
            pendingMutableApplyTask = nil
            applyMutableContent()
            pendingCompletionContent = content
            pendingCompletionViewportIntent = completionIntent
            viewportOwner.streamCompleted()
            transitionToImmutableIfPossible()
        }
    }

    private func scheduleMutableApply() {
        guard pendingMutableApplyTask == nil else { return }
        pendingMutableApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.mutableApplyInterval)
            guard let self, !Task.isCancelled else { return }
            self.pendingMutableApplyTask = nil
            guard self.isStreaming, self.immutableBody == nil else { return }
            self.applyMutableContent()
            self.viewportOwner.scheduleFollowTail()
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
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            lineAnchor: lineAnchor,
            focusLineAnchor: false,
            readerPreferences: readerPreferences,
            perfSurface: perfSurface,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile
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
        pendingMutableApplyTask?.cancel()
        pendingMutableApplyTask = nil
        markdownView.clearContent()
        if let streamObserverID {
            let completedStream = stream
            self.streamObserverID = nil
            // Completion can arrive while the stream is iterating observers.
            // Remove on the next actor turn rather than mutating that dictionary
            // from inside its delivery callback.
            Task { @MainActor in
                await Task.yield()
                completedStream?.removeObserver(streamObserverID)
            }
        }
        stream = nil
    }

    func currentViewportIntent() -> FullScreenMarkdownViewportIntent {
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let y = min(max(scrollView.contentOffset.y, minimumY), maximumY)
        if y - minimumY <= 28 {
            return .top
        }
        if viewportOwner.followsTail || maximumY - y <= 28 {
            return .tail
        }
        let span = maximumY - minimumY
        return .detached(progress: span > 0 ? (y - minimumY) / span : 0)
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
        case .detached(let progress):
            targetY = minimumY + (maximumY - minimumY) * min(max(progress, 0), 1)
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
    var debugHasPendingMutableApplyForTesting: Bool { pendingMutableApplyTask != nil }

    func debugFlushPendingMutableApplyForTesting() {
        pendingMutableApplyTask?.cancel()
        pendingMutableApplyTask = nil
        guard isStreaming, immutableBody == nil else { return }
        applyMutableContent()
        viewportOwner.scheduleFollowTail()
    }

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
