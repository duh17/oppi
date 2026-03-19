import SwiftUI
import UIKit

/// Native UIKit tool row.
///
/// Supports both collapsed and expanded presentation for tool rows, so row
/// expansion uses the same native renderer in both states.
struct ToolTimelineRowConfiguration: UIContentConfiguration {
    let title: String
    let preview: String?
    /// Single discriminated union for expanded content rendering.
    /// Replaces the previous 13 boolean/optional fields, making it
    /// impossible to set conflicting rendering modes.
    let expandedContent: ToolPresentationBuilder.ToolExpandedContent?
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
    /// Pre-rendered attributed title from server segments. When set, takes
    /// priority over the plain `title` + `toolNamePrefix` + `toolNameColor` path.
    let segmentAttributedTitle: NSAttributedString?
    /// Pre-rendered attributed trailing from server result segments.
    let segmentAttributedTrailing: NSAttributedString?
    var selectedTextPiRouter: SelectedTextPiActionRouter? = nil
    var selectedTextSessionId: String? = nil

    func makeContentView() -> any UIView & UIContentView {
        ToolTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }

    func withSelectedTextPi(router: SelectedTextPiActionRouter?, sessionId: String?) -> Self {
        Self(
            title: title,
            preview: preview,
            expandedContent: expandedContent,
            copyCommandText: copyCommandText,
            copyOutputText: copyOutputText,
            languageBadge: languageBadge,
            trailing: trailing,
            titleLineBreakMode: titleLineBreakMode,
            toolNamePrefix: toolNamePrefix,
            toolNameColor: toolNameColor,
            editAdded: editAdded,
            editRemoved: editRemoved,
            collapsedImageBase64: collapsedImageBase64,
            collapsedImageMimeType: collapsedImageMimeType,
            isExpanded: isExpanded,
            isDone: isDone,
            isError: isError,
            segmentAttributedTitle: segmentAttributedTitle,
            segmentAttributedTrailing: segmentAttributedTrailing,
            selectedTextPiRouter: router,
            selectedTextSessionId: sessionId
        )
    }
}

final class ToolTimelineRowContentView: UIView, UIContentView, UIScrollViewDelegate {
    private static let maxValidHeight: CGFloat = 10_000
    static let minOutputViewportHeight: CGFloat = 56
    private static let minDiffViewportHeight: CGFloat = 68
    private static let maxOutputViewportHeight: CGFloat = 620
    private static let maxDiffViewportHeight: CGFloat = 760
    /// Fixed viewport height used during streaming. The cell height stays
    /// constant while content grows inside, eliminating the nested-scroll
    /// invalidation cascade (inner content resize → cell height change →
    /// outer collection layout → contentOffset fight). Double-tap opens
    /// full-screen for the complete content. On completion (isDone), the
    /// viewport resizes once to the natural bucketed height.
    static let streamingViewportHeight: CGFloat = 200
    private static let outputViewportCloseSafeAreaReserve: CGFloat = 128
    private static let diffViewportCloseSafeAreaReserve: CGFloat = 88
    private static let collapsedImagePreviewHeight: CGFloat = 136

    @MainActor
    enum ExpandedViewportMode {
        case none
        case diff
        case code
        case text
    }

    @MainActor
    enum ViewportMode {
        case output
        case expandedDiff
        case expandedCode
        case expandedText

        var minHeight: CGFloat {
            switch self {
            case .output, .expandedText:
                return ToolTimelineRowContentView.minOutputViewportHeight
            case .expandedDiff, .expandedCode:
                return ToolTimelineRowContentView.minDiffViewportHeight
            }
        }

        var maxHeight: CGFloat {
            switch self {
            case .output, .expandedText:
                return ToolTimelineRowContentView.maxOutputViewportHeight
            case .expandedDiff, .expandedCode:
                return ToolTimelineRowContentView.maxDiffViewportHeight
            }
        }

