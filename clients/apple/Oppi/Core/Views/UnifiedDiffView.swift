import SwiftUI
import UIKit

/// Shared high-performance diff renderer used across review and history surfaces.
///
/// Renders server/local hunks with syntax highlighting, numbered lines, and
/// optional word-level spans inside a selectable `UITextView`.
///
/// Small attributed strings build off-main. Large diffs build an off-main
/// source/token index, then mount only visible attributed chunks plus a runway.
struct UnifiedDiffView: View {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String
    var emptyTitle = "No Textual Changes"
    var emptySystemImage = "checkmark.circle"
    var emptyDescription = "This file has no textual changes to show."
    var reviewCommentSourceContext: ReviewCommentSourceContext?
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @Environment(\.themeID) private var themeID

    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        reviewCommentSelectionContext ?? reviewCommentSelectionScope?.makeContext()
    }

    nonisolated static func shouldUseChunkedRendering(
        for hunks: [WorkspaceReviewDiffHunk]
    ) -> Bool {
        var lineCount = 0
        var sourceUTF8Count = 0
        for hunk in hunks {
            lineCount += hunk.lines.count
            for line in hunk.lines {
                sourceUTF8Count += line.text.utf8.count + 16
            }
        }
        return sourceUTF8Count > maximumSingleTextViewUTF8Bytes
            || lineCount > maximumSingleTextViewLines
    }

    nonisolated private static let maximumSingleTextViewUTF8Bytes = 128 * 1024
    nonisolated private static let maximumSingleTextViewLines = 600

    /// Whole-document data for small diffs or an attributed-text-free chunk index.
    @State private var built: BuiltContent?

    var body: some View {
        Group {
            if hunks.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.themeBgDark)
            } else if let built {
                let sourceContext = reviewCommentSourceContext ?? effectiveReviewCommentSelectionContext?.sourceContext(
                    surface: .fullScreenDiff,
                    filePath: filePath
                )
                Group {
                    switch built {
                    case .single(let document):
                        UnifiedDiffTextView(
                            built: document,
                            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
                            sourceContext: sourceContext
                        )
                    case .chunks(let index):
                        UnifiedDiffChunkView(
                            index: index,
                            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
                            sourceContext: sourceContext
                        )
                    }
                }
                .ignoresSafeArea(.keyboard)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.themeBgDark)
            }
        }
        .task(id: filePath + "|\(hunks.count)|\(themeID.rawValue)") {
            guard !hunks.isEmpty else { return }
            let h = hunks
            let fp = filePath
            let result = await Task.detached(priority: .userInitiated) {
                if !Self.shouldUseChunkedRendering(for: h) {
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
                    return BuiltContent.single(BuiltDiff(
                        attributedText: build.attributedText,
                        contentWidth: ceil(measured.width) + 20
                    ))
                }
                return BuiltContent.chunks(DiffAttributedStringBuilder.buildChunkIndex(
                    hunks: h,
                    filePath: fp,
                    options: .init(includeStats: false, includeGapSummary: true)
                ))
            }.value
            guard !Task.isCancelled else { return }
            built = result
        }
    }
}

// MARK: - Async Build

extension UnifiedDiffView {
    enum BuiltContent: @unchecked Sendable {
        case single(BuiltDiff)
        case chunks(DiffAttributedStringBuilder.ChunkIndex)
    }

    /// Build result passed to the small-document UIKit text view.
    struct BuiltDiff: @unchecked Sendable {
        let attributedText: NSAttributedString
        let contentWidth: CGFloat
    }
}

// MARK: - Layout Manager

private final class UnifiedDiffScrollView: UIScrollView {
    weak var diffLayoutManager: DiffBackgroundLayoutManager?

    override func layoutSubviews() {
        super.layoutSubviews()
        diffLayoutManager?.viewportWidth = bounds.width
    }
}

// MARK: - UIViewRepresentable

/// Collection-backed painter shared with future native full-screen diff readers.
private struct UnifiedDiffChunkView: UIViewRepresentable {
    let index: DiffAttributedStringBuilder.ChunkIndex
    let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    let sourceContext: ReviewCommentSourceContext?

    @Environment(\.horizontalBackSwipeAction) private var horizontalBackSwipeAction

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> DiffChunkCollectionView {
        let view = DiffChunkCollectionView(
            index: index,
            backgroundColor: UIColor(Color.themeBgDark),
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            sourceContext: sourceContext
        )
        context.coordinator.installBackSwipe(
            action: horizontalBackSwipeAction,
            on: view.backSwipeHostView
        )
        return view
    }

    func updateUIView(_ uiView: DiffChunkCollectionView, context: Context) {
        uiView.update(
            index: index,
            backgroundColor: UIColor(Color.themeBgDark),
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            sourceContext: sourceContext
        )
        context.coordinator.installBackSwipe(
            action: horizontalBackSwipeAction,
            on: uiView.backSwipeHostView
        )
    }

    @MainActor
    final class Coordinator {
        private let backSwipeCoordinator = HorizontalBackSwipeActionCoordinator()

        func installBackSwipe(
            action: (@MainActor @Sendable () -> Void)?,
            on view: UIView
        ) {
            backSwipeCoordinator.install(action: action, on: view)
        }
    }
}

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
        let layoutManager = DiffBackgroundLayoutManager()
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
        let background = UIColor(Color.themeBgDark)
        uiView.backgroundColor = background
        if let scrollView = uiView.subviews.compactMap({ $0 as? UnifiedDiffScrollView }).first {
            scrollView.backgroundColor = background
            if let textView = scrollView.subviews.compactMap({ $0 as? UITextView }).first {
                textView.textStorage.setAttributedString(built.attributedText)
                if let width = textView.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil }) {
                    width.constant = built.contentWidth
                }
            }
            scrollView.diffLayoutManager?.measuredContentWidth = built.contentWidth
            scrollView.diffLayoutManager?.invalidateDisplay(forCharacterRange: NSRange(
                location: 0,
                length: built.attributedText.length
            ))
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
