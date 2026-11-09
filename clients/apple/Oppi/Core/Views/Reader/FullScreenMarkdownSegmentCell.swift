import UIKit

/// One segment of a full-screen Markdown reader.
final class FullScreenMarkdownSegmentCell: UICollectionViewCell, UITextViewDelegate, UIGestureRecognizerDelegate {
    static let reuseIdentifier = "FullScreenMarkdownSegmentCell"

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    /// Each side's inset placing this block in the reading column; the cell
    /// itself spans the full width so the margins still scroll the document.
    private(set) var readingInset: CGFloat = 0

    private lazy var segmentApplier = AssistantMarkdownSegmentApplier(
        stackView: stackView,
        textViewDelegate: self
    )

    private weak var textViewDelegate: (any UITextViewDelegate)?
    private var doubleTapActivation: (() -> Void)?
    /// Index last configured on this cell so reuse can park its segment views
    /// onto the reader host instead of destroying them.
    var appliedItemIndex: Int?
    var appliedSegmentID: MarkdownReaderSegmentID?
    var parkHandler: ((FullScreenMarkdownSegmentCell) -> Void)?
    private(set) var isGeometryPresentationReady = true
    /// Guards against re-entrant self-sizing. UICollectionView calls
    /// `preferredLayoutAttributesFitting` inside its own layout pass; when the
    /// cell held a large streaming markdown segment, forcing a synchronous
    /// `layoutIfNeeded()` here re-entered that pass and recursed until the
    /// thread stack overflowed (MetricKit badAccess in the stack-guard page).
    private var isMeasuringLayout = false
    private var lastMeasuredAttributes: UICollectionViewLayoutAttributes?
    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var foldTap = ReaderFoldTap(host: contentView) { [weak self] in
        self?.stackView.arrangedSubviews.compactMap { $0 as? BaselineSafeTextView } ?? []
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addGestureRecognizer(foldTap)
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        backgroundColor = .clear
        stackView.setContentHuggingPriority(.required, for: .vertical)
        stackView.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addGestureRecognizer(doubleTapRecognizer)
        contentView.addSubview(stackView)
        let stackLeadingConstraint = stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let stackTrailingConstraint = stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        self.stackLeadingConstraint = stackLeadingConstraint
        self.stackTrailingConstraint = stackTrailingConstraint
        NSLayoutConstraint.activate([
            stackLeadingConstraint,
            stackTrailingConstraint,
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        parkHandler?(self)
        super.prepareForReuse()
        appliedItemIndex = nil
        appliedSegmentID = nil
        parkHandler = nil
        setGeometryPresentationReady(true)
        textViewDelegate = nil
        doubleTapActivation = nil
        segmentApplier.clear()
    }

    func yieldArrangedSegmentViews() -> [UIView] {
        let views = stackView.arrangedSubviews
        for view in views {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        segmentApplier.releaseVideoViewOwnership()
        return views
    }

    func resetApplierAfterYield() {
        segmentApplier.clear()
    }

    func installArrangedSegmentViews(_ views: [UIView]) {
        for existing in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(view)
            if let textView = view as? BaselineSafeTextView {
                textView.delegate = self
                textView.taskControlHandler = segmentApplier.taskControlHandler
            }
            if let imageView = view as? NativeMarkdownImageView {
                imageView.activatePreparedDisplay()
            }
            if let videoView = view as? NativeMarkdownVideoView {
                videoView.setPlaybackVisible(true)
            }
        }
        stackView.invalidateIntrinsicContentSize()
        contentView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setVideoPlaybackVisible(_ visible: Bool) {
        for view in stackView.arrangedSubviews {
            (view as? NativeMarkdownVideoView)?.setPlaybackVisible(visible)
        }
    }

    func observePreparedImageGeometry(_ handler: @escaping (CGFloat) -> Void) {
        segmentApplier.onImagePreparedGeometry = handler
        segmentApplier.onVideoPreparedGeometry = handler
        for view in stackView.arrangedSubviews {
            if let imageView = view as? NativeMarkdownImageView {
                imageView.onPreparedGeometry = handler
            }
            if let videoView = view as? NativeMarkdownVideoView {
                videoView.onPreparedGeometry = handler
            }
        }
    }

    func setGeometryPresentationReady(_ isReady: Bool) {
        guard isGeometryPresentationReady != isReady else { return }
        isGeometryPresentationReady = isReady
        contentView.alpha = isReady ? 1 : 0
        contentView.accessibilityElementsHidden = !isReady
    }

    func bindReaderChrome(
        lineAnchorModeEnabled: Bool,
        textViewDelegate: any UITextViewDelegate,
        doubleTapActivation: (() -> Void)?,
        taskControlHandler: (any ReaderTaskControlHandling)? = nil,
        readingInset: CGFloat = 0
    ) {
        segmentApplier.taskControlHandler = taskControlHandler
        // The source-line enclosure is painted by the reader's overlay; the
        // only horizontal inset is the block's place in the reading column.
        self.readingInset = readingInset
        stackLeadingConstraint?.constant = readingInset
        stackTrailingConstraint?.constant = -readingInset
        _ = lineAnchorModeEnabled
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
    }

    func apply(
        segment: FlatSegment,
        config: AssistantMarkdownContentView.Configuration,
        sourceLineRange: ClosedRange<Int>?,
        lineAnchorModeEnabled: Bool,
        palette: ThemePalette,
        textViewDelegate: any UITextViewDelegate,
        doubleTapActivation: (() -> Void)?,
        canonicalWidth: CGFloat? = nil,
        preparesImagesForDisplay: Bool = true
    ) {
        // Source-line chrome overlays the cell; arranged content always uses
        // the canonical width, less the reading-column inset `bindReaderChrome`
        // set, for the ledger and artifact renderers alike.
        _ = lineAnchorModeEnabled
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
        let arrangedWidth = canonicalWidth.map { max(1, $0 - 2 * readingInset) }
        segmentApplier.preparationWidth = arrangedWidth
        segmentApplier.preparesImagesForDisplay = preparesImagesForDisplay
        segmentApplier.videoPlaybackVisible = preparesImagesForDisplay
        if let canonicalWidth, let arrangedWidth {
            bounds.size.width = canonicalWidth
            contentView.bounds.size.width = canonicalWidth
            stackView.bounds.size.width = arrangedWidth
        }
        segmentApplier.apply(
            segments: [segment],
            config: config,
            sourceLineRanges: [sourceLineRange]
        )
        stackView.invalidateIntrinsicContentSize()
        contentView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        // Break any residual self-sizing recursion: if UIKit re-enters while we
        // are already measuring, hand back the last result instead of forcing
        // another synchronous layout.
        if isMeasuringLayout {
            return lastMeasuredAttributes ?? super.preferredLayoutAttributesFitting(layoutAttributes)
        }
        isMeasuringLayout = true
        defer { isMeasuringLayout = false }

        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        let width = layoutAttributes.size.width
        if bounds.size.width != width {
            bounds.size.width = width
        }
        if contentView.bounds.size.width != width {
            contentView.bounds.size.width = width
        }

        // `systemLayoutSizeFitting` runs the Auto Layout solve internally, so we
        // do not need (and must not force) a `layoutIfNeeded()` pass here — that
        // was the re-entrancy trigger behind the streaming stack overflow.
        let targetSize = CGSize(
            width: max(1, width - 2 * readingInset),
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = stackView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size = CGSize(width: width, height: ceil(max(1, size.height)))
        lastMeasuredAttributes = attributes
        return attributes
    }

    func measuredFittingHeight(width: CGFloat) -> CGFloat {
        let targetWidth = max(1, width)
        if bounds.size.width != targetWidth {
            bounds.size.width = targetWidth
        }
        if contentView.bounds.size.width != targetWidth {
            contentView.bounds.size.width = targetWidth
        }
        let targetSize = CGSize(
            width: max(1, targetWidth - 2 * readingInset),
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = stackView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(max(1, size.height))
    }

    @objc private func handleDoubleTap() {
        doubleTapActivation?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === doubleTapRecognizer
            || otherGestureRecognizer === doubleTapRecognizer
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        textViewDelegate?.textView?(
            textView,
            editMenuForTextIn: range,
            suggestedActions: suggestedActions
        )
    }

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        textViewDelegate?.textView?(
            textView,
            primaryActionFor: textItem,
            defaultAction: defaultAction
        ) ?? defaultAction
    }

    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        textViewDelegate?.textView?(
            textView,
            menuConfigurationFor: textItem,
            defaultMenu: defaultMenu
        ) ?? UITextItem.MenuConfiguration(menu: defaultMenu)
    }
}
