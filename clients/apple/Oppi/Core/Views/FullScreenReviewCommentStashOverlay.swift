import SwiftUI
import UIKit

/// SwiftUI host for the full-screen staged-comment control.
///
/// ``FullScreenCodeViewController`` owns this chrome for timeline and embedded
/// UIKit readers. Chat file sheets that keep SwiftUI navigation — git context
/// review, commit file diffs — never create that controller, so they install
/// the same control here. Previous-file buttons stay in the original leading
/// slot; stash stacks above them using the same padding as Annotate.
///
/// Hosts pass `scope` explicitly. The control is a UIKit floating button so
/// `accessibilityIdentifier` lands on a real `UIView` under iOS 26 glass
/// hosting, matching ``FullScreenCodeViewController``.
struct FullScreenReviewCommentStashOverlayHost<Content: View>: View {
    var isEnabled: Bool = true
    var leadingAccessoryCount: Int = 0
    var reviewCommentSelectionScope: ReviewCommentSelectionScope?
    var content: Content

    @State private var stashPresentation: ReviewCommentStripChrome.StashPresentation?

    var body: some View {
        content
            .overlay(alignment: .bottomLeading) {
                FullScreenReviewCommentStashChromeHost(
                    isEnabled: isEnabled,
                    leadingAccessoryCount: leadingAccessoryCount,
                    reviewCommentSelectionScope: reviewCommentSelectionScope,
                    onOpen: {
                        stashPresentation = ReviewCommentStripChrome.StashPresentation()
                    }
                )
            }
            .sheet(item: $stashPresentation) { presentation in
                FullScreenReviewCommentStashSheetGate(
                    isEnabled: isEnabled,
                    presentation: presentation,
                    reviewCommentSelectionScope: reviewCommentSelectionScope,
                    onClose: { stashPresentation = nil }
                )
            }
    }
}

extension View {
    func fullScreenReviewCommentStashOverlay(
        isEnabled: Bool = true,
        leadingAccessoryCount: Int = 0,
        scope: ReviewCommentSelectionScope? = nil
    ) -> some View {
        FullScreenReviewCommentStashOverlayHost(
            isEnabled: isEnabled,
            leadingAccessoryCount: leadingAccessoryCount,
            reviewCommentSelectionScope: scope,
            content: self
        )
    }
}

private struct FullScreenReviewCommentStashChromeHost: View {
    var isEnabled: Bool
    var leadingAccessoryCount: Int
    var reviewCommentSelectionScope: ReviewCommentSelectionScope?
    var onOpen: () -> Void

    var body: some View {
        if isEnabled,
           let comments = reviewCommentSelectionScope?.router.stash as? ChatReviewCommentsController {
            FullScreenReviewCommentStashChrome(
                comments: comments,
                leadingAccessoryCount: leadingAccessoryCount,
                onOpen: onOpen
            )
        }
    }
}

private struct FullScreenReviewCommentStashSheetGate: View {
    var isEnabled: Bool
    var presentation: ReviewCommentStripChrome.StashPresentation
    var reviewCommentSelectionScope: ReviewCommentSelectionScope?
    var onClose: () -> Void

    var body: some View {
        if isEnabled,
           let comments = reviewCommentSelectionScope?.router.stash as? ChatReviewCommentsController {
            FullScreenReviewCommentStashSheetHost(
                comments: comments,
                presentation: presentation,
                onClose: onClose
            )
        }
    }
}

private struct FullScreenReviewCommentStashChrome: View {
    var comments: ChatReviewCommentsController
    var leadingAccessoryCount: Int
    var onOpen: () -> Void

    @Environment(\.themeID) private var themeID

    var body: some View {
        if comments.stagedCount > 0 {
            FullScreenReviewCommentStashButtonRepresentable(
                stagedCount: comments.stagedCount,
                palette: themeID.palette,
                onOpen: onOpen
            )
            .frame(
                width: FullScreenFloatingControlChrome.controlSize,
                height: FullScreenFloatingControlChrome.controlSize
            )
            .padding(.leading, FullScreenFloatingControlChrome.leadingPadding)
            .padding(
                .bottom,
                FullScreenReviewCommentStashControl.bottomPadding(
                    leadingAccessoryCount: leadingAccessoryCount
                )
            )
        }
    }
}

private struct FullScreenReviewCommentStashButtonRepresentable: UIViewRepresentable {
    var stagedCount: Int
    var palette: ThemePalette
    var onOpen: () -> Void

    func makeUIView(context: Context) -> FullScreenReviewCommentStashButtonView {
        let view = FullScreenReviewCommentStashButtonView(palette: palette, onOpen: onOpen)
        view.update(stagedCount: stagedCount, palette: palette, onOpen: onOpen)
        return view
    }

    func updateUIView(_ uiView: FullScreenReviewCommentStashButtonView, context: Context) {
        uiView.update(stagedCount: stagedCount, palette: palette, onOpen: onOpen)
    }
}

@MainActor
private final class FullScreenReviewCommentStashButtonView: UIView {
    private let button: UIButton
    private let badge = UILabel()
    private var onOpen: () -> Void

    init(palette: ThemePalette, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        button = FullScreenFloatingControlChrome.makeStandaloneButton(
            systemImage: FullScreenReviewCommentStashControl.systemImage,
            accessibilityLabel: FullScreenReviewCommentStashControl.accessibilityLabel,
            accessibilityIdentifier: FullScreenReviewCommentStashControl.accessibilityIdentifier,
            palette: palette
        )
        super.init(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.clipsToBounds = false
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.addTarget(self, action: #selector(open), for: .touchUpInside)
        addSubview(button)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.accessibilityElementsHidden = true
        badge.isUserInteractionEnabled = false
        addSubview(badge)

        clipsToBounds = false
        isAccessibilityElement = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            button.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -2),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: FullScreenFloatingControlChrome.controlSize,
            height: FullScreenFloatingControlChrome.controlSize
        )
    }

    func update(stagedCount: Int, palette: ThemePalette, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        FullScreenFloatingControlChrome.updateStandaloneButton(button, palette: palette)
        button.accessibilityValue = FullScreenReviewCommentStashControl.accessibilityValue(for: stagedCount)
        badge.text = stagedCount > 99 ? "99+" : "\(stagedCount)"
        badge.textColor = UIColor(palette.bgDark)
        badge.backgroundColor = UIColor(palette.cyan)
    }

    @objc private func open() {
        onOpen()
    }
}

private struct FullScreenReviewCommentStashSheetHost: View {
    var comments: ChatReviewCommentsController
    var presentation: ReviewCommentStripChrome.StashPresentation
    var onClose: () -> Void

    var body: some View {
        ReviewCommentStashSheet(
            comments: comments.stagedComments,
            focusedCommentId: nil,
            initialEditingComment: presentation.initialEditingComment,
            onEdit: { comment, body in
                comments.update(comment, body: body) == nil
            },
            onDelete: { comment in
                comments.delete(comment)
            },
            onClose: onClose
        )
    }
}
