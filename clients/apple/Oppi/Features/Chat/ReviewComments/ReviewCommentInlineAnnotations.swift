import UIKit

struct ReviewCommentInlineAnnotation: Equatable, Identifiable {
    let id: String
    let sessionId: String?
    let status: ReviewCommentStatus
    let body: String
    let reference: ReviewCommentReference

    var selectedText: String {
        reference.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum ReviewCommentInlineAnnotationMatcher {
    static func annotations(
        from comments: [ReviewComment],
        for sourceContext: ReviewCommentSourceContext?
    ) -> [ReviewCommentInlineAnnotation] {
        guard let sourceContext else { return [] }

        return comments.compactMap { comment in
            guard isDisplayable(comment.status),
                  matches(reference: comment.reference, sourceContext: sourceContext),
                  sessionMatches(comment: comment, sourceContext: sourceContext) else {
                return nil
            }

            let annotation = ReviewCommentInlineAnnotation(
                id: comment.id,
                sessionId: comment.sessionId,
                status: comment.status,
                body: comment.body,
                reference: comment.reference
            )
            return annotation.selectedText.isEmpty ? nil : annotation
        }
    }

    private static func isDisplayable(_ status: ReviewCommentStatus) -> Bool {
        switch status {
        case .staged, .sent, .open:
            true
        case .resolved, .dismissed:
            false
        }
    }

    private static func sessionMatches(comment: ReviewComment, sourceContext: ReviewCommentSourceContext) -> Bool {
        guard let sessionId = comment.sessionId, !sessionId.isEmpty else { return true }
        return sessionId == sourceContext.sessionId
    }

    private static func matches(reference: ReviewCommentReference, sourceContext: ReviewCommentSourceContext) -> Bool {
        guard reference.source == sourceContext.reviewCommentReferenceSource else { return false }

        if let referenceLanguage = nonEmpty(reference.languageHint),
           referenceLanguage.caseInsensitiveCompare(sourceContext.languageHint ?? "") != .orderedSame {
            return false
        }

        if let referenceTimelineItemId = nonEmpty(reference.timelineItemId) {
            return referenceTimelineItemId == sourceContext.timelineItemId
        }

        if reference.source == .file || reference.source == .gitDiff {
            if let referencePath = nonEmpty(reference.path) {
                return referencePath == sourceContext.filePath
            }
            if nonEmpty(sourceContext.filePath) != nil {
                return true
            }
        }

        return true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ReviewCommentSurfaceKind {
    var reviewCommentReferenceSource: ReviewCommentReferenceSource {
        switch self {
        case .fullScreenDiff:
            return .gitDiff
        case .fullScreenCode, .fullScreenSource, .fullScreenMarkdown:
            return .file
        case .toolCommand, .toolOutput, .toolExpandedText, .fullScreenTerminal:
            return .toolOutput
        case .assistantProse, .userMessage, .assistantCodeBlock, .assistantTable, .thinking, .fullScreenThinking:
            return .timelineText
        }
    }
}

extension ReviewCommentSourceContext {
    var reviewCommentReferenceSource: ReviewCommentReferenceSource {
        surface.reviewCommentReferenceSource
    }
}

extension Notification.Name {
    static let reviewCommentInlineAnnotationTapped = Notification.Name("oppi.reviewCommentInlineAnnotationTapped")
}

@MainActor
enum ReviewCommentInlineAnnotationRenderer {
    static func apply(
        to textView: UITextView,
        annotations: [ReviewCommentInlineAnnotation],
        sourceContext: ReviewCommentSourceContext?
    ) {
        removeExistingBubbleButtons(from: textView)

        guard let sourceContext,
              !annotations.isEmpty,
              let attributedText = textView.attributedText,
              attributedText.length > 0 else {
            return
        }

        let renderedGroups = renderedAnnotationGroups(
            text: attributedText.string,
            annotations: annotations
        )
        guard !renderedGroups.isEmpty else { return }

        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let palette = ThemeRuntimeState.currentPalette()
        let highlightColor = UIColor(palette.purple).withAlphaComponent(0.24)
        let underlineColor = UIColor(palette.purple).withAlphaComponent(0.75)

        for group in renderedGroups {
            mutable.addAttributes([
                .backgroundColor: highlightColor,
                .underlineColor: underlineColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: group.range)
        }

        textView.attributedText = mutable
        installBubbleButtons(
            groups: renderedGroups,
            in: textView,
            sourceContext: sourceContext
        )
    }

    private static func renderedAnnotationGroups(
        text: String,
        annotations: [ReviewCommentInlineAnnotation]
    ) -> [RenderedAnnotationGroup] {
        var grouped: [NSRange: [ReviewCommentInlineAnnotation]] = [:]
        for annotation in annotations {
            guard let range = firstRange(
                of: annotation.selectedText,
                in: text,
                matchingLineRange: requestedLineRange(for: annotation)
            ) else { continue }
            grouped[range, default: []].append(annotation)
        }

        return grouped
            .map { RenderedAnnotationGroup(range: $0.key, annotations: $0.value) }
            .sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    lhs.range.length < rhs.range.length
                } else {
                    lhs.range.location < rhs.range.location
                }
            }
    }

    private static func firstRange(
        of needle: String,
        in text: String,
        matchingLineRange requestedLineRange: ClosedRange<Int>?
    ) -> NSRange? {
        let normalizedNeedle = ReviewCommentSelectionTextFormatter.normalizedSelectedText(needle)
        guard !normalizedNeedle.isEmpty else { return nil }
        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let range = nsText.range(of: normalizedNeedle, options: [], range: searchRange)
            guard range.location != NSNotFound else { return nil }
            if let requestedLineRange {
                let renderedLineRange = lineRange(for: range, in: nsText)
                if renderedLineRange.overlaps(requestedLineRange) {
                    return range
                }
            } else {
                return range
            }

            let nextLocation = NSMaxRange(range)
            guard nextLocation < nsText.length else { return nil }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }
        return nil
    }

    private static func requestedLineRange(for annotation: ReviewCommentInlineAnnotation) -> ClosedRange<Int>? {
        guard let start = annotation.reference.startLine else { return nil }
        let end = annotation.reference.endLine ?? start
        return min(start, end)...max(start, end)
    }

    private static func lineRange(for range: NSRange, in text: NSString) -> ClosedRange<Int> {
        let before = text.substring(to: max(0, min(range.location, text.length)))
        let selected = text.substring(with: range)
        let startLine = before.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        let additionalLines = selected.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }
        return startLine...max(startLine, startLine + additionalLines)
    }

    private static func installBubbleButtons(
        groups: [RenderedAnnotationGroup],
        in textView: UITextView,
        sourceContext: ReviewCommentSourceContext
    ) {
        textView.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)

        for group in groups {
            guard let anchorRect = firstLineRect(for: group.range, in: textView) else { continue }
            let button = ReviewCommentInlineBubbleButton(group: group, sourceContext: sourceContext)
            textView.addSubview(button)
            button.frame = bubbleFrame(anchorRect: anchorRect, in: textView, preferredSize: button.intrinsicContentSize)
        }

        Task { @MainActor [weak textView] in
            guard let textView else { return }
            repositionBubbleButtons(in: textView)
        }
    }

