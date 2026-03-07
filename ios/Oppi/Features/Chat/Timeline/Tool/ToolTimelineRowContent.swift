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
    private static let minOutputViewportHeight: CGFloat = 56
    private static let minDiffViewportHeight: CGFloat = 68
    private static let maxOutputViewportHeight: CGFloat = 620
    private static let maxDiffViewportHeight: CGFloat = 760
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
    private let commandContainer = UIView()
    private let commandLabel = UITextView()
    let outputContainer = UIView()
    private let outputScrollView = HorizontalPanPassthroughScrollView()
    private let outputLabel = UITextView()
    let expandedContainer = UIView()
    let expandedScrollView = HorizontalPanPassthroughScrollView()
    private let expandedSurfaceHostView = ToolExpandedSurfaceHostView()
    let expandedLabel = UITextView()
    private let expandedMarkdownView = AssistantMarkdownContentView()
    private let expandedReadMediaContainer = UIView()
    private let imagePreviewContainer = UIView()
    private let imagePreviewImageView = UIImageView()
    private let borderView = UIView()

    private var currentConfiguration: ToolTimelineRowConfiguration
    private var currentInteractionPolicy: ToolTimelineRowInteractionPolicy?
    private var bodyStackCollapsedHeightConstraint: NSLayoutConstraint?
    private var outputViewportHeightConstraint: NSLayoutConstraint?
    private var outputLabelWidthConstraint: NSLayoutConstraint?
    private var outputLabelHeightLockConstraint: NSLayoutConstraint?
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
    private var outputShouldAutoFollow = true
    var expandedShouldAutoFollow = true
    private var outputUsesViewport = false
    private var outputUsesUnwrappedLayout = false
    var outputRenderedText: String? {
        didSet { outputWidthEstimateCache.invalidate(); outputViewportHeightCache.invalidate() }
    }
    private var commandRenderSignature: Int?
    var outputRenderSignature: Int?
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
    private var outputWidthEstimateCache = ToolTimelineRowWidthEstimateCache()
    private var expandedWidthEstimateCache = ToolTimelineRowWidthEstimateCache()
    private var outputViewportHeightCache = ToolTimelineRowViewportHeightCache()
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
        updateOutputLabelWidthIfNeeded()
        updateExpandedLabelWidthIfNeeded()
        updateExpandedMarkdownWidthIfNeeded()
        updateExpandedReadMediaWidthIfNeeded()
        updateViewportHeightsIfNeeded()
        ToolTimelineRowUIHelpers.clampScrollOffsetIfNeeded(outputScrollView)
        ToolTimelineRowUIHelpers.clampScrollOffsetIfNeeded(expandedScrollView)
    }

    private func updateViewportHeightsIfNeeded() {
        if outputUsesViewport,
           let outputViewportHeightConstraint {
            let mode: ViewportMode = .output
            outputViewportHeightConstraint.constant = ToolTimelineRowLayoutPerformance.resolveViewportHeight(
                cache: &outputViewportHeightCache,
                signature: outputRenderSignature,
                widthBucket: Int(outputContainer.bounds.width.rounded()),
                mode: mode,
                inputBytes: outputRenderedText?.utf8.count ?? 0,
                profile: currentOutputViewportProfile,
                availableHeight: availableViewportHeight(for: mode)
            ) {
                preferredViewportHeight(for: outputLabel, in: outputContainer, mode: mode)
            }
        }

        if expandedUsesViewport,
           let expandedViewportHeightConstraint {
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

    private func updateOutputLabelWidthIfNeeded() {
        guard let outputLabelWidthConstraint else { return }

        if outputUsesUnwrappedLayout,
           let outputRenderedText {
            outputLabelWidthConstraint.priority = .required
            outputLabelWidthConstraint.constant = outputLabelWidthConstant(for: outputRenderedText)
        } else {
            // First self-sizing pass can see frameLayoutGuide width=0.
            // Keep wrapped-text width at high (not required) priority so
            // systemLayoutSizeFitting can inject a temporary fitting width.
            outputLabelWidthConstraint.priority = .defaultHigh
            outputLabelWidthConstraint.constant = -12
        }
    }

    private func outputLabelWidthConstant(for renderedText: String) -> CGFloat {
        ToolTimelineRowLayoutPerformance.monospaceWidthConstant(
            frameWidth: max(1, outputScrollView.bounds.width),
            renderedText: renderedText,
            cache: &outputWidthEstimateCache,
            metricMode: "output"
        )
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

    private func setOutputVerticalLockEnabled(_ enabled: Bool) {
        outputLabelHeightLockConstraint?.isActive = enabled
    }

    func setExpandedVerticalLockEnabled(_ enabled: Bool) {
        expandedLabelHeightLockConstraint?.isActive = enabled
    }

    private var currentOutputViewportProfile: ToolTimelineRowViewportProfile? {
        guard outputUsesViewport else { return nil }
        return ToolTimelineRowViewportProfile(kind: .bashOutput, text: outputRenderedText)
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
                  outputUsesUnwrappedLayout,
                  let widthConstraint = outputLabelWidthConstraint,
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

        // Ensure first-pass sizing converges before the collection view's next
        // self-sizing cycle (important for hosted + async media paths).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsLayout()
            self.layoutIfNeeded()
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
        ToolTimelineRowViewStyler.styleCommand(
            commandContainer: commandContainer,
            commandLabel: commandLabel
        )
        ToolTimelineRowViewStyler.styleOutput(
            outputContainer: outputContainer,
            outputScrollView: outputScrollView,
            outputLabel: outputLabel,
            delegate: self
        )
        ToolTimelineRowViewStyler.styleExpanded(
            expandedContainer: expandedContainer,
            expandedScrollView: expandedScrollView,
            expandedLabel: expandedLabel,
            expandedMarkdownView: expandedMarkdownView,
            expandedReadMediaContainer: expandedReadMediaContainer,
            delegate: self
        )

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

        trailingStack.addArrangedSubview(languageBadgeIconView)
        trailingStack.addArrangedSubview(addedLabel)
        trailingStack.addArrangedSubview(removedLabel)
        trailingStack.addArrangedSubview(trailingLabel)

        NSLayoutConstraint.activate(
            ToolTimelineRowLayoutBuilder.makeLanguageBadgeConstraints(
                languageBadgeIconView: languageBadgeIconView
            )
        )

        commandContainer.addSubview(commandLabel)
        outputContainer.addSubview(outputScrollView)
        outputScrollView.addSubview(outputLabel)
        expandedContainer.addSubview(expandedScrollView)
        expandedScrollView.addSubview(expandedSurfaceHostView)
        expandedSurfaceHostView.prepareSurfaceView(expandedLabel)
        expandedSurfaceHostView.prepareSurfaceView(expandedMarkdownView)
        expandedSurfaceHostView.prepareSurfaceView(expandedReadMediaContainer)
        bodyStack.addArrangedSubview(previewLabel)
        bodyStack.addArrangedSubview(imagePreviewContainer)
        bodyStack.addArrangedSubview(commandContainer)
        bodyStack.addArrangedSubview(outputContainer)
        bodyStack.addArrangedSubview(expandedContainer)

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
            commandContainer: commandContainer,
            commandLabel: commandLabel,
            outputContainer: outputContainer,
            outputScrollView: outputScrollView,
            outputLabel: outputLabel,
            expandedContainer: expandedContainer,
            expandedScrollView: expandedScrollView,
            expandedSurfaceHostView: expandedSurfaceHostView,
            expandedLabel: expandedLabel,
            expandedMarkdownView: expandedMarkdownView,
            expandedReadMediaContainer: expandedReadMediaContainer,
            imagePreviewContainer: imagePreviewContainer,
            imagePreviewImageView: imagePreviewImageView,
            minOutputViewportHeight: Self.minOutputViewportHeight,
            minDiffViewportHeight: Self.minDiffViewportHeight,
            collapsedImagePreviewHeight: Self.collapsedImagePreviewHeight
        )

        toolLeadingConstraint = layout.toolLeading
        toolWidthConstraint = layout.toolWidth
        titleLeadingToStatusConstraint = layout.titleLeadingToStatus
        titleLeadingToToolConstraint = layout.titleLeadingToTool
        outputLabelWidthConstraint = layout.outputLabelWidth
        outputLabelHeightLockConstraint = layout.outputLabelHeightLock
        expandedLabelWidthConstraint = layout.expandedLabelWidth
        expandedLabelHeightLockConstraint = layout.expandedLabelHeightLock
        expandedMarkdownWidthConstraint = layout.expandedMarkdownWidth
        expandedReadMediaWidthConstraint = layout.expandedReadMediaWidth
        imagePreviewHeightConstraint = layout.imagePreviewHeight
        outputViewportHeightConstraint = layout.outputViewportHeight
        expandedViewportHeightConstraint = layout.expandedViewportHeight

        // During the first self-sizing measurement pass, scroll view frame
        // layout guides can still report width=0. Keep markdown/hosted width
        // constraints below required priority so systemLayoutSizeFitting can
        // provide a temporary fitting width instead of measuring at 0px.
        expandedMarkdownWidthConstraint?.priority = .defaultHigh
        expandedReadMediaWidthConstraint?.priority = .defaultHigh

        NSLayoutConstraint.activate(layout.all)
    }

    private typealias ExpandedRenderVisibility = ToolRowRenderVisibility

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
            let visibility = ToolTimelineRowExpandedModeRouter.route(
                expandedContent: expandedContent,
                renderBash: { command, output, unwrapped in
                    self.renderExpandedBashMode(
                        command: command,
                        output: output,
                        unwrapped: unwrapped,
                        configuration: configuration,
                        outputColor: outputColor,
                        wasOutputVisible: wasOutputVisible
                    )
                },
                renderDiff: { lines, path in
                    self.renderExpandedDiffMode(
                        lines: lines,
                        path: path,
                        isStreaming: !configuration.isDone,
                        wasExpandedVisible: wasExpandedVisible
                    )
                },
                renderCode: { text, language, startLine in
                    self.renderExpandedCodeMode(
                        text: text,
                        language: language,
                        startLine: startLine,
                        isStreaming: !configuration.isDone,
                        wasExpandedVisible: wasExpandedVisible
                    )
                },
                renderMarkdown: { text in
                    self.renderExpandedMarkdownMode(
                        text: text,
                        isStreaming: !configuration.isDone,
                        wasExpandedVisible: wasExpandedVisible,
                        isDone: configuration.isDone,
                        markdownSelectionEnabled: renderPlan.interactionSpec.markdownSelectionEnabled
                    )
                },
                renderPlot: { spec, fallbackText in
                    self.renderExpandedPlotMode(spec: spec, fallbackText: fallbackText)
                },
                renderReadMedia: { output, filePath, startLine in
                    self.renderExpandedReadMediaMode(
                        output: output,
                        filePath: filePath,
                        startLine: startLine,
                        isError: configuration.isError
                    )
                },
                renderText: { text, language in
                    self.renderExpandedTextMode(
                        text: text,
                        language: language,
                        configuration: configuration,
                        outputColor: outputColor,
                        wasExpandedVisible: wasExpandedVisible
                    )
                }
            )

            showExpandedContainer = visibility.showExpandedContainer
            showCommandContainer = visibility.showCommandContainer
            showOutputContainer = visibility.showOutputContainer
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
            ToolTimelineRowDisplayState.resetCommandState(
                commandLabel: commandLabel,
                commandRenderSignature: &commandRenderSignature
            )
        }
        ToolTimelineRowDisplayState.applyContainerVisibility(
            commandContainer,
            shouldShow: showCommandContainer,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasCommandVisible
        )

        if !showOutputContainer {
            // Do not pass stored properties by `inout` directly here.
            // resetOutputState() programmatically updates contentOffset, which
            // synchronously triggers scrollViewDidScroll and can re-enter
            // outputShouldAutoFollow mutation while inout access is active.
            var localOutputUsesUnwrappedLayout = outputUsesUnwrappedLayout
            var localOutputRenderedText = outputRenderedText
            var localOutputRenderSignature = outputRenderSignature
            var localOutputUsesViewport = outputUsesViewport
            var localOutputShouldAutoFollow = outputShouldAutoFollow

            ToolTimelineRowDisplayState.resetOutputState(
                outputLabel: outputLabel,
                outputScrollView: outputScrollView,
                outputViewportHeightConstraint: outputViewportHeightConstraint,
                outputColor: outputColor,
                outputUsesUnwrappedLayout: &localOutputUsesUnwrappedLayout,
                outputRenderedText: &localOutputRenderedText,
                outputRenderSignature: &localOutputRenderSignature,
                outputUsesViewport: &localOutputUsesViewport,
                outputShouldAutoFollow: &localOutputShouldAutoFollow
            )

            outputUsesUnwrappedLayout = localOutputUsesUnwrappedLayout
            outputRenderedText = localOutputRenderedText
            outputRenderSignature = localOutputRenderSignature
            outputUsesViewport = localOutputUsesViewport
            outputShouldAutoFollow = localOutputShouldAutoFollow

            updateOutputLabelWidthIfNeeded()
            outputScrollView.isScrollEnabled = false
            setOutputVerticalLockEnabled(false)
        }
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
            }
        }

        ToolTimelineRowDisplayState.applyStatusAppearance(
            isDone: configuration.isDone,
            isError: configuration.isError,
            statusImageView: statusImageView,
            borderView: borderView
        )
    }

    private func renderExpandedBashMode(
        command: String?,
        output: String?,
        unwrapped: Bool,
        configuration: ToolTimelineRowConfiguration,
        outputColor: UIColor,
        wasOutputVisible: Bool
    ) -> ExpandedRenderVisibility {
        cancelDeferredCodeHighlight()

        var localCommandRenderSignature = commandRenderSignature
        var localOutputRenderSignature = outputRenderSignature
        var localOutputRenderedText = outputRenderedText
        var localOutputUsesUnwrappedLayout = outputUsesUnwrappedLayout
        var localOutputUsesViewport = outputUsesViewport
        var localOutputShouldAutoFollow = outputShouldAutoFollow
        var outputDidTextChange = false

        let visibility = ToolRowBashRenderStrategy.render(
            command: command,
            output: output,
            unwrapped: unwrapped,
            isError: configuration.isError,
            isStreaming: !configuration.isDone,
            outputColor: outputColor,
            commandTextColor: UIColor(Color.themeFg),
            wasOutputVisible: wasOutputVisible,
            commandLabel: commandLabel,
            outputLabel: outputLabel,
            outputScrollView: outputScrollView,
            commandRenderSignature: &localCommandRenderSignature,
            outputRenderSignature: &localOutputRenderSignature,
            outputRenderedText: &localOutputRenderedText,
            outputUsesUnwrappedLayout: &localOutputUsesUnwrappedLayout,
            outputUsesViewport: &localOutputUsesViewport,
            outputShouldAutoFollow: &localOutputShouldAutoFollow,
            outputDidTextChange: &outputDidTextChange,
            outputViewportHeightConstraint: outputViewportHeightConstraint,
            hideExpandedContainer: { self.hideExpandedContainer(outputColor: outputColor) }
        )

        commandRenderSignature = localCommandRenderSignature
        outputRenderSignature = localOutputRenderSignature
        outputRenderedText = localOutputRenderedText
        outputUsesUnwrappedLayout = localOutputUsesUnwrappedLayout
        outputUsesViewport = localOutputUsesViewport
        outputShouldAutoFollow = localOutputShouldAutoFollow

        if visibility.showOutputContainer {
            setOutputVerticalLockEnabled(localOutputUsesUnwrappedLayout)
            updateOutputLabelWidthIfNeeded()
        } else {
            setOutputVerticalLockEnabled(false)
        }
        if outputDidTextChange {
            scheduleOutputAutoScrollToBottomIfNeeded()
        }

        return visibility
    }

    private func renderExpandedDiffMode(
        lines: [DiffLine],
        path: String?,
        isStreaming: Bool,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderVisibility {
        cancelDeferredCodeHighlight()

        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolRowDiffRenderStrategy.render(
            lines: lines,
            path: path,
            isStreaming: isStreaming,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isCurrentModeDiff: expandedViewportMode == .diff,
            wasExpandedVisible: wasExpandedVisible,
            showExpandedLabel: showExpandedLabel,
            setModeDiff: { self.expandedViewportMode = .diff },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow

        if visibility.showExpandedContainer {
            setExpandedVerticalLockEnabled(true)
            updateExpandedLabelWidthIfNeeded()
        }

        return visibility
    }

    private func renderExpandedMarkdownMode(
        text: String,
        isStreaming: Bool,
        wasExpandedVisible: Bool,
        isDone: Bool,
        markdownSelectionEnabled: Bool
    ) -> ExpandedRenderVisibility {
        cancelDeferredCodeHighlight()

        let previousExpandedRenderSignature = expandedRenderSignature
        let wasUsingMarkdownLayout = expandedUsesMarkdownLayout

        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolRowMarkdownRenderStrategy.render(
            text: text,
            isStreaming: isStreaming,
            expandedMarkdownView: expandedMarkdownView,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            wasExpandedVisible: wasExpandedVisible,
            isUsingMarkdownLayout: expandedUsesMarkdownLayout,
            shouldAutoFollowOnFirstRender: !isDone,
            selectedTextPiRouter: markdownSelectionEnabled ? selectedTextPiRouter : nil,
            selectedTextSourceContext: markdownSelectionEnabled
                ? expandedMarkdownSelectedTextSourceContext(for: .markdown(text: text))
                : nil,
            textSelectionEnabled: markdownSelectionEnabled,
            showExpandedMarkdown: showExpandedMarkdown,
            setModeText: { self.expandedViewportMode = .text },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow
        setExpandedVerticalLockEnabled(false)

        let didRerenderMarkdown = localExpandedRenderSignature != previousExpandedRenderSignature
        let didEnterMarkdownLayout = !wasUsingMarkdownLayout && expandedUsesMarkdownLayout

        // Markdown subviews are added synchronously but Auto Layout hasn't
        // measured them yet when preferredViewportHeight runs in the same
        // cycle. Defer one layout invalidation only when markdown content
        // actually changed (or mode switched into markdown). Re-invalidating
        // every apply causes avoidable mid-gesture reflows and scroll snapback.
        if didRerenderMarkdown || didEnterMarkdownLayout {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setNeedsLayout()
                self.layoutIfNeeded()
                ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
            }
        }

        return visibility
    }

    private func renderExpandedPlotMode(
        spec: PlotChartSpec,
        fallbackText: String?
    ) -> ExpandedRenderVisibility {
        cancelDeferredCodeHighlight()

        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolRowPlotRenderStrategy.render(
            spec: spec,
            fallbackText: fallbackText,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isUsingReadMediaLayout: expandedUsesReadMediaLayout,
            hasExpandedPlotContentView: expandedReadMediaContentView is NativeExpandedPlotView,
            showExpandedHostedView: showExpandedHostedView,
            installExpandedPlotView: installExpandedPlotView(spec:fallbackText:),
            setModeText: { self.expandedViewportMode = .text },
            showExpandedViewport: showExpandedViewport
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow
        setExpandedVerticalLockEnabled(false)

        return visibility
    }

    private func renderExpandedReadMediaMode(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool
    ) -> ExpandedRenderVisibility {
        cancelDeferredCodeHighlight()

        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolRowReadMediaRenderStrategy.render(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isUsingReadMediaLayout: expandedUsesReadMediaLayout,
            hasExpandedReadMediaContentView: expandedReadMediaContentView != nil,
            showExpandedHostedView: showExpandedHostedView,
            installExpandedReadMediaView: installExpandedReadMediaView(output:isError:filePath:startLine:),
            setModeText: { self.expandedViewportMode = .text },
            showExpandedViewport: showExpandedViewport
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow
        setExpandedVerticalLockEnabled(false)

        return visibility
    }

    private func renderExpandedTextMode(
        text: String,
        language: SyntaxLanguage?,
        configuration: ToolTimelineRowConfiguration,
        outputColor: UIColor,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderVisibility {
        cancelDeferredCodeHighlight()

        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolRowTextRenderStrategy.render(
            text: text,
            language: language,
            isError: configuration.isError,
            isStreaming: !configuration.isDone,
            outputColor: outputColor,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            wasExpandedVisible: wasExpandedVisible,
            isCurrentModeText: expandedViewportMode == .text,
            isUsingMarkdownLayout: expandedUsesMarkdownLayout,
            isUsingReadMediaLayout: expandedUsesReadMediaLayout,
            shouldAutoFollowOnFirstRender: !configuration.isDone,
            showExpandedLabel: showExpandedLabel,
            setModeText: { self.expandedViewportMode = .text },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow
        setExpandedVerticalLockEnabled(false)

        return visibility
    }

    private func updateSelectedTextIntegration(
        plan: ToolRowRenderPlan,
        showCommandContainer: Bool,
        showOutputContainer: Bool,
        showExpandedContainer: Bool,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent?
    ) {
        let commandSelectionEnabled = showCommandContainer
            && plan.interactionSpec.commandSelectionEnabled
            && selectedTextSourceContext(for: commandLabel, expandedContent: expandedContent) != nil
        commandLabel.isSelectable = commandSelectionEnabled
        commandDoubleTapGesture.isEnabled = !commandSelectionEnabled
        commandSingleTapBlocker.isEnabled = !commandSelectionEnabled

        let outputSelectionEnabled = showOutputContainer
            && plan.interactionSpec.outputSelectionEnabled
            && selectedTextSourceContext(for: outputLabel, expandedContent: expandedContent) != nil
        outputLabel.isSelectable = outputSelectionEnabled
        outputDoubleTapGesture.isEnabled = !outputSelectionEnabled
        outputSingleTapBlocker.isEnabled = !outputSelectionEnabled

        let expandedSelectionEnabled = showExpandedContainer
            && !expandedUsesReadMediaLayout
            && plan.interactionSpec.expandedLabelSelectionEnabled
            && selectedTextSourceContext(for: expandedLabel, expandedContent: expandedContent) != nil
        expandedLabel.isSelectable = expandedSelectionEnabled

        let markdownSelectionEnabled = showExpandedContainer
            && expandedUsesMarkdownLayout
            && plan.interactionSpec.markdownSelectionEnabled
            && selectedTextPiRouter != nil
            && selectedTextSessionId != nil

        if markdownSelectionEnabled || expandedSelectionEnabled {
            setExpandedContainerTapCopyGestureEnabled(false)
            expandedPinchGesture.isEnabled = false
        }
    }

    private func selectedTextSourceContext(
        for textView: UITextView,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent? = nil
    ) -> SelectedTextSourceContext? {
        guard selectedTextPiRouter != nil,
              let sessionId = selectedTextSessionId else {
            return nil
        }

        if textView === commandLabel {
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolCommand,
                sourceLabel: currentConfiguration.title
            )
        }

        if textView === outputLabel {
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolOutput,
                sourceLabel: currentConfiguration.title
            )
        }

        guard textView === expandedLabel,
              let expandedContent else {
            return nil
        }

        switch expandedContent {
        case .code(_, let language, let startLine, let filePath):
            let lineRange: ClosedRange<Int>?
            if let startLine {
                let lineCount = max(1, (expandedLabel.text ?? expandedLabel.attributedText?.string ?? "").components(separatedBy: "\n").count)
                lineRange = startLine...(startLine + lineCount - 1)
            } else {
                lineRange = nil
            }
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: currentConfiguration.title,
                filePath: filePath,
                lineRange: lineRange,
                languageHint: language?.displayName
            )

        case .diff(_, let path):
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: currentConfiguration.title,
                filePath: path
            )

        case .text(_, let language):
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: currentConfiguration.title,
                languageHint: language?.displayName
            )

        case .bash, .markdown, .plot, .readMedia:
            return nil
        }
    }

    private func expandedMarkdownSelectedTextSourceContext(
        for content: ToolPresentationBuilder.ToolExpandedContent
    ) -> SelectedTextSourceContext? {
        guard selectedTextPiRouter != nil,
              let sessionId = selectedTextSessionId else {
            return nil
        }

        guard case .markdown = content else { return nil }
        return SelectedTextSourceContext(
            sessionId: sessionId,
            surface: .toolExpandedText,
            sourceLabel: currentConfiguration.title
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
            setOutputVerticalLockEnabled(unwrapped)
        } else {
            outputScrollView.isScrollEnabled = false
            setOutputVerticalLockEnabled(false)
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
        copy(text: text, feedbackView: commandContainer)
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

    private func scheduleOutputAutoScrollToBottomIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.outputShouldAutoFollow,
                  !self.outputContainer.isHidden else {
                return
            }
            ToolTimelineRowUIHelpers.scrollToBottom(self.outputScrollView, animated: false)
        }
    }

    func scheduleExpandedAutoScrollToBottomIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.expandedShouldAutoFollow,
                  !self.expandedContainer.isHidden else {
                return
            }
            ToolTimelineRowUIHelpers.scrollToBottom(self.expandedScrollView, animated: false)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === outputScrollView {
            if outputLabelHeightLockConstraint?.isActive == true {
                let lockedY = -outputScrollView.adjustedContentInset.top
                if abs(outputScrollView.contentOffset.y - lockedY) > 0.5 {
                    outputScrollView.contentOffset.y = lockedY
                }
            }
            outputShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(outputScrollView)
        } else if scrollView === expandedScrollView {
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
            sourceContext: selectedTextSourceContext(for: textView, expandedContent: currentConfiguration.expandedContent)
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
