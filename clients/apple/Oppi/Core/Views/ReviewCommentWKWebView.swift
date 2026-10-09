import UIKit
import WebKit

/// WKWebView subclass that adds the Comment actions to the text selection edit menu.
///
/// When the user selects text, the shared Comment (and dictate) actions appear in
/// the edit menu. Chat-scoped routers render the draft composer inline near the
/// web view; fallback routers keep the existing routed composer behavior.
final class ReviewCommentWKWebView: WKWebView {
    private(set) var reviewCommentRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Wire a `ReviewCommentSelectionRouter` for selected-text comments.
    func configureReviewCommentRouter(
        _ router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        guard let router, let sourceContext else {
            reviewCommentRouter = nil
            reviewCommentSourceContext = nil
            return
        }
        reviewCommentRouter = router
        reviewCommentSourceContext = sourceContext
    }

    // MARK: - Edit menu via buildMenu(with:)

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard let reviewCommentRouter else { return }

        let actions = ReviewCommentSelectionMenuBuilder.commentActions(router: reviewCommentRouter) { [weak self] startsDictation in
            self?.handleCommentAction(startsDictation: startsDictation)
        }
        let commentMenu = UIMenu(title: "", options: .displayInline, children: actions)
        builder.insertSibling(commentMenu, beforeMenu: .standardEdit)
    }

    private func handleCommentAction(startsDictation: Bool) {
        evaluateJavaScript("window.getSelection()?.toString() || ''") { [weak self] result, _ in
            guard let self,
                  let raw = result as? String else { return }
            let text = ReviewCommentSelectionTextFormatter.normalizedSelectedText(raw)
            guard !text.isEmpty,
                  let router = reviewCommentRouter,
                  let sourceContext = reviewCommentSourceContext else { return }
            let request = ReviewCommentSelectionRequest(
                selectedText: text,
                source: sourceContext,
                startsDictation: startsDictation
            )
            if router.supportsInlineCommentComposer {
                evaluateJavaScript("window.getSelection()?.removeAllRanges()")
                ReviewCommentInlineDraftPresenter.present(
                    sourceView: self,
                    request: request,
                    router: router
                )
            } else {
                router.dispatch(request, presentingViewController: nearestViewController())
            }
        }
    }

    private func nearestViewController() -> UIViewController? {
        var current: UIResponder? = self
        while let node = current {
            if let controller = node as? UIViewController {
                return controller
            }
            current = node.next
        }
        return nil
    }
}
