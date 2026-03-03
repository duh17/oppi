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

    func makeContentView() -> any UIView & UIContentView {
        ToolTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
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
    private static let fullScreenOverflowThreshold: CGFloat = 2

    @MainActor
    private enum ExpandedViewportMode {
        case none
        case diff
        case code
        case text
    }

    @MainActor
    private enum ViewportMode {
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
    private let commandLabel = UILabel()
    private let outputContainer = UIView()
    private let outputScrollView = HorizontalPanPassthroughScrollView()
    private let outputLabel = UILabel()
    private let expandedContainer = UIView()
    private let expandedScrollView = HorizontalPanPassthroughScrollView()
    private let expandedLabel = UILabel()
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
    private var expandedShouldAutoFollow = true
    private var outputUsesViewport = false
    private var outputUsesUnwrappedLayout = false
    private var outputRenderedText: String?
    private var commandRenderSignature: Int?
    private var outputRenderSignature: Int?
    private var expandedRenderSignature: Int?
    private var expandedUsesViewport = false
    private var expandedUsesMarkdownLayout = false
    private var expandedUsesReadMediaLayout = false
    private var expandedReadMediaContentView: UIView?
    /// Tracks which base64 image is currently being decoded / displayed.
    private var imagePreviewDecodedKey: String?
    private var imagePreviewDecodeTask: Task<Void, Never>?
    private var expandedViewportMode: ExpandedViewportMode = .none
    private var expandedRenderedText: String?
    private var expandedMarkdownHeightCacheSignature: Int?
    private var expandedMarkdownHeightCacheWidth: Int?
    private var expandedMarkdownHeightCacheValue: CGFloat?
    private var expandedPinchDidTriggerFullScreen = false
    private let fullScreenTerminalStream: TerminalTraceStream
    private let expandFloatingButton = UIButton(type: .system)

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
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? ToolTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
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
        updateExpandFloatingButtonVisibility()
        ToolTimelineRowUIHelpers.clampScrollOffsetIfNeeded(outputScrollView)
        ToolTimelineRowUIHelpers.clampScrollOffsetIfNeeded(expandedScrollView)
    }

    private func updateViewportHeightsIfNeeded() {
        if outputUsesViewport,
           let outputViewportHeightConstraint {
            outputViewportHeightConstraint.constant = preferredViewportHeight(
                for: outputLabel,
                in: outputContainer,
                mode: .output
            )
        }

        if expandedUsesViewport,
           let expandedViewportHeightConstraint {
            let mode: ViewportMode
            switch expandedViewportMode {
            case .diff:
                mode = .expandedDiff
            case .code:
                mode = .expandedCode
            case .text, .none:
                mode = .expandedText
            }

            let expandedContentView: UIView
            if expandedUsesReadMediaLayout {
                expandedContentView = expandedReadMediaContainer
            } else if expandedUsesMarkdownLayout {
                expandedContentView = expandedMarkdownView
            } else {
                expandedContentView = expandedLabel
            }

            let widthBucket = Int(expandedContainer.bounds.width.rounded())
            let signature = expandedRenderSignature

            let preferredHeight: CGFloat
            if expandedUsesMarkdownLayout,
               signature == expandedMarkdownHeightCacheSignature,
               widthBucket == expandedMarkdownHeightCacheWidth,
               let cachedHeight = expandedMarkdownHeightCacheValue {
                preferredHeight = cachedHeight
            } else {
                preferredHeight = preferredViewportHeight(
                    for: expandedContentView,
                    in: expandedContainer,
                    mode: mode
                )
                if expandedUsesMarkdownLayout {
                    expandedMarkdownHeightCacheSignature = signature
                    expandedMarkdownHeightCacheWidth = widthBucket
                    expandedMarkdownHeightCacheValue = preferredHeight
                }
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
        let frameWidth = max(1, outputScrollView.bounds.width)
        let minimumContentWidth = max(1, frameWidth - 12)
        let estimatedContentWidth = ToolTimelineRowRenderMetrics.estimatedMonospaceLineWidth(renderedText)
        let contentWidth = max(minimumContentWidth, estimatedContentWidth)
        return contentWidth - frameWidth
    }

    private func updateExpandedLabelWidthIfNeeded() {
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
        let frameWidth = max(1, expandedScrollView.bounds.width)
        let minimumContentWidth = max(1, frameWidth - 12)
        let estimatedContentWidth = ToolTimelineRowRenderMetrics.estimatedMonospaceLineWidth(renderedText)
        let contentWidth = max(minimumContentWidth, estimatedContentWidth)
        return contentWidth - frameWidth
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

    private func setExpandedVerticalLockEnabled(_ enabled: Bool) {
        expandedLabelHeightLockConstraint?.isActive = enabled
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
    private func showExpandedLabel() {
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

    /// Prepare for embedded expanded content (UIKit-first, optional SwiftUI fallback).
    private func showExpandedHostedView() {
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
    private func showExpandedViewport() {
        expandedViewportHeightConstraint?.isActive = true
        expandedUsesViewport = true
    }

    /// Reset expanded container to hidden/default state.
    private func hideExpandedContainer(outputColor: UIColor) {
        expandedMarkdownHeightCacheSignature = nil
        expandedMarkdownHeightCacheWidth = nil
        expandedMarkdownHeightCacheValue = nil
        expandedLabel.attributedText = nil
        expandedLabel.text = nil
        expandedLabel.textColor = outputColor
        expandedLabel.lineBreakMode = .byCharWrapping
        expandedLabel.isHidden = false
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

        ToolTimelineRowViewStyler.styleImagePreview(
            imagePreviewContainer: imagePreviewContainer,
            imagePreviewImageView: imagePreviewImageView
        )
        imagePreviewContainer.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleImagePreviewTap))
        )
        imagePreviewContainer.addInteraction(UIContextMenuInteraction(delegate: self))
        imagePreviewContainer.addSubview(imagePreviewImageView)

        ToolTimelineRowViewStyler.styleExpandFloatingButton(expandFloatingButton)
        expandFloatingButton.addTarget(self, action: #selector(handleExpandFloatingButtonTap), for: .touchUpInside)

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
        expandedScrollView.addSubview(expandedLabel)
        expandedScrollView.addSubview(expandedMarkdownView)
        expandedScrollView.addSubview(expandedReadMediaContainer)
        expandedContainer.addSubview(expandFloatingButton)
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
        expandedContainer.addGestureRecognizer(expandedDoubleTapGesture)
        expandedContainer.addGestureRecognizer(expandedPinchGesture)

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
            expandedLabel: expandedLabel,
            expandedMarkdownView: expandedMarkdownView,
            expandedReadMediaContainer: expandedReadMediaContainer,
            imagePreviewContainer: imagePreviewContainer,
            imagePreviewImageView: imagePreviewImageView,
            expandFloatingButton: expandFloatingButton,
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

    private typealias ExpandedRenderVisibility = ToolTimelineRowExpandedRenderer.Visibility

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
        let wasExpandedVisible = !expandedContainer.isHidden
        let wasCommandVisible = !commandContainer.isHidden
        let wasOutputVisible = !outputContainer.isHidden

        // Reset gesture interception (specific cases disable it below)
        setExpandedContainerGestureInterceptionEnabled(true)
        currentInteractionPolicy = nil

        var showExpandedContainer = false
        var showCommandContainer = false
        var showOutputContainer = false

        if configuration.isExpanded, let rawExpandedContent = configuration.expandedContent {
            let expandedContent = normalizedExpandedContentForHotPath(rawExpandedContent)
            currentInteractionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
                expandedContent
            )
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
                        isStreaming: !configuration.isDone
                    )
                },
                renderCode: { text, language, startLine in
                    self.renderExpandedCodeMode(
                        text: text,
                        language: language,
                        startLine: startLine,
                        isStreaming: !configuration.isDone
                    )
                },
                renderMarkdown: { text in
                    self.renderExpandedMarkdownMode(
                        text: text,
                        isStreaming: !configuration.isDone,
                        wasExpandedVisible: wasExpandedVisible,
                        isDone: configuration.isDone
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
            applyInteractionPolicy(policy, showOutputContainer: showOutputContainer)
        } else {
            setExpandedContainerGestureInterceptionEnabled(true)
            expandedScrollView.isScrollEnabled = false
            outputScrollView.isScrollEnabled = false
        }

        let showImagePreview = !imagePreviewContainer.isHidden
        let showBody = showPreview || showImagePreview || showExpandedContainer || showCommandContainer || showOutputContainer
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody
        updateViewportHeightsIfNeeded()
        updateExpandFloatingButtonVisibility()

        if isExpandingTransition {
            // Reuse path: an expanded code/diff row can leave stack-view layout
            // caches with stale large fitting heights until the next layout pass.
            // Force one synchronous layout on expand so first self-sizing uses
            // current constraints/content instead of stale cached geometry.
            setNeedsLayout()
            layoutIfNeeded()
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
        var localCommandRenderSignature = commandRenderSignature
        var localOutputRenderSignature = outputRenderSignature
        var localOutputRenderedText = outputRenderedText
        var localOutputUsesUnwrappedLayout = outputUsesUnwrappedLayout
        var localOutputUsesViewport = outputUsesViewport
        var localOutputShouldAutoFollow = outputShouldAutoFollow
        var outputDidTextChange = false

        let visibility = ToolTimelineRowExpandedRenderer.renderBashMode(
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
        isStreaming: Bool
    ) -> ExpandedRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderDiffMode(
            lines: lines,
            path: path,
            isStreaming: isStreaming,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isCurrentModeDiff: expandedViewportMode == .diff,
            showExpandedLabel: showExpandedLabel,
            setModeDiff: { self.expandedViewportMode = .diff },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport
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

    private func renderExpandedCodeMode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?,
        isStreaming: Bool
    ) -> ExpandedRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderCodeMode(
            text: text,
            language: language,
            startLine: startLine,
            isStreaming: isStreaming,
            expandedLabel: expandedLabel,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isCurrentModeCode: expandedViewportMode == .code,
            showExpandedLabel: showExpandedLabel,
            setModeCode: { self.expandedViewportMode = .code },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport
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
        isDone: Bool
    ) -> ExpandedRenderVisibility {
        let previousExpandedRenderSignature = expandedRenderSignature
        let wasUsingMarkdownLayout = expandedUsesMarkdownLayout

        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderMarkdownMode(
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
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderPlotMode(
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
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderReadMediaMode(
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
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderTextMode(
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

    private func updateExpandFloatingButtonVisibility() {
        let shouldShow = !expandedContainer.isHidden
            && fullScreenContent != nil
            && expandedContentOverflowsViewport()
        expandFloatingButton.isHidden = !shouldShow
    }

    private func expandedContentOverflowsViewport() -> Bool {
        let inset = expandedScrollView.adjustedContentInset
        let scrollViewportHeight = max(0, expandedScrollView.bounds.height - inset.top - inset.bottom)

        let constraintViewportHeight: CGFloat
        if let expandedViewportHeightConstraint, expandedViewportHeightConstraint.isActive {
            constraintViewportHeight = max(0, expandedViewportHeightConstraint.constant)
        } else {
            constraintViewportHeight = 0
        }

        let viewportHeight = constraintViewportHeight > 1
            ? constraintViewportHeight
            : scrollViewportHeight

        guard viewportHeight > 1 else {
            return false
        }
        if !expandedUsesMarkdownLayout && !expandedUsesReadMediaLayout {
            return expandedLabelOverflowsViewport(viewportHeight)
        }
        let resolvedContentHeight: CGFloat
        if expandedUsesMarkdownLayout,
           expandedScrollView.contentSize.height <= 1 {
            let cellWidth = bounds.width > 10 ? bounds.width : (window?.bounds.width ?? 375)
            let containerWidth = max(expandedContainer.bounds.width, max(100, cellWidth - 16))
            resolvedContentHeight = measuredExpandedContentHeight(for: expandedMarkdownView, width: max(1, containerWidth - 12))
        } else {
            resolvedContentHeight = expandedScrollView.contentSize.height
        }
        return resolvedContentHeight - viewportHeight > Self.fullScreenOverflowThreshold
    }
    private func expandedLabelOverflowsViewport(_ viewportHeight: CGFloat) -> Bool {
        let cellWidth = bounds.width > 10 ? bounds.width : (window?.bounds.width ?? 375)
        let measuredContainerWidth = max(expandedContainer.bounds.width, max(100, cellWidth - 16))
        let width: CGFloat
        if expandedViewportMode == .diff || expandedViewportMode == .code,
           let widthConstraint = expandedLabelWidthConstraint,
           widthConstraint.constant > 1 {
            let frameWidth = expandedScrollView.bounds.width > 10
                ? expandedScrollView.bounds.width
                : measuredContainerWidth
            width = max(1, frameWidth + widthConstraint.constant)
        } else {
            width = max(1, measuredContainerWidth - 12)
        }
        let contentHeight = measuredExpandedContentHeight(for: expandedLabel, width: width)
        let overflowY = contentHeight - viewportHeight
        return overflowY > Self.fullScreenOverflowThreshold
    }

    private func normalizedExpandedContentForHotPath(
        _ content: ToolPresentationBuilder.ToolExpandedContent
    ) -> ToolPresentationBuilder.ToolExpandedContent {
        // Expanded tool content is now UIKit-first for timeline hot paths.
        // SwiftUI is preserved behind per-view install gates as a fallback.
        content
    }

    private func applyInteractionPolicy(
        _ policy: ToolTimelineRowInteractionPolicy,
        showOutputContainer: Bool
    ) {
        setExpandedContainerTapCopyGestureEnabled(policy.enablesTapCopyGesture)
        expandedPinchGesture.isEnabled = policy.enablesPinchGesture

        expandedScrollView.alwaysBounceHorizontal = policy.allowsHorizontalScroll
        expandedScrollView.showsHorizontalScrollIndicator = policy.allowsHorizontalScroll
        expandedScrollView.isScrollEnabled = policy.allowsHorizontalScroll

        if showOutputContainer, case .bash(let unwrapped) = policy.mode {
            outputScrollView.alwaysBounceHorizontal = policy.allowsHorizontalScroll
            outputScrollView.showsHorizontalScrollIndicator = policy.allowsHorizontalScroll
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
    // periphery:ignore - used by ToolRowContentViewTests via @testable import
    var expandedTapCopyGestureEnabledForTesting: Bool {
        expandedDoubleTapGesture.isEnabled && expandedSingleTapBlocker.isEnabled
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

    @objc private func handleOutputDoubleTap() {
        guard let text = outputCopyText else { return }
        copy(text: text, feedbackView: outputContainer)
    }

    @objc private func handleExpandedDoubleTap() {
        if canShowFullScreenContent {
            showFullScreenContent()
            return
        }

        guard let text = outputCopyText else { return }
        copy(text: text, feedbackView: expandedContainer)
    }

    @objc private func handleExpandFloatingButtonTap() {
        showFullScreenContent()
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

    private var outputCopyText: String? {
        if let explicit = currentConfiguration.copyOutputText,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        return nil
    }

    private var fullScreenContent: FullScreenCodeContent? {
        ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: currentConfiguration,
            outputCopyText: outputCopyText,
            interactionPolicy: currentInteractionPolicy,
            terminalStream: fullScreenTerminalStream
        )
    }

    private var canShowFullScreenContent: Bool {
        fullScreenContent != nil
    }

    private func showFullScreenContent() {
        guard let content = fullScreenContent else {
            return
        }

        ToolTimelineRowPresentationHelpers.presentFullScreenContent(content, from: self)
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

    private func copy(text: String, feedbackView: UIView) {
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

    private func scheduleExpandedAutoScrollToBottomIfNeeded() {
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
