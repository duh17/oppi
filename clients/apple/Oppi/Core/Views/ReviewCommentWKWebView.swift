import UIKit
import WebKit

/// WKWebView subclass that adds the Comment action to the text selection edit menu.
///
/// When the user selects text, a single Comment action appears in the edit menu.
/// Chat-scoped routers render the draft composer inline near the web view;
/// fallback routers keep the existing routed composer behavior.
final class ReviewCommentWKWebView: WKWebView {
    /// Called when the user picks the comment action on selected text.
    var reviewCommentHandler: ((String, UIViewController?) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Edit menu via buildMenu(with:)

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard reviewCommentHandler != nil else { return }

        let commentAction = UIAction(
            title: "Comment",
            image: UIImage(systemName: "text.bubble")
        ) { [weak self] _ in
            self?.handleCommentAction()
        }

        let commentMenu = UIMenu(title: "", options: .displayInline, children: [commentAction])
        builder.insertSibling(commentMenu, beforeMenu: .standardEdit)
    }

    private func handleCommentAction() {
        evaluateJavaScript("window.getSelection()?.toString() || ''") { [weak self] result, _ in
            guard let self,
                  let raw = result as? String else { return }
            let text = ReviewCommentSelectionTextFormatter.normalizedSelectedText(raw)
            guard !text.isEmpty else { return }
            self.reviewCommentHandler?(text, self.nearestViewController())
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

// MARK: - Router bridge

extension ReviewCommentWKWebView {
    /// Wire a `ReviewCommentSelectionRouter` as the handler.
    func configureReviewCommentRouter(
        _ router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        guard let router, let sourceContext else {
            reviewCommentHandler = nil
            return
        }
        reviewCommentHandler = { [weak self] text, presentingViewController in
            let request = ReviewCommentSelectionRequest(
                selectedText: text,
                source: sourceContext
            )
            if router.supportsInlineCommentComposer, let self {
                evaluateJavaScript("window.getSelection()?.removeAllRanges()")
                ReviewCommentInlineDraftPresenter.present(
                    sourceView: self,
                    request: request,
                    router: router
                )
            } else {
                router.dispatch(request, presentingViewController: presentingViewController)
            }
        }
    }
}
