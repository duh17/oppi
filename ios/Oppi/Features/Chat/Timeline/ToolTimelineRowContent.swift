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
    private static let autoFollowBottomThreshold: CGFloat = 18
    private static let collapsedImagePreviewHeight: CGFloat = 136
    private static let fullScreenOverflowThreshold: CGFloat = 2
    private static let genericLanguageBadgeSymbolName = "chevron.left.forwardslash.chevron.right"

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
        clampScrollOffsetIfNeeded(outputScrollView)
        clampScrollOffsetIfNeeded(expandedScrollView)
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
        let estimatedContentWidth = Self.estimatedMonospaceLineWidth(renderedText)
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
        let estimatedContentWidth = Self.estimatedMonospaceLineWidth(renderedText)
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

    private static func estimatedMonospaceLineWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 1 }

        let maxLineLength = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).reduce(0) { max($0, $1.count) }

        guard maxLineLength > 0 else { return 1 }

        let font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(charWidth * CGFloat(maxLineLength)) + 12
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

    private static func displayCommandText(_ text: String) -> String {
        ToolRowTextRenderer.displayCommandText(text)
    }

    private static func displayOutputText(_ text: String) -> String {
        ToolRowTextRenderer.displayOutputText(text)
    }

    private static func commandSignature(displayCommand: String) -> Int {
        var hasher = Hasher()
        hasher.combine("command")
        hasher.combine(displayCommand)
        hasher.combine(displayCommand.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes)
        return hasher.finalize()
    }

    private static func outputSignature(displayOutput: String, isError: Bool, unwrapped: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine("bash-output")
        hasher.combine(displayOutput)
        hasher.combine(isError)
        hasher.combine(unwrapped)
        return hasher.finalize()
    }

    private static func diffSignature(lines: [DiffLine], path: String?) -> Int {
        var hasher = Hasher()
        hasher.combine("diff")
        hasher.combine(path ?? "")
        hasher.combine(lines.count)
        for line in lines {
            switch line.kind {
            case .context:
                hasher.combine(0)
            case .added:
                hasher.combine(1)
            case .removed:
                hasher.combine(2)
            }
            hasher.combine(line.text)
        }
        return hasher.finalize()
    }

    private static func codeSignature(
        displayText: String,
        language: SyntaxLanguage?,
        startLine: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("code")
        hasher.combine(displayText)
        hasher.combine(language)
        hasher.combine(startLine)
        return hasher.finalize()
    }

    private static func markdownSignature(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine("markdown")
        hasher.combine(text)
        return hasher.finalize()
    }

    private static func todoSignature(_ output: String) -> Int {
        var hasher = Hasher()
        hasher.combine("todo")
        hasher.combine(output)
        return hasher.finalize()
    }

    private static func readMediaSignature(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("read-media")
        hasher.combine(output)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(isError)
        return hasher.finalize()
    }

    private static func textSignature(
        displayText: String,
        language: SyntaxLanguage?,
        isError: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("text")
        hasher.combine(displayText)
        hasher.combine(language)
        hasher.combine(isError)
        return hasher.finalize()
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
            self.invalidateEnclosingCollectionViewLayout()
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
        resetScrollPosition(expandedScrollView)
    }

    private func setupViews() {
        backgroundColor = .clear

        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.layer.cornerRadius = 10
        borderView.layer.borderWidth = 1

        addSubview(borderView)

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.contentMode = .scaleAspectFit

        toolImageView.translatesAutoresizingMaskIntoConstraints = false
        toolImageView.contentMode = .scaleAspectFit
        toolImageView.tintColor = UIColor(Color.themeCyan)
        toolImageView.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = UIColor(Color.themeFg)
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 4
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)

        languageBadgeIconView.translatesAutoresizingMaskIntoConstraints = false
        languageBadgeIconView.contentMode = .scaleAspectFit
        languageBadgeIconView.tintColor = UIColor(Color.themeBlue)
        languageBadgeIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        languageBadgeIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        languageBadgeIconView.setContentHuggingPriority(.required, for: .horizontal)

        addedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        addedLabel.textColor = UIColor(Color.themeDiffAdded)
        addedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addedLabel.setContentHuggingPriority(.required, for: .horizontal)

        removedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        removedLabel.textColor = UIColor(Color.themeDiffRemoved)
        removedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        removedLabel.setContentHuggingPriority(.required, for: .horizontal)

        trailingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        trailingLabel.textColor = UIColor(Color.themeComment)
        trailingLabel.numberOfLines = 1
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = UIColor(Color.themeFgDim)
        previewLabel.numberOfLines = 3

        commandContainer.layer.cornerRadius = 6
        commandContainer.backgroundColor = UIColor(Color.themeBgHighlight.opacity(0.9))
        commandContainer.layer.borderWidth = 1
        commandContainer.layer.borderColor = UIColor(Color.themeBlue.opacity(0.35)).cgColor

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.numberOfLines = 0
        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.textColor = UIColor(Color.themeFg)

        outputContainer.layer.cornerRadius = 6
        outputContainer.layer.masksToBounds = true
        outputContainer.backgroundColor = UIColor(Color.themeBgDark)
        outputContainer.layer.borderWidth = 1
        outputContainer.layer.borderColor = UIColor(Color.themeComment.opacity(0.2)).cgColor

        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.alwaysBounceVertical = true
        outputScrollView.alwaysBounceHorizontal = false
        outputScrollView.showsVerticalScrollIndicator = true
        outputScrollView.showsHorizontalScrollIndicator = false
        outputScrollView.delegate = self

        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputLabel.numberOfLines = 0
        outputLabel.lineBreakMode = .byCharWrapping
        outputLabel.textColor = UIColor(Color.themeFg)

        expandedContainer.layer.cornerRadius = 6
        expandedContainer.layer.masksToBounds = true
        expandedContainer.backgroundColor = UIColor(Color.themeBgDark.opacity(0.9))

        expandedScrollView.translatesAutoresizingMaskIntoConstraints = false
        expandedScrollView.alwaysBounceVertical = true
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsVerticalScrollIndicator = true
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedScrollView.delegate = self

        expandedLabel.translatesAutoresizingMaskIntoConstraints = false
        expandedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        expandedLabel.numberOfLines = 0
        expandedLabel.lineBreakMode = .byCharWrapping

        expandedMarkdownView.translatesAutoresizingMaskIntoConstraints = false
        expandedMarkdownView.backgroundColor = .clear
        expandedMarkdownView.isHidden = true

        expandedReadMediaContainer.translatesAutoresizingMaskIntoConstraints = false
        expandedReadMediaContainer.backgroundColor = .clear
        expandedReadMediaContainer.isHidden = true

        imagePreviewContainer.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewContainer.backgroundColor = UIColor(Color.themeBgDark)
        imagePreviewContainer.layer.cornerRadius = 6
        imagePreviewContainer.layer.masksToBounds = true
        imagePreviewContainer.isHidden = true
        imagePreviewContainer.isUserInteractionEnabled = true
        imagePreviewContainer.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleImagePreviewTap))
        )
        imagePreviewContainer.addInteraction(UIContextMenuInteraction(delegate: self))

        imagePreviewImageView.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewImageView.contentMode = .scaleAspectFit
        imagePreviewImageView.clipsToBounds = true
        imagePreviewContainer.addSubview(imagePreviewImageView)

        expandFloatingButton.translatesAutoresizingMaskIntoConstraints = false
        let expandBtnSymbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        expandFloatingButton.setImage(
            UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandBtnSymbolConfig),
            for: .normal
        )
        expandFloatingButton.tintColor = UIColor(Color.themeCyan)
        expandFloatingButton.backgroundColor = UIColor(Color.themeBgHighlight)
        expandFloatingButton.layer.cornerRadius = 18
        expandFloatingButton.layer.borderWidth = 1
        expandFloatingButton.layer.borderColor = UIColor(Color.themeComment.opacity(0.3)).cgColor
        expandFloatingButton.accessibilityIdentifier = "tool.expand-full-screen"
        expandFloatingButton.isHidden = true
        expandFloatingButton.addTarget(self, action: #selector(handleExpandFloatingButtonTap), for: .touchUpInside)

        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.spacing = 4
        bodyStackCollapsedHeightConstraint = bodyStack.heightAnchor.constraint(equalToConstant: 0)

        trailingStack.addArrangedSubview(languageBadgeIconView)
        trailingStack.addArrangedSubview(addedLabel)
        trailingStack.addArrangedSubview(removedLabel)
        trailingStack.addArrangedSubview(trailingLabel)

        NSLayoutConstraint.activate([
            languageBadgeIconView.widthAnchor.constraint(equalToConstant: 10),
            languageBadgeIconView.heightAnchor.constraint(equalToConstant: 10),
        ])

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

        outputViewportHeightConstraint = outputContainer.heightAnchor.constraint(equalToConstant: Self.minOutputViewportHeight)
        expandedViewportHeightConstraint = expandedContainer.heightAnchor.constraint(equalToConstant: Self.minDiffViewportHeight)

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

        toolLeadingConstraint = toolImageView.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 0)
        toolWidthConstraint = toolImageView.widthAnchor.constraint(equalToConstant: 0)
        titleLeadingToStatusConstraint = titleLabel.leadingAnchor.constraint(equalTo: statusImageView.trailingAnchor, constant: 5)
        titleLeadingToToolConstraint = titleLabel.leadingAnchor.constraint(equalTo: toolImageView.trailingAnchor, constant: 5)
        outputLabelWidthConstraint = outputLabel.widthAnchor.constraint(
            equalTo: outputScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        expandedLabelWidthConstraint = expandedLabel.widthAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        expandedMarkdownWidthConstraint = expandedMarkdownView.widthAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        expandedReadMediaWidthConstraint = expandedReadMediaContainer.widthAnchor.constraint(
            equalTo: expandedScrollView.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        // During the first self-sizing measurement pass, scroll view frame
        // layout guides can still report width=0. Keep markdown/hosted width
        // constraints below required priority so systemLayoutSizeFitting can
        // provide a temporary fitting width instead of measuring at 0px.
        expandedMarkdownWidthConstraint?.priority = .defaultHigh
        expandedReadMediaWidthConstraint?.priority = .defaultHigh
        imagePreviewHeightConstraint = imagePreviewContainer.heightAnchor.constraint(
            equalToConstant: Self.collapsedImagePreviewHeight
        )

        guard let toolLeadingConstraint,
              let toolWidthConstraint,
              let titleLeadingToStatusConstraint,
              let outputLabelWidthConstraint,
              let expandedLabelWidthConstraint,
              let expandedMarkdownWidthConstraint,
              let expandedReadMediaWidthConstraint,
              let imagePreviewHeightConstraint else {
            assertionFailure("Expected tool-row constraints to be initialized")
            return
        }

        NSLayoutConstraint.activate([
            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderView.topAnchor.constraint(equalTo: topAnchor),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusImageView.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 8),
            statusImageView.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 6),
            statusImageView.widthAnchor.constraint(equalToConstant: 14),
            statusImageView.heightAnchor.constraint(equalToConstant: 14),

            toolLeadingConstraint,
            toolImageView.centerYAnchor.constraint(equalTo: statusImageView.centerYAnchor),
            toolWidthConstraint,
            toolImageView.heightAnchor.constraint(equalToConstant: 12),

            titleLeadingToStatusConstraint,
            titleLabel.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 6),

            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            trailingStack.centerYAnchor.constraint(equalTo: statusImageView.centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -8),

            bodyStack.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 8),
            bodyStack.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -8),
            bodyStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyStack.bottomAnchor.constraint(equalTo: borderView.bottomAnchor, constant: -6),

            commandLabel.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor, constant: 6),
            commandLabel.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -6),
            commandLabel.topAnchor.constraint(equalTo: commandContainer.topAnchor, constant: 5),
            commandLabel.bottomAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: -5),

            outputScrollView.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor),
            outputScrollView.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor),
            outputScrollView.topAnchor.constraint(equalTo: outputContainer.topAnchor),
            outputScrollView.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor),

            outputLabel.leadingAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            outputLabel.trailingAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            outputLabel.topAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.topAnchor, constant: 5),
            outputLabel.bottomAnchor.constraint(equalTo: outputScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            outputLabelWidthConstraint,

            expandedScrollView.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            expandedScrollView.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            expandedScrollView.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            expandedScrollView.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),

            expandedLabel.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            expandedLabel.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            expandedLabel.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor, constant: 5),
            expandedLabel.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            expandedLabelWidthConstraint,

            expandedMarkdownView.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            expandedMarkdownView.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            expandedMarkdownView.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor, constant: 5),
            expandedMarkdownView.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            expandedMarkdownWidthConstraint,

            expandedReadMediaContainer.leadingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            expandedReadMediaContainer.trailingAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            expandedReadMediaContainer.topAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.topAnchor, constant: 5),
            expandedReadMediaContainer.bottomAnchor.constraint(equalTo: expandedScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            expandedReadMediaWidthConstraint,

            imagePreviewImageView.leadingAnchor.constraint(equalTo: imagePreviewContainer.leadingAnchor, constant: 6),
            imagePreviewImageView.trailingAnchor.constraint(equalTo: imagePreviewContainer.trailingAnchor, constant: -6),
            imagePreviewImageView.topAnchor.constraint(equalTo: imagePreviewContainer.topAnchor, constant: 6),
            imagePreviewImageView.bottomAnchor.constraint(equalTo: imagePreviewContainer.bottomAnchor, constant: -6),
            imagePreviewHeightConstraint,
            imagePreviewImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),

            expandFloatingButton.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -10),
            expandFloatingButton.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -10),
            expandFloatingButton.widthAnchor.constraint(equalToConstant: 36),
            expandFloatingButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private struct ExpandedRenderVisibility {
        let showExpandedContainer: Bool
        let showCommandContainer: Bool
        let showOutputContainer: Bool
    }

    private func apply(configuration: ToolTimelineRowConfiguration) {
        let previousConfiguration = currentConfiguration
        let isExpandingTransition = !previousConfiguration.isExpanded && configuration.isExpanded
        currentConfiguration = configuration

        if let segmentTitle = configuration.segmentAttributedTitle {
            titleLabel.attributedText = segmentTitle
        } else {
            titleLabel.attributedText = ToolRowTextRenderer.styledTitle(
                title: configuration.title,
                toolNamePrefix: configuration.toolNamePrefix,
                toolNameColor: configuration.toolNameColor
            )
        }
        applyToolIcon(
            toolNamePrefix: configuration.toolNamePrefix,
            toolNameColor: configuration.toolNameColor
        )
        titleLabel.lineBreakMode = configuration.titleLineBreakMode
        if configuration.isExpanded {
            titleLabel.numberOfLines = configuration.titleLineBreakMode == .byTruncatingMiddle ? 1 : 3
        } else {
            titleLabel.numberOfLines = 1
        }

        let badge = configuration.languageBadge?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let badgeSymbolName = Self.languageBadgeSymbolName(for: badge),
           let badgeImage = UIImage(systemName: badgeSymbolName) {
            languageBadgeIconView.image = badgeImage
            languageBadgeIconView.isHidden = false
        } else {
            languageBadgeIconView.image = nil
            languageBadgeIconView.isHidden = true
        }

        if let added = configuration.editAdded, let removed = configuration.editRemoved {
            addedLabel.text = added > 0 ? "+\(added)" : nil
            addedLabel.isHidden = addedLabel.text == nil

            removedLabel.text = removed > 0 ? "-\(removed)" : nil
            removedLabel.isHidden = removedLabel.text == nil

            if added == 0, removed == 0 {
                trailingLabel.text = "modified"
                trailingLabel.isHidden = false
            } else {
                trailingLabel.text = nil
                trailingLabel.isHidden = true
            }
        } else {
            addedLabel.text = nil
            addedLabel.isHidden = true
            removedLabel.text = nil
            removedLabel.isHidden = true
            if let segmentTrailing = configuration.segmentAttributedTrailing {
                trailingLabel.attributedText = segmentTrailing
                trailingLabel.isHidden = false
            } else {
                trailingLabel.attributedText = nil
                trailingLabel.text = configuration.trailing
                trailingLabel.isHidden = configuration.trailing == nil
            }
        }

        trailingStack.isHidden = languageBadgeIconView.isHidden
            && addedLabel.isHidden
            && removedLabel.isHidden
            && trailingLabel.isHidden

        let preview = configuration.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showPreview = !configuration.isExpanded && !(preview?.isEmpty ?? true)
        previewLabel.text = preview
        previewLabel.isHidden = !showPreview

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
            let visibility: ExpandedRenderVisibility

            switch expandedContent {
            case .bash(let command, let output, let unwrapped):
                visibility = renderExpandedBashMode(
                    command: command,
                    output: output,
                    unwrapped: unwrapped,
                    configuration: configuration,
                    outputColor: outputColor,
                    wasOutputVisible: wasOutputVisible
                )

            case .diff(let lines, let path):
                visibility = renderExpandedDiffMode(lines: lines, path: path)

            case .code(let text, let language, let startLine, _):
                visibility = renderExpandedCodeMode(
                    text: text,
                    language: language,
                    startLine: startLine
                )

            case .markdown(let text):
                visibility = renderExpandedMarkdownMode(
                    text: text,
                    wasExpandedVisible: wasExpandedVisible
                )

            case .todoCard(let output):
                visibility = renderExpandedTodoMode(output: output)

            case .readMedia(let output, let filePath, let startLine):
                visibility = renderExpandedReadMediaMode(
                    output: output,
                    filePath: filePath,
                    startLine: startLine,
                    isError: configuration.isError
                )

            case .text(let text, let language):
                visibility = renderExpandedTextMode(
                    text: text,
                    language: language,
                    configuration: configuration,
                    outputColor: outputColor,
                    wasExpandedVisible: wasExpandedVisible
                )
            }

            showExpandedContainer = visibility.showExpandedContainer
            showCommandContainer = visibility.showCommandContainer
            showOutputContainer = visibility.showOutputContainer
        }

        // Hide containers that aren't needed by the active content
        if !showExpandedContainer {
            hideExpandedContainer(outputColor: outputColor)
        }
        expandedContainer.isHidden = !showExpandedContainer
        if showExpandedContainer {
            animateInPlaceReveal(
                expandedContainer,
                shouldAnimate: isExpandingTransition && !wasExpandedVisible
            )
        } else {
            resetRevealAppearance(expandedContainer)
        }

        if !showCommandContainer {
            commandLabel.attributedText = nil
            commandLabel.text = nil
            commandLabel.textColor = UIColor(Color.themeFg)
            commandRenderSignature = nil
        }
        commandContainer.isHidden = !showCommandContainer
        if showCommandContainer {
            animateInPlaceReveal(
                commandContainer,
                shouldAnimate: isExpandingTransition && !wasCommandVisible
            )
        } else {
            resetRevealAppearance(commandContainer)
        }

        if !showOutputContainer {
            outputLabel.attributedText = nil
            outputLabel.text = nil
            outputLabel.textColor = outputColor
            outputLabel.lineBreakMode = .byCharWrapping
            outputScrollView.alwaysBounceHorizontal = false
            outputScrollView.showsHorizontalScrollIndicator = false
            outputUsesUnwrappedLayout = false
            outputRenderedText = nil
            outputRenderSignature = nil
            updateOutputLabelWidthIfNeeded()
            outputViewportHeightConstraint?.isActive = false
            outputUsesViewport = false
            outputShouldAutoFollow = true
            resetScrollPosition(outputScrollView)
        }
        outputContainer.isHidden = !showOutputContainer
        if showOutputContainer {
            animateInPlaceReveal(
                outputContainer,
                shouldAnimate: isExpandingTransition && !wasOutputVisible
            )
        } else {
            resetRevealAppearance(outputContainer)
        }

        let showImagePreview = !imagePreviewContainer.isHidden
        let showBody = showPreview || showImagePreview || showExpandedContainer || showCommandContainer || showOutputContainer
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody
        updateViewportHeightsIfNeeded()
        updateExpandFloatingButtonVisibility()

        let symbolName: String
        let statusColor: UIColor
        if !configuration.isDone {
            symbolName = "play.circle.fill"
            statusColor = UIColor(Color.themeBlue)
        } else if configuration.isError {
            symbolName = "xmark.circle.fill"
            statusColor = UIColor(Color.themeRed)
        } else {
            symbolName = "checkmark.circle.fill"
            statusColor = UIColor(Color.themeGreen)
        }

        statusImageView.image = UIImage(systemName: symbolName)
        statusImageView.tintColor = statusColor

        if !configuration.isDone {
            borderView.backgroundColor = UIColor(Color.themeBgHighlight.opacity(0.75))
            borderView.layer.borderColor = UIColor(Color.themeBlue.opacity(0.25)).cgColor
        } else if configuration.isError {
            borderView.backgroundColor = UIColor(Color.themeRed.opacity(0.08))
            borderView.layer.borderColor = UIColor(Color.themeRed.opacity(0.25)).cgColor
        } else {
            borderView.backgroundColor = UIColor(Color.themeGreen.opacity(0.06))
            borderView.layer.borderColor = UIColor(Color.themeComment.opacity(0.2)).cgColor
        }
    }

    private func renderExpandedBashMode(
        command: String?,
        output: String?,
        unwrapped: Bool,
        configuration: ToolTimelineRowConfiguration,
        outputColor: UIColor,
        wasOutputVisible: Bool
    ) -> ExpandedRenderVisibility {
        var showCommandContainer = false
        var showOutputContainer = false

        if let command, !command.isEmpty {
            let displayCmd = Self.displayCommandText(command)
            let signature = Self.commandSignature(displayCommand: displayCmd)
            if signature != commandRenderSignature {
                if displayCmd.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes {
                    commandLabel.attributedText = ToolRowTextRenderer.shellHighlighted(displayCmd)
                } else {
                    commandLabel.attributedText = nil
                    commandLabel.text = displayCmd
                    commandLabel.textColor = UIColor(Color.themeFg)
                }
                commandRenderSignature = signature
            }
            showCommandContainer = true
        } else {
            commandRenderSignature = nil
        }

        if let output, !output.isEmpty {
            let displayOutput = Self.displayOutputText(output)
            let signature = Self.outputSignature(
                displayOutput: displayOutput,
                isError: configuration.isError,
                unwrapped: unwrapped
            )

            var textChanged = false
            if signature != outputRenderSignature {
                let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                    displayOutput,
                    isError: configuration.isError
                )
                let nextRendered = presentation.attributedText?.string ?? presentation.plainText ?? ""
                let prevOutputRendered = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                textChanged = prevOutputRendered != nextRendered

                ToolRowTextRenderer.applyANSIOutputPresentation(
                    presentation,
                    to: outputLabel,
                    plainTextColor: outputColor
                )
                outputRenderSignature = signature
                outputRenderedText = unwrapped ? nextRendered : nil
            }

            if unwrapped {
                outputLabel.lineBreakMode = .byClipping
                outputScrollView.alwaysBounceHorizontal = true
                outputScrollView.showsHorizontalScrollIndicator = true
                outputUsesUnwrappedLayout = true
            } else {
                outputLabel.lineBreakMode = .byCharWrapping
                outputScrollView.alwaysBounceHorizontal = false
                outputScrollView.showsHorizontalScrollIndicator = false
                outputUsesUnwrappedLayout = false
                outputRenderedText = nil
            }
            updateOutputLabelWidthIfNeeded()
            outputViewportHeightConstraint?.isActive = true
            outputUsesViewport = true
            showOutputContainer = true
            if !wasOutputVisible { outputShouldAutoFollow = true }
            if textChanged { scheduleOutputAutoScrollToBottomIfNeeded() }
        } else {
            outputRenderSignature = nil
        }

        // Bash expanded content uses command + output containers only.
        hideExpandedContainer(outputColor: outputColor)

        return ExpandedRenderVisibility(
            showExpandedContainer: false,
            showCommandContainer: showCommandContainer,
            showOutputContainer: showOutputContainer
        )
    }

    private func renderExpandedDiffMode(lines: [DiffLine], path: String?) -> ExpandedRenderVisibility {
        let signature = Self.diffSignature(lines: lines, path: path)
        let shouldRerender = signature != expandedRenderSignature
            || expandedViewportMode != .diff
            || expandedLabel.attributedText == nil

        showExpandedLabel()
        if shouldRerender {
            let diffText = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: path)
            expandedLabel.text = nil
            expandedLabel.attributedText = diffText
            expandedRenderedText = diffText.string
            expandedRenderSignature = signature
        }

        expandedLabel.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        expandedViewportMode = .diff
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldRerender { resetScrollPosition(expandedScrollView) }

        return ExpandedRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    private func renderExpandedCodeMode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?
    ) -> ExpandedRenderVisibility {
        let displayText = Self.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1
        let signature = Self.codeSignature(
            displayText: displayText,
            language: language,
            startLine: resolvedStartLine
        )
        let shouldRerender = signature != expandedRenderSignature
            || expandedViewportMode != .code
            || expandedLabel.attributedText == nil

        showExpandedLabel()
        if shouldRerender {
            let codeText = ToolRowTextRenderer.makeCodeAttributedText(
                text: displayText,
                language: language,
                startLine: resolvedStartLine
            )
            expandedLabel.text = nil
            expandedLabel.attributedText = codeText
            expandedRenderedText = codeText.string
            expandedRenderSignature = signature
        }

        expandedLabel.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        expandedViewportMode = .code
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldRerender { resetScrollPosition(expandedScrollView) }

        return ExpandedRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    private func renderExpandedMarkdownMode(
        text: String,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderVisibility {
        let signature = Self.markdownSignature(text)
        let shouldRerender = signature != expandedRenderSignature
            || !expandedUsesMarkdownLayout

        showExpandedMarkdown()
        // Markdown expanded content should support native UITextView selection
        // on double-tap across tool surfaces.
        setExpandedContainerTapCopyGestureEnabled(false)

        expandedRenderedText = text
        updateExpandedLabelWidthIfNeeded()
        if shouldRerender {
            expandedMarkdownView.apply(configuration: .init(
                content: text,
                isStreaming: false,
                themeID: ThemeRuntimeState.currentThemeID()
            ))
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedViewportMode = .text
        showExpandedViewport()
        if !wasExpandedVisible { expandedShouldAutoFollow = true }
        if shouldRerender { scheduleExpandedAutoScrollToBottomIfNeeded() }

        return ExpandedRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    private func renderExpandedTodoMode(output: String) -> ExpandedRenderVisibility {
        let signature = Self.todoSignature(output)
        let shouldReinstall = signature != expandedRenderSignature
            || !expandedUsesReadMediaLayout
            || expandedReadMediaContentView == nil

        showExpandedHostedView()
        expandedRenderedText = output
        if shouldReinstall {
            installExpandedTodoView(output: output)
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedViewportMode = .text
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldReinstall { resetScrollPosition(expandedScrollView) }

        return ExpandedRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    private func renderExpandedReadMediaMode(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool
    ) -> ExpandedRenderVisibility {
        let signature = Self.readMediaSignature(
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
        if shouldReinstall { resetScrollPosition(expandedScrollView) }

        return ExpandedRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    private func renderExpandedTextMode(
        text: String,
        language: SyntaxLanguage?,
        configuration: ToolTimelineRowConfiguration,
        outputColor: UIColor,
        wasExpandedVisible: Bool
    ) -> ExpandedRenderVisibility {
        let displayText = Self.displayOutputText(text)
        let signature = Self.textSignature(
            displayText: displayText,
            language: language,
            isError: configuration.isError
        )
        let shouldRerender = signature != expandedRenderSignature
            || expandedViewportMode != .text
            || expandedUsesMarkdownLayout
            || expandedUsesReadMediaLayout
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)

        showExpandedLabel()
        if shouldRerender {
            let presentation: ToolRowTextRenderer.ANSIOutputPresentation
            if let language, !configuration.isError {
                presentation = ToolRowTextRenderer.makeSyntaxOutputPresentation(
                    displayText,
                    language: language
                )
            } else {
                presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                    displayText,
                    isError: configuration.isError
                )
            }

            ToolRowTextRenderer.applyANSIOutputPresentation(
                presentation,
                to: expandedLabel,
                plainTextColor: outputColor
            )
            expandedRenderedText = presentation.attributedText?.string ?? presentation.plainText ?? ""
            expandedRenderSignature = signature
        }

        expandedLabel.lineBreakMode = .byCharWrapping
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        expandedViewportMode = .text
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        if !wasExpandedVisible { expandedShouldAutoFollow = true }
        if shouldRerender { scheduleExpandedAutoScrollToBottomIfNeeded() }

        return ExpandedRenderVisibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    private func animateInPlaceReveal(_ view: UIView, shouldAnimate: Bool) {
        guard shouldAnimate else {
            resetRevealAppearance(view)
            return
        }

        view.layer.removeAnimation(forKey: "tool.reveal")
        // Keep reveal almost imperceptible: tiny in-place opacity settle only.
        view.alpha = 0.97

        UIView.animate(
            withDuration: ToolRowExpansionAnimation.contentRevealDuration,
            delay: ToolRowExpansionAnimation.contentRevealDelay,
            options: [.allowUserInteraction, .curveLinear, .beginFromCurrentState]
        ) {
            // Pure in-place fade (no transform/translation), so panels feel
            // like they open within the row rather than slide in.
            view.alpha = 1
        }
    }

    private func resetRevealAppearance(_ view: UIView) {
        view.layer.removeAnimation(forKey: "tool.reveal")
        view.alpha = 1
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
        presentFullScreenImage(image)
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
        switch currentConfiguration.toolNamePrefix {
        case "read", "write", "edit":
            return true
        default:
            return false
        }
    }

    private var fullScreenContent: FullScreenCodeContent? {
        guard currentConfiguration.isExpanded,
              supportsFullScreenPreview,
              let content = currentConfiguration.expandedContent else {
            return nil
        }

        switch content {
        case .diff(let lines, let path):
            let newText = outputCopyText ?? DiffEngine.formatUnified(lines)
            return .diff(
                oldText: "",
                newText: newText,
                filePath: path,
                precomputedLines: lines
            )

        case .markdown(let text):
            guard !text.isEmpty else { return nil }
            // Extract filePath from code case context — markdown doesn't carry filePath
            return .markdown(content: text, filePath: nil)

        case .code(let text, let language, let startLine, let filePath):
            let copyText = outputCopyText ?? text
            guard !copyText.isEmpty else { return nil }
            return .code(
                content: copyText,
                language: language?.displayName,
                filePath: filePath,
                startLine: startLine ?? 1
            )

        case .readMedia, .todoCard, .bash, .text:
            return nil
        }
    }

    private var canShowFullScreenContent: Bool {
        fullScreenContent != nil
    }

    private func showFullScreenContent() {
        guard let content = fullScreenContent,
              let presenter = nearestViewController() else {
            return
        }

        let controller = FullScreenCodeViewController(content: content)
        // Use .overFullScreen to keep the presenting VC in the window hierarchy.
        // .fullScreen removes the presenter's view, which triggers SwiftUI
        // onDisappear/onAppear on the ChatView — causing a full session
        // disconnect + reconnect cycle and potential session routing bugs.
        controller.modalPresentationStyle = .overFullScreen
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID().preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

    private func presentFullScreenImage(_ image: UIImage) {
        guard let presenter = nearestViewController() else { return }
        let controller = FullScreenImageViewController(image: image)
        // Use .overFullScreen — see showFullScreenContent() comment.
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionView and
    /// invalidate its layout so self-sizing cells get re-measured.
    private func invalidateEnclosingCollectionViewLayout() {
        var view: UIView? = superview
        while let current = view {
            if let collectionView = current as? UICollectionView {
                UIView.performWithoutAnimation {
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                }
                return
            }
            view = current.superview
        }
    }

    private func contextMenuTarget(for interactionView: UIView?) -> ContextMenuTarget? {
        guard let interactionView else {
            return nil
        }

        if interactionView === commandContainer {
            return .command
        }

        if interactionView === outputContainer {
            return .output
        }

        if interactionView === expandedContainer {
            return .expanded
        }

        if interactionView === imagePreviewContainer {
            return .imagePreview
        }

        return nil
    }

    private func feedbackView(for target: ContextMenuTarget) -> UIView {
        switch target {
        case .command:
            commandContainer
        case .output:
            outputContainer
        case .expanded:
            expandedContainer
        case .imagePreview:
            imagePreviewContainer
        }
    }

    func contextMenu(for target: ContextMenuTarget) -> UIMenu? {
        let command = commandCopyText
        let output = outputCopyText

        var actions: [UIMenuElement] = []

        switch target {
        case .command:
            if let command {
                actions.append(
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        guard let self else { return }
                        self.copy(text: command, feedbackView: self.feedbackView(for: target))
                    }
                )
            }

            if let output {
                actions.append(
                    UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        guard let self else { return }
                        self.copy(text: output, feedbackView: self.feedbackView(for: target))
                    }
                )
            }

        case .output, .expanded:
            guard let output else {
                return nil
            }

            if target == .expanded,
               canShowFullScreenContent {
                actions.append(
                    UIAction(
                        title: "Open Full Screen",
                        image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                    ) { [weak self] _ in
                        self?.showFullScreenContent()
                    }
                )
            }

            actions.append(
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    guard let self else { return }
                    self.copy(text: output, feedbackView: self.feedbackView(for: target))
                }
            )

            if let command {
                actions.append(
                    UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { [weak self] _ in
                        guard let self else { return }
                        self.copy(text: command, feedbackView: self.feedbackView(for: target))
                    }
                )
            }

        case .imagePreview:
            guard let image = imagePreviewImageView.image else { return nil }
            actions.append(
                UIAction(
                    title: "View Full Screen",
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { [weak self] _ in
                    self?.presentFullScreenImage(image)
                }
            )
            actions.append(
                UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = image
                }
            )
            actions.append(
                UIAction(title: "Save to Photos", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    PhotoLibrarySaver.save(image)
                }
            )
        }

        guard !actions.isEmpty else {
            return nil
        }

        return UIMenu(title: "", children: actions)
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
            self.scrollToBottom(self.outputScrollView, animated: false)
        }
    }

    private func scheduleExpandedAutoScrollToBottomIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.expandedShouldAutoFollow,
                  !self.expandedContainer.isHidden else {
                return
            }
            self.scrollToBottom(self.expandedScrollView, animated: false)
        }
    }

    private func clampScrollOffsetIfNeeded(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let viewportWidth = max(0, scrollView.bounds.width - inset.left - inset.right)
        let viewportHeight = max(0, scrollView.bounds.height - inset.top - inset.bottom)

        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - viewportWidth + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - viewportHeight + inset.bottom)

        var clamped = scrollView.contentOffset
        clamped.x = min(max(clamped.x, minX), maxX)
        clamped.y = min(max(clamped.y, minY), maxY)

        guard abs(clamped.x - scrollView.contentOffset.x) > 0.5
                || abs(clamped.y - scrollView.contentOffset.y) > 0.5 else {
            return
        }

        scrollView.setContentOffset(clamped, animated: false)
    }

    private func resetScrollPosition(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: -inset.top),
            animated: false
        )
    }

    private func scrollToBottom(_ scrollView: UIScrollView, animated: Bool) {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard viewportHeight > 0 else { return }

        let bottomY = max(
            -inset.top,
            scrollView.contentSize.height - viewportHeight + inset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: bottomY),
            animated: animated
        )
    }

    private func isNearBottom(_ scrollView: UIScrollView) -> Bool {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard viewportHeight > 0 else { return true }

        let bottomY = scrollView.contentOffset.y + inset.top + viewportHeight
        let distance = max(0, scrollView.contentSize.height - bottomY)
        return distance <= Self.autoFollowBottomThreshold
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === outputScrollView {
            outputShouldAutoFollow = isNearBottom(outputScrollView)
        } else if scrollView === expandedScrollView {
            expandedShouldAutoFollow = isNearBottom(expandedScrollView)
        }
    }

    private func applyToolIcon(toolNamePrefix: String?, toolNameColor: UIColor) {
        guard let symbolName = Self.toolSymbolName(for: toolNamePrefix),
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

    private static func toolSymbolName(for toolNamePrefix: String?) -> String? {
        switch toolNamePrefix {
        case "$":
            return "dollarsign"
        case "read":
            return "magnifyingglass"
        case "write":
            return "pencil"
        case "edit":
            return "arrow.left.arrow.right"
        case "todo":
            return "checklist"
        case "remember":
            return "brain.head.profile"
        case "recall":
            return "brain.head.profile"
        default:
            return nil
        }
    }

    private static func languageBadgeSymbolName(for badge: String?) -> String? {
        guard let badge, !badge.isEmpty else {
            return nil
        }

        let normalized = badge.lowercased()
        if normalized.contains("⚠︎media") || normalized.contains("media") {
            return "exclamationmark.triangle"
        }

        if normalized.contains("swift"), UIImage(systemName: "swift") != nil {
            return "swift"
        }

        return Self.genericLanguageBadgeSymbolName
    }

}

