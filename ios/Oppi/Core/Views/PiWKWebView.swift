import UIKit
import WebKit

/// WKWebView subclass that adds a π edit menu item for text selection.
///
/// When the user selects text, "π" appears in the callout bar. Tapping it presents
/// an action sheet with pi actions (Explain, Do it, Fix, Refactor, Add to Prompt)
/// and calls the configured handler.
///
/// Uses `UIMenuController.shared.menuItems` to register the custom selector —
/// still the only mechanism for WKWebView edit menu customization. WKUIDelegate
/// only exposes `willPresent/willDismissEditMenu` animation hooks, not menu content.
/// UITextView delegates that implement `editMenuForTextIn:suggestedActions:` override
/// UIMenuController items entirely, so chat-timeline π menus are unaffected.
final class PiWKWebView: WKWebView {
    /// Called when the user picks a pi action on selected text.
    var piActionHandler: ((String, SelectedTextPiActionKind) -> Void)?

    // Register the π selector once per process. UIEditMenuInteraction discovers
    // custom actions from UIMenuController.shared.menuItems via the responder chain.
    private static let registerMenuItem: Void = {
        let item = UIMenuItem(title: "π", action: #selector(piMenuAction(_:)))
        var existing = UIMenuController.shared.menuItems ?? []
        existing.removeAll { $0.action == #selector(piMenuAction(_:)) }
        existing.append(item)
        UIMenuController.shared.menuItems = existing
    }()

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        _ = Self.registerMenuItem
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Responder chain

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(piMenuAction(_:)) {
            return piActionHandler != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func piMenuAction(_ sender: Any?) {
        evaluateJavaScript("window.getSelection()?.toString() || ''") { [weak self] result, _ in
            guard let self,
                  let raw = result as? String else { return }
            let text = SelectedTextPiPromptFormatter.normalizedSelectedText(raw)
            guard !text.isEmpty else { return }
            self.presentPiActionSheet(selectedText: text)
        }
    }

    // MARK: - Action sheet

    private func presentPiActionSheet(selectedText: String) {
        guard let viewController = findViewController() else { return }

        let sheet = UIAlertController(title: "π", message: nil, preferredStyle: .actionSheet)
        for kind in SelectedTextPiActionKind.allCases {
            sheet.addAction(UIAlertAction(title: kind.title, style: .default) { [weak self] _ in
                self?.piActionHandler?(selectedText, kind)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        // iPad popover anchor
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = [.up, .down]
        }

        viewController.present(sheet, animated: true)
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                var top = vc
                while let presented = top.presentedViewController {
                    top = presented
                }
                return top
            }
            responder = next
        }
        return nil
    }
}

// MARK: - Router bridge

extension PiWKWebView {
    /// Wire a `SelectedTextPiActionRouter` as the handler.
    func configurePiRouter(
        _ router: SelectedTextPiActionRouter?,
        sourceContext: SelectedTextSourceContext?
    ) {
        guard let router, let sourceContext else {
            piActionHandler = nil
            return
        }
        piActionHandler = { text, actionKind in
            router.dispatch(SelectedTextPiRequest(
                action: actionKind,
                selectedText: text,
                source: sourceContext
            ))
        }
    }
}