    static func repositionBubbleButtons(in textView: UITextView) {
        let buttons = textView.subviews.compactMap { $0 as? ReviewCommentInlineBubbleButton }
        guard !buttons.isEmpty else { return }

        textView.layoutManager.ensureLayout(for: textView.textContainer)
        for button in buttons {
            guard let rect = firstLineRect(for: button.range, in: textView) else { continue }
            button.frame = bubbleFrame(anchorRect: rect, in: textView, preferredSize: button.intrinsicContentSize)
        }
    }

    private static func firstLineRect(for characterRange: NSRange, in textView: UITextView) -> CGRect? {
        guard characterRange.location != NSNotFound,
              characterRange.length > 0,
              NSMaxRange(characterRange) <= textView.textStorage.length else {
            return nil
        }

        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }

        var lineRect: CGRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, stop in
            lineRect = usedRect
            stop.pointee = true
        }

        guard var rect = lineRect else { return nil }
        rect.origin.x += textView.textContainerInset.left
        rect.origin.y += textView.textContainerInset.top
        rect = rect.offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
        return rect.integral
    }

    private static func bubbleFrame(anchorRect: CGRect, in textView: UITextView, preferredSize: CGSize) -> CGRect {
        let width = max(44, ceil(preferredSize.width))
        let height = max(44, ceil(preferredSize.height))
        let horizontalGap: CGFloat = 4
        let verticalGap: CGFloat = 4
        let maxX = max(0, textView.bounds.width - width)
        let x = min(max(anchorRect.maxX + horizontalGap, 0), maxX)
        let topY = anchorRect.minY - height - verticalGap
        let y = topY >= 0 ? topY : min(anchorRect.maxY + verticalGap, max(0, textView.bounds.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func removeExistingBubbleButtons(from textView: UITextView) {
        for case let button as ReviewCommentInlineBubbleButton in textView.subviews {
            button.removeFromSuperview()
        }
    }
}

private struct RenderedAnnotationGroup {
    let range: NSRange
    let annotations: [ReviewCommentInlineAnnotation]
}

private final class ReviewCommentInlineBubbleButton: UIButton {
    let range: NSRange
    private let annotations: [ReviewCommentInlineAnnotation]
    private let sourceContext: ReviewCommentSourceContext

    init(group: RenderedAnnotationGroup, sourceContext: ReviewCommentSourceContext) {
        self.range = group.range
        self.annotations = group.annotations
        self.sourceContext = sourceContext
        super.init(frame: .zero)
        configure(count: group.annotations.count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure(count: Int) {
        let palette = ThemeRuntimeState.currentPalette()
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "text.bubble")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        config.imagePadding = count > 1 ? 4 : 0
        config.title = count > 1 ? "\(count)" : nil
        config.baseBackgroundColor = UIColor(palette.bgDark).withAlphaComponent(0.94)
        config.baseForegroundColor = UIColor(palette.purple)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        configuration = config

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        accessibilityLabel = "Review comment"
        accessibilityHint = "Shows the comment for the highlighted text."
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @objc private func handleTap() {
        NotificationCenter.default.post(
            name: .reviewCommentInlineAnnotationTapped,
            object: nil,
            userInfo: [
                "commentId": annotations[0].id,
                "commentIds": annotations.map(\.id),
                "sessionId": sourceContext.sessionId,
            ]
        )
    }
}