// MARK: - Native Expanded Tool Views (UIKit Hot Path)

private final class NativeExpandedTodoView: UIView {
    private let rootStack = UIStackView()
    private var renderSignature: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(output: String, themeID: ThemeID) {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(themeID.rawValue)
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature

        let palette = themeID.palette
        clearRows()

        switch NativeExpandedTodoParser.parse(output) {
        case .item(let item):
            rootStack.addArrangedSubview(makeTodoItemCard(item: item, palette: palette))

        case .list(let list):
            rootStack.addArrangedSubview(makeTodoListCard(list: list, palette: palette))

        case .text(let text):
            rootStack.addArrangedSubview(
                makePlainTextCard(
                    text: String(text.prefix(2_000)),
                    color: UIColor(palette.fg),
                    palette: palette
                )
            )
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func clearRows() {
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func makeTodoItemCard(item: NativeExpandedTodoItem, palette: ThemePalette) -> UIView {
        let container = makeCardContainer(palette: palette)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 8

        let idLabel = UILabel()
        idLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        idLabel.textColor = UIColor(palette.cyan)
        idLabel.text = item.displayID
        topRow.addArrangedSubview(idLabel)

        if let status = item.status, !status.isEmpty {
            topRow.addArrangedSubview(makeStatusBadge(status: status, palette: palette))
        }

        topRow.addArrangedSubview(UIView())

        if let createdAt = item.createdAt, !createdAt.isEmpty {
            let createdLabel = UILabel()
            createdLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            createdLabel.textColor = UIColor(palette.comment)
            createdLabel.text = createdAt
            topRow.addArrangedSubview(createdLabel)
        }

        stack.addArrangedSubview(topRow)

        if let title = item.title, !title.isEmpty {
            let titleLabel = UILabel()
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = UIColor(palette.fg)
            titleLabel.numberOfLines = 0
            titleLabel.text = title
            stack.addArrangedSubview(titleLabel)
        }

        if !item.normalizedTags.isEmpty {
            let tagsLabel = UILabel()
            tagsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            tagsLabel.textColor = UIColor(palette.blue)
            tagsLabel.numberOfLines = 2
            let visibleTags = item.normalizedTags.prefix(10).joined(separator: ", ")
            tagsLabel.text = "tags: \(visibleTags)"
            stack.addArrangedSubview(tagsLabel)
        }

        let body = item.trimmedBody
        if !body.isEmpty {
            let bodyLabel = UILabel()
            bodyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            bodyLabel.textColor = UIColor(palette.fg)
            bodyLabel.numberOfLines = 0
            bodyLabel.text = String(body.prefix(8_000))
            stack.addArrangedSubview(bodyLabel)

            if body.count > 8_000 {
                let truncated = UILabel()
                truncated.font = .systemFont(ofSize: 10, weight: .regular)
                truncated.textColor = UIColor(palette.comment)
                truncated.text = "… body truncated"
                stack.addArrangedSubview(truncated)
            }
        }

        return container
    }

    private func makeTodoListCard(list: NativeExpandedTodoListPayload, palette: ThemePalette) -> UIView {
        let container = makeCardContainer(palette: palette)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        for section in list.sections {
            guard !section.items.isEmpty else { continue }

            let sectionTitle = UILabel()
            sectionTitle.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            sectionTitle.textColor = UIColor(palette.comment)
            sectionTitle.text = section.title
            stack.addArrangedSubview(sectionTitle)

            for item in section.items.prefix(12) {
                let row = UILabel()
                row.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                row.textColor = UIColor(palette.fg)
                row.numberOfLines = 1
                row.lineBreakMode = .byTruncatingTail
                row.text = item.listSummaryLine
                stack.addArrangedSubview(row)
            }

            if section.items.count > 12 {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(section.items.count - 12) more"
                stack.addArrangedSubview(more)
            }
        }

        if stack.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(
                makePlainTextCard(
                    text: "No todo items in output",
                    color: UIColor(palette.comment),
                    palette: palette
                )
            )
        }

        return container
    }

    private func makePlainTextCard(text: String, color: UIColor, palette: ThemePalette) -> UIView {
        let container = makeCardContainer(palette: palette)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.numberOfLines = 0
        label.text = text

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }

    private func makeCardContainer(palette: ThemePalette) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor
        return container
    }

    private func makeStatusBadge(status: String, palette: ThemePalette) -> UIView {
        let normalized = status.lowercased()
        let tint: UIColor
        switch normalized {
        case "done", "closed":
            tint = UIColor(palette.green)
        case "in-progress", "in_progress", "inprogress":
            tint = UIColor(palette.orange)
        case "open":
            tint = UIColor(palette.blue)
        default:
            tint = UIColor(palette.comment)
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textColor = tint
        label.text = status

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = tint.withAlphaComponent(0.12)
        container.layer.cornerRadius = 8
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }
}

private enum NativeExpandedTodoParsed {
    case item(NativeExpandedTodoItem)
    case list(NativeExpandedTodoListPayload)
    case text(String)
}

private struct NativeExpandedTodoItem: Decodable {
    let id: String?
    let title: String?
    let tags: [String]?
    let status: String?
    let createdAt: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tags
        case status
        case createdAt = "created_at"
        case body
    }

    var looksLikeTodo: Bool {
        id != nil || title != nil || status != nil || createdAt != nil || body != nil || !(tags ?? []).isEmpty
    }

    var displayID: String {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "TODO-unknown" : trimmed
    }

    var normalizedTags: [String] {
        tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
    }

    var trimmedBody: String {
        (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var listSummaryLine: String {
        var parts: [String] = [displayID]
        if let status, !status.isEmpty {
            parts.append("[\(status)]")
        }
        if let title, !title.isEmpty {
            parts.append(title)
        }
        return parts.joined(separator: " ")
    }
}

private struct NativeExpandedTodoSection {
    let title: String
    let items: [NativeExpandedTodoItem]
}

private struct NativeExpandedTodoListPayload: Decodable {
    let assigned: [NativeExpandedTodoItem]?
    let open: [NativeExpandedTodoItem]?
    let closed: [NativeExpandedTodoItem]?

    var hasSections: Bool {
        assigned != nil || open != nil || closed != nil
    }

    var sections: [NativeExpandedTodoSection] {
        [
            NativeExpandedTodoSection(title: "Assigned", items: assigned ?? []),
            NativeExpandedTodoSection(title: "Open", items: open ?? []),
            NativeExpandedTodoSection(title: "Closed", items: closed ?? []),
        ]
    }
}

private enum NativeExpandedTodoParser {
    static func parse(_ output: String) -> NativeExpandedTodoParsed {
        guard let data = output.data(using: .utf8) else {
            return .text(output)
        }

        let decoder = JSONDecoder()

        if let list = try? decoder.decode(NativeExpandedTodoListPayload.self, from: data), list.hasSections {
            return .list(list)
        }

        if let item = try? decoder.decode(NativeExpandedTodoItem.self, from: data), item.looksLikeTodo {
            return .item(item)
        }

        return .text(output)
    }
}

private final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
    private var decodeTasks: [Task<Void, Never>] = []
    private var renderGeneration = 0
    private var renderSignature: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int,
        themeID: ThemeID
    ) {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(isError)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(themeID.rawValue)
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature

        cancelDecodeTasks()
        clearRows()

        let palette = themeID.palette
        let parsed = NativeExpandedReadMediaParser.parse(output)

        if let filePath, !filePath.isEmpty {
            let pathLabel = UILabel()
            pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            pathLabel.textColor = UIColor(palette.comment)
            pathLabel.numberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.text = filePath.shortenedPath
            rootStack.addArrangedSubview(pathLabel)
        }

        if !parsed.strippedText.isEmpty {
            let textLabel = UILabel()
            textLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textLabel.textColor = UIColor(isError ? palette.red : palette.fg)
            textLabel.numberOfLines = 0
            textLabel.text = String(parsed.strippedText.prefix(3_000))
            rootStack.addArrangedSubview(makeCardView(contentView: textLabel, palette: palette))
        }

        if !parsed.images.isEmpty {
            let countLabel = UILabel()
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Images (\(parsed.images.count))"
            rootStack.addArrangedSubview(countLabel)

            let visibleImages = parsed.images.prefix(4)
            for image in visibleImages {
                rootStack.addArrangedSubview(makeImageCard(image: image, palette: palette))
            }
            if parsed.images.count > visibleImages.count {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.images.count - visibleImages.count) more image attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if !parsed.audio.isEmpty {
            let countLabel = UILabel()
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Audio (\(parsed.audio.count))"
            rootStack.addArrangedSubview(countLabel)

            for (index, clip) in parsed.audio.prefix(6).enumerated() {
                let row = UILabel()
                row.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                row.textColor = UIColor(palette.fg)
                row.numberOfLines = 1
                row.lineBreakMode = .byTruncatingTail
                row.text = "🔊 Clip \(index + 1) • \(clip.mimeType ?? "audio/unknown")"
                rootStack.addArrangedSubview(makeCardView(contentView: row, palette: palette))
            }
            if parsed.audio.count > 6 {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.audio.count - 6) more audio attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if parsed.strippedText.isEmpty && parsed.images.isEmpty && parsed.audio.isEmpty {
            let empty = UILabel()
            empty.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            empty.textColor = UIColor(palette.comment)
            empty.numberOfLines = 0
            empty.text = "No readable media output"
            rootStack.addArrangedSubview(makeCardView(contentView: empty, palette: palette))
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeCardView(contentView: UIView, palette: ThemePalette) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            contentView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }

    private func makeImageCard(image: ImageExtractor.ExtractedImage, palette: ThemePalette) -> UIView {
        let card = TappableImageCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(palette.bgDark)
        card.layer.cornerRadius = 8
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 180),
        ])

        card.configure(placeholderColor: UIColor(palette.comment))

        let generation = renderGeneration
        let base64 = image.base64
        let task = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.renderGeneration == generation else {
                return
            }

            card.setDecodedImage(decoded)
        }

        decodeTasks.append(task)
        return card
    }

