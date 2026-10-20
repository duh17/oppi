#if DEBUG
import Observation
import UIKit

enum ReviewCommentStashHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--review-comment-stash-harness")
            || processInfo.environment["PI_REVIEW_COMMENT_STASH_HARNESS"] == "1"
#else
        return false
#endif
    }
}

/// The stash sheet at the root of a router navigation controller, as chat
/// presents it, over one fixture comment, with a diagnostic of the last save.
@MainActor
final class ReviewCommentStashHarnessController: UIViewController {
    private let stash = ReviewCommentStashHarnessModel()
    private let saved = UILabel()

    init(root: AppRootEnvironment) {
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let navigation = RouterNavigationController(
            rootViewController: ReviewCommentStashViewController(stash: stash, onClose: {})
        )
        addChild(navigation)
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)

        saved.font = .systemFont(ofSize: 1)
        saved.alpha = 0.02
        saved.isAccessibilityElement = true
        saved.accessibilityLabel = "Review comment save completed"
        saved.accessibilityIdentifier = "diag.reviewCommentStash.saved"
        saved.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(saved)
        NSLayoutConstraint.activate([
            navigation.view.topAnchor.constraint(equalTo: view.topAnchor),
            navigation.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            navigation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            saved.topAnchor.constraint(equalTo: view.topAnchor),
            saved.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        let value = stash.didSave ? "1" : "0"
        saved.text = value
        saved.accessibilityValue = value
    }
}

@MainActor @Observable
private final class ReviewCommentStashHarnessModel: ReviewCommentStashHandling {
    var comments = [ReviewCommentStashHarnessModel.fixtureComment]
    var didSave = false

    var stagedComments: [ReviewComment] { comments }
    var stagedCount: Int { comments.count }

    func update(_ comment: ReviewComment, body: String) -> String? {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else {
            return "Missing comment"
        }
        comments[index].body = body
        comments[index].updatedAt += 1
        didSave = true
        return nil
    }

    func delete(_ comment: ReviewComment) {
        comments.removeAll { $0.id == comment.id }
    }

    private static let fixtureComment = ReviewComment(
        id: "review-comment-stash-harness-comment",
        workspaceId: "workspace-1",
        sessionId: "session-1",
        turnId: nil,
        author: .human,
        status: .staged,
        severity: nil,
        body: "Original comment.",
        attachments: nil,
        reference: ReviewCommentReference(
            source: .timelineText,
            label: "Timeline",
            path: nil,
            side: nil,
            startLine: nil,
            endLine: nil,
            selectedText: "The selected text under review.",
            languageHint: nil,
            toolCallId: nil,
            timelineItemId: "timeline-item-1",
            url: nil
        ),
        createdAt: 1,
        updatedAt: 1,
        sentAt: nil
    )
}
#endif