        var closeSafeAreaReserve: CGFloat {
            switch self {
            case .output, .expandedText:
                return ToolTimelineRowContentView.outputViewportCloseSafeAreaReserve
            case .expandedDiff, .expandedCode:
                return ToolTimelineRowContentView.diffViewportCloseSafeAreaReserve
            }
        }
    }

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
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let trailingLabel = UILabel()
    private let bodyStack = UIStackView()
    private let previewLabel = UILabel()
    let bashToolRowView = BashToolRowView()
    let expandedContainer = UIView()
    let expandedScrollView = HorizontalPanPassthroughScrollView()
    private let expandedSurfaceHostView = ToolExpandedSurfaceHostView()
    let expandedLabel = UITextView()
    private let expandedMarkdownView = AssistantMarkdownContentView()
    private let expandedReadMediaContainer = UIView()
    private let imagePreviewContainer = UIView()
    private let imagePreviewImageView = UIImageView()
    private let borderView = UIView()

    // MARK: - Mirror-reflection forwarding for test compatibility
    // These lazy stored properties alias BashToolRowView's internal surfaces.
    // Stored (not computed) so Mirror(reflecting: self).children finds them by name.

    // periphery:ignore - Mirror reflection in ToolTimelineRowModeDispatchTests
    private lazy var commandContainer: UIView = bashToolRowView.commandContainer
    // periphery:ignore - Mirror reflection in ToolTimelineRowModeDispatchTests
    private lazy var outputContainer: UIView = bashToolRowView.outputContainer
    // periphery:ignore - Mirror reflection in ToolTimelineRowModeDispatchTests
    private lazy var outputScrollView: HorizontalPanPassthroughScrollView = bashToolRowView.outputScrollView
    // periphery:ignore - selected-text delegate + ToolRowContentViewTests
    private lazy var commandLabel: UITextView = bashToolRowView.commandLabel
    // periphery:ignore - selected-text delegate
    private lazy var outputLabel: UITextView = bashToolRowView.outputLabel

    private var currentConfiguration: ToolTimelineRowConfiguration
    private var currentInteractionPolicy: ToolTimelineRowInteractionPolicy?
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
    var expandedRenderSignature: Int?
    private var expandedUsesViewport = false
    var expandedUsesMarkdownLayout = false
    var expandedUsesReadMediaLayout = false
    private var expandedReadMediaContentView: UIView?
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
    private let fullScreenTerminalStream: TerminalTraceStream
    private let fullScreenSourceStream: SourceTraceStream

