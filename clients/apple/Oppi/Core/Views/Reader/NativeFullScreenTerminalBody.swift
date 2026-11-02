import UIKit

private final class FullScreenTerminalChunkCell: UICollectionViewCell {
    static let reuseIdentifier = "FullScreenTerminalChunkCell"

    let textView = FullScreenReviewCommentTextView()
    #if DEBUG
    var installMilliseconds: [Double] = []
    var layoutMilliseconds: [Double] = []

    override func layoutSubviews() {
        let start = CACurrentMediaTime()
        super.layoutSubviews()
        layoutMilliseconds = [max(layoutMilliseconds.first ?? 0, (CACurrentMediaTime() - start) * 1_000)]
    }
    #endif

    func install(_ text: NSAttributedString?) {
        #if DEBUG
        let start = CACurrentMediaTime()
        #endif
        textView.attributedText = text
        #if DEBUG
        if text != nil {
            installMilliseconds = [max(installMilliseconds.first ?? 0, (CACurrentMediaTime() - start) * 1_000)]
        }
        #endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
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
        textView.attributedText = nil
        textView.text = nil
        textView.delegate = nil
        textView.reviewCommentSourceLineRangeResolver = nil
    }
}

private final class FullScreenTerminalVirtualizedLayout: UICollectionViewLayout {
    var itemSizes: [CGSize] = []

    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    private var cachedContentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        var y: CGFloat = 0
        var width = collectionView?.bounds.width ?? 0
        cachedAttributes = itemSizes.enumerated().map { index, size in
            let attrs = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attrs.frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height
            width = max(width, size.width)
            return attrs
        }
        cachedContentSize = CGSize(width: width, height: y)
    }

    override var collectionViewContentSize: CGSize { cachedContentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes.indices.contains(indexPath.item) ? cachedAttributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

final class NativeFullScreenTerminalBody: UIView, UIScrollViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate {
    // VT interpretation is required work, not a deferred color decoration.
    // Keep the synchronous budget small; larger histories build off-main.
    private static let maxSynchronousANSIBytes = 16 * 1024
    private static let maxEstimatedOutputWidth: CGFloat = 120_000
    private static let virtualizedChunkLineLimit = 160
    private static let virtualizedChunkVisualLineLimit = 64
    private static let virtualizedChunkByteLimit = 32 * 1024
    private static let attributedChunkCacheLimit = 14

    nonisolated private static func isMainThreadForDiagnostics() -> Bool {
        Thread.isMainThread
    }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let commandView = FullScreenReviewCommentTextView()
    private let outputView = FullScreenReviewCommentTextView()
    private let virtualizedLayout = FullScreenTerminalVirtualizedLayout()
    private lazy var virtualizedCollectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: virtualizedLayout
    )
    private let palette: ThemePalette
    private var usingCompletedSidecar = false
    private let streamNoticeLabel = UILabel()
    private let streamNoticeContainer = UIStackView()
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences

    /// What the body shows: the trace's text, or the sidecar's once loaded.
    private struct Frame: Equatable {
        let output: String
        let command: String?
        let isDone: Bool
    }

    private var latestSnapshot: Frame
    private var renderedSnapshot: Frame?
    private var renderedOutputText = ""
    private var renderedOutputAttributedBase: NSAttributedString?
    private var stackWidthConstraint: NSLayoutConstraint?
    private var virtualizedSource = ""
    private var virtualizedIndex: ANSIParser.TerminalChunkIndex?
    private var virtualizedCommand: NSAttributedString?
    // Identity of the mounted index, not the serialized replay in progress.
    // Starting a replay must not invalidate paints for the still-visible index.
    private var virtualizedGeneration = 0
    private var attributedChunkCache: [Int: NSAttributedString] = [:]
    private var attributedChunkLRU: [Int] = []
    private var chunkRenderTasks: [Int: Task<Void, Never>] = [:]
    private var lastVirtualizedLayoutSize: CGSize = .zero
    private var virtualizedWrapColumns: Int?
    private var virtualizedSizingWidth: CGFloat?
    #if DEBUG
    private var debugIndexRanOnMainThread: Bool?
    private var debugIndexMilliseconds: Double = 0
    #endif

    private lazy var standardTailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: scrollView,
        shouldAutoFollowTail: false,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    private var renderTask: Task<Void, Never>?
    private lazy var virtualizedTailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: virtualizedCollectionView,
        shouldAutoFollowTail: false,
        performLayout: { [weak self] in self?.layoutIfNeeded() }
    )

    private var activeTerminalScrollView: UIScrollView {
        virtualizedCollectionView.isHidden ? scrollView : virtualizedCollectionView
    }

    private var tailFollowCoordinator: TailFollowScrollCoordinator {
        virtualizedCollectionView.isHidden ? standardTailFollowCoordinator : virtualizedTailFollowCoordinator
    }

    private var sidecarSource: ToolOutputSidecarWindowSource?
    private var sidecarTerminalResolved = false
    private var sidecarTask: Task<Void, Never>?
    private var sidecarExpectsMore = false
    private var sidecarHasPendingAppend = false

    init(
        content: String,
        command: String?,
        isStreaming: Bool = false,
        palette: ThemePalette,
        outputWrapped: Bool? = nil,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.terminal.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        sidecarSource: ToolOutputSidecarWindowSource? = nil
    ) {
        self.palette = palette
        self.sidecarSource = sidecarSource
        var preferences = readerPreferences
        if let outputWrapped {
            preferences.wrapsText = outputWrapped
        }
        self.readerPreferences = preferences
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext

        let initialSnapshot = Frame(output: content, command: command, isDone: !isStreaming)
        latestSnapshot = initialSnapshot

        super.init(frame: .zero)
        setup()
        tailFollowCoordinator.shouldAutoFollowTail = !initialSnapshot.isDone
        render(snapshot: initialSnapshot)
        startSidecarLoadingIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        renderTask?.cancel()
        sidecarTask?.cancel()
        chunkRenderTasks.values.forEach { $0.cancel() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !virtualizedSource.isEmpty, virtualizedWrapColumns != wrappedChunkColumns {
            enterVirtualizedMode(source: virtualizedSource)
        }
        updateWrappingLayout()
        if virtualizedCollectionView.bounds.size != lastVirtualizedLayoutSize {
            lastVirtualizedLayoutSize = virtualizedCollectionView.bounds.size
            virtualizedLayout.invalidateLayout()
        }
        tailFollowCoordinator.onLayoutPass()
    }

    private func setup() {
        backgroundColor = palette.ui.bgDark

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.delegate = self

        virtualizedCollectionView.translatesAutoresizingMaskIntoConstraints = false
        virtualizedCollectionView.backgroundColor = palette.ui.bgDark
        virtualizedCollectionView.alwaysBounceVertical = true
        virtualizedCollectionView.showsVerticalScrollIndicator = true
        virtualizedCollectionView.dataSource = self
        virtualizedCollectionView.delegate = self
        virtualizedCollectionView.isHidden = true
        virtualizedCollectionView.register(
            FullScreenTerminalChunkCell.self,
            forCellWithReuseIdentifier: FullScreenTerminalChunkCell.reuseIdentifier
        )

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill

        commandView.translatesAutoresizingMaskIntoConstraints = false
        commandView.isEditable = false
        commandView.isSelectable = true
        commandView.isScrollEnabled = false
        commandView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        commandView.textContainer.lineFragmentPadding = 0
        commandView.backgroundColor = palette.ui.bgHighlight
        commandView.layer.cornerRadius = 8
        commandView.delegate = self
        commandView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )

        outputView.translatesAutoresizingMaskIntoConstraints = false
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isScrollEnabled = false
        outputView.backgroundColor = .clear
        outputView.textContainerInset = UIEdgeInsets(top: 4, left: 6, bottom: 14, right: 6)
        outputView.textContainer.lineFragmentPadding = 0
        outputView.font = codeFont
        outputView.textColor = palette.ui.fg
        outputView.delegate = self
        outputView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        applyOutputWrapMode()

        addSubview(scrollView)
        addSubview(virtualizedCollectionView)
        scrollView.addSubview(stack)

        streamNoticeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        streamNoticeLabel.textColor = palette.ui.comment
        streamNoticeLabel.numberOfLines = 0
        streamNoticeLabel.isHidden = true
        streamNoticeLabel.accessibilityIdentifier = "terminal-output-status"
        streamNoticeContainer.translatesAutoresizingMaskIntoConstraints = false
        streamNoticeContainer.axis = .vertical
        streamNoticeContainer.isLayoutMarginsRelativeArrangement = true
        streamNoticeContainer.layoutMargins = .zero
        streamNoticeContainer.addArrangedSubview(streamNoticeLabel)
        addSubview(streamNoticeContainer)
        stack.addArrangedSubview(commandView)
        stack.addArrangedSubview(outputView)

        let stackWidth = stack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -20
        )
        stackWidthConstraint = stackWidth

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: streamNoticeContainer.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            virtualizedCollectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            virtualizedCollectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            virtualizedCollectionView.topAnchor.constraint(equalTo: streamNoticeContainer.bottomAnchor),
            virtualizedCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            streamNoticeContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            streamNoticeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            streamNoticeContainer.topAnchor.constraint(equalTo: topAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackWidth,
        ])
    }

    private func setStreamNotice(_ notice: String?) {
        streamNoticeLabel.text = notice
        streamNoticeLabel.isHidden = notice == nil
        streamNoticeContainer.layoutMargins = notice == nil ? .zero : UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        setNeedsLayout()
    }

    /// Shows the running call's next output.
    func apply(_ snapshot: TerminalSnapshot) {
        latestSnapshot = Frame(output: snapshot.output, command: snapshot.command, isDone: snapshot.isDone)
        render(snapshot: latestSnapshot)
    }

    private func render(snapshot: Frame) {
        guard snapshot != renderedSnapshot else {
            tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            return
        }

        renderedSnapshot = snapshot

        if let command = snapshot.command,
           !command.isEmpty {
            commandView.isHidden = false
            let attributedCommand = ToolRowTextRenderer.bashCommandHighlighted(command)
            virtualizedCommand = attributedCommand
            commandView.attributedText = attributedCommand
        } else {
            commandView.isHidden = true
            virtualizedCommand = nil
            commandView.attributedText = nil
            commandView.text = nil
        }

        renderTerminalOutput(snapshot.output, isStreaming: !snapshot.isDone)
        tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
    }

    private func renderTerminalOutput(_ content: String, isStreaming: Bool) {
        if !sidecarExpectsMore, content.utf8.count <= Self.maxSynchronousANSIBytes {
            renderTask?.cancel()
            renderTask = nil
            sidecarHasPendingAppend = false
            leaveVirtualizedMode()
            let resolved: String
            do {
                resolved = sidecarTerminalResolved ? content : try TerminalLogEngine.render(content)
            } catch {
                resolved = "Terminal rendering failed: \(error)"
            }
            // ANSIParser is now only the native SGR-to-theme painter. It never
            // interprets raw terminal bytes; Ghostty has resolved cursor/screen
            // state before text is handed to TextKit.
            let attributedOutput = ANSIParser.attributedString(from: resolved, baseForeground: .themeFg)
            renderedOutputAttributedBase = attributedOutput
            outputView.attributedText = attributedOutput
            applyOutputFont()
            renderedOutputText = outputView.attributedText?.string ?? ""
            updateWrappingLayout()
            return
        }
        // Streaming must also interpret cursor instructions. Large snapshots
        // use the same detached engine/index path, not a stripped-text tier.
        enterVirtualizedMode(source: content)
    }

    var immediateCopyText: String? {
        guard sidecarSource == nil, renderTask == nil, virtualizedSource.isEmpty else { return nil }
        return renderedOutputText
    }

    /// Clipboard output shares the painted terminal semantics. Materialize a
    /// complete sidecar before interpretation; never independently strip windows.
    func resolvedCopyText() async -> String? {
        let heldSource = virtualizedSource.isEmpty ? latestSnapshot.output : virtualizedSource
        var source = heldSource
        if let sidecarSource {
            do {
                if sidecarSource.loadRawRange != nil {
                    if let resolved = try await Self.loadRawTerminalHistory(sidecarSource) {
                        return ANSIParser.strip(resolved)
                    }
                    return renderedOutputText.isEmpty ? ANSIParser.strip(heldSource) : renderedOutputText
                }
                if let first = try await sidecarSource.loadFirst() {
                    var complete = first.text
                    var offset = first.endByteOffset
                    while offset < first.totalBytes {
                        try Task.checkCancellation()
                        guard let next = try await sidecarSource.loadNext(offset),
                              next.endByteOffset > offset, next.totalBytes == first.totalBytes else { break }
                        complete += next.text
                        offset = next.endByteOffset
                    }
                    if offset == first.totalBytes, complete.utf8.count == first.totalBytes {
                        source = complete
                    }
                }
            } catch {
                // A stopped session may have lost its sidecar; copy the held
                // resolved preview, not an unresolved or half-fetched mixture.
            }
        }
        guard !Task.isCancelled else { return nil }
        let sameSource = source.utf8.elementsEqual(heldSource.utf8)
        if sameSource, virtualizedSource.isEmpty, virtualizedCollectionView.isHidden, renderTask == nil {
            return renderedOutputText
        }
        let chunks = sameSource && renderTask == nil ? virtualizedIndex?.chunks : nil
        let capturedSource = source
        return await withCancellableDetachedTask(priority: .userInitiated) { () -> String? in
            if let chunks {
                return chunks.map { ANSIParser.strip($0.rawText) }.joined()
            }
            return try? TerminalLogEngine.plainText(capturedSource)
        }
    }

    /// Content-Range is the byte authority, not a decoded String's UTF-8 size.
    /// Hold the readable preview until the complete raw log has been interpreted
    /// once, then use the existing resolved-text/virtualized presentation path.
    private static func loadRawTerminalHistory(_ source: ToolOutputSidecarWindowSource) async throws -> String? {
        guard let fetch = source.loadRawRange else { return nil }
        var bytes = Data()
        var offset = 0
        var total: Int?
        repeat {
            try Task.checkCancellation()
            let upper = min(total ?? ToolOutputSidecarHTTP.firstWindowBytes,
                offset + ToolOutputSidecarHTTP.firstWindowBytes)
            guard let page = try await fetch(offset..<upper) else { return nil }
            guard let length = page.totalBytes, length >= 0,
                  total == nil || total == length,
                  page.start == offset, page.end <= length,
                  page.data.count == page.end - offset,
                  page.end > offset || length == 0 else { throw APIError.invalidResponse }
            bytes.append(page.data)
            offset = page.end
            total = length
        } while offset < (total ?? 0)
        let completeBytes = bytes
        let result = await withCancellableDetachedTask(priority: .userInitiated) { () -> Result<String, Error>? in
            do {
                let engine = try TerminalLogEngine()
                try engine.feed(completeBytes)
                return .success(try engine.paint())
            } catch { return .failure(error) }
        }
        guard let result else { throw CancellationError() }
        return try result.get()
    }

    private func startSidecarLoadingIfNeeded() {
        guard let sidecarSource else { return }
        sidecarTask?.cancel()
        sidecarTask = Task { [weak self] in
            do {
                if sidecarSource.loadRawRange != nil {
                    let resolved = try await Self.loadRawTerminalHistory(sidecarSource)
                    guard let self, !Task.isCancelled else { return }
                    guard let resolved else {
                        self.setStreamNotice("Terminal history unavailable")
                        return
                    }
                    self.usingCompletedSidecar = true
                    self.sidecarTerminalResolved = true
                    self.sidecarExpectsMore = false
                    self.setStreamNotice(nil)
                    self.renderedSnapshot = nil
                    self.latestSnapshot = .init(output: resolved, command: self.latestSnapshot.command, isDone: true)
                    self.render(snapshot: self.latestSnapshot)
                    return
                }
                let first = try await sidecarSource.loadFirst()
                guard !Task.isCancelled else { return }
                var offset = 0
                var total = 0
                if let first {
                    let applied = await MainActor.run { () -> Bool in
                        guard let self, !Task.isCancelled else { return false }
                        self.applyFirstSidecarWindow(first)
                        return true
                    }
                    if !applied { return }
                    offset = first.endByteOffset
                    total = first.totalBytes
                } else {
                    guard !Task.isCancelled else { return }
                    self?.setStreamNotice("Terminal history unavailable")
                    return
                }
                while offset < total {
                    guard let next = try await sidecarSource.loadNext(offset),
                          !next.text.isEmpty else { break }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self?.appendOutputWindow(next.text)
                    }
                    offset = next.endByteOffset
                    total = next.totalBytes
                    if next.isComplete { break }
                }
                await MainActor.run {
                    self?.sidecarExpectsMore = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.sidecarExpectsMore = false
                    self?.setStreamNotice("Terminal history unavailable")
                }
            }
        }
    }

    private func applyFirstSidecarWindow(_ window: ToolOutputSidecarWindow) {
        usingCompletedSidecar = true
        setStreamNotice(nil)
        sidecarExpectsMore = !window.isComplete
        sidecarHasPendingAppend = false
        latestSnapshot = Frame(
            output: window.text,
            command: latestSnapshot.command,
            isDone: true
        )
        // The first window may equal the preview, but its new completeness
        // requires the one-terminal window path even when the bytes match.
        renderedSnapshot = nil
        render(snapshot: latestSnapshot)
    }

    func appendOutputWindow(_ text: String) {
        guard !text.isEmpty else { return }
        if virtualizedCollectionView.isHidden, !sidecarExpectsMore {
            let combined = (virtualizedSource.isEmpty ? latestSnapshot.output : virtualizedSource) + text
            latestSnapshot = Frame(
                output: combined,
                command: latestSnapshot.command,
                isDone: true
            )
            render(snapshot: latestSnapshot)
            return
        }
        virtualizedSource += text
        if renderTask != nil {
            sidecarHasPendingAppend = true
            return
        }
        if virtualizedIndex == nil {
            enterVirtualizedMode(source: virtualizedSource)
            return
        }
        appendVirtualizedWindow()
    }

    private func appendVirtualizedWindow() {
        // A later window can move the cursor and overwrite a preceding chunk.
        // Interpret the ordered source as one terminal before rebuilding the
        // presentation index. Never parse raw windows as independent terminals.
        enterVirtualizedMode(source: virtualizedSource)
    }

    private func flushSidecarPendingAppend() {
        guard sidecarHasPendingAppend else { return }
        sidecarHasPendingAppend = false
        appendVirtualizedWindow()
    }

    private var wrappedChunkColumns: Int? {
        guard readerPreferences.wrapsText else { return nil }
        let glyphWidth = max(1, ("M" as NSString).size(withAttributes: [.font: codeFont]).width)
        return max(1, Int((bounds.width - 32) / glyphWidth))
    }

    private func enterVirtualizedMode(source: String) {
        virtualizedSource = source
        if renderTask != nil {
            sidecarHasPendingAppend = true
            return
        }
        let generation = virtualizedGeneration
        let terminalResolved = sidecarTerminalResolved
        let chunkLineLimit = Self.virtualizedChunkLineLimit
        let chunkByteLimit = Self.virtualizedChunkByteLimit
        let visualLineLimit = Self.virtualizedChunkVisualLineLimit
        let wrappedColumns = wrappedChunkColumns
        virtualizedWrapColumns = wrappedColumns
        // Keep the mounted reader while one replay runs. Later snapshots
        // coalesce to the latest source instead of cancelling useful work.
        guard wrappedColumns == nil || bounds.width > 32 else { return }

        renderTask = Task { [weak self] in
            guard let build = await withCancellableDetachedTask(
                priority: .userInitiated,
                operation: { () -> (ANSIParser.TerminalChunkIndex, Bool, Double)? in
                    let ranOnMainThread = Self.isMainThreadForDiagnostics()
                    let start = CACurrentMediaTime()
                    let resolved: String
                    do {
                        resolved = terminalResolved ? source : try TerminalLogEngine.render(source)
                    } catch {
                        resolved = "Terminal rendering failed: \(error)"
                    }
                    guard !Task.isCancelled else { return nil }
                    let index = ANSIParser.TerminalChunkIndex.build(
                        from: resolved,
                        maxLines: chunkLineLimit,
                        maxBytes: chunkByteLimit,
                        wrappedColumns: wrappedColumns,
                        maxVisualLines: visualLineLimit
                    )
                    return (index, ranOnMainThread, (CACurrentMediaTime() - start) * 1_000)
                }
            ), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled, generation == self.virtualizedGeneration else { return }
                if self.sidecarHasPendingAppend, self.virtualizedIndex != nil {
                    // Preserve the reader/cache while a newer source is queued.
                    // An initial index is still allowed through, so continuous
                    // input cannot starve the first paint.
                    self.renderTask = nil
                    self.flushSidecarPendingAppend()
                    return
                }
                let activeScrollView = self.virtualizedCollectionView.isHidden
                    ? self.scrollView : self.virtualizedCollectionView
                let previousOffset = activeScrollView.contentOffset
                let followTail = self.tailFollowCoordinator.shouldAutoFollowTail
                self.virtualizedGeneration += 1
                self.chunkRenderTasks.values.forEach { $0.cancel() }
                self.chunkRenderTasks.removeAll()
                self.attributedChunkCache.removeAll()
                self.attributedChunkLRU.removeAll()
                self.virtualizedIndex = build.0
                self.renderedOutputAttributedBase = nil
                self.renderedOutputText = ""
                self.outputView.attributedText = nil
                self.scrollView.isHidden = true
                self.virtualizedCollectionView.isHidden = false
                self.virtualizedTailFollowCoordinator.shouldAutoFollowTail = followTail
                #if DEBUG
                self.debugIndexRanOnMainThread = build.1
                self.debugIndexMilliseconds = build.2
                #endif
                self.virtualizedSizingWidth = nil
                self.virtualizedCollectionView.reloadData()
                self.refreshVirtualizedItemSizes()
                // A drag during replay still owns the reader at commit time.
                let totalHeight = self.virtualizedLayout.itemSizes.reduce(CGFloat.zero) { $0 + $1.height }
                let maxY = max(0, totalHeight - self.virtualizedCollectionView.bounds.height)
                self.virtualizedCollectionView.setContentOffset(
                    CGPoint(x: previousOffset.x, y: followTail ? maxY : min(maxY, max(0, previousOffset.y))),
                    animated: false
                )
                self.prepareVisibleChunkRunway()
                self.renderTask = nil
                self.flushSidecarPendingAppend()
            }
        }
    }

    private func leaveVirtualizedMode() {
        // Invalidate even before the first index appears: a hidden collection
        // can still have an abandoned replay waiting to commit.
        virtualizedGeneration += 1
        virtualizedSource = ""
        guard !virtualizedCollectionView.isHidden else { return }
        standardTailFollowCoordinator.shouldAutoFollowTail = tailFollowCoordinator.shouldAutoFollowTail
        chunkRenderTasks.values.forEach { $0.cancel() }
        chunkRenderTasks.removeAll()
        attributedChunkCache.removeAll()
        attributedChunkLRU.removeAll()
        virtualizedIndex = nil
        virtualizedSource = ""
        virtualizedCollectionView.isHidden = true
        scrollView.isHidden = false
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
    }

    private func applyOutputWrapMode() {
        let wraps = readerPreferences.wrapsText
        outputView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        scrollView.alwaysBounceHorizontal = !wraps
        scrollView.showsHorizontalScrollIndicator = !wraps
        virtualizedCollectionView.alwaysBounceHorizontal = !wraps
        virtualizedCollectionView.showsHorizontalScrollIndicator = !wraps
        if wraps {
            scrollView.contentOffset.x = -scrollView.adjustedContentInset.left
            virtualizedCollectionView.contentOffset.x = -virtualizedCollectionView.adjustedContentInset.left
        }
        for cell in virtualizedCollectionView.visibleCells.compactMap({ $0 as? FullScreenTerminalChunkCell }) {
            cell.textView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        }
        virtualizedLayout.invalidateLayout()
        updateWrappingLayout()
    }

    private func applyOutputFont() {
        outputView.font = codeFont
        guard let attributedText = renderedOutputAttributedBase ?? outputView.attributedText,
              attributedText.length > 0 else { return }
        outputView.attributedText = fullScreenAttributedCodeText(
            from: attributedText,
            font: codeFont
        )
    }

    private func updateWrappingLayout() {
        if !virtualizedCollectionView.isHidden {
            refreshVirtualizedItemSizes()
            return
        }
        let viewportWidth = max(1, scrollView.bounds.width)
        let minimumWidth = max(0, viewportWidth - 20)
        let targetWidth = readerPreferences.wrapsText
            ? minimumWidth
            : max(minimumWidth, estimatedUnwrappedOutputWidth())
        stackWidthConstraint?.constant = targetWidth - viewportWidth
    }

    private func estimatedUnwrappedOutputWidth() -> CGFloat {
        let outputColumns = virtualizedIndex?.widestLineColumnCount
            ?? Self.widestLineColumnCount(in: renderedOutputText)
        let commandColumns = Self.widestLineColumnCount(
            in: virtualizedCommand?.string ?? ""
        )
        let columns = max(outputColumns, commandColumns)
        let sampleWidth = ("M" as NSString).size(
            withAttributes: [.font: codeFont]
        ).width
        let textWidth = CGFloat(columns) * max(1, sampleWidth)
        let insetWidth = outputView.textContainerInset.left + outputView.textContainerInset.right + 12
        return min(Self.maxEstimatedOutputWidth, ceil(textWidth + insetWidth))
    }

    private func refreshVirtualizedItemSizes() {
        guard virtualizedSizingWidth != virtualizedCollectionView.bounds.width else { return }
        virtualizedSizingWidth = virtualizedCollectionView.bounds.width
        let count = virtualizedCommandItemCount + (virtualizedIndex?.chunks.count ?? 0)
        virtualizedLayout.itemSizes = (0..<count).map { sizeForVirtualizedItem(at: $0) }
        virtualizedLayout.invalidateLayout()
    }

    private static func widestLineColumnCount(in text: String) -> Int {
        var widest = 0
        var current = 0
        for character in text {
            if character == "\n" {
                widest = max(widest, current)
                current = 0
            } else if character == "\t" {
                current += 4
            } else {
                current += 1
            }
        }
        return max(widest, current)
    }

    #if DEBUG
    struct VirtualizationDiagnostics {
        let retainedSourceUTF8Count: Int
        let chunkCount: Int
        let cachedChunkCount: Int
        let mountedChunkCount: Int
        let mountedUTF16Count: Int
        let collectionContentWidth: CGFloat
        let collectionBoundsWidth: CGFloat
        let indexRanOnMainThread: Bool?
        let indexMilliseconds: Double
        let installMilliseconds: [Double]
        let layoutMilliseconds: [Double]
        let mountedVisualLines: [Int]
    }

    func virtualizationDiagnosticsForTesting() -> VirtualizationDiagnostics? {
        guard let virtualizedIndex else { return nil }
        let cells = virtualizedCollectionView.visibleCells.compactMap { $0 as? FullScreenTerminalChunkCell }
        return VirtualizationDiagnostics(
            retainedSourceUTF8Count: virtualizedSource.utf8.count,
            chunkCount: virtualizedIndex.chunks.count,
            cachedChunkCount: attributedChunkCache.count,
            mountedChunkCount: cells.count,
            mountedUTF16Count: cells.reduce(into: 0) { $0 += $1.textView.textStorage.length },
            collectionContentWidth: virtualizedCollectionView.contentSize.width,
            collectionBoundsWidth: virtualizedCollectionView.bounds.width,
            indexRanOnMainThread: debugIndexRanOnMainThread,
            indexMilliseconds: debugIndexMilliseconds,
            installMilliseconds: cells.flatMap(\.installMilliseconds),
            layoutMilliseconds: cells.flatMap(\.layoutMilliseconds),
            mountedVisualLines: cells.map { Int(ceil(($0.bounds.height - 4) / codeFont.lineHeight)) }
        )
    }

    #endif

    private var virtualizedCommandItemCount: Int { virtualizedCommand == nil ? 0 : 1 }

    private func chunkIndex(for item: Int) -> Int? {
        let index = item - virtualizedCommandItemCount
        guard let virtualizedIndex, virtualizedIndex.chunks.indices.contains(index) else { return nil }
        return index
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        virtualizedCommandItemCount + (virtualizedIndex?.chunks.count ?? 0)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FullScreenTerminalChunkCell.reuseIdentifier,
            for: indexPath
        ) as? FullScreenTerminalChunkCell else {
            return UICollectionViewCell()
        }
        let textView = cell.textView
        textView.delegate = self
        textView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        textView.textContainer.lineBreakMode = readerPreferences.wrapsText ? .byCharWrapping : .byClipping

        if virtualizedCommandItemCount == 1, indexPath.item == 0 {
            textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            textView.backgroundColor = palette.ui.bgHighlight
            textView.layer.cornerRadius = 8
            textView.reviewCommentSourceLineRangeResolver = nil
            textView.attributedText = virtualizedCommand
        } else if let chunkIndex = chunkIndex(for: indexPath.item) {
            textView.textContainerInset = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
            textView.backgroundColor = .clear
            textView.layer.cornerRadius = 0
            let startLine = virtualizedIndex?.chunks[chunkIndex].displayedStartLine ?? 1
            textView.reviewCommentSourceLineRangeResolver = { [weak textView] range in
                guard let textView,
                      let local = ReviewCommentSelectionEditMenuSupport.textLineRange(
                        in: textView.textStorage.string,
                        range: range
                      ) else { return nil }
                return (startLine + local.lowerBound - 1)...(startLine + local.upperBound - 1)
            }
            if attributedChunkCache[chunkIndex] == nil, let chunk = virtualizedIndex?.chunks[chunkIndex] {
                // A visible bounded chunk must not mount blank while async
                // runway formatting catches up after a drag or index swap.
                let attributed = fullScreenAttributedCodeText(
                    from: ANSIParser.attributedString(from: chunk.leadingSGR + chunk.rawText, baseForeground: .themeFg),
                    font: codeFont
                )
                cacheAttributedChunk(attributed, at: chunkIndex)
            }
            cell.install(attributedChunkCache[chunkIndex])
        }
        return cell
    }

    private func sizeForVirtualizedItem(at item: Int) -> CGSize {
        let viewportWidth = max(1, virtualizedCollectionView.bounds.width - 20)
        let width = readerPreferences.wrapsText
            ? viewportWidth
            : max(viewportWidth, estimatedUnwrappedOutputWidth())
        if virtualizedCommandItemCount == 1, item == 0 {
            let command = virtualizedCommand?.string ?? ""
            let visualLines: Int
            if readerPreferences.wrapsText {
                let glyphWidth = max(1, ("M" as NSString).size(withAttributes: [.font: codeFont]).width)
                let columns = max(1, Int((viewportWidth - 24) / glyphWidth))
                visualLines = command.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, line in
                    count += max(1, (line.count + columns - 1) / columns)
                }
            } else {
                visualLines = max(1, command.split(separator: "\n", omittingEmptySubsequences: false).count)
            }
            return CGSize(width: width, height: CGFloat(max(1, visualLines)) * codeFont.lineHeight + 20)
        }
        guard let chunkIndex = chunkIndex(for: item),
              let chunk = virtualizedIndex?.chunks[chunkIndex] else {
            return CGSize(width: width, height: codeFont.lineHeight + 4)
        }
        let visualLines: Int
        if readerPreferences.wrapsText {
            let glyphWidth = max(1, ("M" as NSString).size(withAttributes: [.font: codeFont]).width)
            let columns = max(1, Int((viewportWidth - 12) / glyphWidth))
            visualLines = chunk.lineColumnCounts.reduce(into: 0) { count, lineColumns in
                count += max(1, (lineColumns + columns - 1) / columns)
            }
        } else {
            visualLines = max(1, chunk.lineColumnCounts.count)
        }
        return CGSize(width: width, height: CGFloat(visualLines) * codeFont.lineHeight + 4)
    }

    private func prepareVisibleChunkRunway() {
        let visible = virtualizedCollectionView.indexPathsForVisibleItems.compactMap {
            chunkIndex(for: $0.item)
        }
        guard let first = visible.min(), let last = visible.max(), let index = virtualizedIndex,
              !index.chunks.isEmpty else { return }
        for chunkIndex in max(0, first - 2)...min(index.chunks.count - 1, last + 2) {
            scheduleChunkRender(chunkIndex)
        }
    }

    private func scheduleChunkRender(_ chunkIndex: Int) {
        guard attributedChunkCache[chunkIndex] == nil,
              chunkRenderTasks[chunkIndex] == nil,
              let index = virtualizedIndex,
              index.chunks.indices.contains(chunkIndex) else { return }
        let chunk = index.chunks[chunkIndex]
        let input = chunk.leadingSGR + chunk.rawText
        let generation = virtualizedGeneration
        chunkRenderTasks[chunkIndex] = Task { [weak self] in
            guard let wrapper = await withCancellableDetachedTask(
                priority: .userInitiated,
                operation: {
                    SendableNSAttributedString(
                        ANSIParser.attributedString(from: input, baseForeground: .themeFg)
                    )
                }
            ), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.virtualizedGeneration else { return }
                self.chunkRenderTasks[chunkIndex] = nil
                let attributed = fullScreenAttributedCodeText(from: wrapper.value, font: self.codeFont)
                self.cacheAttributedChunk(attributed, at: chunkIndex)
                let item = chunkIndex + self.virtualizedCommandItemCount
                if let cell = self.virtualizedCollectionView.cellForItem(
                    at: IndexPath(item: item, section: 0)
                ) as? FullScreenTerminalChunkCell {
                    cell.install(attributed)
                }
            }
        }
    }

    private func cacheAttributedChunk(_ attributed: NSAttributedString, at index: Int) {
        attributedChunkCache[index] = attributed
        attributedChunkLRU.removeAll { $0 == index }
        attributedChunkLRU.append(index)
        let visible = Set(virtualizedCollectionView.indexPathsForVisibleItems.compactMap {
            chunkIndex(for: $0.item)
        })
        while attributedChunkCache.count > Self.attributedChunkCacheLimit,
              let candidate = attributedChunkLRU.first(where: { !visible.contains($0) }) {
            attributedChunkCache[candidate] = nil
            attributedChunkLRU.removeAll { $0 == candidate }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === activeTerminalScrollView else { return }
        tailFollowCoordinator.handleWillBeginDragging()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === activeTerminalScrollView else { return }
        if scrollView === virtualizedCollectionView { prepareVisibleChunkRunway() }
        tailFollowCoordinator.handleDidScroll(
            isUserDriven: scrollView.isDragging || scrollView.isDecelerating,
            isStreaming: !latestSnapshot.isDone
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === activeTerminalScrollView else { return }
        tailFollowCoordinator.handleDidEndDragging(
            willDecelerate: decelerate,
            isStreaming: !latestSnapshot.isDone
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === activeTerminalScrollView else { return }
        tailFollowCoordinator.handleDidEndDecelerating(isStreaming: !latestSnapshot.isDone)
    }
}

extension NativeFullScreenTerminalBody: ReaderBody {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        let textSizeChanged = preferences.textScale != readerPreferences.textScale
        readerPreferences = preferences
        if !virtualizedCollectionView.isHidden,
           textSizeChanged || virtualizedWrapColumns != wrappedChunkColumns {
            enterVirtualizedMode(source: virtualizedSource)
        }
        if textSizeChanged {
            applyOutputFont()
        }
        applyOutputWrapMode()
        setNeedsLayout()
    }
}

extension NativeFullScreenTerminalBody: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}
