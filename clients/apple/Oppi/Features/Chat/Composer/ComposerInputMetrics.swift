import UIKit

@MainActor
enum ComposerInputMetrics {
    static let controlDiameter: CGFloat = 44
    static let inlineMaxLines = 8
    static let inlineMaxLinesWithAttachments = 4
    /// Leaves room for a four-line response and the composer action row above
    /// the iPhone keyboard. Longer inline asks scroll within this viewport.
    static let inlineAskCardMaxHeightWithKeyboard: CGFloat = 240
    /// Without the keyboard there is room for a title, a few lines of the
    /// message, two or three options, and the action row.
    static let inlineAskCardMaxHeight: CGFloat = 380
    static let inlineTextMinHeight: CGFloat = 40

    static func maxTextHeight(
        font: UIFont,
        textContainerInset: UIEdgeInsets,
        maxLines: Int = inlineMaxLines
    ) -> CGFloat {
        let lineHeight = max(font.lineHeight, UIFont.preferredFont(forTextStyle: .body).lineHeight)
        return ceil(lineHeight * CGFloat(maxLines) + textContainerInset.top + textContainerInset.bottom)
    }

    static func textViewGrowth(
        for textView: UITextView,
        fittingWidth: CGFloat,
        minHeight: CGFloat = inlineTextMinHeight,
        maxLines: Int = inlineMaxLines
    ) -> (height: CGFloat, isScrollEnabled: Bool) {
        let measured = textView.sizeThatFits(
            CGSize(width: max(1, fittingWidth), height: CGFloat.greatestFiniteMagnitude)
        ).height
        let maxHeight = maxTextHeight(
            font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
            textContainerInset: textView.textContainerInset,
            maxLines: maxLines
        )
        let height = min(max(minHeight, ceil(measured)), maxHeight)
        return (height, measured > maxHeight + 1)
    }
}
