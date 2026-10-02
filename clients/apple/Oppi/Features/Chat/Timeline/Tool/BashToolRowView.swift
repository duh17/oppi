import SwiftUI
import UIKit

// MARK: - BashRenderInput

struct BashRenderInput {
    let command: String?
    let output: String?
    let unwrapped: Bool
    let isError: Bool
    let isStreaming: Bool
    let sessionId: String?
    let resourcePressure: StreamingRenderPolicy.ResourcePressure
    let terminalResolved: Bool

    init(
        command: String?,
        output: String?,
        unwrapped: Bool,
        isError: Bool,
        isStreaming: Bool,
        sessionId: String? = nil,
        resourcePressure: StreamingRenderPolicy.ResourcePressure = .nominal,
        terminalResolved: Bool = false
    ) {
        self.command = command
        self.output = output
        self.unwrapped = unwrapped
        self.isError = isError
        self.isStreaming = isStreaming
        self.sessionId = sessionId
        self.resourcePressure = resourcePressure
        self.terminalResolved = terminalResolved
    }
}

// MARK: - BashRenderResult

struct BashRenderResult {
    let showCommand: Bool
    let showOutput: Bool
}

// MARK: - BashToolRowView

/// Self-contained bash tool row rendering view.
///
/// Owns the command label and output scroll view used for bash tool calls.
/// The parent hands it a `BashRenderInput` value type and gets back a
/// `BashRenderResult` with visibility flags. No inout params; all render
/// state is internal.
///
/// UIView subviews (`commandContainer`, `outputContainer`, `commandLabel`,
/// `outputScrollView`, `outputLabel`) are exposed as `let` so the parent can
/// attach gestures, context menu interactions, and selected-text delegates.
@MainActor
final class BashToolRowView: UIView, UIScrollViewDelegate {

    // MARK: - Surfaces

    let commandContainer = UIView()
    let outputContainer = UIView()
    let commandLabel = UITextView()
    let outputScrollView = HorizontalPanPassthroughScrollView()
    let outputLabel = UITextView()

    // MARK: - State (read by parent for viewport/layout management)

    private(set) var outputUsesViewport = false

    private(set) var outputRenderedText: String? {
        didSet {
            outputWidthEstimateCache.invalidate()
            outputViewportHeightCache.invalidate()
        }
    }

    private(set) var outputRenderSignature: Int?
    private(set) var outputUsesUnwrappedLayout = false
    var outputShouldAutoFollow = true

    // MARK: - Layout constraints (read by parent)

    private(set) var outputViewportHeightConstraint: NSLayoutConstraint?
    private(set) var outputLabelWidthConstraint: NSLayoutConstraint?
    private(set) var outputLabelHeightLockConstraint: NSLayoutConstraint?

    // MARK: - Caches (accessed by parent viewport height resolution)

    var outputWidthEstimateCache = ToolTimelineRowWidthEstimateCache()
    var outputViewportHeightCache = ToolTimelineRowViewportHeightCache()

    // MARK: - Private render state

    private var commandRenderSignature: Int?
    private var commandShowsHighlight = false
    private var pendingFollowTail = false
    private var ownsTerminalOutput = false
    private var perfSessionId: String?
    /// Latest owned paint withheld while the reader is detached.
    private var frozenLiveOutput: (input: BashRenderInput, outputColor: UIColor)?
    /// The painted text is a live tail of an owned stream.
    private var outputShowsLiveTail = false

    /// A live inline row lays out its whole UITextView on every paint. The
    /// owner's 2000-line ring made that O(ring) TextKit work at paint cadence,
    /// which starved the main thread on fast streams. The inline row shows a
    /// bounded tail; the full-screen reader keeps the ring.
    nonisolated static let liveTailLineLimit = 200
    nonisolated static let liveTailByteLimit = 64 * 1024

    // MARK: - Deferred terminal rendering

    /// Large terminal snapshots are interpreted and painted off-main. Small
    /// streaming previews retain one engine and feed only the appended bytes.
    static let deferredANSIByteThreshold = 4 * 1024

