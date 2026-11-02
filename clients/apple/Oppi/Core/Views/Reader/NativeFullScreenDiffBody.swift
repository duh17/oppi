import UIKit

final class NativeFullScreenDiffBody: UIView {
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let scrollView = UIScrollView()
    private let diffTextView = FullScreenReviewCommentTextView()
    private let progressView = UIActivityIndicatorView(style: .medium)
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences
    private var widthConstraint: NSLayoutConstraint?
    private var unwrappedContentWidth: CGFloat = 1
    private var builtDiffText: NSAttributedString?
    private var buildTask: Task<Void, Never>?

    private struct BuiltDiff: @unchecked Sendable {
        let text: NSAttributedString
        let width: CGFloat
    }

    init(
        document: ToolDiffDocument,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.diff.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.readerPreferences = readerPreferences

        super.init(frame: .zero)
        backgroundColor = palette.ui.bgDark

        let filePath = document.filePath
        let fileName = filePath.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let relativePath = filePath.flatMap { path -> String? in
            guard let fileName else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            return parent == path || parent.isEmpty || parent == "/" ? fileName : parent
        }

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = palette.ui.bgDark
        addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppFont.systemFeedbackMedium
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textColor = palette.ui.fg
        titleLabel.text = fileName ?? String(localized: "Changes")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = AppFont.systemSmall
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = palette.ui.fgDim
        subtitleLabel.text = relativePath ?? String(localized: "Review changes")
        subtitleLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        headerView.addSubview(textStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = palette.ui.bgDark
        addSubview(scrollView)

        diffTextView.translatesAutoresizingMaskIntoConstraints = false
        diffTextView.font = codeFont
        diffTextView.textColor = palette.ui.fg
        diffTextView.backgroundColor = .clear
        diffTextView.isEditable = false
        diffTextView.isSelectable = true
        diffTextView.isScrollEnabled = false
        diffTextView.textContainerInset = UIEdgeInsets(top: 6, left: 12, bottom: 16, right: 12)
        diffTextView.textContainer.lineFragmentPadding = 0
        diffTextView.textContainer.lineBreakMode = readerPreferences.wrapsText ? .byCharWrapping : .byClipping
        diffTextView.textContainer.widthTracksTextView = false
        diffTextView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffTextView.delegate = self
        diffTextView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )

        let widthConstraint = diffTextView.widthAnchor.constraint(equalToConstant: 1)
        self.widthConstraint = widthConstraint

        scrollView.addSubview(diffTextView)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.color = palette.ui.fgDim
        progressView.startAnimating()
        addSubview(progressView)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),

            textStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            diffTextView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            diffTextView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            diffTextView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            diffTextView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            widthConstraint,
            diffTextView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
            progressView.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        diffTextView.text = document.copyText
        applyWrapMode()
        let displayPath = filePath ?? "diff.txt"
        let lines = document.lines
        buildTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.buildDiff(lines: lines, displayPath: displayPath)
            }.value

            guard !Task.isCancelled else { return }
            self?.applyBuiltDiff(result)
        }
    }

    deinit {
        buildTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyWrapMode()
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
    }

    nonisolated private static func buildDiff(lines: [DiffLine], displayPath: String) -> BuiltDiff {
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
        let build = DiffAttributedStringBuilder.buildResult(
            hunks: hunks,
            filePath: displayPath,
            options: .init(includeStats: true, includeGapSummary: true)
        )
        let measured = build.attributedText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return BuiltDiff(
            text: build.attributedText,
            width: ceil(measured.width) + 24
        )
    }

    private func applyBuiltDiff(_ result: BuiltDiff) {
        builtDiffText = result.text
        let styledText = styledDiffText(result.text)
        diffTextView.setAttributedTextPreservingSelection(styledText)
        unwrappedContentWidth = max(result.width, measuredWidth(of: styledText))
        applyWrapMode()
        progressView.stopAnimating()
        progressView.removeFromSuperview()
        setNeedsLayout()
    }

    private func applyTextSize() {
        diffTextView.font = codeFont
        if let attributedText = builtDiffText ?? diffTextView.attributedText,
           attributedText.length > 0 {
            let styledText = styledDiffText(attributedText)
            diffTextView.setAttributedTextPreservingSelection(styledText)
            unwrappedContentWidth = measuredWidth(of: styledText)
        }
        applyWrapMode()
    }

    private func applyWrapMode() {
        let wraps = readerPreferences.wrapsText
        let viewportWidth = max(1, scrollView.bounds.width)
        let insets = diffTextView.textContainerInset
        let textContainerWidth = max(1, viewportWidth - insets.left - insets.right)
        diffTextView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        // Do not use `widthTracksTextView` + `.zero`: wrap-on first layout after a
        // 0-width open leaves a zero-height container until Wrap Text is toggled.
        diffTextView.textContainer.widthTracksTextView = false
        diffTextView.textContainer.size = wraps
            ? CGSize(width: textContainerWidth, height: .greatestFiniteMagnitude)
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scrollView.alwaysBounceHorizontal = !wraps
        scrollView.showsHorizontalScrollIndicator = !wraps
        widthConstraint?.constant = wraps ? viewportWidth : max(unwrappedContentWidth, viewportWidth)
        if wraps {
            scrollView.contentOffset.x = -scrollView.adjustedContentInset.left
        }
        diffTextView.invalidateIntrinsicContentSize()
        diffTextView.layoutManager.ensureLayout(for: diffTextView.textContainer)
    }

    private func styledDiffText(_ attributedText: NSAttributedString) -> NSAttributedString {
        FullScreenDiffTextStyle.styled(attributedText, preferences: readerPreferences)
    }

    private func measuredWidth(of attributedText: NSAttributedString) -> CGFloat {
        let measured = attributedText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return ceil(measured.width) + 24
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

extension NativeFullScreenDiffBody: ReaderBody {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        applyTextSize()
        setNeedsLayout()
    }
}

