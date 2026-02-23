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
    private let outputScrollView = UIScrollView()
    private let outputLabel = UILabel()
    private let expandedContainer = UIView()
    private let expandedScrollView = UIScrollView()
    private let expandedLabel = UILabel()
    private let expandedMarkdownView = AssistantMarkdownContentView()
    private let expandedReadMediaContainer = UIView()
    private let imagePreviewContainer = UIView()
    private let imagePreviewImageView = UIImageView()
    private let borderView = UIView()

    private var currentConfiguration: ToolTimelineRowConfiguration
    private var bodyStackCollapsedHeightConstraint: NSLayoutConstraint?
    private var outputViewportHeightConstraint: NSLayoutConstraint?
    private var outputLabelWidthConstraint: NSLayoutConstraint?
    private var expandedViewportHeightConstraint: NSLayoutConstraint?
    private var expandedLabelWidthConstraint: NSLayoutConstraint?
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
    private var expandedPinchDidTriggerFullScreen = false
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

            expandedViewportHeightConstraint.constant = preferredViewportHeight(
                for: expandedContentView,
                in: expandedContainer,
                mode: mode
            )
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
        let measuredContainerWidth = container.bounds.width > 10 ? container.bounds.width : fallbackContainerWidth

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
        let contentSize = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingExpandedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        let contentHeight = ceil(contentSize.height + 10)
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

    private func installExpandedTodoView(output: String) {
        let native: NativeExpandedTodoView
        if let existing = expandedReadMediaContentView as? NativeExpandedTodoView {
            native = existing
        } else {
            clearExpandedReadMediaView()
            native = NativeExpandedTodoView()
            installExpandedEmbeddedView(native)
        }

        native.apply(output: output, themeID: ThemeRuntimeState.currentThemeID())
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

    // MARK: - Expanded Content Helpers

    /// Prepare for label-based expanded content (diff, code, plain text).
    private func showExpandedLabel() {
        expandedMarkdownView.isHidden = true
        expandedLabel.isHidden = false
        expandedReadMediaContainer.isHidden = true
        expandedUsesMarkdownLayout = false
        expandedUsesReadMediaLayout = false
        clearExpandedReadMediaView()
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
        updateExpandedLabelWidthIfNeeded()
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
        expandedLabelWidthConstraint = layout.expandedLabelWidth
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

        var showExpandedContainer = false
        var showCommandContainer = false
        var showOutputContainer = false

        if configuration.isExpanded, let rawExpandedContent = configuration.expandedContent {
            let expandedContent = normalizedExpandedContentForHotPath(rawExpandedContent)
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
                    self.renderExpandedDiffMode(lines: lines, path: path)
                },
                renderCode: { text, language, startLine in
                    self.renderExpandedCodeMode(
                        text: text,
                        language: language,
                        startLine: startLine
                    )
                },
                renderMarkdown: { text in
                    self.renderExpandedMarkdownMode(
                        text: text,
                        wasExpandedVisible: wasExpandedVisible
                    )
                },
                renderTodo: { output in
                    self.renderExpandedTodoMode(output: output)
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
            ToolTimelineRowDisplayState.resetOutputState(
                outputLabel: outputLabel,
                outputScrollView: outputScrollView,
                outputViewportHeightConstraint: outputViewportHeightConstraint,
                outputColor: outputColor,
                outputUsesUnwrappedLayout: &outputUsesUnwrappedLayout,
                outputRenderedText: &outputRenderedText,
                outputRenderSignature: &outputRenderSignature,
                outputUsesViewport: &outputUsesViewport,
                outputShouldAutoFollow: &outputShouldAutoFollow
            )
            updateOutputLabelWidthIfNeeded()
        }
        ToolTimelineRowDisplayState.applyContainerVisibility(
            outputContainer,
            shouldShow: showOutputContainer,
            isExpandingTransition: isExpandingTransition,
            wasVisible: wasOutputVisible
        )

        let showImagePreview = !imagePreviewContainer.isHidden
        let showBody = showPreview || showImagePreview || showExpandedContainer || showCommandContainer || showOutputContainer
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody
        updateViewportHeightsIfNeeded()
        updateExpandFloatingButtonVisibility()

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
            updateOutputLabelWidthIfNeeded()
        }
        if outputDidTextChange {
            scheduleOutputAutoScrollToBottomIfNeeded()
        }

        return visibility
    }

    private func renderExpandedDiffMode(lines: [DiffLine], path: String?) -> ExpandedRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderDiffMode(
            lines: lines,
            path: path,
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

        return visibility
    }

    private func renderExpandedCodeMode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?
    ) -> ExpandedRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderCodeMode(
            text: text,
            language: language,
            startLine: startLine,
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

        return visibility
    }

    private func renderExpandedMarkdownMode(
        text: String,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderMarkdownMode(
            text: text,
            expandedMarkdownView: expandedMarkdownView,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            wasExpandedVisible: wasExpandedVisible,
            isUsingMarkdownLayout: expandedUsesMarkdownLayout,
            showExpandedMarkdown: showExpandedMarkdown,
            setExpandedContainerTapCopyGestureEnabled: setExpandedContainerTapCopyGestureEnabled,
            setModeText: { self.expandedViewportMode = .text },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow

        return visibility
    }

    private func renderExpandedTodoMode(output: String) -> ExpandedRenderVisibility {
        var localExpandedRenderSignature = expandedRenderSignature
        var localExpandedRenderedText = expandedRenderedText
        var localExpandedShouldAutoFollow = expandedShouldAutoFollow

        let visibility = ToolTimelineRowExpandedRenderer.renderTodoMode(
            output: output,
            expandedScrollView: expandedScrollView,
            expandedRenderSignature: &localExpandedRenderSignature,
            expandedRenderedText: &localExpandedRenderedText,
            expandedShouldAutoFollow: &localExpandedShouldAutoFollow,
            isUsingReadMediaLayout: expandedUsesReadMediaLayout,
            hasExpandedReadMediaContentView: expandedReadMediaContentView != nil,
            showExpandedHostedView: showExpandedHostedView,
            installExpandedTodoView: installExpandedTodoView(output:),
            setModeText: { self.expandedViewportMode = .text },
            showExpandedViewport: showExpandedViewport
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow

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
            showExpandedLabel: showExpandedLabel,
            setModeText: { self.expandedViewportMode = .text },
            updateExpandedLabelWidthIfNeeded: updateExpandedLabelWidthIfNeeded,
            showExpandedViewport: showExpandedViewport,
            scheduleExpandedAutoScrollToBottomIfNeeded: scheduleExpandedAutoScrollToBottomIfNeeded
        )

        expandedRenderSignature = localExpandedRenderSignature
        expandedRenderedText = localExpandedRenderedText
        expandedShouldAutoFollow = localExpandedShouldAutoFollow

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
        let viewportWidth = max(0, expandedScrollView.bounds.width - inset.left - inset.right)
        let viewportHeight = max(0, expandedScrollView.bounds.height - inset.top - inset.bottom)

        guard viewportWidth > 1, viewportHeight > 1 else {
            return false
        }

        let overflowX = expandedScrollView.contentSize.width - viewportWidth
        let overflowY = expandedScrollView.contentSize.height - viewportHeight

        return overflowX > Self.fullScreenOverflowThreshold
            || overflowY > Self.fullScreenOverflowThreshold
    }

    private func normalizedExpandedContentForHotPath(
        _ content: ToolPresentationBuilder.ToolExpandedContent
    ) -> ToolPresentationBuilder.ToolExpandedContent {
        // Expanded tool content is now UIKit-first for timeline hot paths.
        // SwiftUI is preserved behind per-view install gates as a fallback.
        content
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
        guard let image = imagePreviewImageView.image else { return }
        ToolTimelineRowPresentationHelpers.presentFullScreenImage(image, from: self)
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

    private var supportsFullScreenPreview: Bool {
        ToolTimelineRowFullScreenSupport.supportsPreview(
            toolNamePrefix: currentConfiguration.toolNamePrefix
        )
    }

    private var fullScreenContent: FullScreenCodeContent? {
        guard supportsFullScreenPreview else { return nil }
        return ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: currentConfiguration,
            outputCopyText: outputCopyText
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
            outputShouldAutoFollow = ToolTimelineRowUIHelpers.isNearBottom(outputScrollView)
        } else if scrollView === expandedScrollView {
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
