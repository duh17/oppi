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

enum MacReviewCommentTextHeightBehavior: Equatable {
    case fillAvailable
    case fitContent(maxHeight: CGFloat)
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
    var heightBehavior: MacReviewCommentTextHeightBehavior = .fillAvailable
    var accessibilityIdentifier: String? = nil

    @Environment(\.macReviewCommentStaging) private var staging
    @Environment(\.theme) private var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
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
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.font = FontPreferenceStore.macCodeFont()
        textView.identifier = NSUserInterfaceItemIdentifier(
            accessibilityIdentifier ?? "mac.reviewComment.text"
        )

        scrollView.documentView = textView
        applyLayout(to: scrollView, textView: textView)
        applyContent(to: textView)
        applyHandler(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MacReviewCommentTextViewBridge else { return }
        applyLayout(to: scrollView, textView: textView)
        applyContent(to: textView)
        applyHandler(to: textView)
        if let accessibilityIdentifier {
            let identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
            scrollView.identifier = identifier
            textView.identifier = identifier
        }
        scrollView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard case .fitContent(let maximumHeight) = heightBehavior,
              let width = finitePositive(proposal.width ?? scrollView.bounds.width),
              let heightLimit = finitePositive(
                min(finitePositive(proposal.height) ?? maximumHeight, maximumHeight)
              ),
              let textView = scrollView.documentView as? MacReviewCommentTextViewBridge,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return nil
        }

        var clipSize = anticipatedClipSize(
            frameSize: NSSize(width: width, height: heightLimit),
            scrollView: scrollView,
            hasHorizontalScroller: false,
            hasVerticalScroller: false
        )
        var textSize = measuredTextSize(
            textView: textView,
            textContainer: textContainer,
            layoutManager: layoutManager,
            clipWidth: visibleWidth(of: clipSize, scrollView: scrollView)
        )
        var hasHorizontalScroller = !fillsColumn
            && textSize.width > visibleWidth(of: clipSize, scrollView: scrollView) + 0.5
        clipSize = anticipatedClipSize(
            frameSize: NSSize(width: width, height: heightLimit),
            scrollView: scrollView,
            hasHorizontalScroller: hasHorizontalScroller,
            hasVerticalScroller: false
        )
        var hasVerticalScroller = textSize.height
            > visibleHeight(of: clipSize, scrollView: scrollView) + 0.5

        if hasVerticalScroller {
            clipSize = anticipatedClipSize(
                frameSize: NSSize(width: width, height: heightLimit),
                scrollView: scrollView,
                hasHorizontalScroller: false,
                hasVerticalScroller: true
            )
            textSize = measuredTextSize(
                textView: textView,
                textContainer: textContainer,
                layoutManager: layoutManager,
                clipWidth: visibleWidth(of: clipSize, scrollView: scrollView)
            )
            hasHorizontalScroller = !fillsColumn
                && textSize.width > visibleWidth(of: clipSize, scrollView: scrollView) + 0.5
            clipSize = anticipatedClipSize(
                frameSize: NSSize(width: width, height: heightLimit),
                scrollView: scrollView,
                hasHorizontalScroller: hasHorizontalScroller,
                hasVerticalScroller: true
            )
            hasVerticalScroller = textSize.height
                > visibleHeight(of: clipSize, scrollView: scrollView) + 0.5
        }

        let naturalFrameSize = anticipatedFrameSize(
            contentSize: NSSize(
                width: textSize.width + scrollView.contentInsets.left + scrollView.contentInsets.right,
                height: textSize.height + scrollView.contentInsets.top + scrollView.contentInsets.bottom
            ),
            scrollView: scrollView,
            hasHorizontalScroller: hasHorizontalScroller,
            hasVerticalScroller: hasVerticalScroller
        )
        let fittedHeight = hasVerticalScroller ? heightLimit : min(naturalFrameSize.height, heightLimit)
        let fittedClipSize = anticipatedClipSize(
            frameSize: NSSize(width: width, height: fittedHeight),
            scrollView: scrollView,
            hasHorizontalScroller: hasHorizontalScroller,
            hasVerticalScroller: hasVerticalScroller
        )

