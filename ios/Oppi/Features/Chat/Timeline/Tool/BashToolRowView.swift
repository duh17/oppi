import SwiftUI
import UIKit

// MARK: - BashRenderInput

struct BashRenderInput {
    let command: String?
    let output: String?
    let unwrapped: Bool
    let isError: Bool
    let isStreaming: Bool
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

    // MARK: - Streaming append state (step 7)

    /// UTF-16 length of plain-text content already rendered during streaming.
    /// Used to append only the delta on each streaming chunk.
    private var streamAppendOffset = 0

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
                    inputBytes: displayCmd.utf8.count
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
                } else {
                    // Full ANSI parse (done state or small content).
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
                }

                ChatTimelinePerf.recordRenderStrategy(
                    mode: tier == .cheap ? "bash.output.stream" : "bash.output.ansi",
                    durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
                    inputBytes: displayOutput.utf8.count
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

    /// Apply streaming output using incremental plain-text append when possible.
    ///
    /// Tracks how many UTF-16 code units have already been rendered. On each
    /// new chunk, if the stripped text is a monotonic extension of what's
    /// already displayed, only the delta is appended — avoiding a full
    /// NSAttributedString rebuild for large growing outputs.
    ///
    /// Falls back to a full rebuild when content is replaced/truncated.
    /// Returns whether the visible content changed.
    private func applyStreamingOutput(_ displayOutput: String, outputColor: UIColor) -> Bool {
        let stripped = ANSIParser.strip(displayOutput)
        let strippedNS = stripped as NSString
        let newLen = strippedNS.length

        if streamAppendOffset > 0, newLen > streamAppendOffset {
            let existingLen = (outputLabel.text as NSString?)?.length ?? 0
            if existingLen == streamAppendOffset {
                // Delta is everything beyond what we already rendered.
                let deltaRange = NSRange(location: streamAppendOffset, length: newLen - streamAppendOffset)
                let delta = strippedNS.substring(with: deltaRange)

                let font = ToolFont.regular
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: outputColor,
                ]

                if let existing = outputLabel.attributedText, existing.length > 0 {
                    let mutable = NSMutableAttributedString(attributedString: existing)
                    mutable.append(NSAttributedString(string: delta, attributes: attrs))
                    outputLabel.attributedText = mutable
                } else {
                    // First attributed append: set full content with attrs.
                    outputLabel.attributedText = NSAttributedString(
                        string: stripped,
                        attributes: attrs
                    )
                }
                streamAppendOffset = newLen
                return true
            }
        }

        // Full rebuild.
        let prevText = outputLabel.text
        outputLabel.attributedText = nil
        outputLabel.text = stripped
        outputLabel.textColor = outputColor
        streamAppendOffset = newLen
        return prevText != stripped
    }

    // MARK: - Reset

    /// Reset output render state. Called when output container is hidden.
    func resetOutputState(outputColor: UIColor) {
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
        ToolTimelineRowUIHelpers.resetScrollPosition(outputScrollView)
    }

    /// Reset command render state. Called when command container is hidden.
    func resetCommandState() {
        commandLabel.attributedText = nil
        commandLabel.text = nil
        commandLabel.textColor = UIColor(Color.themeFg)
        commandRenderSignature = nil
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
            metricMode: "output"
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
        commandContainer.backgroundColor = UIColor(Color.themeBgHighlight.opacity(0.9))
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
