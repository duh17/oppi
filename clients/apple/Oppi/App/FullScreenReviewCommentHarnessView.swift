#if DEBUG
import SwiftUI
import UIKit

enum FullScreenReviewCommentHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--fullscreen-review-comment-harness")
            || processInfo.environment["PI_FULLSCREEN_REVIEW_COMMENT_HARNESS"] == "1"
#else
        return false
#endif
    }
}

struct FullScreenReviewCommentHarnessView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FullScreenReviewCommentHarnessViewController {
        FullScreenReviewCommentHarnessViewController()
    }

    func updateUIViewController(_ uiViewController: FullScreenReviewCommentHarnessViewController, context: Context) {
        uiViewController.updateDiagnostics()
    }
}

final class FullScreenReviewCommentHarnessViewController: UIViewController {
    private static let fixtureCode = """
    ensure_debug_sentry_dsn() {
      if [[ -n "${SENTRY_DSN:-}" ]]; then
        return
      fi

      local sentry_dsn_file="${SENTRY_DSN_FILE:-$SENTRY_DSN_FILE_DEFAULT}"
      if [[ -f "$sentry_dsn_file" ]]; then
        SENTRY_DSN="$(<"$sentry_dsn_file")"
        export SENTRY_DSN
      fi
    }
    """

    private let diagnosticsStack = UIStackView()
    private let readyLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "harness.ready")
    private let selectionBarLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.reviewComment.selectionBar")
    private let inlineComposerLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.reviewComment.inlineComposer")
    private let selectButton = UIButton(type: .system)
    private var codeController: FullScreenCodeViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(ThemeID.dark.palette.bgDark)
        installCodeController()
        installHarnessControls()
        updateDiagnostics()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDiagnostics()
    }

    func updateDiagnostics() {
        setDiagnostic(readyLabel, value: 1)
        setDiagnostic(selectionBarLabel, value: hasVisibleView(identifier: "review-comment.selection-bar") ? 1 : 0)
        setDiagnostic(inlineComposerLabel, value: hasVisibleView(identifier: "review-comment.inline-composer") ? 1 : 0)
    }

    private func installCodeController() {
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in },
            inlineSave: { _, _ in true },
            inlineQuickComments: [.fix]
        )
        let context = ReviewCommentSelectionContext(
            dispatcher: router,
            sessionId: "session-1",
            sourceLabel: "Full Screen Code",
            filePath: "scripts/oppi.sh",
            languageHint: "bash"
        )
        let controller = FullScreenCodeViewController.makeHarnessController(
            content: .code(
                content: Self.fixtureCode,
                language: "bash",
                filePath: "scripts/oppi.sh",
                startLine: 193
            ),
            reviewCommentSelectionContext: context
        )
        codeController = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func installHarnessControls() {
        selectButton.accessibilityIdentifier = "harness.reviewComment.select"
        selectButton.accessibilityLabel = "Select review comment code"
        var config = UIButton.Configuration.filled()
        config.title = "Select code"
        config.baseForegroundColor = UIColor(ThemeID.dark.palette.bgDark)
        config.baseBackgroundColor = UIColor(ThemeID.dark.palette.cyan)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        selectButton.configuration = config
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.addAction(UIAction { [weak self] _ in
            self?.selectFixtureRange()
        }, for: .touchUpInside)
        view.addSubview(selectButton)

        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 1
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsStack.isAccessibilityElement = false
        diagnosticsStack.alpha = 0.02
        [readyLabel, selectionBarLabel, inlineComposerLabel].forEach(diagnosticsStack.addArrangedSubview)
        view.addSubview(diagnosticsStack)

        NSLayoutConstraint.activate([
            selectButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            selectButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            diagnosticsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            diagnosticsStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
        ])
    }

    private func selectFixtureRange() {
        view.layoutIfNeeded()
        guard let textView = firstFullScreenReviewCommentTextView(in: view) else {
            updateDiagnostics()
            return
        }
        let text = (textView.attributedText?.string ?? textView.text ?? "") as NSString
        var range = text.range(of: "local sentry_dsn_file")
        if range.location == NSNotFound {
            range = NSRange(location: 0, length: min(5, text.length))
        }
        guard range.location != NSNotFound, range.length > 0 else {
            updateDiagnostics()
            return
        }

        textView.becomeFirstResponder()
        textView.selectedRange = range
        textView.layoutIfNeeded()
        updateDiagnostics()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateDiagnostics()
        }
    }

    private func firstFullScreenReviewCommentTextView(in root: UIView) -> FullScreenReviewCommentTextView? {
        if let textView = root as? FullScreenReviewCommentTextView {
            return textView
        }
        for subview in root.subviews {
            if let match = firstFullScreenReviewCommentTextView(in: subview) {
                return match
            }
        }
        return nil
    }

    private func hasVisibleView(identifier: String) -> Bool {
        allViews(in: view).contains {
            $0.accessibilityIdentifier == identifier
                && !$0.isHidden
                && $0.alpha > 0.01
                && $0.window != nil
        }
    }

    private func allViews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }

    private static func makeDiagnosticLabel(id: String) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = id
        label.isAccessibilityElement = true
        label.font = .systemFont(ofSize: 1)
        label.textColor = .white
        label.backgroundColor = .clear
        label.text = "0"
        label.accessibilityLabel = id
        label.accessibilityValue = "0"
        return label
    }

    private func setDiagnostic(_ label: UILabel, value: Int) {
        let text = String(value)
        label.text = text
        label.accessibilityValue = text
    }
}
#endif
