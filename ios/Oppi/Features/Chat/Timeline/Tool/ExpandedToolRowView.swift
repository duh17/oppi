import SwiftUI
import UIKit

// MARK: - ExpandedRenderMode

enum ExpandedRenderMode {
    case code(text: String, language: SyntaxLanguage?, startLine: Int?)
    case diff(lines: [DiffLine], path: String?)
    case text(text: String, language: SyntaxLanguage?, isError: Bool)
    case markdown(text: String, isDone: Bool, markdownSelectionEnabled: Bool,
                  selectedTextPiRouter: SelectedTextPiActionRouter?,
                  selectedTextSourceContext: SelectedTextSourceContext?)
    case plot(spec: PlotChartSpec, fallbackText: String?)
    case readMedia(output: String, filePath: String?, startLine: Int, isError: Bool)
}

// MARK: - ExpandedRenderInput

struct ExpandedRenderInput {
    let mode: ExpandedRenderMode
    let isStreaming: Bool
    let outputColor: UIColor
}

// MARK: - ExpandedRenderResult

struct ExpandedRenderResult {
    let showExpandedContainer: Bool
    let activeViewportMode: ToolTimelineRowContentView.ExpandedViewportMode
}

// MARK: - ExpandedToolRowView

/// Self-contained expanded tool row rendering controller.
///
/// Owns the expanded scroll view, label, markdown view, and hosted-view
/// container used for code/diff/text/markdown/plot/readMedia tool calls.
/// The parent hands it an `ExpandedRenderInput` value type and gets back an
/// `ExpandedRenderResult` with visibility flags. No inout params; all render
/// state is internal.
///
/// UIView surfaces (`expandedContainer`, `expandedScrollView`,
/// `expandedLabel`) are exposed as `let` so the parent can build the view
/// hierarchy, attach gestures, context menus, and selected-text delegates.
@MainActor
final class ExpandedToolRowView: NSObject, UIScrollViewDelegate {

    // MARK: - Surfaces (exposed for parent gestures/interactions)

    let expandedContainer = UIView()
    let expandedScrollView = HorizontalPanPassthroughScrollView()
    let expandedLabel = UITextView()

    // MARK: - Internal surfaces (exposed for parent layout builder)

    // periphery:ignore - parent layout builder needs these
    let expandedSurfaceHostView = ToolExpandedSurfaceHostView()
    // periphery:ignore - parent layout builder needs these
    let expandedMarkdownView = AssistantMarkdownContentView()
    // periphery:ignore - parent layout builder needs these
    let expandedReadMediaContainer = UIView()

    // MARK: - State (read by parent for viewport/layout)

    private(set) var expandedViewportMode: ToolTimelineRowContentView.ExpandedViewportMode = .none

    private(set) var expandedRenderedText: String? {
        didSet { expandedWidthEstimateCache.invalidate(); expandedViewportHeightCache.invalidate() }
    }

    private(set) var expandedRenderSignature: Int?
    var expandedShouldAutoFollow = true
    private(set) var expandedUsesMarkdownLayout = false
    private(set) var expandedUsesReadMediaLayout = false

    // MARK: - Layout constraints (read by parent)

    private(set) var expandedViewportHeightConstraint: NSLayoutConstraint?
    private(set) var expandedLabelWidthConstraint: NSLayoutConstraint?
    private(set) var expandedLabelHeightLockConstraint: NSLayoutConstraint?
    private(set) var expandedMarkdownWidthConstraint: NSLayoutConstraint?
    private(set) var expandedReadMediaWidthConstraint: NSLayoutConstraint?

    // MARK: - Caches

    var expandedWidthEstimateCache = ToolTimelineRowWidthEstimateCache()
    var expandedViewportHeightCache = ToolTimelineRowViewportHeightCache()

    // MARK: - Private state

    private var expandedUsesViewport = false
    private var expandedReadMediaContentView: UIView?
    private var expandedPinchDidTriggerFullScreen = false
    var expandedCodeDeferredHighlightSignature: Int?
    var expandedCodeDeferredHighlightTask: Task<Void, Never>?

    /// Set by apply(). Consumed by parent's flushPendingFollowTail().
    var needsFollowTail = false

    /// Set when the expanded view needs layout invalidation.
    /// Consumed by parent after apply() returns.
    var needsLayoutInvalidation = false

