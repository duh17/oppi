import SwiftUI
import UIKit

/// Shared high-performance diff renderer used across review and history surfaces.
///
/// Renders server/local hunks with syntax highlighting, numbered lines, and
/// optional word-level spans inside a selectable `UITextView`.
struct UnifiedDiffView: View {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String
    var emptyTitle = "No Textual Changes"
    var emptySystemImage = "checkmark.circle"
    var emptyDescription = "This diff has no textual changes to show."

    var body: some View {
        if hunks.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: emptySystemImage,
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBgDark)
        } else {
            UnifiedDiffTextView(hunks: hunks, filePath: filePath)
                .ignoresSafeArea(.keyboard)
        }
    }
}

/// Layout manager that draws full-width backgrounds for added/removed lines.
/// `NSAttributedString.backgroundColor` only paints behind characters; this
/// extends the tint to cover the entire line fragment rect edge-to-edge.
private final class UnifiedDiffLayoutManager: NSLayoutManager {
    /// Scroll view reference used to ensure backgrounds extend at least to the
    /// visible width when content is narrower than the viewport.
    weak var hostScrollView: UIScrollView?

    /// Measured content width set after text layout.
    var measuredContentWidth: CGFloat = 0

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let textContainer = textContainers.first else { return }

        let viewWidth = hostScrollView?.bounds.width ?? 0
        let fillWidth = max(measuredContentWidth, viewWidth)

        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.18))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.15))
        let headerBg = UIColor(Color.themeBgHighlight)

        textStorage.enumerateAttribute(diffLineKindAttributeKey, in: NSRange(location: 0, length: textStorage.length), options: []) { value, attrRange, _ in
            guard let kind = value as? String else { return }
            let bg: UIColor
            switch kind {
            case "added": bg = addedBg
            case "removed": bg = removedBg
            case "header": bg = headerBg
            default: return
            }

            let glyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                var fillRect = rect
                fillRect.origin.x = 0
                fillRect.size.width = fillWidth
                fillRect.origin.x += origin.x
                fillRect.origin.y += origin.y
                bg.setFill()
                UIRectFillUsingBlendMode(fillRect, .normal)
            }
        }
    }
}

/// Non-scrolling UITextView inside a UIScrollView — matches the proven pattern
/// from `NativeFullScreenDiffBody` that supports both horizontal and vertical
/// scrolling with explicit measured-width constraints.
private struct UnifiedDiffTextView: UIViewRepresentable {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String

    func makeUIView(context: Context) -> UIView {
        let textStorage = NSTextStorage()
        let layoutManager = UnifiedDiffLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = UITextView(frame: .zero, textContainer: textContainer)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.backgroundColor = UIColor(Color.themeBgDark)

        let attrText = DiffAttributedStringBuilder.build(hunks: hunks, filePath: filePath)
        textStorage.setAttributedString(attrText)

        // Measure content to set explicit width — drives horizontal scroll.
        let measured = attrText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let contentWidth = ceil(measured.width) + 20
        layoutManager.hostScrollView = scrollView
        layoutManager.measuredContentWidth = contentWidth

        scrollView.addSubview(textView)

        let wrapper = UIView()
        wrapper.backgroundColor = UIColor(Color.themeBgDark)
        wrapper.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),

            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalToConstant: contentWidth),
            textView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        return wrapper
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
