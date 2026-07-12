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

    init(
        command: String?,
        output: String?,
        unwrapped: Bool,
        isError: Bool,
        isStreaming: Bool,
        sessionId: String? = nil
    ) {
        self.command = command
        self.output = output
        self.unwrapped = unwrapped
        self.isError = isError
        self.isStreaming = isStreaming
        self.sessionId = sessionId
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
    private var pendingFollowTail = false
    private var perfSessionId: String?

    // MARK: - Deferred ANSI highlight

    /// Byte threshold above which ANSI highlighting is deferred to a background
    /// thread. Below this, synchronous parsing is fast enough (< 16ms on device).
    static let deferredANSIByteThreshold = 4 * 1024

    private var deferredANSITask: Task<Void, Never>?
    private var deferredANSISignature: Int?

    #if DEBUG
    nonisolated(unsafe) static var deferredANSIDelayForTesting: Duration?
    #endif

    // MARK: - Streaming append state (step 7)

    /// UTF-16 length of plain-text content already rendered during streaming.
    /// Used to append only the delta on each streaming chunk.
    private var streamAppendOffset = 0

    /// Incremental ANSI stripper for streaming — avoids O(n^2) by only
    /// processing new bytes on each chunk instead of re-stripping the full
    /// accumulated output.
    private var incrementalStripper = ANSIParser.IncrementalStripper()

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

    // MARK: - Apply

    /// Refresh persistent UIKit chrome before rendering or revealing the row.
    /// The view can be reused across a live system appearance change.
    func applyTheme(_ palette: ThemePalette) {
        commandContainer.backgroundColor = UIColor(palette.bgHighlight)
        commandContainer.layer.borderColor = UIColor(palette.blue.opacity(0.35)).cgColor
        commandLabel.textColor = UIColor(palette.fg)

        outputContainer.backgroundColor = UIColor(palette.bgDark)
        outputContainer.layer.borderColor = UIColor(palette.comment.opacity(0.2)).cgColor
        outputLabel.textColor = UIColor(palette.fg)
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
        var showCommand = false
        var showOutput = false

        // MARK: Command

        if let command = input.command, !command.isEmpty {
            let displayCmd = ToolTimelineRowRenderMetrics.displayCommandText(command)
            let signature = ToolTimelineRowRenderMetrics.commandSignature(displayCommand: displayCmd)
            if signature != commandRenderSignature {
                let startNs = ChatTimelinePerf.timestampNs()
                if let cached = ToolRowRenderCache.get(signature: signature) {
                    commandLabel.attributedText = cached
                } else if displayCmd.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes {
                    let highlighted = ToolRowTextRenderer.bashCommandHighlighted(displayCmd)
                    ToolRowRenderCache.set(signature: signature, attributed: highlighted)
                    commandLabel.attributedText = highlighted
                } else {
                    commandLabel.attributedText = nil
                    commandLabel.text = displayCmd
                    commandLabel.textColor = UIColor(Color.themeFg)
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "bash.command",
                    durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
                    inputBytes: displayCmd.utf8.count,
                    sessionId: input.sessionId
                )
                commandRenderSignature = signature
            }
            showCommand = true
        } else {
            commandRenderSignature = nil
        }

        // MARK: Output

        if let output = input.output, !output.isEmpty {
            let displayOutput = ToolTimelineRowRenderMetrics.displayOutputText(output)
            let signature = ToolTimelineRowRenderMetrics.outputSignature(
                displayOutput: displayOutput,
                isError: input.isError,
                unwrapped: input.unwrapped,
                isStreaming: input.isStreaming
            )

            if signature != outputRenderSignature {
                let startNs = ChatTimelinePerf.timestampNs()
                let tier = StreamingRenderPolicy.tier(
                    isStreaming: input.isStreaming,
                    contentKind: .bash,
                    byteCount: displayOutput.utf8.count,
                    lineCount: 0
                )

                let didTextChange: Bool

                if tier == .cheap {
                    // Streaming: use incremental plain-text append.
                    didTextChange = applyStreamingOutput(displayOutput, outputColor: outputColor)
                } else if let cached = ToolRowRenderCache.get(signature: signature) {
                    let prevText = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                    didTextChange = prevText != cached.string
                    outputLabel.attributedText = cached
                    streamAppendOffset = 0
                    incrementalStripper.reset()
                } else if displayOutput.utf8.count > Self.deferredANSIByteThreshold {
                    // Large output: show placeholder now, parse ANSI in background.
                    // Plain text (no ESC byte): strip is O(1), use full text.
                    // ANSI content: use bounded prefix to avoid blocking main thread.
                    let hasANSI = displayOutput.utf8.contains(0x1B)
                    let placeholder = hasANSI
                        ? ANSIParser.stripPrefix(displayOutput, maxInputBytes: 512)
                        : displayOutput
                    let prevText = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                    didTextChange = prevText != placeholder
                    outputLabel.attributedText = nil
                    outputLabel.text = placeholder
                    outputLabel.textColor = outputColor
                    streamAppendOffset = 0
                    incrementalStripper.reset()
                    scheduleDeferredANSIHighlight(
                        text: displayOutput,
                        isError: input.isError,
                        signature: signature,
                        outputColor: outputColor,
                        unwrapped: input.unwrapped,
                        sessionId: input.sessionId
                    )
                } else {
                    // Small output: synchronous ANSI parse is fast enough.
                    cancelDeferredANSIHighlight()
                    let p = ToolRowTextRenderer.makeANSIOutputPresentation(
                        displayOutput,
                        isError: input.isError
                    )
                    if let attr = p.attributedText {
                        ToolRowRenderCache.set(signature: signature, attributed: attr)
                    }
                    let nextText = p.attributedText?.string ?? p.plainText ?? ""
                    let prevText = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                    didTextChange = prevText != nextText
                    ToolRowTextRenderer.applyANSIOutputPresentation(
                        p,
                        to: outputLabel,
                        plainTextColor: outputColor
                    )
                    streamAppendOffset = 0
                    incrementalStripper.reset()
                }

                let renderMode: String
                if tier == .cheap {
                    renderMode = "bash.output.stream"
                } else if deferredANSISignature == signature {
                    renderMode = "bash.output.deferred"
                } else {
                    renderMode = "bash.output.ansi"
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: renderMode,
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

    // MARK: - Streaming Append (step 7)

    /// Apply streaming output using incremental ANSI stripping.
    ///
    /// Uses `ANSIParser.IncrementalStripper` to process only new bytes
    /// on each chunk, keeping per-chunk cost O(delta) instead of O(n).
    /// Appends the stripped delta directly to the label.
    ///
    /// Falls back to a full rebuild when the stripper returns nil
    /// (unchanged input) or when the label state is inconsistent.
    /// Returns whether the visible content changed.
    private func applyStreamingOutput(_ displayOutput: String, outputColor: UIColor) -> Bool {
        guard let delta = incrementalStripper.delta(displayOutput) else {
            return false
        }

        let font = ToolFont.regular
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: outputColor,
        ]

        let existingLen = (outputLabel.attributedText?.length)
            ?? (outputLabel.text as NSString?)?.length
            ?? 0

        if existingLen == streamAppendOffset, streamAppendOffset > 0 {
            // Append delta to existing attributed text.
            if let existing = outputLabel.attributedText, existing.length > 0 {
                let mutable = NSMutableAttributedString(attributedString: existing)
                mutable.append(NSAttributedString(string: delta, attributes: attrs))
                outputLabel.attributedText = mutable
            } else {
                // Label was set via .text — rebuild as attributed.
                let fullText = (outputLabel.text ?? "") + delta
                outputLabel.attributedText = NSAttributedString(
                    string: fullText,
                    attributes: attrs
                )
            }
        } else {
            // First chunk or label is inconsistent — set full stripped text.
            // Use the stripper's total output length to reconstruct.
            let stripped = ANSIParser.strip(displayOutput)
            outputLabel.attributedText = NSAttributedString(
                string: stripped,
                attributes: attrs
            )
        }

        streamAppendOffset = incrementalStripper.strippedUTF16Length
        return true
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
        outputShouldAutoFollow = true
        streamAppendOffset = 0
        incrementalStripper.reset()
        ToolTimelineRowUIHelpers.resetScrollPosition(outputScrollView)
    }

    /// Reset command render state. Called when command container is hidden.
    func resetCommandState() {
        cancelDeferredANSIHighlight()
        commandLabel.attributedText = nil
        commandLabel.text = nil
        commandLabel.textColor = UIColor(Color.themeFg)
        commandRenderSignature = nil
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
    }

    private func scheduleDeferredANSIHighlight(
        text: String,
        isError: Bool,
        signature: Int,
        outputColor: UIColor,
        unwrapped: Bool,
        sessionId: String?
    ) {
        // Skip if already computing this exact signature.
        if deferredANSISignature == signature,
           let task = deferredANSITask,
           !task.isCancelled {
            return
        }

        cancelDeferredANSIHighlight()
        deferredANSISignature = signature

        deferredANSITask = Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            if let artificialDelay = BashToolRowView.deferredANSIDelayForTesting {
                try? await Task.sleep(for: artificialDelay)
            }
            #endif

            let renderStart = ContinuousClock.now
            let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                text,
                isError: isError
            )
            guard let attributed = presentation.attributedText else { return }
            let result = DeferredANSIResult(attributed: attributed)
            let durationMs = Int((ContinuousClock.now - renderStart) / .milliseconds(1))

            await MainActor.run { [weak self] in
                guard let self,
                      self.deferredANSISignature == signature else {
                    return
                }

                defer {
                    self.deferredANSITask = nil
                    self.deferredANSISignature = nil
                }

                ToolRowRenderCache.set(signature: signature, attributed: result.attributed)
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "bash.output.deferred.highlight",
                    durationMs: durationMs,
                    inputBytes: text.utf8.count,
                    sessionId: sessionId
                )

                // Only apply if cell still shows this signature.
                guard self.outputRenderSignature == signature else { return }

                self.outputLabel.attributedText = result.attributed
                self.streamAppendOffset = 0
                self.incrementalStripper.reset()
                self.outputRenderedText = unwrapped ? result.attributed.string : nil
                self.updateOutputLabelWidthIfNeeded()
                self.setNeedsLayout()
            }
        }
    }

    // MARK: - Vertical Lock

    func setOutputVerticalLockEnabled(_ enabled: Bool) {
        outputLabelHeightLockConstraint?.isActive = enabled
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
        ToolTimelineRowUIHelpers.scrollToBottom(outputScrollView, animated: false)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === outputScrollView else { return }
        if outputLabelHeightLockConstraint?.isActive == true {
            let lockedY = -outputScrollView.adjustedContentInset.top
            if abs(outputScrollView.contentOffset.y - lockedY) > 0.5 {
                outputScrollView.contentOffset.y = lockedY
            }
        }
        outputShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(outputScrollView)
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