    /// The parent view that hosts the expanded surfaces.
    /// Used for layout invalidation and deferred highlight setNeedsLayout.
    weak var hostView: UIView?

    // MARK: - Init

    override init() {
        super.init()
        setupViews()
    }

    deinit {
        expandedCodeDeferredHighlightTask?.cancel()
    }

    // MARK: - Apply

    /// Render expanded content.
    ///
    /// Returns which surfaces should be visible. The parent is responsible
    /// for showing/hiding `expandedContainer` and calling
    /// `flushFollowTail()` once the container is visible with valid bounds.
    func apply(
        input: ExpandedRenderInput,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderResult {
        needsFollowTail = false

        switch input.mode {
        case .code(let text, let language, let startLine):
            return applyCode(
                text: text,
                language: language,
                startLine: startLine,
                isStreaming: input.isStreaming,
                wasExpandedVisible: wasExpandedVisible
            )

        case .diff(let lines, let path):
            return applyDiff(
                lines: lines,
                path: path,
                isStreaming: input.isStreaming,
                wasExpandedVisible: wasExpandedVisible
            )

        case .text(let text, let language, let isError):
            return applyText(
                text: text,
                language: language,
                isError: isError,
                isStreaming: input.isStreaming,
                outputColor: input.outputColor,
                wasExpandedVisible: wasExpandedVisible
            )

        case .markdown(let text, let isDone, let markdownSelectionEnabled,
                       let selectedTextPiRouter, let selectedTextSourceContext):
            return applyMarkdown(
                text: text,
                isStreaming: input.isStreaming,
                isDone: isDone,
                wasExpandedVisible: wasExpandedVisible,
                markdownSelectionEnabled: markdownSelectionEnabled,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: selectedTextSourceContext
            )

        case .plot(let spec, let fallbackText):
            return applyPlot(spec: spec, fallbackText: fallbackText)

        case .readMedia(let output, let filePath, let startLine, let isError):
            return applyReadMedia(
                output: output,
                filePath: filePath,
                startLine: startLine,
                isError: isError
            )
        }
    }

    // MARK: - Code

    private func applyCode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?,
        isStreaming: Bool,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderResult {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: displayText,
            language: language,
            startLine: resolvedStartLine,
            isStreaming: isStreaming
        )

        let currentRenderedString = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        let needsNonStreamingUpgrade = !isStreaming && currentRenderedString == displayText
        let shouldRerender = signature != expandedRenderSignature
            || expandedViewportMode != .code
            || needsNonStreamingUpgrade
        let previousRenderedText = expandedRenderedText

        showExpandedLabel()

        var deferredHighlight: DeferredHighlight?

        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let profile = StreamingRenderPolicy.ContentProfile.from(text: displayText)
            let languageCategory = Self.codeLanguageCategory(for: language)
            let tier = StreamingRenderPolicy.tier(
                isStreaming: isStreaming,
                contentKind: .code(language: languageCategory),
                byteCount: profile.byteCount,
                lineCount: profile.lineCount,
                maxLineByteCount: profile.maxLineByteCount
            )

            switch tier {
            case .cheap:
                applyPlainText(displayText)

            case .deferred, .full:
                if let cached = ToolRowRenderCache.get(signature: signature) {
                    expandedLabel.text = nil
                    expandedLabel.attributedText = cached
                } else if tier == .deferred {
                    applyPlainText(displayText)
                    deferredHighlight = DeferredHighlight(
                        text: displayText,
                        language: language ?? .unknown,
                        startLine: resolvedStartLine,
                        signature: signature
                    )
                } else {
                    let codeText = ToolRowTextRenderer.makeCodeAttributedText(
                        text: displayText,
                        language: language,
                        startLine: resolvedStartLine
                    )
                    ToolRowRenderCache.set(signature: signature, attributed: codeText)
                    expandedLabel.text = nil
                    expandedLabel.attributedText = codeText
                }
            }

            ChatTimelinePerf.recordRenderStrategy(
                mode: tier == .cheap ? "code.stream" : (deferredHighlight != nil ? "code.deferred" : "code.highlight"),
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: displayText.utf8.count,
                language: language?.displayName
            )
            expandedRenderedText = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
            expandedRenderSignature = signature
        }

