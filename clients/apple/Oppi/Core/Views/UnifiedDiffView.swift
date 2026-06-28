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
    var emptyDescription = "This file has no textual changes to show."
    var reviewCommentSourceContext: ReviewCommentSourceContext?
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope

    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        reviewCommentSelectionContext ?? reviewCommentSelectionScope?.makeContext()
    }

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
                    reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
                    sourceContext: reviewCommentSourceContext ?? effectiveReviewCommentSelectionContext?.sourceContext(
                        surface: .fullScreenDiff,
                        filePath: filePath
                    )
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
                let build = DiffAttributedStringBuilder.buildResult(
                    hunks: h,
                    filePath: fp,
                    options: .init(includeStats: false, includeGapSummary: true)
                )
                let measured = build.attributedText.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                return BuiltDiff(attributedText: build.attributedText, contentWidth: ceil(measured.width) + 20)
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
    /// Visible scroll width set from `UnifiedDiffScrollView.layoutSubviews()`.
    /// `drawBackground` is a nonisolated UIKit override in Swift 6, so it must
    /// not reach back into a main-actor-isolated `UIScrollView` directly.
    nonisolated(unsafe) var viewportWidth: CGFloat = 0

    /// Measured content width set after text layout.
    nonisolated(unsafe) var measuredContentWidth: CGFloat = 0

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let textContainer = textContainers.first else { return }

        let fillWidth = max(measuredContentWidth, viewportWidth)

        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.10))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.08))
        let headerBg = UIColor(Color.themeBgHighlight)
        let addedBar = UIColor(Color.themeDiffAdded)
        let removedBar = UIColor(Color.themeDiffRemoved)
        let barWidth: CGFloat = 2.5

        storage.enumerateAttribute(diffLineKindAttributeKey, in: NSRange(location: 0, length: storage.length), options: []) { value, attrRange, _ in
            guard let kind = value as? String else { return }
            let bg: UIColor
            let bar: UIColor?
            switch kind {
            case "added": bg = addedBg; bar = addedBar
            case "removed": bg = removedBg; bar = removedBar
            case "header": bg = headerBg; bar = nil
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

                // Draw left gutter bar for added/removed lines
                if let bar {
                    var barRect = fillRect
                    barRect.size.width = barWidth
                    bar.setFill()
                    UIRectFillUsingBlendMode(barRect, .normal)
                }
            }
        }
    }
}

private final class UnifiedDiffScrollView: UIScrollView {
    weak var diffLayoutManager: UnifiedDiffLayoutManager?

    override func layoutSubviews() {
        super.layoutSubviews()
        diffLayoutManager?.viewportWidth = bounds.width
    }
}

// MARK: - UIViewRepresentable

/// Non-scrolling UITextView inside a UIScrollView — displays a pre-built
/// attributed string. The build happens off the main thread in the parent view.
private struct UnifiedDiffTextView: UIViewRepresentable {
    let built: UnifiedDiffView.BuiltDiff
    let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    let sourceContext: ReviewCommentSourceContext?

    @Environment(\.horizontalBackSwipeAction) private var horizontalBackSwipeAction

    func makeCoordinator() -> Coordinator {
        Coordinator(
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            sourceContext: sourceContext
        )
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

        let scrollView = UnifiedDiffScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.backgroundColor = UIColor(Color.themeBgDark)

        textStorage.setAttributedString(built.attributedText)
        scrollView.diffLayoutManager = layoutManager
        layoutManager.viewportWidth = scrollView.bounds.width
        layoutManager.measuredContentWidth = built.contentWidth

        scrollView.addSubview(textView)
        context.coordinator.installBackSwipe(action: horizontalBackSwipeAction, on: scrollView)

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
        context.coordinator.reviewCommentSelectionContext = reviewCommentSelectionContext
        context.coordinator.sourceContext = sourceContext
        if let scrollView = uiView.subviews.compactMap({ $0 as? UnifiedDiffScrollView }).first {
            context.coordinator.installBackSwipe(action: horizontalBackSwipeAction, on: scrollView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var reviewCommentSelectionContext: ReviewCommentSelectionContext?
        var sourceContext: ReviewCommentSourceContext?
        private let backSwipeCoordinator = HorizontalBackSwipeActionCoordinator()

        init(
            reviewCommentSelectionContext: ReviewCommentSelectionContext?,
            sourceContext: ReviewCommentSourceContext?
        ) {
            self.reviewCommentSelectionContext = reviewCommentSelectionContext
            self.sourceContext = sourceContext
        }

        func installBackSwipe(
            action: (@MainActor @Sendable () -> Void)?,
            on view: UIView
        ) {
            backSwipeCoordinator.install(action: action, on: view)
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            ReviewCommentSelectionEditMenuSupport.buildMenu(
                textView: textView,
                range: range,
                suggestedActions: suggestedActions,
                router: reviewCommentSelectionContext?.dispatcher,
                sourceContext: sourceContext
            )
        }
    }
}