        scrollView.hasHorizontalScroller = hasHorizontalScroller
        scrollView.hasVerticalScroller = hasVerticalScroller
        textView.setFrameSize(NSSize(
            width: max(fittedClipSize.width, textSize.width),
            height: max(fittedClipSize.height, textSize.height)
        ))
        return CGSize(width: width, height: fittedHeight)
    }

    private func measuredTextSize(
        textView: NSTextView,
        textContainer: NSTextContainer,
        layoutManager: NSLayoutManager,
        clipWidth: CGFloat
    ) -> NSSize {
        if fillsColumn {
            textView.setFrameSize(NSSize(
                width: max(clipWidth, 1),
                height: max(textView.frame.height, 1)
            ))
        }
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let font = textView.font ?? FontPreferenceStore.macCodeFont()
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        // TextKit's used rect already includes both line-fragment padding edges.
        return NSSize(
            width: ceil(max(usedRect.width, 1) + textView.textContainerInset.width * 2),
            height: ceil(max(usedRect.height, lineHeight) + textView.textContainerInset.height * 2)
        )
    }

    private func anticipatedClipSize(
        frameSize: NSSize,
        scrollView: NSScrollView,
        hasHorizontalScroller: Bool,
        hasVerticalScroller: Bool
    ) -> NSSize {
        NSScrollView.contentSize(
            forFrameSize: frameSize,
            horizontalScrollerClass: scrollerClass(
                scrollView.horizontalScroller,
                isEnabled: hasHorizontalScroller
            ),
            verticalScrollerClass: scrollerClass(
                scrollView.verticalScroller,
                isEnabled: hasVerticalScroller
            ),
            borderType: scrollView.borderType,
            controlSize: scrollerControlSize(for: scrollView),
            scrollerStyle: scrollView.scrollerStyle
        )
    }

    private func anticipatedFrameSize(
        contentSize: NSSize,
        scrollView: NSScrollView,
        hasHorizontalScroller: Bool,
        hasVerticalScroller: Bool
    ) -> NSSize {
        NSScrollView.frameSize(
            forContentSize: contentSize,
            horizontalScrollerClass: scrollerClass(
                scrollView.horizontalScroller,
                isEnabled: hasHorizontalScroller
            ),
            verticalScrollerClass: scrollerClass(
                scrollView.verticalScroller,
                isEnabled: hasVerticalScroller
            ),
            borderType: scrollView.borderType,
            controlSize: scrollerControlSize(for: scrollView),
            scrollerStyle: scrollView.scrollerStyle
        )
    }

    private func scrollerClass(_ scroller: NSScroller?, isEnabled: Bool) -> AnyClass? {
        guard isEnabled else { return nil }
        guard let scroller else { return NSScroller.self }
        return type(of: scroller)
    }

    private func scrollerControlSize(for scrollView: NSScrollView) -> NSControl.ControlSize {
        scrollView.horizontalScroller?.controlSize
            ?? scrollView.verticalScroller?.controlSize
            ?? .regular
    }

    private func visibleWidth(of clipSize: NSSize, scrollView: NSScrollView) -> CGFloat {
        max(
            clipSize.width - scrollView.contentInsets.left - scrollView.contentInsets.right,
            0
        )
    }

    private func visibleHeight(of clipSize: NSSize, scrollView: NSScrollView) -> CGFloat {
        max(
            clipSize.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom,
            0
        )
    }

    private func finitePositive(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func applyLayout(
        to scrollView: NSScrollView,
        textView: MacReviewCommentTextViewBridge
    ) {
        textView.textContainer?.widthTracksTextView = fillsColumn
        textView.textContainer?.containerSize = NSSize(
            width: fillsColumn ? max(textView.frame.width, 1) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = !fillsColumn
        textView.autoresizingMask = fillsColumn ? [.width] : []

        if heightBehavior == .fillAvailable {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
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