    private lazy var commandDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleCommandDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var outputDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleOutputDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var expandedDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleExpandedDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var expandedPinchGesture: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleExpandedPinch(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    private lazy var commandSingleTapBlocker: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(ignoreTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.require(toFail: commandDoubleTapGesture)
        return recognizer
    }()

    private lazy var outputSingleTapBlocker: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(ignoreTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.require(toFail: outputDoubleTapGesture)
        return recognizer
    }()

    private lazy var expandedSingleTapBlocker: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(ignoreTap))
        recognizer.numberOfTapsRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.require(toFail: expandedDoubleTapGesture)
        return recognizer
    }()

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
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? ToolTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private var selectedTextPiRouter: SelectedTextPiActionRouter? {
        currentConfiguration.selectedTextPiRouter
    }

    private var selectedTextSessionId: String? {
        currentConfiguration.selectedTextSessionId
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

    override func layoutSubviews() {
        super.layoutSubviews()
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

    private func updateViewportHeightsIfNeeded() {
        let isStreaming = !currentConfiguration.isDone

        if bashToolRowView.outputUsesViewport,
           let outputViewportHeightConstraint = bashToolRowView.outputViewportHeightConstraint {
            let mode: ViewportMode = .output
            if isStreaming {
                outputViewportHeightConstraint.constant = streamingConstrainedHeight(for: mode)
            } else {
                outputViewportHeightConstraint.constant = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
                    cache: &bashToolRowView.outputViewportHeightCache,
                    signature: bashToolRowView.outputRenderSignature,
                    widthBucket: Int(bashToolRowView.outputContainer.bounds.width.rounded()),
                    mode: mode,
                    inputBytes: bashToolRowView.outputRenderedText?.utf8.count ?? 0,
                    profile: currentOutputViewportProfile,
                    availableHeight: availableViewportHeight(for: mode)
                ) {
                    self.preferredViewportHeight(
                        for: self.bashToolRowView.outputLabel,
                        in: self.bashToolRowView.outputContainer,
                        mode: mode
                    )
                }
            }
        }

        if expandedUsesViewport,
           let expandedViewportHeightConstraint {
            if isStreaming {
                let mode: ViewportMode = switch expandedViewportMode {
                case .diff: .expandedDiff
                case .code: .expandedCode
                case .text, .none: .expandedText
                }
                // Fixed viewport during streaming — only contentOffset moves inside.
                expandedViewportHeightConstraint.constant = streamingConstrainedHeight(for: mode)
            } else {
                let mode: ViewportMode = switch expandedViewportMode {
                case .diff: .expandedDiff
                case .code: .expandedCode
                case .text, .none: .expandedText
                }
                let expandedContentView = expandedUsesReadMediaLayout ? expandedReadMediaContainer
                    : (expandedUsesMarkdownLayout ? expandedMarkdownView : expandedLabel)
                let widthBucket = Int(expandedContainer.bounds.width.rounded())
                let signature = expandedRenderSignature

                let preferredHeight = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
                    cache: &expandedViewportHeightCache,
                    signature: signature,
                    widthBucket: widthBucket,
                    mode: mode,
                    inputBytes: expandedRenderedText?.utf8.count ?? 0,
                    profile: currentExpandedViewportProfile,
                    availableHeight: availableViewportHeight(for: mode)
                ) {
                    preferredViewportHeight(for: expandedContentView, in: expandedContainer, mode: mode)
                }

                expandedViewportHeightConstraint.constant = preferredHeight
            }
        }
    }

    /// Fixed streaming viewport height, clamped to the available screen space.
    private func streamingConstrainedHeight(for mode: ViewportMode) -> CGFloat {
        let available = availableViewportHeight(for: mode)
        return max(mode.minHeight, min(Self.streamingViewportHeight, available))
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
            metricMode: metricMode
        )
    }

    private func updateExpandedMarkdownWidthIfNeeded() {
        guard let expandedMarkdownWidthConstraint else { return }
        expandedMarkdownWidthConstraint.constant = -12
    }

    private func updateExpandedReadMediaWidthIfNeeded() {
        guard let expandedReadMediaWidthConstraint else { return }
        expandedReadMediaWidthConstraint.constant = -12
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

    private func availableViewportHeight(for mode: ViewportMode) -> CGFloat {
        let windowHeight = window?.bounds.height
            ?? superview?.bounds.height
            ?? max(bounds.height, 600)
        let safeInsets = window?.safeAreaInsets ?? .zero
        return max(
            mode.minHeight,
            windowHeight - safeInsets.top - safeInsets.bottom - mode.closeSafeAreaReserve
        )
    }

    private func preferredViewportHeight(
        for contentView: UIView,
        in container: UIView,
        mode: ViewportMode
    ) -> CGFloat {
        // Use the best width available: container > cell > window > 375.
        // Before the first layout pass bounds can be zero, which causes
        // text measurement at width 1px and wildly inflated heights.
        let cellWidth = bounds.width > 10
            ? bounds.width
            : (window?.bounds.width ?? 375)
        let fallbackContainerWidth = max(100, cellWidth - 16)
        let measuredContainerWidth = max(container.bounds.width, fallbackContainerWidth)

        // For diff/horizontal-scroll modes, measure at the label's actual
        // width (lines don't wrap). Using the container width would cause
        // text wrapping in the measurement, producing a height much taller
        // than the real rendered content.
        let width: CGFloat
        if mode == .expandedDiff || mode == .expandedCode,
           let widthConstraint = expandedLabelWidthConstraint,
           widthConstraint.constant > 1 {
            let frameWidth = expandedScrollView.bounds.width > 10
                ? expandedScrollView.bounds.width
                : measuredContainerWidth
            // Width constraint is relative to frameLayoutGuide width.
            width = max(1, frameWidth + widthConstraint.constant)
        } else if mode == .output,
                  bashToolRowView.outputUsesUnwrappedLayout,
                  let widthConstraint = bashToolRowView.outputLabelWidthConstraint,
                  widthConstraint.constant > 1 {
            let frameWidth = outputScrollView.bounds.width > 10
                ? outputScrollView.bounds.width
                : measuredContainerWidth
            width = max(1, frameWidth + widthConstraint.constant)
        } else {
            width = max(1, measuredContainerWidth - 12)
        }
        let contentHeight = measuredExpandedContentHeight(
            for: contentView,
            width: width
        )
        let windowHeight = window?.bounds.height
            ?? superview?.bounds.height
            ?? max(bounds.height, 600)
        let safeInsets = window?.safeAreaInsets ?? .zero
        let availableHeight = max(
            mode.minHeight,
            windowHeight - safeInsets.top - safeInsets.bottom - mode.closeSafeAreaReserve
        )
        let maxAllowed = min(mode.maxHeight, availableHeight)

        return min(maxAllowed, max(mode.minHeight, contentHeight))
    }

    private func measuredExpandedContentHeight(for contentView: UIView, width: CGFloat) -> CGFloat {
        if let label = contentView as? UILabel {
            let labelSize = label.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            return ceil(max(1, labelSize.height) + 10)
        }

        let contentSize = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingExpandedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(max(1, contentSize.height) + 10)
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

        // Coalesced invalidation defers the layout pass to the end of the
        // current runloop tick, so all synchronous changes from the enclosing
        // apply() settle before one single layoutIfNeeded fires.
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
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

        // Fixed container height prevents secondary cell-size jumps when image decode finishes.
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
            }
        }
    }

    private func clearExpandedReadMediaView() {
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
        // Reset the label width constraint from code/diff mode (required priority,
        // large constant) to the default wrapped-text state. The hidden label's
        // constraints still participate in layout and can force the shared
        // contentLayoutGuide wider than the markdown view expects, enabling
        // unintended horizontal scrolling and scroll-gesture conflicts.
        expandedLabelWidthConstraint?.priority = .defaultHigh
        expandedLabelWidthConstraint?.constant = -12
    }

    /// Prepare for embedded expanded content.
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
        // Reset the label width constraint from code/diff mode to prevent
        // the hidden label from dominating contentLayoutGuide width.
        expandedLabelWidthConstraint?.priority = .defaultHigh
        expandedLabelWidthConstraint?.constant = -12
        updateExpandedReadMediaWidthIfNeeded()
        setExpandedContainerGestureInterceptionEnabled(false)
    }

    /// Activate the expanded viewport height constraint.
    func showExpandedViewport() {
        expandedViewportHeightConstraint?.isActive = true
        expandedUsesViewport = true
    }

    /// Reset expanded container to hidden/default state.
    private func hideExpandedContainer(outputColor: UIColor) {
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
            trailingLabel: trailingLabel
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

        trailingStack.addArrangedSubview(addedLabel)
        trailingStack.addArrangedSubview(removedLabel)
        trailingStack.addArrangedSubview(trailingLabel)
        trailingStack.addArrangedSubview(languageBadgeIconView)

        NSLayoutConstraint.activate(
            ToolTimelineRowLayoutBuilder.makeLanguageBadgeConstraints(
                languageBadgeIconView: languageBadgeIconView
            )
        )

        expandedContainer.addSubview(expandedScrollView)
        expandedScrollView.addSubview(expandedSurfaceHostView)
        expandedSurfaceHostView.prepareSurfaceView(expandedLabel)
        expandedSurfaceHostView.prepareSurfaceView(expandedMarkdownView)
        expandedSurfaceHostView.prepareSurfaceView(expandedReadMediaContainer)
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
        let previousConfiguration = currentConfiguration
        let isExpandingTransition = !previousConfiguration.isExpanded && configuration.isExpanded
        currentConfiguration = configuration

        fullScreenTerminalStream.update(
            output: configuration.copyOutputText ?? "",
            command: configuration.copyCommandText,
            isDone: configuration.isDone
        )

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
        ToolTimelineRowDisplayState.updateTrailingVisibility(
            trailingStack: trailingStack,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel
        )

        let showPreview = ToolTimelineRowDisplayState.applyPreview(
            configuration: configuration,
            previewLabel: previewLabel
        )

        // Collapsed image thumbnail for read tool image files
        applyImagePreview(configuration: configuration)

        let outputColor = configuration.isError ? UIColor(Color.themeRed) : UIColor(Color.themeFg)
        let renderPlan = ToolRowPlanBuilder.build(configuration: configuration)
        let wasExpandedVisible = !expandedContainer.isHidden
        let wasCommandVisible = !commandContainer.isHidden
        let wasOutputVisible = !outputContainer.isHidden

        // Reset follow-tail flags; render strategies will set them if needed.
        expandedNeedsFollowTail = false

        // Reset gesture interception (specific cases disable it below)
        setExpandedContainerGestureInterceptionEnabled(true)
        currentInteractionPolicy = renderPlan.interactionPolicy
        updateFullScreenSourceStream(configuration: configuration)

        var showExpandedContainer = false
        var showCommandContainer = false
        var showOutputContainer = false
        var activeExpandedContent: ToolPresentationBuilder.ToolExpandedContent?

        if configuration.isExpanded, let expandedContent = configuration.expandedContent {
            activeExpandedContent = expandedContent

            if case .bash(let command, let output, let unwrapped) = expandedContent {
                // Bash mode: uses command/output containers, not expanded container.
                cancelDeferredCodeHighlight()
                hideExpandedContainer(outputColor: outputColor)

                let input = BashRenderInput(
                    command: command,
                    output: output,
                    unwrapped: unwrapped,
                    isError: configuration.isError,
                    isStreaming: !configuration.isDone
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

                showCommandContainer = result.showCommand
                showOutputContainer = result.showOutput
            } else {
                // All non-bash modes use the expanded container.
                let output = makeExpandedRenderOutput(
                    expandedContent: expandedContent,
                    configuration: configuration,
                    renderPlan: renderPlan,
                    outputColor: outputColor,
                    wasExpandedVisible: wasExpandedVisible
                )
                applyExpandedRenderOutput(output)
                showExpandedContainer = true
            }
        }

        // Hide containers that aren't needed by the active content
        if !showExpandedContainer {
            hideExpandedContainer(outputColor: outputColor)
        }
        ToolTimelineRowDisplayState.applyContainerVisibility(
            expandedContainer,
            shouldShow: showExpandedContainer,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasExpandedVisible
        )

        if !showCommandContainer {
            bashToolRowView.resetCommandState()
        }
        ToolTimelineRowDisplayState.applyContainerVisibility(
            commandContainer,
            shouldShow: showCommandContainer,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasCommandVisible
        )

        if !showOutputContainer {
            // resetOutputState() resets contentOffset, which synchronously triggers
            // scrollViewDidScroll inside BashToolRowView — no exclusivity hazard
            // since all state is now internal to BashToolRowView.
            bashToolRowView.resetOutputState(outputColor: outputColor)
            bashToolRowView.updateOutputLabelWidthIfNeeded()
            outputScrollView.isScrollEnabled = false
            bashToolRowView.setOutputVerticalLockEnabled(false)
        }
        // Also hide the bash container when neither command nor output shows.
        bashToolRowView.isHidden = !showCommandContainer && !showOutputContainer
        ToolTimelineRowDisplayState.applyContainerVisibility(
            outputContainer,
            shouldShow: showOutputContainer,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasOutputVisible
        )

        if let policy = currentInteractionPolicy,
           showExpandedContainer || showOutputContainer {
            applyInteractionPolicy(
                policy,
                spec: renderPlan.interactionSpec,
                showOutputContainer: showOutputContainer
            )
        } else {
            setExpandedContainerGestureInterceptionEnabled(true)
            expandedScrollView.isScrollEnabled = false
            outputScrollView.isScrollEnabled = false
        }

        updateSelectedTextIntegration(
            plan: renderPlan,
            showCommandContainer: showCommandContainer,
            showOutputContainer: showOutputContainer,
            showExpandedContainer: showExpandedContainer,
            expandedContent: activeExpandedContent
        )

        let showImagePreview = !imagePreviewContainer.isHidden
        let showBody = showPreview || showImagePreview || showExpandedContainer || showCommandContainer || showOutputContainer
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody
        updateViewportHeightsIfNeeded()

        if isExpandingTransition, showExpandedContainer || showOutputContainer {
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
        }

        // Drive auto-scroll after containers are visible and have valid bounds.
        flushPendingFollowTail()

        ToolTimelineRowDisplayState.applyStatusAppearance(
            isDone: configuration.isDone,
            isError: configuration.isError,
            statusImageView: statusImageView,
            borderView: borderView
        )
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
                wasExpandedVisible: wasExpandedVisible
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
                wasExpandedVisible: wasExpandedVisible
            )

        case .markdown(let text):
            let markdownSelectionEnabled = renderPlan.interactionSpec.markdownSelectionEnabled
            return ToolRowMarkdownRenderStrategy.render(
                text: text,
                isStreaming: isStreaming,
                expandedMarkdownView: expandedMarkdownView,
                expandedScrollView: expandedScrollView,
                previousSignature: expandedRenderSignature,
                previousRenderedText: expandedRenderedText,
                previousAutoFollow: expandedShouldAutoFollow,
                wasExpandedVisible: wasExpandedVisible,
                isUsingMarkdownLayout: expandedUsesMarkdownLayout,
                selectedTextPiRouter: markdownSelectionEnabled ? selectedTextPiRouter : nil,
                selectedTextSourceContext: markdownSelectionEnabled
                    ? selectedTextSessionId.flatMap { sessionId in
                        ToolTimelineRowSelectedTextSupport.sourceContext(
                            surface: .expandedMarkdown,
                            expandedContent: .markdown(text: text),
                            sessionId: sessionId,
                            sourceLabel: configuration.title,
                            expandedLabelText: nil
                        )
                    }
                    : nil,
                textSelectionEnabled: markdownSelectionEnabled
            )

        case .plot(let spec, let fallbackText):
            return ToolRowPlotRenderStrategy.render(
                spec: spec,
                fallbackText: fallbackText,
                previousSignature: expandedRenderSignature,
                isUsingReadMediaLayout: expandedUsesReadMediaLayout,
                hasExpandedPlotContentView: expandedReadMediaContentView is NativeExpandedPlotView
            )

        case .readMedia(let output, let filePath, let startLine):
            return ToolRowReadMediaRenderStrategy.render(
                output: output,
                filePath: filePath,
                startLine: startLine,
                isError: configuration.isError,
                previousSignature: expandedRenderSignature,
                isUsingReadMediaLayout: expandedUsesReadMediaLayout,
                hasExpandedReadMediaContentView: expandedReadMediaContentView != nil
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
                isUsingReadMediaLayout: expandedUsesReadMediaLayout
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
                isUsingReadMediaLayout: expandedUsesReadMediaLayout
            )
        }
    }

    private func applyExpandedRenderOutput(_ output: ExpandedRenderOutput) {
        // Execute view-installation intent before surface switch so the
        // hosted view is in the hierarchy when showExpandedHostedView() runs.
        switch output.installAction {
        case .none:
            break
        case .plot(let spec, let fallbackText):
            installExpandedPlotView(spec: spec, fallbackText: fallbackText)
        case .readMedia(let mediaOutput, let isError, let filePath, let startLine):
            installExpandedReadMediaView(output: mediaOutput, isError: isError, filePath: filePath, startLine: startLine)
        }

        switch output.surface {
        case .label:     showExpandedLabel()
        case .markdown:  showExpandedMarkdown()
        case .hostedView: showExpandedHostedView()
        }

        expandedRenderSignature = output.renderSignature
        expandedRenderedText = output.renderedText
        expandedShouldAutoFollow = output.shouldAutoFollow
        expandedViewportMode = output.viewportMode

        expandedLabel.textContainer.lineBreakMode = output.lineBreakMode
        expandedScrollView.alwaysBounceHorizontal = output.horizontalScroll
        expandedScrollView.showsHorizontalScrollIndicator = output.horizontalScroll

        setExpandedVerticalLockEnabled(output.verticalLock)
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()

        if let deferred = output.deferredHighlight {
            scheduleDeferredCodeHighlightIfNeeded(deferred)
        } else {
            cancelDeferredCodeHighlight()
        }

        switch output.scrollBehavior {
        case .followTail: scheduleExpandedAutoScrollToBottomIfNeeded()
        case .resetToTop: ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
        case .preserve: break
        }

        if output.invalidateLayout {
            setNeedsLayout()
            ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
        }
    }

    private func updateSelectedTextIntegration(
        plan: ToolRowRenderPlan,
        showCommandContainer: Bool,
        showOutputContainer: Bool,
        showExpandedContainer: Bool,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent?
    ) {
        let hasSession = selectedTextPiRouter != nil && selectedTextSessionId != nil
        let hasExpandedContext = hasSession && {
            guard let sessionId = selectedTextSessionId else { return false }
            return ToolTimelineRowSelectedTextSupport.sourceContext(
                surface: .expandedLabel,
                expandedContent: expandedContent,
                sessionId: sessionId,
                sourceLabel: currentConfiguration.title,
                expandedLabelText: expandedLabel.text ?? expandedLabel.attributedText?.string
            ) != nil
        }()

        let flags = ToolTimelineRowSelectedTextSupport.selectionFlags(
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

    private func resolveSelectedTextSourceContext(for textView: UITextView) -> SelectedTextSourceContext? {
        guard let sessionId = selectedTextSessionId,
              selectedTextPiRouter != nil else {
            return nil
        }
        let surface: ToolTimelineRowSelectedTextSupport.Surface
        if textView === commandLabel { surface = .command } else if textView === outputLabel { surface = .output } else if textView === expandedLabel { surface = .expandedLabel } else { return nil }
        return ToolTimelineRowSelectedTextSupport.sourceContext(
            surface: surface,
            expandedContent: currentConfiguration.expandedContent,
            sessionId: sessionId,
            sourceLabel: currentConfiguration.title,
            expandedLabelText: expandedLabel.text ?? expandedLabel.attributedText?.string
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
        expandedDoubleTapGesture.isEnabled && expandedSingleTapBlocker.isEnabled
    }

    // periphery:ignore - used by ToolExpandedSurfaceHostTests via @testable import
    var activeExpandedSurfaceKindForTesting: ActiveExpandedSurfaceKindForTesting {
        switch expandedSurfaceHostView.activeView {
        case expandedLabel:
            .label
        case expandedMarkdownView:
            .markdown
        case expandedReadMediaContainer:
            .hosted
        default:
            .none
        }
    }
    #endif

    @objc private func ignoreTap() {
        // Intentionally empty: consumes single taps inside copy-target areas so
        // collection-view row selection does not interfere with copy gestures.
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
            finalContent = nil
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
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSessionId,
            selectedTextSourceLabel: currentConfiguration.title
        )
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
            },
            onOpenFullScreenContent: { [weak self] in
                self?.showFullScreenContent()
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // outputScrollView scroll events are handled by BashToolRowView (its own delegate).
        if scrollView === expandedScrollView {
            if expandedLabelHeightLockConstraint?.isActive == true {
                let lockedY = -expandedScrollView.adjustedContentInset.top
                if abs(expandedScrollView.contentOffset.y - lockedY) > 0.5 {
                    expandedScrollView.contentOffset.y = lockedY
                }
            }
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
        SelectedTextPiEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: resolveSelectedTextSourceContext(for: textView)
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
