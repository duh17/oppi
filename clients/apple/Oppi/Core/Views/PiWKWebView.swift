import UIKit
import WebKit

/// WKWebView subclass that adds π quick actions to the text selection edit menu.
///
/// When the user selects text, a "π" submenu appears in the edit menu callout
/// with actions like Explain, Do it, Fix, Refactor, Add to Prompt.
///
/// Uses `buildMenu(with:)` — the stable `UIResponder` API (iOS 13+) — to inject
/// menu items into WKWebView's edit menu. The system walks the responder chain
/// when building the edit menu, so overriding here on the WKWebView subclass
/// inserts our items alongside the standard Copy/Look Up/Translate actions.
///
/// When an action is triggered, the selected text is retrieved via JavaScript
/// (`window.getSelection()`) and dispatched through the configured handler.
final class PiWKWebView: WKWebView {
    /// Called when the user picks a pi action on selected text.
    var piActionHandler: ((String, PiQuickAction) -> Void)?

    /// Store for user-configured actions. Set externally before the menu is shown.
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

        let quickActions = piActionStore?.actions ?? PiQuickAction.builtInDefaults

        let menuActions = quickActions.map { quickAction in
            UIAction(
                title: quickAction.title,
                image: UIImage(systemName: quickAction.systemImage)
            ) { [weak self] _ in
                self?.handlePiAction(quickAction)
            }
        }

        let piMenu = UIMenu(title: "π", children: menuActions)

        // Insert π before the standard edit menu (Copy, etc.) so it
        // appears first — matching the UITextView π menu ordering.
        builder.insertSibling(piMenu, beforeMenu: .standardEdit)
    }

    private func handlePiAction(_ quickAction: PiQuickAction) {
        evaluateJavaScript("window.getSelection()?.toString() || ''") { [weak self] result, _ in
            guard let self,
                  let raw = result as? String else { return }
            let text = SelectedTextPiPromptFormatter.normalizedSelectedText(raw)
            guard !text.isEmpty else { return }
            self.piActionHandler?(text, quickAction)
        }
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
        piActionHandler = { text, quickAction in
            router.dispatch(SelectedTextPiRequest(
                action: quickAction,
                selectedText: text,
                source: sourceContext
            ))
        }
    }
}
