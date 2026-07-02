import AppKit
import SwiftUI

struct MacOrgDocumentPreview: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Org", systemImage: "doc.richtext")
                .font(.caption)
                .fontWeight(.semibold)
            MacAttributedDocumentTextView(attributedText: Self.render(content))
                .frame(minHeight: 120, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private static func render(_ content: String) -> NSAttributedString {
        let document = OrgParser().parse(content)
        let configuration = RenderConfiguration(
            fontSize: 13,
            maxWidth: 700,
            theme: .fallback,
            displayMode: .inline
        )
        return OrgAttributedStringRenderer().renderAttributedString(document, configuration: configuration)
    }
}

private struct MacAttributedDocumentTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedText)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }
}