    private var deferredANSITask: Task<Void, Never>?
    private var deferredANSISignature: Int?
    private var deferredCommandTask: Task<Void, Never>?
    private var deferredCommandSignature: Int?

    #if DEBUG
    nonisolated(unsafe) static var deferredANSIDelayForTesting: Duration?
    nonisolated(unsafe) static var deferredCommandHighlightDelayForTesting: Duration?
    private(set) var debugCommandHighlightWorkCountForTesting = 0
    #endif

    // Own incremental VT state only for small synchronous previews. Large jobs
    // create an independent engine so cancellation/reuse cannot reorder writes.
    private var terminalEngine: TerminalLogEngine?

    // MARK: - Internal layout

    private let internalStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        outputScrollView.layoutIfNeeded()
        // A deferred paint dirties this view, not necessarily its parent row.
        // Settle TextKit here so the final paint can follow without another delta.
        flushDeferredScrollToBottom()
    }

    // MARK: - Apply

    /// Refresh persistent UIKit chrome before rendering or revealing the row.
    /// The view can be reused across a live system appearance change.
    func applyTheme(_ palette: ThemePalette) {
        commandContainer.backgroundColor = UIColor(palette.bgHighlight)
        commandContainer.layer.borderColor = UIColor(palette.blue.opacity(0.35)).cgColor
        // Do not assign UITextView.textColor here. That property paints the
        // entire attributed string, wiping shell/ANSI colors. Command and
        // output signatures already include the active theme, so `apply`
        // re-highlights when the palette actually changes.

        outputContainer.backgroundColor = UIColor(palette.bgDark)
        outputContainer.layer.borderColor = UIColor(palette.comment.opacity(0.2)).cgColor
    }

    /// Render bash content.
    ///
    /// Returns which surfaces should be visible. The parent is responsible
    /// for showing/hiding `commandContainer` and `outputContainer` (via
    /// `ToolTimelineRowDisplayState.applyContainerVisibility`), then calling
    /// `flushFollowTail()` once both are visible with valid bounds.
    func apply(
        input: BashRenderInput,
        outputColor: UIColor,
        wasOutputVisible: Bool
    ) -> BashRenderResult {
        perfSessionId = input.sessionId
        ownsTerminalOutput = input.terminalResolved
        outputScrollView.allowsVerticalPan = input.terminalResolved
        var showCommand = false
        var showOutput = false

        // MARK: Command

        if let command = input.command, !command.isEmpty {
            let displayCmd = ToolTimelineRowRenderMetrics.displayCommandText(command)
            let signature = ToolTimelineRowRenderMetrics.commandSignature(displayCommand: displayCmd)
            applyCommandHighlight(
                displayCmd: displayCmd,
                signature: signature,
                pressure: input.resourcePressure,
                sessionId: input.sessionId
            )
            showCommand = true
        } else {
            cancelDeferredCommandHighlight()
            commandRenderSignature = nil
            commandShowsHighlight = false
        }

        // MARK: Output

        // While a finger or deceleration owns the viewport, or the reader has
        // left the tail, keep a painted live tail still, through completion
        // too. Content must not move under the reader; paints are skipped,
        // not laid out, and the newest one lands when they settle at the tail.
        let freezeLiveOutput = input.terminalResolved && outputShowsLiveTail && !outputShouldAutoFollow
        if freezeLiveOutput {
            frozenLiveOutput = (input, outputColor)
        } else {
            frozenLiveOutput = nil
        }

        if let output = input.output, !output.isEmpty {
            let displayOutput = input.terminalResolved && input.isStreaming
                ? String(Self.liveTail(of: output))
                : ToolTimelineRowRenderMetrics.displayOutputText(output)
            let signature = ToolTimelineRowRenderMetrics.outputSignature(
                displayOutput: displayOutput,
                isError: input.isError,
                unwrapped: input.unwrapped,
                isStreaming: input.isStreaming
            ) ^ (input.terminalResolved ? 0x5354524D : 0)

            if signature != outputRenderSignature, !freezeLiveOutput {
                let startNs = ChatTimelinePerf.timestampNs()
                let didTextChange: Bool
                let previousText = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                if let cached = ToolRowRenderCache.get(signature: signature) {
                    cancelDeferredANSIHighlight()
                    outputLabel.attributedText = cached
                    outputShowsLiveTail = input.terminalResolved && input.isStreaming
                    didTextChange = previousText != cached.string
                } else if displayOutput.utf8.count > Self.deferredANSIByteThreshold {
                    terminalEngine = nil
                    // Never display a raw stripped preview: cursor instructions
                    // are required state, including while streaming.
                    if previousText.isEmpty {
                        outputLabel.text = "Rendering terminal output…"
                        outputLabel.textColor = outputColor
                    }
                    didTextChange = false
                    scheduleDeferredANSIHighlight(
                        text: displayOutput,
                        isError: input.isError,
                        signature: signature,
                        outputColor: outputColor,
                        unwrapped: input.unwrapped,
                        sessionId: input.sessionId,
                        terminalResolved: input.terminalResolved,
                        source: input
                    )
                } else {
                    cancelDeferredANSIHighlight()
                    do {
                        let resolved: String
                        if input.terminalResolved {
                            terminalEngine = nil
                            resolved = displayOutput
                        } else {
                            let engine = try terminalEngine ?? TerminalLogEngine()
                            terminalEngine = engine
                            resolved = try engine.update(displayOutput)
                        }
                        let attributed = ToolRowTextRenderer.ansiHighlighted(
                            resolved, baseForeground: input.isError ? .themeRed : .themeFg
                        )
                        ToolRowRenderCache.set(signature: signature, attributed: attributed)
                        outputLabel.attributedText = attributed
                        outputShowsLiveTail = input.terminalResolved && input.isStreaming
                        didTextChange = previousText != attributed.string
                    } catch {
                        outputLabel.text = "Terminal rendering failed: \(error)"
                        outputLabel.textColor = outputColor
                        terminalEngine = nil
                        didTextChange = true
                    }
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: deferredANSISignature == signature ? "bash.output.deferred" : "bash.output.terminal",
                    durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
                    inputBytes: displayOutput.utf8.count,
                    sessionId: input.sessionId
                )

                outputRenderSignature = signature
                outputRenderedText = input.unwrapped
                    ? (outputLabel.attributedText?.string ?? outputLabel.text)
                    : nil

                if didTextChange {
                    schedulePendingFollowTail()
                }
            }

            if input.unwrapped {
                outputLabel.textContainer.lineBreakMode = .byClipping
                // Horizontal scrolling is only meaningful once streaming finishes
                // and the content width stabilises. During streaming the viewport
                // auto-follows vertically; enabling horizontal scroll at the same
                // time causes gesture conflicts and meaningless scroll offsets.
                outputScrollView.alwaysBounceHorizontal = !input.isStreaming
                outputScrollView.showsHorizontalScrollIndicator = !input.isStreaming
                outputUsesUnwrappedLayout = true
            } else {
                outputLabel.textContainer.lineBreakMode = .byCharWrapping
                outputScrollView.alwaysBounceHorizontal = false
                outputScrollView.showsHorizontalScrollIndicator = false
                outputUsesUnwrappedLayout = false
                outputRenderedText = nil
            }

            // Apply error background tint (terminal style: dark bg + red wash).
            applyOutputBackground(isError: input.isError)

            outputViewportHeightConstraint?.isActive = true
            outputUsesViewport = true
            showOutput = true

            if !wasOutputVisible {
                outputShouldAutoFollow = true
            }
        } else {
            outputRenderSignature = nil
        }

        return BashRenderResult(showCommand: showCommand, showOutput: showOutput)
    }

    // MARK: - Terminal-style error background (step 5)

    private func applyOutputBackground(isError: Bool) {
        if isError {
            outputContainer.backgroundColor = UIColor(Color.themeRed.opacity(0.10))
            outputContainer.layer.borderColor = UIColor(Color.themeRed.opacity(0.35)).cgColor
        } else {
            outputContainer.backgroundColor = UIColor(Color.themeBgDark)
            outputContainer.layer.borderColor = UIColor(Color.themeComment.opacity(0.2)).cgColor
        }
    }

    // MARK: - Reset

    /// Reset output render state. Called when output container is hidden.
    func resetOutputState(outputColor: UIColor) {
        cancelDeferredANSIHighlight()
        outputLabel.attributedText = nil
        outputLabel.text = nil
        outputLabel.textColor = outputColor
        outputLabel.textContainer.lineBreakMode = .byCharWrapping
        outputScrollView.alwaysBounceHorizontal = false
        outputScrollView.showsHorizontalScrollIndicator = false
        outputUsesUnwrappedLayout = false
        outputRenderedText = nil
        outputRenderSignature = nil
        outputViewportHeightConstraint?.isActive = false
        outputUsesViewport = false
        ownsTerminalOutput = false
        frozenLiveOutput = nil
        outputShowsLiveTail = false
        outputScrollView.allowsVerticalPan = false
        terminalEngine = nil
        ToolTimelineRowUIHelpers.resetScrollPosition(outputScrollView)
        // After the scroll reset: its didScroll measures the old content.
        outputShouldAutoFollow = true
    }

    /// Reset command render state. Called when command container is hidden.
    /// Output work has its own lifetime, including tools with no command header.
    func resetCommandState() {
        cancelDeferredCommandHighlight()
        commandLabel.attributedText = nil
        commandLabel.text = nil
        commandLabel.textColor = UIColor(Color.themeFg)
        commandRenderSignature = nil
        commandShowsHighlight = false
    }

    // MARK: - Command syntax highlight

    private struct DeferredCommandResult: @unchecked Sendable {
        let attributed: NSAttributedString
    }

    private func applyCommandHighlight(
        displayCmd: String,
        signature: Int,
        pressure: StreamingRenderPolicy.ResourcePressure,
        sessionId: String?
    ) {
        if let cached = ToolRowRenderCache.get(signature: signature) {
            if commandLabel.attributedText !== cached {
                commandLabel.attributedText = cached
            }
            cancelDeferredCommandHighlight()
            commandRenderSignature = signature
            commandShowsHighlight = true
            return
        }

        if signature == commandRenderSignature, commandShowsHighlight {
            return
        }

        let profile = StreamingRenderPolicy.ContentProfile.from(text: displayCmd)
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: .known),
            byteCount: profile.byteCount,
            lineCount: profile.lineCount,
            maxLineByteCount: profile.maxLineByteCount,
            pressure: pressure,
            consumer: .explicit
        )

        let startNs = ChatTimelinePerf.timestampNs()
        switch tier {
        case .cheap:
            cancelDeferredCommandHighlight()
            applyPlainCommand(displayCmd)
            commandShowsHighlight = false

        case .deferred:
            applyPlainCommand(displayCmd)
            commandShowsHighlight = false
            scheduleDeferredCommandHighlight(
                text: displayCmd,
                signature: signature,
                sessionId: sessionId
            )

        case .full:
            cancelDeferredCommandHighlight()
            #if DEBUG
            debugCommandHighlightWorkCountForTesting += 1
            #endif
            let highlighted = ToolRowTextRenderer.bashCommandHighlighted(displayCmd)
            ToolRowRenderCache.set(signature: signature, attributed: highlighted)
            commandLabel.attributedText = highlighted
            commandShowsHighlight = true
        }

        ChatTimelinePerf.recordRenderStrategy(
            mode: tier == .deferred ? "bash.command.deferred" : "bash.command",
            durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
            inputBytes: displayCmd.utf8.count,
            sessionId: sessionId
        )
        commandRenderSignature = signature
    }

    private func applyPlainCommand(_ text: String) {
        commandLabel.attributedText = nil
        commandLabel.text = text
        commandLabel.textColor = UIColor(Color.themeFg)
    }

    private func cancelDeferredCommandHighlight() {
        deferredCommandTask?.cancel()
        deferredCommandTask = nil
        deferredCommandSignature = nil
    }

    private func scheduleDeferredCommandHighlight(
        text: String,
        signature: Int,
        sessionId: String?
    ) {
        if deferredCommandSignature == signature,
           let task = deferredCommandTask,
           !task.isCancelled {
            return
        }

        cancelDeferredCommandHighlight()
        deferredCommandSignature = signature
        let themeID = ThemeRuntimeState.currentThemeID()

        deferredCommandTask = Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            if let artificialDelay = BashToolRowView.deferredCommandHighlightDelayForTesting {
                try? await Task.sleep(for: artificialDelay)
            }
            #endif
            guard !Task.isCancelled else { return }

            let renderStart = ContinuousClock.now
            let highlighted = ToolRowTextRenderer.bashCommandHighlighted(text, themeID: themeID)
            let result = DeferredCommandResult(attributed: highlighted)
            let durationMs = Int((ContinuousClock.now - renderStart) / .milliseconds(1))

            await MainActor.run { [weak self] in
                guard let self,
                      self.deferredCommandSignature == signature else {
                    return
                }

                defer {
                    self.deferredCommandTask = nil
                    self.deferredCommandSignature = nil
                }

                guard self.commandRenderSignature == signature else { return }

                #if DEBUG
                self.debugCommandHighlightWorkCountForTesting += 1
                #endif
                ToolRowRenderCache.set(signature: signature, attributed: result.attributed)
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "bash.command.deferred.highlight",
                    durationMs: durationMs,
                    inputBytes: text.utf8.count,
                    sessionId: sessionId
                )
                self.commandLabel.attributedText = result.attributed
                self.commandShowsHighlight = true
            }
        }
    }

    // MARK: - Deferred ANSI Highlight

    /// Wrapper to send NSAttributedString across isolation boundaries.
    private struct DeferredANSIResult: @unchecked Sendable {
        let attributed: NSAttributedString
    }

    private func cancelDeferredANSIHighlight() {
        deferredANSITask?.cancel()
        deferredANSITask = nil
        deferredANSISignature = nil
        pendingDeferredANSIRequest = nil
    }

    private struct DeferredANSIRequest {
        let text: String
        let isError: Bool
        let signature: Int
        let outputColor: UIColor
        let unwrapped: Bool
        let sessionId: String?
        let themeID: ThemeID
        let terminalResolved: Bool
        /// The render input that scheduled this job, withheld if the reader
        /// detaches from a painted live tail before the job lands.
        let source: BashRenderInput?
    }

    private var pendingDeferredANSIRequest: DeferredANSIRequest?

    private func scheduleDeferredANSIHighlight(
        text: String, isError: Bool, signature: Int, outputColor: UIColor,
        unwrapped: Bool, sessionId: String?, terminalResolved: Bool = false, source: BashRenderInput? = nil
    ) {
        let request = DeferredANSIRequest(text: text, isError: isError,
            signature: signature, outputColor: outputColor, unwrapped: unwrapped,
            sessionId: sessionId, themeID: ThemeRuntimeState.currentThemeID(), terminalResolved: terminalResolved,
            source: source)
        if deferredANSITask != nil {
            // Keep one useful worker and only the latest cumulative snapshot.
            if deferredANSISignature != signature { pendingDeferredANSIRequest = request }
            return
        }
        deferredANSISignature = signature
        deferredANSITask = Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            if let artificialDelay = BashToolRowView.deferredANSIDelayForTesting {
                try? await Task.sleep(for: artificialDelay)
            }
            #endif
            let renderStart = ContinuousClock.now
            guard !Task.isCancelled else { return }
            let attributed: NSAttributedString
            let succeeded: Bool
            do {
                let resolved = terminalResolved ? text : try TerminalLogEngine.render(text)
                attributed = ToolRowTextRenderer.ansiHighlighted(
                    resolved, baseForeground: isError ? .themeRed : .themeFg
                )
                succeeded = true
            } catch is CancellationError {
                return
            } catch {
                attributed = NSAttributedString(string: "Terminal rendering failed: \(error)")
                succeeded = false
            }
            let result = DeferredANSIResult(attributed: attributed)
            let durationMs = Int((ContinuousClock.now - renderStart) / .milliseconds(1))
            await MainActor.run { [weak self] in
                guard let self, self.deferredANSISignature == signature else { return }
                let pending = self.pendingDeferredANSIRequest
                self.pendingDeferredANSIRequest = nil
                self.deferredANSITask = nil
                self.deferredANSISignature = nil
                let isLatest = self.outputRenderSignature == signature
                // A replacement tail/new tool must not paint the old result.
                let isEarlierAppend = pending.map {
                    $0.text.utf8.starts(with: text.utf8) && $0.isError == isError
                        && $0.themeID == request.themeID
                } ?? false
                if succeeded && isLatest && request.themeID == ThemeRuntimeState.currentThemeID() {
                    ToolRowRenderCache.set(signature: signature, attributed: result.attributed)
                }
                if request.themeID == ThemeRuntimeState.currentThemeID(),
                   isLatest || (succeeded && isEarlierAppend),
                   self.ownsTerminalOutput, self.outputShowsLiveTail, !self.outputShouldAutoFollow {
                    // The reader detached from a painted live tail while this
                    // job ran. Same rule as apply: keep the tail still and land
                    // the newest input when they settle back at the tail.
                    if self.frozenLiveOutput == nil, let source = request.source {
                        self.frozenLiveOutput = (source, request.outputColor)
                    }
                    if isLatest { self.outputRenderSignature = nil }
                } else if request.themeID == ThemeRuntimeState.currentThemeID(),
                   isLatest || (succeeded && isEarlierAppend) {
                    self.outputLabel.attributedText = result.attributed
                    self.outputShowsLiveTail = request.source.map { $0.terminalResolved && $0.isStreaming } ?? false
                    self.terminalEngine = nil
                    self.outputRenderedText = self.outputUsesUnwrappedLayout ? result.attributed.string : nil
                    self.updateOutputLabelWidthIfNeeded()
                    self.schedulePendingFollowTail()
                    self.flushFollowTail()
                    self.setNeedsLayout()
                    if !succeeded && isLatest { self.outputRenderSignature = nil }
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "bash.output.deferred.highlight", durationMs: durationMs,
                    inputBytes: text.utf8.count, sessionId: sessionId
                )
                if let pending {
                    self.scheduleDeferredANSIHighlight(text: pending.text, isError: pending.isError,
                        signature: pending.signature, outputColor: pending.outputColor,
                        unwrapped: pending.unwrapped, sessionId: pending.sessionId, terminalResolved: pending.terminalResolved,
                        source: pending.source)
                }
            }
        }
    }

    // MARK: - Vertical Lock

    func setOutputVerticalLockEnabled(_ enabled: Bool) {
        // A live owned ring needs its full vertical extent to follow/browse
        // the tail. The legacy horizontal-only preview keeps its height lock.
        outputLabelHeightLockConstraint?.isActive = enabled && !ownsTerminalOutput
    }

    // MARK: - Width Update

    func updateOutputLabelWidthIfNeeded() {
        guard let outputLabelWidthConstraint else { return }
        if outputUsesUnwrappedLayout, let outputRenderedText {
            outputLabelWidthConstraint.priority = .required
            outputLabelWidthConstraint.constant = outputLabelWidthConstant(for: outputRenderedText)
        } else {
            outputLabelWidthConstraint.priority = .defaultHigh
            outputLabelWidthConstraint.constant = -12
        }
    }

    // MARK: - Follow Tail

    /// Defer follow-tail to the next layout pass.
    ///
    /// Instead of forcing synchronous `layoutIfNeeded()` during apply(),
    /// invalidate and let `layoutSubviews()` handle the scroll-to-bottom.
    func flushFollowTail() {
        guard pendingFollowTail, !outputContainer.isHidden else { return }
        outputLabel.invalidateIntrinsicContentSize()
        outputScrollView.setNeedsLayout()
        outputPendingScrollToBottom = true
        pendingFollowTail = false
    }

    /// Whether a deferred scroll-to-bottom is pending for output.
    private var outputPendingScrollToBottom = false

    /// Called from parent's `layoutSubviews()` to flush any deferred scroll.
    func flushDeferredScrollToBottom() {
        guard outputPendingScrollToBottom else { return }
        outputPendingScrollToBottom = false
        guard !ownsTerminalOutput || (!outputScrollView.isDragging && !outputScrollView.isDecelerating) else { return }
        ToolTimelineRowUIHelpers.followTail(in: outputScrollView, contentLabel: outputLabel)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === outputScrollView, ownsTerminalOutput else { return }
        outputShouldAutoFollow = false
        pendingFollowTail = false
        outputPendingScrollToBottom = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === outputScrollView else { return }
        // Reflow/programmatic tail following must not detach the live clock.
        if ownsTerminalOutput {
            if !scrollView.isDragging, !scrollView.isDecelerating { return }
            // A finger/deceleration owns the viewport even inside the tail
            // threshold. Only gesture-end callbacks may re-arm following.
            outputShouldAutoFollow = false
            return
        }
        if outputLabelHeightLockConstraint?.isActive == true {
            let lockedY = -outputScrollView.adjustedContentInset.top
            if abs(outputScrollView.contentOffset.y - lockedY) > 0.5 {
                outputScrollView.contentOffset.y = lockedY
            }
        }
        outputShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(outputScrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === outputScrollView, ownsTerminalOutput, !decelerate else { return }
        settleLiveFollow()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === outputScrollView, ownsTerminalOutput else { return }
        settleLiveFollow()
    }

    /// Returning to the tail re-arms following and paints the newest withheld
    /// snapshot now, so a quiet stream does not wait for its next byte.
    private func settleLiveFollow() {
        outputShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(outputScrollView)
        guard outputShouldAutoFollow, let frozen = frozenLiveOutput else { return }
        _ = apply(input: frozen.input, outputColor: frozen.outputColor, wasOutputVisible: true)
        flushFollowTail()
    }

    /// Last `liveTailLineLimit` lines, further bounded to `liveTailByteLimit`.
    /// Cuts land on line starts; the live engine formats each committed line
    /// with its own SGR state, so a cut never inherits a dangling style.
    nonisolated static func liveTail(of text: String) -> Substring {
        let utf8 = text.utf8
        var index = utf8.endIndex
        var bytes = 0 // byte count of text[index...]
        // A trailing newline terminates the last line; it does not start one.
        if index > utf8.startIndex, utf8[utf8.index(before: index)] == 0x0A {
            index = utf8.index(before: index)
            bytes = 1
        }
        var start: String.Index?
        var lines = 0
        while index > utf8.startIndex {
            let previous = utf8.index(before: index)
            if utf8[previous] == 0x0A {
                // `index` starts a line. Always keep the last line, even when
                // it alone exceeds the byte budget.
                if start != nil, bytes > liveTailByteLimit { break }
                start = index
                lines += 1
                if lines == liveTailLineLimit { break }
            }
            index = previous
            bytes += 1
        }
        guard let start, index > utf8.startIndex || bytes > liveTailByteLimit else {
            return text[...]
        }
        return text[start...]
    }

    // MARK: - Private Helpers

    private func schedulePendingFollowTail() {
        guard outputShouldAutoFollow else { return }
        pendingFollowTail = true
    }

    private func outputLabelWidthConstant(for renderedText: String) -> CGFloat {
        ToolTimelineRowLayoutPerformance.monospaceWidthConstant(
            frameWidth: max(1, outputScrollView.bounds.width),
            renderedText: renderedText,
            cache: &outputWidthEstimateCache,
            metricMode: "output",
            sessionId: perfSessionId
        )
    }

    // MARK: - Setup

    private func configureTerminalTextView(_ tv: UITextView) {
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.font = ToolFont.regular
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byCharWrapping
        tv.backgroundColor = .clear
    }

    private func setupViews() {
        // MARK: Command container — terminal prompt style

        commandContainer.translatesAutoresizingMaskIntoConstraints = false
        commandContainer.layer.cornerRadius = 6
        commandContainer.backgroundColor = UIColor(Color.themeBgHighlight)
        commandContainer.layer.borderWidth = 1
        commandContainer.layer.borderColor = UIColor(Color.themeBlue.opacity(0.35)).cgColor
        commandContainer.isHidden = true

        configureTerminalTextView(commandLabel)
        commandLabel.textColor = UIColor(Color.themeFg)

        // MARK: Output container — dark terminal pane

        outputContainer.translatesAutoresizingMaskIntoConstraints = false
        outputContainer.layer.cornerRadius = 6
        outputContainer.layer.masksToBounds = true
        outputContainer.backgroundColor = UIColor(Color.themeBgDark)
        outputContainer.layer.borderWidth = 1
        outputContainer.layer.borderColor = UIColor(Color.themeComment.opacity(0.2)).cgColor
        outputContainer.isHidden = true

        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.alwaysBounceVertical = false
        outputScrollView.alwaysBounceHorizontal = false
        outputScrollView.bounces = false
        outputScrollView.isDirectionalLockEnabled = true
        outputScrollView.isScrollEnabled = false
        outputScrollView.showsVerticalScrollIndicator = true
        outputScrollView.showsHorizontalScrollIndicator = false
        outputScrollView.delegate = self

        configureTerminalTextView(outputLabel)
        outputLabel.textColor = UIColor(Color.themeFg)

        // MARK: Hierarchy

        commandContainer.addSubview(commandLabel)
        outputContainer.addSubview(outputScrollView)
        outputScrollView.addSubview(outputLabel)
        internalStack.addArrangedSubview(commandContainer)
        internalStack.addArrangedSubview(outputContainer)
        addSubview(internalStack)

        // MARK: Constraints

        let outputLabelWidth = outputLabel.widthAnchor.constraint(
            equalTo: outputScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        let outputLabelHeightLock = outputLabel.heightAnchor.constraint(
            equalTo: outputScrollView.frameLayoutGuide.heightAnchor,
            constant: -10
        )
        let outputViewportHeight = outputContainer.heightAnchor.constraint(
            equalToConstant: ToolTimelineRowContentView.minOutputViewportHeight
        )

        NSLayoutConstraint.activate([
            internalStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            internalStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            internalStack.topAnchor.constraint(equalTo: topAnchor),
            internalStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            commandLabel.leadingAnchor.constraint(
                equalTo: commandContainer.leadingAnchor, constant: 6),
            commandLabel.trailingAnchor.constraint(
                equalTo: commandContainer.trailingAnchor, constant: -6),
            commandLabel.topAnchor.constraint(
                equalTo: commandContainer.topAnchor, constant: 5),
            commandLabel.bottomAnchor.constraint(
                equalTo: commandContainer.bottomAnchor, constant: -5),

            outputScrollView.leadingAnchor.constraint(
                equalTo: outputContainer.leadingAnchor),
            outputScrollView.trailingAnchor.constraint(
                equalTo: outputContainer.trailingAnchor),
            outputScrollView.topAnchor.constraint(
                equalTo: outputContainer.topAnchor),
            outputScrollView.bottomAnchor.constraint(
                equalTo: outputContainer.bottomAnchor),

            outputLabel.leadingAnchor.constraint(
                equalTo: outputScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            outputLabel.trailingAnchor.constraint(
                equalTo: outputScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            outputLabel.topAnchor.constraint(
                equalTo: outputScrollView.contentLayoutGuide.topAnchor, constant: 5),
            outputLabel.bottomAnchor.constraint(
                equalTo: outputScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            outputLabelWidth,
        ])

        outputLabelWidthConstraint = outputLabelWidth
        outputLabelHeightLockConstraint = outputLabelHeightLock
        outputViewportHeightConstraint = outputViewportHeight
    }
}