    private func clearRows() {
        renderGeneration += 1
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func cancelDecodeTasks() {
        for task in decodeTasks {
            task.cancel()
        }
        decodeTasks.removeAll(keepingCapacity: false)
    }
}

/// Interactive image card with tap-to-fullscreen and context menu (Copy/Save/Share).
///
/// Used by `NativeExpandedReadMediaView` for expanded image cards and designed
/// to be self-contained — handles its own gestures and modal presentation.
private final class TappableImageCard: UIView, UIContextMenuInteractionDelegate {
    private let cardImageView = UIImageView()
    private let placeholderLabel = UILabel()
    private(set) var decodedImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(placeholderColor: UIColor) {
        cardImageView.translatesAutoresizingMaskIntoConstraints = false
        cardImageView.contentMode = .scaleAspectFit
        cardImageView.clipsToBounds = true
        addSubview(cardImageView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.text = "Decoding image…"
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            cardImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardImageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @MainActor
    func setDecodedImage(_ image: UIImage?) {
        decodedImage = image
        if let image {
            cardImageView.image = image
            placeholderLabel.isHidden = true
        } else {
            placeholderLabel.text = "Image preview unavailable"
            placeholderLabel.isHidden = false
        }
    }

    @objc private func handleTap() {
        guard let image = decodedImage else { return }
        presentFullScreenImage(image)
    }

    private func presentFullScreenImage(_ image: UIImage) {
        guard let presenter = nearestViewController() else { return }
        let controller = FullScreenImageViewController(image: image)
        // Use .overFullScreen — see ToolTimelineRowContentView.showFullScreenContent() comment.
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let image = decodedImage else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: "", children: [
                UIAction(
                    title: "View Full Screen",
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { _ in
                    self?.presentFullScreenImage(image)
                },
                UIAction(
                    title: "Copy Image",
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.image = image
                },
                UIAction(
                    title: "Save to Photos",
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { _ in
                    PhotoLibrarySaver.save(image)
                },
            ])
        }
    }
}

private struct NativeExpandedReadMediaParsed {
    let strippedText: String
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
}

private enum NativeExpandedReadMediaParser {
    static func parse(_ output: String) -> NativeExpandedReadMediaParsed {
        let images = ImageExtractor.extract(from: output)
        let audio = AudioExtractor.extract(from: output)

        let strippedText: String
        if images.isEmpty && audio.isEmpty {
            strippedText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            var text = output
            let ranges = (images.map(\.range) + audio.map(\.range))
                .sorted { $0.lowerBound > $1.lowerBound }
            for range in ranges {
                text.removeSubrange(range)
            }
            strippedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return NativeExpandedReadMediaParsed(
            strippedText: strippedText,
            images: images,
            audio: audio
        )
    }
}

extension ToolTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let target = contextMenuTarget(for: interaction.view),
              contextMenu(for: target) != nil else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: target)
        }
    }
}
