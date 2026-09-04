import Testing
import UIKit
@testable import Oppi

@Suite("Follow-tail Core Text measure")
@MainActor
struct FollowTailMeasureTests {
    @Test func unwrappedLongLineDoesNotWrapToViewport() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView()
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.size = CGSize(width: 4_000, height: CGFloat.greatestFiniteMagnitude)
        textView.text = String(repeating: "A", count: 400)
        scrollView.addSubview(textView)

        ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)

        let lineHeight = ceil(textView.font?.lineHeight ?? 16)
        #expect(scrollView.contentSize.height < lineHeight * 3)
        #expect(scrollView.contentSize.height > lineHeight * 0.5)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(scrollView))
    }

    @Test func wrappingTextUsesContainerWidth() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = makeExpandedTextView()
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.size = CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)
        textView.text = String(repeating: "word ", count: 80)
        scrollView.addSubview(textView)

        ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)

        let lineHeight = ceil(textView.font?.lineHeight ?? 16)
        #expect(scrollView.contentSize.height > lineHeight * 4)
        #expect(ToolTimelineRowUIHelpers.isNearBottom(scrollView))
    }

    private func makeExpandedTextView() -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return textView
    }
}
