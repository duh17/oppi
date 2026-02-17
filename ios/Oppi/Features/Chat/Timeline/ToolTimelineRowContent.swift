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
    private var expandedUsesViewport = false
    private var expandedUsesMarkdownLayout = false
    private var expandedUsesReadMediaLayout = false
    private var expandedReadMediaContentView: (any UIView & UIContentView)?
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
            outputLabelWidthConstraint.constant = outputLabelWidthConstant(for: outputRenderedText)
        } else {
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
            guard let expandedRenderedText else { return }
            expandedLabelWidthConstraint.constant = expandedLabelWidthConstant(for: expandedRenderedText)

        case .text, .none:
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

    private func installExpandedReadMediaView(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int
    ) {
        clearExpandedReadMediaView()

        let hosted = UIHostingConfiguration {
            AsyncToolOutput(
                output: output,
                isError: isError,
                filePath: filePath,
                startLine: startLine
            )
        }
        .margins(.all, 0)
        .makeContentView()

        hosted.translatesAutoresizingMaskIntoConstraints = false
        expandedReadMediaContainer.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: expandedReadMediaContainer.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: expandedReadMediaContainer.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: expandedReadMediaContainer.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: expandedReadMediaContainer.bottomAnchor),
        ])

        expandedReadMediaContentView = hosted

        // UIHostingConfiguration deferred sizing — see installExpandedTodoView.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setNeedsLayout()
            self.layoutIfNeeded()
            self.invalidateEnclosingCollectionViewLayout()
        }
    }

    private func installExpandedTodoView(output: String) {
        clearExpandedReadMediaView()

        let hosted = UIHostingConfiguration {
            TodoToolOutputView(output: output)
        }
        .margins(.all, 0)
        .makeContentView()

        hosted.translatesAutoresizingMaskIntoConstraints = false
        expandedReadMediaContainer.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: expandedReadMediaContainer.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: expandedReadMediaContainer.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: expandedReadMediaContainer.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: expandedReadMediaContainer.bottomAnchor),
        ])

        expandedReadMediaContentView = hosted

        // UIHostingConfiguration views don't report correct sizes via
        // systemLayoutSizeFitting until after their first SwiftUI layout pass.
        // Force a deferred layout on the content view (so the viewport height
        // constraint updates to the correct value) then invalidate the
        // enclosing collection view's layout so the cell gets re-measured.
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

    /// Prepare for hosted SwiftUI expanded content (todo cards, read media).
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
        toolImageView.tintColor = UIColor(Color.tokyoCyan)
        toolImageView.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = UIColor(Color.tokyoFg)
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
        languageBadgeIconView.tintColor = UIColor(Color.tokyoBlue)
        languageBadgeIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        languageBadgeIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        languageBadgeIconView.setContentHuggingPriority(.required, for: .horizontal)

        addedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        addedLabel.textColor = UIColor(Color.tokyoGreen)
        addedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addedLabel.setContentHuggingPriority(.required, for: .horizontal)

        removedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        removedLabel.textColor = UIColor(Color.tokyoRed)
        removedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        removedLabel.setContentHuggingPriority(.required, for: .horizontal)

        trailingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        trailingLabel.textColor = UIColor(Color.tokyoComment)
        trailingLabel.numberOfLines = 1
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = UIColor(Color.tokyoFgDim)
        previewLabel.numberOfLines = 3

        commandContainer.layer.cornerRadius = 6
        commandContainer.backgroundColor = UIColor(Color.tokyoBgHighlight.opacity(0.9))
        commandContainer.layer.borderWidth = 1
        commandContainer.layer.borderColor = UIColor(Color.tokyoBlue.opacity(0.35)).cgColor

        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.numberOfLines = 0
        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.textColor = UIColor(Color.tokyoFg)

        outputContainer.layer.cornerRadius = 6
        outputContainer.layer.masksToBounds = true
        outputContainer.backgroundColor = UIColor(Color.tokyoBgDark)
        outputContainer.layer.borderWidth = 1
        outputContainer.layer.borderColor = UIColor(Color.tokyoComment.opacity(0.2)).cgColor

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
        outputLabel.textColor = UIColor(Color.tokyoFg)

        expandedContainer.layer.cornerRadius = 6
        expandedContainer.layer.masksToBounds = true
        expandedContainer.backgroundColor = UIColor(Color.tokyoBgDark.opacity(0.9))

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
        imagePreviewContainer.backgroundColor = UIColor(Color.tokyoBgDark)
        imagePreviewContainer.layer.cornerRadius = 6
        imagePreviewContainer.layer.masksToBounds = true
        imagePreviewContainer.isHidden = true

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
        expandFloatingButton.tintColor = UIColor(Color.tokyoCyan)
        expandFloatingButton.backgroundColor = UIColor(Color.tokyoBgHighlight)
        expandFloatingButton.layer.cornerRadius = 18
        expandFloatingButton.layer.borderWidth = 1
        expandFloatingButton.layer.borderColor = UIColor(Color.tokyoComment.opacity(0.3)).cgColor
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

    private func apply(configuration: ToolTimelineRowConfiguration) {
        let previousConfiguration = currentConfiguration
        let isExpandingTransition = !previousConfiguration.isExpanded && configuration.isExpanded
        currentConfiguration = configuration

        titleLabel.attributedText = ToolRowTextRenderer.styledTitle(
            title: configuration.title,
            toolNamePrefix: configuration.toolNamePrefix,
            toolNameColor: configuration.toolNameColor
        )
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
            trailingLabel.text = configuration.trailing
            trailingLabel.isHidden = configuration.trailing == nil
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

        let outputColor = configuration.isError ? UIColor(Color.tokyoRed) : UIColor(Color.tokyoFg)
        let wasExpandedVisible = !expandedContainer.isHidden
        let wasCommandVisible = !commandContainer.isHidden
        let wasOutputVisible = !outputContainer.isHidden
        let previousRendered = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""

        // Reset gesture interception (specific cases disable it below)
        setExpandedContainerGestureInterceptionEnabled(true)

        var showExpandedContainer = false
        var showCommandContainer = false
        var showOutputContainer = false

        if configuration.isExpanded, let expandedContent = configuration.expandedContent {
            switch expandedContent {
            case .bash(let command, let output, let unwrapped):
                // --- Command block ---
                if let command, !command.isEmpty {
                    let displayCmd = Self.displayCommandText(command)
                    if displayCmd.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes {
                        commandLabel.attributedText = ToolRowTextRenderer.shellHighlighted(displayCmd)
                    } else {
                        commandLabel.attributedText = nil
                        commandLabel.text = displayCmd
                        commandLabel.textColor = UIColor(Color.tokyoFg)
                    }
                    showCommandContainer = true
                }

                // --- Output viewport ---
                if let output, !output.isEmpty {
                    let displayOutput = Self.displayOutputText(output)
                    let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                        displayOutput, isError: configuration.isError
                    )
                    let nextRendered = presentation.attributedText?.string ?? presentation.plainText ?? ""
                    let prevOutputRendered = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                    let textChanged = prevOutputRendered != nextRendered

                    ToolRowTextRenderer.applyANSIOutputPresentation(
                        presentation, to: outputLabel, plainTextColor: outputColor
                    )
                    if unwrapped {
                        outputLabel.lineBreakMode = .byClipping
                        outputScrollView.alwaysBounceHorizontal = true
                        outputScrollView.showsHorizontalScrollIndicator = true
                        outputUsesUnwrappedLayout = true
                        outputRenderedText = nextRendered
                    } else {
                        outputLabel.lineBreakMode = .byCharWrapping
                        outputScrollView.alwaysBounceHorizontal = false
                        outputScrollView.showsHorizontalScrollIndicator = false
                        outputUsesUnwrappedLayout = false
                        outputRenderedText = nil
                    }
                    updateOutputLabelWidthIfNeeded()
                    outputViewportHeightConstraint?.isActive = true
                    showOutputContainer = true
                    outputUsesViewport = true
                    if !wasOutputVisible { outputShouldAutoFollow = true }
                    if textChanged { scheduleOutputAutoScrollToBottomIfNeeded() }
                }

                // Hide expanded container for bash (uses command+output instead)
                hideExpandedContainer(outputColor: outputColor)

            case .diff(let lines, let path):
                let diffText = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: path)
                let textChanged = previousRendered != diffText.string

                showExpandedLabel()
                expandedLabel.text = nil
                expandedLabel.attributedText = diffText
                expandedLabel.lineBreakMode = .byClipping
                expandedScrollView.alwaysBounceHorizontal = true
                expandedScrollView.showsHorizontalScrollIndicator = true
                expandedViewportMode = .diff
                expandedRenderedText = diffText.string
                updateExpandedLabelWidthIfNeeded()
                showExpandedViewport()
                showExpandedContainer = true
                expandedShouldAutoFollow = false
                if textChanged { resetScrollPosition(expandedScrollView) }

            case .code(let text, let language, let startLine, _):
                let displayText = Self.displayOutputText(text)
                let codeText = ToolRowTextRenderer.makeCodeAttributedText(
                    text: displayText, language: language, startLine: startLine ?? 1
                )
                let textChanged = previousRendered != codeText.string

                showExpandedLabel()
                expandedLabel.text = nil
                expandedLabel.attributedText = codeText
                expandedLabel.lineBreakMode = .byClipping
                expandedScrollView.alwaysBounceHorizontal = true
                expandedScrollView.showsHorizontalScrollIndicator = true
                expandedViewportMode = .code
                expandedRenderedText = codeText.string
                updateExpandedLabelWidthIfNeeded()
                showExpandedViewport()
                showExpandedContainer = true
                expandedShouldAutoFollow = false
                if textChanged { resetScrollPosition(expandedScrollView) }

            case .markdown(let text):
                let previousMarkdownRendered = expandedRenderedText ?? previousRendered
                let textChanged = previousMarkdownRendered != text

                showExpandedMarkdown()
                expandedRenderedText = text
                updateExpandedLabelWidthIfNeeded()
                expandedMarkdownView.apply(configuration: .init(
                    content: text, isStreaming: false,
                    themeID: ThemeRuntimeState.currentThemeID()
                ))
                expandedScrollView.alwaysBounceHorizontal = false
                expandedScrollView.showsHorizontalScrollIndicator = false
                expandedViewportMode = .text
                showExpandedViewport()
                showExpandedContainer = true
                if !wasExpandedVisible { expandedShouldAutoFollow = true }
                if textChanged { scheduleExpandedAutoScrollToBottomIfNeeded() }

            case .todoCard(let output):
                let previousTodoRendered = expandedRenderedText ?? previousRendered
                let textChanged = previousTodoRendered != output

                showExpandedHostedView()
                expandedRenderedText = output
                installExpandedTodoView(output: output)
                expandedScrollView.alwaysBounceHorizontal = false
                expandedScrollView.showsHorizontalScrollIndicator = false
                expandedViewportMode = .text
                showExpandedViewport()
                showExpandedContainer = true
                expandedShouldAutoFollow = false
                if textChanged { resetScrollPosition(expandedScrollView) }

            case .readMedia(let output, let filePath, let startLine):
                let previousMediaRendered = expandedRenderedText ?? previousRendered
                let textChanged = previousMediaRendered != output

                showExpandedHostedView()
                expandedRenderedText = output
                installExpandedReadMediaView(
                    output: output, isError: configuration.isError,
                    filePath: filePath, startLine: startLine
                )
                expandedScrollView.alwaysBounceHorizontal = false
                expandedScrollView.showsHorizontalScrollIndicator = false
                expandedViewportMode = .text
                showExpandedViewport()
                showExpandedContainer = true
                expandedShouldAutoFollow = false
                if textChanged { resetScrollPosition(expandedScrollView) }

            case .text(let text, let language):
                let displayText = Self.displayOutputText(text)
                let presentation: ToolRowTextRenderer.ANSIOutputPresentation
                if let language, !configuration.isError {
                    presentation = ToolRowTextRenderer.makeSyntaxOutputPresentation(
                        displayText, language: language
                    )
                } else {
                    presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                        displayText, isError: configuration.isError
                    )
                }
                let nextRendered = presentation.attributedText?.string ?? presentation.plainText ?? ""
                let textChanged = previousRendered != nextRendered

                showExpandedLabel()
                ToolRowTextRenderer.applyANSIOutputPresentation(
                    presentation, to: expandedLabel, plainTextColor: outputColor
                )
                expandedLabel.lineBreakMode = .byCharWrapping
                expandedScrollView.alwaysBounceHorizontal = false
                expandedScrollView.showsHorizontalScrollIndicator = false
                expandedViewportMode = .text
                expandedRenderedText = nil
                updateExpandedLabelWidthIfNeeded()
                showExpandedViewport()
                showExpandedContainer = true
                if !wasExpandedVisible { expandedShouldAutoFollow = true }
                if textChanged { scheduleExpandedAutoScrollToBottomIfNeeded() }
            }
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
            commandLabel.textColor = UIColor(Color.tokyoFg)
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
        expandFloatingButton.isHidden = expandedContainer.isHidden || fullScreenContent == nil
        updateViewportHeightsIfNeeded()

        let symbolName: String
        let statusColor: UIColor
        if !configuration.isDone {
            symbolName = "play.circle.fill"
            statusColor = UIColor(Color.tokyoBlue)
        } else if configuration.isError {
            symbolName = "xmark.circle.fill"
            statusColor = UIColor(Color.tokyoRed)
        } else {
            symbolName = "checkmark.circle.fill"
            statusColor = UIColor(Color.tokyoGreen)
        }

        statusImageView.image = UIImage(systemName: symbolName)
        statusImageView.tintColor = statusColor

        if !configuration.isDone {
            borderView.backgroundColor = UIColor(Color.tokyoBgHighlight.opacity(0.75))
            borderView.layer.borderColor = UIColor(Color.tokyoBlue.opacity(0.25)).cgColor
        } else if configuration.isError {
            borderView.backgroundColor = UIColor(Color.tokyoRed.opacity(0.08))
            borderView.layer.borderColor = UIColor(Color.tokyoRed.opacity(0.25)).cgColor
        } else {
            borderView.backgroundColor = UIColor(Color.tokyoGreen.opacity(0.06))
            borderView.layer.borderColor = UIColor(Color.tokyoComment.opacity(0.2)).cgColor
        }
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

    private func setExpandedContainerGestureInterceptionEnabled(_ enabled: Bool) {
        expandedDoubleTapGesture.isEnabled = enabled
        expandedSingleTapBlocker.isEnabled = enabled
        expandedPinchGesture.isEnabled = enabled
    }

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

        let view = FullScreenCodeView(content: content)
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .fullScreen
        controller.view.backgroundColor = UIColor(Color.tokyoBgDark)
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
    /// Used after UIHostingConfiguration views complete their first SwiftUI
    /// layout pass and report a different intrinsic size.
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

    private func copy(text: String, feedbackView: UIView) {
        UIPasteboard.general.string = text

        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.8)

        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            feedbackView.alpha = 0.78
        } completion: { _ in
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseOut]
            ) {
                feedbackView.alpha = 1
            }
        }
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

extension ToolTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let isCommandTarget = interaction.view === commandContainer
        let isOutputTarget = interaction.view === outputContainer || interaction.view === expandedContainer

        let command = commandCopyText
        let output = outputCopyText

        var actions: [UIMenuElement] = []

        if isCommandTarget, let command {
            actions.append(
                UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { [weak self] _ in
                    guard let self else { return }
                    self.copy(text: command, feedbackView: self.commandContainer)
                }
            )
            if let output {
                actions.append(
                    UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        guard let self else { return }
                        self.copy(text: output, feedbackView: self.commandContainer)
                    }
                )
            }
        } else if isOutputTarget, let output {
            if interaction.view === expandedContainer,
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
                UIAction(title: "Copy Output", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    guard let self else { return }
                    let feedbackView = interaction.view ?? self.outputContainer
                    self.copy(text: output, feedbackView: feedbackView)
                }
            )
            if let command {
                actions.append(
                    UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { [weak self] _ in
                        guard let self else { return }
                        let feedbackView = interaction.view ?? self.outputContainer
                        self.copy(text: command, feedbackView: feedbackView)
                    }
                )
            }
        }

        guard !actions.isEmpty else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: actions)
        }
    }
}
