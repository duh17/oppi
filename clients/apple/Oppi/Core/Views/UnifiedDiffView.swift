import SwiftUI
import UIKit

/// Shared high-performance diff renderer used across review and history surfaces.
///
/// Renders server/local hunks with syntax highlighting, numbered lines, and
/// optional word-level spans inside a selectable `UITextView`.
///
/// The attributed string build runs off the main thread via `Task.detached`
/// to prevent app hangs on large diffs (500+ lines).
struct UnifiedDiffView: View {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String
    var emptyTitle = "No Textual Changes"
    var emptySystemImage = "checkmark.circle"
    var emptyDescription = "This diff has no textual changes to show."
    var selectedTextSourceContext: SelectedTextSourceContext?

    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @Environment(\.piQuickActionStore) private var piQuickActionStore

    /// Pre-built attributed string + measured width, computed off main thread.
    @State private var built: BuiltDiff?

    var body: some View {
        Group {
            if hunks.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.themeBgDark)
            } else if let built {
                UnifiedDiffTextView(
                    built: built,
                    piRouter: piRouter,
                    piQuickActionStore: piQuickActionStore,
                    sourceContext: selectedTextSourceContext
                )
                .ignoresSafeArea(.keyboard)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.themeBgDark)
            }
        }
        .task(id: filePath + "|\(hunks.count)") {
            guard !hunks.isEmpty else { return }
            let h = hunks
            let fp = filePath
            let result = await Task.detached(priority: .userInitiated) {
                let attrText = DiffAttributedStringBuilder.build(hunks: h, filePath: fp)
                let measured = attrText.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                return BuiltDiff(attributedText: attrText, contentWidth: ceil(measured.width) + 20)
            }.value
            built = result
        }
    }
}

// MARK: - Async Build

extension UnifiedDiffView {
    /// Build result passed to the UIKit text view.
    struct BuiltDiff: @unchecked Sendable {
        let attributedText: NSAttributedString
        let contentWidth: CGFloat
    }

}

// MARK: - Layout Manager

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

        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.10))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.08))
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

// MARK: - UIViewRepresentable

/// Non-scrolling UITextView inside a UIScrollView — displays a pre-built
/// attributed string. The build happens off the main thread in the parent view.
private struct UnifiedDiffTextView: UIViewRepresentable {
    let built: UnifiedDiffView.BuiltDiff
    let piRouter: SelectedTextPiActionRouter?
    let piQuickActionStore: PiQuickActionStore?
    let sourceContext: SelectedTextSourceContext?

    func makeCoordinator() -> Coordinator {
        Coordinator(piRouter: piRouter, piQuickActionStore: piQuickActionStore, sourceContext: sourceContext)
    }

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
        textView.delegate = context.coordinator

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.backgroundColor = UIColor(Color.themeBgDark)

        textStorage.setAttributedString(built.attributedText)
        layoutManager.hostScrollView = scrollView
        layoutManager.measuredContentWidth = built.contentWidth

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
            textView.widthAnchor.constraint(equalToConstant: built.contentWidth),
            textView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        return wrapper
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.piRouter = piRouter
        context.coordinator.piQuickActionStore = piQuickActionStore
        context.coordinator.sourceContext = sourceContext
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var piRouter: SelectedTextPiActionRouter?
        var piQuickActionStore: PiQuickActionStore?
        var sourceContext: SelectedTextSourceContext?

        init(
            piRouter: SelectedTextPiActionRouter?,
            piQuickActionStore: PiQuickActionStore?,
            sourceContext: SelectedTextSourceContext?
        ) {
            self.piRouter = piRouter
            self.piQuickActionStore = piQuickActionStore
            self.sourceContext = sourceContext
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            SelectedTextPiEditMenuSupport.buildMenu(
                textView: textView,
                range: range,
                suggestedActions: suggestedActions,
                router: piRouter,
                sourceContext: sourceContext,
                actionStore: piQuickActionStore
            )
        }
    }
}
