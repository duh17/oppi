import UIKit
import WebKit

/// WKWebView subclass that adds the Comment action to the text selection edit menu.
///
/// When the user selects text, a single Comment action appears in the edit menu.
/// Configurable quick comments live inside the comment composer sheet rather than
/// crowding the selection menu.
///
/// Uses `buildMenu(with:)` — the stable `UIResponder` API (iOS 13+) — to inject
/// menu items into WKWebView's edit menu. The system walks the responder chain
/// when building the edit menu, so overriding here on the WKWebView subclass
/// inserts our item alongside the standard Copy/Look Up/Translate actions.
///
/// When the action is triggered, the selected text is retrieved via JavaScript
/// (`window.getSelection()`) and dispatched through the configured handler.
final class PiWKWebView: WKWebView {
    /// Called when the user picks the comment action on selected text.
    var piActionHandler: ((String, PiQuickAction, UIViewController?) -> Void)?

    /// Store for user-configured quick comments. Kept for wiring compatibility;
    /// the edit menu itself always shows one Comment action.
    var piActionStore: PiQuickActionStore?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Edit menu via buildMenu(with:)

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard piActionHandler != nil else { return }

        let quickAction = PiQuickAction.reviewCommentAction
        let commentAction = UIAction(
            title: quickAction.title,
            image: UIImage(systemName: quickAction.systemImage)
        ) { [weak self] _ in
            self?.handlePiAction(quickAction)
        }

        // Insert an inline menu before the standard edit actions so this reads
        // as a direct "Comment" action, not as a π submenu.
        let commentMenu = UIMenu(title: "", options: .displayInline, children: [commentAction])
        builder.insertSibling(commentMenu, beforeMenu: .standardEdit)
    }

    private func handlePiAction(_ quickAction: PiQuickAction) {
        evaluateJavaScript("window.getSelection()?.toString() || ''") { [weak self] result, _ in
            guard let self,
                  let raw = result as? String else { return }
            let text = SelectedTextPiPromptFormatter.normalizedSelectedText(raw)
            guard !text.isEmpty else { return }
            self.piActionHandler?(text, quickAction, self.nearestViewController())
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

extension PiWKWebView {
    /// Wire a `SelectedTextPiActionRouter` as the handler.
    func configurePiRouter(
        _ router: SelectedTextPiActionRouter?,
        sourceContext: SelectedTextSourceContext?,
        actionStore: PiQuickActionStore? = nil
    ) {
        guard let router, let sourceContext else {
            piActionHandler = nil
            piActionStore = nil
            return
        }
        piActionStore = actionStore
        piActionHandler = { text, quickAction, presentingViewController in
            router.dispatch(
                SelectedTextPiRequest(
                    action: quickAction,
                    selectedText: text,
                    source: sourceContext
                ),
                presentingViewController: presentingViewController
            )
        }
    }
}