extension NativeFullScreenDiffBody: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

#if DEBUG
extension NativeFullScreenDiffBody {
    struct DiffWrappingDiagnostics: Equatable {
        let wrapsText: Bool
        let textContainerLineBreakMode: NSLineBreakMode
        let paragraphLineBreakMode: NSLineBreakMode?
        let paragraphHeadIndent: CGFloat
        let expectedCodeColumnX: CGFloat
        let fragmentCount: Int
        let firstFragmentX: CGFloat
        let secondFragmentX: CGFloat?
    }

    func diffWrappingDiagnosticsForTesting() -> DiffWrappingDiagnostics? {
        layoutIfNeeded()
        diffTextView.layoutIfNeeded()
        diffTextView.layoutManager.ensureLayout(for: diffTextView.textContainer)

        let attributedText = diffTextView.attributedText ?? NSAttributedString()
        let source = attributedText.string as NSString
        var fallback: DiffWrappingDiagnostics?
        var location = 0
        while location < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            if let diagnostics = diffWrappingDiagnosticsForLine(
                attributedText: attributedText,
                lineStart: location,
                contentsEnd: contentsEnd
            ) {
                if diagnostics.fragmentCount >= 2 {
                    return diagnostics
                }
                if fallback == nil {
                    fallback = diagnostics
                }
            }
            guard lineEnd > location else { break }
            location = lineEnd
        }
        return fallback
    }

    private func diffWrappingDiagnosticsForLine(
        attributedText: NSAttributedString,
        lineStart: Int,
        contentsEnd: Int
    ) -> DiffWrappingDiagnostics? {
        guard contentsEnd > lineStart,
              let expectedIndent = FullScreenDiffTextStyle.codeColumnIndent(
                in: attributedText,
                lineStart: lineStart,
                contentsEnd: contentsEnd
              ) else { return nil }

        let contentsRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let glyphRange = diffTextView.layoutManager.glyphRange(
            forCharacterRange: contentsRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        var fragmentXs: [CGFloat] = []
        diffTextView.layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(glyphRange, lineGlyphRange)
            guard intersection.length > 0 else { return }
            fragmentXs.append(usedRect.minX)
        }
        guard let firstFragmentX = fragmentXs.first else { return nil }

        let paragraphStyle = attributedText.attribute(
            .paragraphStyle,
            at: lineStart,
            effectiveRange: nil
        ) as? NSParagraphStyle

        return DiffWrappingDiagnostics(
            wrapsText: readerPreferences.wrapsText,
            textContainerLineBreakMode: diffTextView.textContainer.lineBreakMode,
            paragraphLineBreakMode: paragraphStyle?.lineBreakMode,
            paragraphHeadIndent: paragraphStyle?.headIndent ?? 0,
            expectedCodeColumnX: expectedIndent,
            fragmentCount: fragmentXs.count,
            firstFragmentX: firstFragmentX,
            secondFragmentX: fragmentXs.dropFirst().first
        )
    }
}
#endif
