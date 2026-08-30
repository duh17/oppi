import AppKit
import SwiftUI

@MainActor
enum MacReviewCommentTextPaint {
    static func applyPlainTextColor(
        _ color: NSColor,
        to textView: NSTextView,
        usesAttributedText: Bool
    ) {
        guard !usesAttributedText else { return }
        textView.textColor = color
        textView.insertionPointColor = color
    }
}

/// Selectable NSTextView used for Mac review comments.
///
/// This is the honest selection surface: native AppKit selection and the
/// standard contextual menu, not a UIKit edit menu.
struct MacReviewCommentTextView: NSViewRepresentable {
    let text: String
    var attributedText: NSAttributedString? = nil
    var source: MacReviewCommentSource
    var fillsColumn = true
    var accessibilityIdentifier: String? = nil

    @Environment(\.macReviewCommentStaging) private var staging
    @Environment(\.theme) private var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.identifier = NSUserInterfaceItemIdentifier(
            accessibilityIdentifier ?? "mac.reviewComment.text"
        )

        let textView = MacReviewCommentTextViewBridge()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = fillsColumn
        textView.textContainer?.containerSize = NSSize(
            width: fillsColumn ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = !fillsColumn
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = FontPreferenceStore.macCodeFont()
        textView.identifier = NSUserInterfaceItemIdentifier(
            accessibilityIdentifier ?? "mac.reviewComment.text"
        )

        scrollView.documentView = textView
        applyContent(to: textView)
        applyHandler(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MacReviewCommentTextViewBridge else { return }
        applyContent(to: textView)
        applyHandler(to: textView)
        if let accessibilityIdentifier {
            let identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
            scrollView.identifier = identifier
            textView.identifier = identifier
        }
    }

    private func applyContent(to textView: MacReviewCommentTextViewBridge) {
        textView.font = FontPreferenceStore.macCodeFont()
        MacReviewCommentTextPaint.applyPlainTextColor(
            NSColor(theme.text.primary),
            to: textView,
            usesAttributedText: attributedText != nil
        )
        if let attributedText {
            if textView.attributedString() != attributedText {
                let selected = textView.selectedRange()
                textView.textStorage?.setAttributedString(attributedText)
                if NSMaxRange(selected) <= attributedText.length {
                    textView.setSelectedRange(selected)
                }
            }
        } else if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            if NSMaxRange(selected) <= (text as NSString).length {
                textView.setSelectedRange(selected)
            }
        }
        textView.source = source
    }

    private func applyHandler(to textView: MacReviewCommentTextViewBridge) {
        if let staging {
            textView.onAddComment = { draft in
                staging.beginDraft(draft)
            }
        } else {
            textView.onAddComment = nil
        }
        textView.source = source
    }

}

@MainActor
final class MacReviewCommentTextViewBridge: NSTextView {
    var source = MacReviewCommentSource(kind: .unknown)
    var onAddComment: ((MacReviewCommentDraft) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let built = MacReviewCommentMenuBuilder.menu(
            insertingCommentInto: menu,
            selectedText: selectedTextForReviewComment() ?? "",
            canComment: onAddComment != nil
        )
        if let item = built.items.first, item.title == MacReviewCommentMenu.addCommentTitle {
            item.target = self
            item.action = #selector(addReviewComment(_:))
        }
        return built
    }

    @objc func addReviewComment(_ sender: Any?) {
        guard let draft = currentDraft() else { return }
        onAddComment?(draft)
    }

    func selectedTextForReviewComment() -> String? {
        let range = selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let nsText = string as NSString
        guard NSMaxRange(range) <= nsText.length else { return nil }
        let selected = nsText.substring(with: range)
        let normalized = MacReviewCommentSelectionFormatting.normalizedSelectedText(selected)
        return normalized.isEmpty ? nil : normalized
    }

    func currentDraft() -> MacReviewCommentDraft? {
        let range = selectedRange()
        guard let selected = selectedTextForReviewComment() else { return nil }
        return MacReviewCommentDraft.make(
            selectedText: selected,
            utf16Range: range,
            in: string,
            source: source
        )
    }
}