        applyHorizontalScrollLayout()
        expandedViewportMode = .code
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()

        // Deferred highlight lifecycle
        if let deferredHighlight {
            scheduleDeferredCodeHighlightIfNeeded(deferredHighlight)
        } else {
            cancelDeferredCodeHighlight()
        }

        // Vertical lock: during streaming, label must grow beyond viewport for
        // auto-follow. On done, lock for horizontal-scroll-only mode.
        setExpandedVerticalLockEnabled(!isStreaming)
        updateExpandedLabelWidthIfNeeded()

        // Auto-follow (unified)
        applyAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: displayText
        )

        return ExpandedRenderResult(
            showExpandedContainer: true,
            activeViewportMode: .code
        )
    }

    // MARK: - Diff

    private func applyDiff(
        lines: [DiffLine],
        path: String?,
        isStreaming: Bool,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderResult {
        cancelDeferredCodeHighlight()

        let signature = ToolTimelineRowRenderMetrics.diffSignature(
            lines: lines, path: path, isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || expandedViewportMode != .diff
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)
        let previousRenderedText = expandedRenderedText

        showExpandedLabel()

        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let inputBytes = lines.reduce(0) { $0 + $1.text.utf8.count }
            let tier = StreamingRenderPolicy.tier(
                isStreaming: isStreaming,
                contentKind: .diff,
                byteCount: inputBytes,
                lineCount: lines.count
            )

            if tier == .cheap {
                let plainDiff = lines.map { line in
                    switch line.kind {
                    case .added: "+ \(line.text)"
                    case .removed: "- \(line.text)"
                    case .context: "  \(line.text)"
                    }
                }.joined(separator: "\n")
                expandedLabel.attributedText = nil
                expandedLabel.text = plainDiff
                expandedLabel.textColor = UIColor(.themeFg)
                expandedLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                expandedRenderedText = plainDiff
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                expandedLabel.text = nil
                expandedLabel.attributedText = cached
                expandedRenderedText = cached.string
            } else {
                let diffText = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: path)
                ToolRowRenderCache.set(signature: signature, attributed: diffText)
                expandedLabel.text = nil
                expandedLabel.attributedText = diffText
                expandedRenderedText = diffText.string
            }
            ChatTimelinePerf.recordRenderStrategy(
                mode: tier == .cheap ? "diff.stream" : "diff.highlight",
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: inputBytes,
                language: path.flatMap { ToolRowTextRenderer.diffLanguage(for: $0)?.displayName }
            )
            expandedRenderSignature = signature
        }

        applyHorizontalScrollLayout()
        expandedViewportMode = .diff
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()

        // During streaming, don't lock label height to the viewport.
        setExpandedVerticalLockEnabled(!isStreaming)
        updateExpandedLabelWidthIfNeeded()

        // Auto-follow (unified)
        let currentRenderedText = expandedRenderedText ?? ""
        applyAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: currentRenderedText
        )

        return ExpandedRenderResult(
            showExpandedContainer: true,
            activeViewportMode: .diff
        )
    }

    // MARK: - Text

    private func applyText(
        text: String,
        language: SyntaxLanguage?,
        isError: Bool,
        isStreaming: Bool,
        outputColor: UIColor,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderResult {
        cancelDeferredCodeHighlight()

        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let signature = ToolTimelineRowRenderMetrics.textSignature(
            displayText: displayText,
            language: language,
            isError: isError,
            isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || expandedViewportMode != .text
            || expandedUsesMarkdownLayout
            || expandedUsesReadMediaLayout
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)
        let previousRenderedText = expandedRenderedText

        showExpandedLabel()

        if shouldRerender {
            let renderStartNs = ChatTimelinePerf.timestampNs()
            let tier = StreamingRenderPolicy.tier(
                isStreaming: isStreaming,
                contentKind: .plainText,
                byteCount: displayText.utf8.count,
                lineCount: 0
            )

            let presentation: ToolRowTextRenderer.ANSIOutputPresentation
            if tier == .cheap {
                presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                    attributedText: nil,
                    plainText: ANSIParser.strip(displayText)
                )
            } else if let cached = ToolRowRenderCache.get(signature: signature) {
                presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                    attributedText: cached,
                    plainText: nil
                )
            } else if let language, !isError {
                let p = ToolRowTextRenderer.makeSyntaxOutputPresentation(
                    displayText,
                    language: language
                )
                if let attr = p.attributedText {
                    ToolRowRenderCache.set(signature: signature, attributed: attr)
                }
                presentation = p
            } else {
                let p = ToolRowTextRenderer.makeANSIOutputPresentation(
                    displayText,
                    isError: isError
                )
                if let attr = p.attributedText {
                    ToolRowRenderCache.set(signature: signature, attributed: attr)
                }
                presentation = p
            }
            ChatTimelinePerf.recordRenderStrategy(
                mode: tier == .cheap ? "text.stream" : (language != nil ? "text.syntax" : "text.ansi"),
                durationMs: ChatTimelinePerf.elapsedMs(since: renderStartNs),
                inputBytes: displayText.utf8.count,
                language: language?.displayName
            )

            ToolRowTextRenderer.applyANSIOutputPresentation(
                presentation,
                to: expandedLabel,
                plainTextColor: outputColor
            )
            expandedRenderedText = presentation.attributedText?.string ?? presentation.plainText ?? ""
            expandedRenderSignature = signature
        }

        applyWrappedLayout()
        expandedViewportMode = .text
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        setExpandedVerticalLockEnabled(false)

        // Auto-follow (unified)
        applyAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: displayText
        )

        return ExpandedRenderResult(
            showExpandedContainer: true,
            activeViewportMode: .text
        )
    }

    // MARK: - Markdown

    private func applyMarkdown(
        text: String,
        isStreaming: Bool,
        isDone: Bool,
        wasExpandedVisible: Bool,
        markdownSelectionEnabled: Bool,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) -> ExpandedRenderResult {
        cancelDeferredCodeHighlight()

        let previousExpandedRenderSignature = expandedRenderSignature
        let wasUsingMarkdownLayout = expandedUsesMarkdownLayout

        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text, isStreaming: isStreaming)
        let shouldRerender = signature != expandedRenderSignature
            || !expandedUsesMarkdownLayout
        let previousRenderedText = expandedRenderedText

        showExpandedMarkdown()

        expandedRenderedText = text
        updateExpandedLabelWidthIfNeeded()
        expandedMarkdownView.apply(configuration: .init(
            content: text,
            isStreaming: isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: markdownSelectionEnabled,
            selectedTextPiRouter: markdownSelectionEnabled ? selectedTextPiRouter : nil,
            selectedTextSourceContext: markdownSelectionEnabled ? selectedTextSourceContext : nil
        ))
        if shouldRerender {
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedViewportMode = .text
        showExpandedViewport()
        setExpandedVerticalLockEnabled(false)

        // Auto-follow (unified)
        applyAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: text
        )

        let didRerenderMarkdown = expandedRenderSignature != previousExpandedRenderSignature
        let didEnterMarkdownLayout = !wasUsingMarkdownLayout && expandedUsesMarkdownLayout

        if didRerenderMarkdown || didEnterMarkdownLayout {
            needsLayoutInvalidation = true
        }

        return ExpandedRenderResult(
            showExpandedContainer: true,
            activeViewportMode: .text
        )
    }

    // MARK: - Plot

    private func applyPlot(
        spec: PlotChartSpec,
        fallbackText: String?
    ) -> ExpandedRenderResult {
        cancelDeferredCodeHighlight()

        let signature = ToolTimelineRowRenderMetrics.plotSignature(
            spec: spec,
            fallbackText: fallbackText
        )
        let shouldReinstall = signature != expandedRenderSignature
            || !expandedUsesReadMediaLayout
            || !(expandedReadMediaContentView is NativeExpandedPlotView)

        showExpandedHostedView()
        expandedRenderedText = fallbackText
        if shouldReinstall {
            installExpandedPlotView(spec: spec, fallbackText: fallbackText)
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedViewportMode = .text
        showExpandedViewport()
        expandedShouldAutoFollow = false
        setExpandedVerticalLockEnabled(false)
        if shouldReinstall { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return ExpandedRenderResult(
            showExpandedContainer: true,
            activeViewportMode: .text
        )
    }

    // MARK: - ReadMedia

    private func applyReadMedia(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool
    ) -> ExpandedRenderResult {
        cancelDeferredCodeHighlight()

        let signature = ToolTimelineRowRenderMetrics.readMediaSignature(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError
        )
        let shouldReinstall = signature != expandedRenderSignature
            || !expandedUsesReadMediaLayout
            || expandedReadMediaContentView == nil

        showExpandedHostedView()
        expandedRenderedText = output
        if shouldReinstall {
            installExpandedReadMediaView(
                output: output,
                isError: isError,
                filePath: filePath,
                startLine: startLine
            )
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedViewportMode = .text
        showExpandedViewport()
        expandedShouldAutoFollow = false
        setExpandedVerticalLockEnabled(false)
        if shouldReinstall { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return ExpandedRenderResult(
            showExpandedContainer: true,
            activeViewportMode: .text
        )
    }

    // MARK: - Unified Auto-Follow

    /// Unified auto-follow logic for code/diff/text/markdown modes.
    ///
    /// The three original strategy variants had slightly different conditions
    /// that looked accidental rather than intentional. This unifies them:
    /// - First render while streaming → enable
    /// - Streaming continuation → preserve current state
    /// - Cell reuse (non-continuation content change) during streaming → re-enable
    /// - Done → disable
    private func applyAutoFollow(
        isStreaming: Bool,
        shouldRerender: Bool,
        wasExpandedVisible: Bool,
        previousRenderedText: String?,
        currentDisplayText: String
    ) {
        let isStreamingContinuation = previousRenderedText.map {
            !$0.isEmpty && currentDisplayText.hasPrefix($0)
        } ?? false

        if isStreaming {
            if !wasExpandedVisible || previousRenderedText == nil {
                // First render or newly-visible during streaming
                expandedShouldAutoFollow = true
            } else if !isStreamingContinuation, shouldRerender {
                // Non-continuation content during streaming = cell reuse
                expandedShouldAutoFollow = true
            }
            // Otherwise preserve current auto-follow state
        } else {
            expandedShouldAutoFollow = false
        }

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleFollowTail()
            } else if !isStreaming {
                ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
            }
        }
    }

    private func scheduleFollowTail() {
        guard expandedShouldAutoFollow else { return }
        needsFollowTail = true
    }

    // MARK: - Surface Switching

    /// Prepare for label-based expanded content (diff, code, plain text).
    func showExpandedLabel() {
        expandedSurfaceHostView.activateSurfaceView(expandedLabel)
        expandedMarkdownView.isHidden = true
        expandedLabel.isHidden = false
        expandedReadMediaContainer.isHidden = true
        expandedUsesMarkdownLayout = false
        expandedUsesReadMediaLayout = false
        clearExpandedReadMediaView()
        clearExpandedMarkdownContent()
    }

    /// Prepare for markdown expanded content.
    private func showExpandedMarkdown() {
        expandedSurfaceHostView.activateSurfaceView(expandedMarkdownView)
        expandedLabel.attributedText = nil
        expandedLabel.text = nil
        expandedLabel.isHidden = true
        expandedMarkdownView.isHidden = false
        expandedReadMediaContainer.isHidden = true
        expandedUsesMarkdownLayout = true
        expandedUsesReadMediaLayout = false
        clearExpandedReadMediaView()
        expandedLabelWidthConstraint?.priority = .defaultHigh
        expandedLabelWidthConstraint?.constant = -12
    }

    /// Prepare for embedded expanded content (plot, readMedia).
    private func showExpandedHostedView() {
        expandedSurfaceHostView.activateSurfaceView(expandedReadMediaContainer)
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
        updateExpandedReadMediaWidthIfNeeded()
    }

    /// Activate the expanded viewport height constraint.
    private func showExpandedViewport() {
        expandedViewportHeightConstraint?.isActive = true
        expandedUsesViewport = true
    }

    // MARK: - Code Language Category

    static func codeLanguageCategory(
        for language: SyntaxLanguage?
    ) -> StreamingRenderPolicy.CodeLanguageCategory {
        guard let language else { return .none }
        return language == .unknown ? .unknown : .known
    }

    // MARK: - Layout Mode Helpers

    private func applyHorizontalScrollLayout() {
        expandedLabel.textContainer.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
    }

    private func applyWrappedLayout() {
        expandedLabel.textContainer.lineBreakMode = .byCharWrapping
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
    }

    private func applyPlainText(_ text: String) {
        expandedLabel.attributedText = nil
        expandedLabel.text = text
        expandedLabel.textColor = UIColor(.themeFg)
        expandedLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    }

    // MARK: - Vertical Lock

    func setExpandedVerticalLockEnabled(_ enabled: Bool) {
        expandedLabelHeightLockConstraint?.isActive = enabled
    }

    // MARK: - Width Update

    func updateExpandedLabelWidthIfNeeded() {
        guard let expandedLabelWidthConstraint else { return }

        switch expandedViewportMode {
        case .diff, .code:
            expandedLabelWidthConstraint.priority = .required
            guard let expandedRenderedText else { return }
            expandedLabelWidthConstraint.constant = expandedLabelWidthConstant(for: expandedRenderedText)

        case .text, .none:
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
            metricMode: metricMode
        )
    }

    func updateExpandedMarkdownWidthIfNeeded() {
        guard let expandedMarkdownWidthConstraint else { return }
        expandedMarkdownWidthConstraint.constant = -12
    }

    func updateExpandedReadMediaWidthIfNeeded() {
        guard let expandedReadMediaWidthConstraint else { return }
        expandedReadMediaWidthConstraint.constant = -12
    }

    // MARK: - Viewport Profile

    var currentExpandedViewportProfile: ToolTimelineRowViewportProfile? {
        guard expandedUsesViewport else { return nil }

        let kind: ToolTimelineRowViewportKind
        if expandedUsesMarkdownLayout {
            kind = .markdown
        } else if expandedUsesReadMediaLayout {
            kind = expandedReadMediaContentView is NativeExpandedPlotView ? .plot : .readMedia
        } else {
            kind = switch expandedViewportMode {
            case .diff: .diff
            case .code: .code
            case .text, .none: .text
            }
        }

        return ToolTimelineRowViewportProfile(kind: kind, text: expandedRenderedText)
    }

    /// The content view to use for viewport height measurement.
    var expandedContentView: UIView {
        expandedUsesReadMediaLayout ? expandedReadMediaContainer
            : (expandedUsesMarkdownLayout ? expandedMarkdownView : expandedLabel)
    }

    // MARK: - Reset

    /// Reset expanded container to hidden/default state.
    func reset(outputColor: UIColor) {
        cancelDeferredCodeHighlight()
        expandedSurfaceHostView.clearActiveSurface()
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
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedScrollView.isScrollEnabled = false
        setExpandedVerticalLockEnabled(false)
        expandedViewportMode = .none
        expandedRenderedText = nil
        expandedRenderSignature = nil
        updateExpandedLabelWidthIfNeeded()
        expandedViewportHeightConstraint?.isActive = false
        expandedUsesViewport = false
        expandedShouldAutoFollow = true
        ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
    }

    // MARK: - Deferred Code Highlight

    struct DeferredHighlightedCode: @unchecked Sendable {
        let attributed: NSAttributedString
    }

    #if DEBUG
    nonisolated(unsafe) static var deferredCodeHighlightDelayForTesting: Duration?
    #endif

    func cancelDeferredCodeHighlight() {
        expandedCodeDeferredHighlightTask?.cancel()
        expandedCodeDeferredHighlightTask = nil
        expandedCodeDeferredHighlightSignature = nil
    }

    func scheduleDeferredCodeHighlightIfNeeded(
        _ deferredHighlight: DeferredHighlight
    ) {
        if expandedCodeDeferredHighlightSignature == deferredHighlight.signature,
           let task = expandedCodeDeferredHighlightTask,
           !task.isCancelled {
            return
        }

        cancelDeferredCodeHighlight()
        expandedCodeDeferredHighlightSignature = deferredHighlight.signature

        expandedCodeDeferredHighlightTask = Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            if let artificialDelay = ExpandedToolRowView.deferredCodeHighlightDelayForTesting {
                try? await Task.sleep(for: artificialDelay)
            }
            #endif

            let renderStart = ContinuousClock.now
            let highlighted = DeferredHighlightedCode(attributed: ToolRowTextRenderer.makeCodeAttributedText(
                text: deferredHighlight.text,
                language: deferredHighlight.language,
                startLine: deferredHighlight.startLine
            ))
            let durationMs = Int((ContinuousClock.now - renderStart) / .milliseconds(1))

            await MainActor.run { [weak self] in
                ToolRowRenderCache.set(
                    signature: deferredHighlight.signature,
                    attributed: highlighted.attributed
                )
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "code.deferred.highlight",
                    durationMs: durationMs,
                    inputBytes: deferredHighlight.text.utf8.count,
                    language: deferredHighlight.language.displayName
                )

                guard let self,
                      self.expandedCodeDeferredHighlightSignature == deferredHighlight.signature else {
                    return
                }

                defer {
                    self.expandedCodeDeferredHighlightTask = nil
                    self.expandedCodeDeferredHighlightSignature = nil
                }

                guard self.expandedRenderSignature == deferredHighlight.signature,
                      self.expandedViewportMode == .code,
                      !self.expandedUsesMarkdownLayout,
                      !self.expandedUsesReadMediaLayout else {
                    return
                }

                self.expandedLabel.text = nil
                self.expandedLabel.attributedText = highlighted.attributed
                self.expandedRenderedText = highlighted.attributed.string
                self.updateExpandedLabelWidthIfNeeded()
                self.hostView?.setNeedsLayout()
            }
        }
    }

    // MARK: - Install Embedded Views

    private func installExpandedReadMediaView(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int
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
            themeID: ThemeRuntimeState.currentThemeID()
        )
    }

    private func installExpandedPlotView(spec: PlotChartSpec, fallbackText: String?) {
        let native: NativeExpandedPlotView
        if let existing = expandedReadMediaContentView as? NativeExpandedPlotView {
            native = existing
        } else {
            clearExpandedReadMediaView()
            native = NativeExpandedPlotView()
            installExpandedEmbeddedView(native)
        }

        native.apply(
            spec: spec,
            fallbackText: fallbackText,
            themeID: ThemeRuntimeState.currentThemeID()
        )
    }

    private func installExpandedEmbeddedView(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        expandedReadMediaContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: expandedReadMediaContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: expandedReadMediaContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: expandedReadMediaContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: expandedReadMediaContainer.bottomAnchor),
        ])

        expandedReadMediaContentView = view
        needsLayoutInvalidation = true
    }

    private func clearExpandedReadMediaView() {
        expandedReadMediaContentView?.removeFromSuperview()
        expandedReadMediaContentView = nil
    }

    private func clearExpandedMarkdownContent() {
        expandedMarkdownView.clearContent()
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === expandedScrollView else { return }
        if expandedLabelHeightLockConstraint?.isActive == true {
            let lockedY = -expandedScrollView.adjustedContentInset.top
            if abs(expandedScrollView.contentOffset.y - lockedY) > 0.5 {
                expandedScrollView.contentOffset.y = lockedY
            }
        }
        expandedShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(expandedScrollView)
    }



    // MARK: - Setup

    /// Style expanded views. Does NOT add them to a view hierarchy — the
    /// parent is responsible for hierarchy and constraints.
    private func setupViews() {
        ToolTimelineRowViewStyler.styleExpanded(
            expandedContainer: expandedContainer,
            expandedScrollView: expandedScrollView,
            expandedLabel: expandedLabel,
            expandedMarkdownView: expandedMarkdownView,
            expandedReadMediaContainer: expandedReadMediaContainer,
            delegate: self
        )
    }

    /// Called by parent after layout builder creates constraints.
    func installConstraints(
        expandedLabelWidth: NSLayoutConstraint,
        expandedLabelHeightLock: NSLayoutConstraint,
        expandedMarkdownWidth: NSLayoutConstraint,
        expandedReadMediaWidth: NSLayoutConstraint,
        expandedViewportHeight: NSLayoutConstraint
    ) {
        expandedLabelWidthConstraint = expandedLabelWidth
        expandedLabelHeightLockConstraint = expandedLabelHeightLock
        expandedMarkdownWidthConstraint = expandedMarkdownWidth
        expandedReadMediaWidthConstraint = expandedReadMediaWidth
        expandedViewportHeightConstraint = expandedViewportHeight

        expandedMarkdownWidthConstraint?.priority = .defaultHigh
        expandedReadMediaWidthConstraint?.priority = .defaultHigh
    }
}

// MARK: - DeferredHighlight (shared type)

struct DeferredHighlight: Sendable {
    let text: String
    let language: SyntaxLanguage
    let startLine: Int
    let signature: Int
}
