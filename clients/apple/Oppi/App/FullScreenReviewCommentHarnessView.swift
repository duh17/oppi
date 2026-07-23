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
    ensure_debug_fixture_cache() {
      local cache_root="${OPPI_FIXTURE_CACHE_DIR:-$TMPDIR/oppi-fixture-cache}"
      mkdir -p "$cache_root"

      if [[ -f "$cache_root/ready" ]]; then
        return
      fi

      printf 'ready\n' > "$cache_root/ready"
    }
    """

    private static let diffWrappingLongLine = "it(\"flags concrete key branches inside the server architecture boundary when extensions install UI proxies through runtime hooks\")"

    private static var embeddedModeEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--fullscreen-embedded-review-harness")
            || processInfo.environment["PI_FULLSCREEN_REVIEW_COMMENT_HARNESS_EMBEDDED"] == "1"
    }

    private static var diffWrappingModeEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--fullscreen-diff-wrapping-harness")
            || processInfo.environment["PI_FULLSCREEN_REVIEW_COMMENT_HARNESS_DIFF_WRAPPING"] == "1"
    }

    private static var diffWrappingLines: [DiffLine] {
        [
            DiffLine(kind: .context, text: "}", oldLineNumber: 217, newLineNumber: 217),
            DiffLine(kind: .context, text: "});", oldLineNumber: 218, newLineNumber: 218),
            DiffLine(kind: .context, text: "", oldLineNumber: 219, newLineNumber: 219),
            DiffLine(kind: .added, text: diffWrappingLongLine, oldLineNumber: nil, newLineNumber: 220),
            DiffLine(kind: .added, text: "    const repoRoot = mkdtempSync(join(tmpdir(), \"oppi-architecture-layer-rules-\"));", oldLineNumber: nil, newLineNumber: 221),
            DiffLine(kind: .added, text: "", oldLineNumber: nil, newLineNumber: 222),
            DiffLine(kind: .added, text: "    try {", oldLineNumber: nil, newLineNumber: 223),
            DiffLine(kind: .added, text: "        write(", oldLineNumber: nil, newLineNumber: 224),
            DiffLine(kind: .added, text: "            join(repoRoot, \"pi-extensions/oppi-ui-proxy.ts\"),", oldLineNumber: nil, newLineNumber: 225),
            DiffLine(kind: .added, text: "            [", oldLineNumber: nil, newLineNumber: 226),
            DiffLine(kind: .added, text: "                \"function installExtensionUIProxy(ctx) {\",", oldLineNumber: nil, newLineNumber: 227),
            DiffLine(kind: .added, text: "                \"  const ui = ctx.ui;\",", oldLineNumber: nil, newLineNumber: 228),
            DiffLine(kind: .added, text: "                \"  ui.setWidget = (key, content) => {\",", oldLineNumber: nil, newLineNumber: 229),
            DiffLine(kind: .added, text: "                \"    if (key === 'local-only') return content;\",", oldLineNumber: nil, newLineNumber: 230),
            DiffLine(kind: .added, text: "            ].join(\"\\n\"),", oldLineNumber: nil, newLineNumber: 231),
        ]
    }

    private let diagnosticsStack = UIStackView()
    private let readyLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "harness.ready")
    private let inlineComposerLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.reviewComment.inlineComposer")
    private let diffWrapReadyLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.diffWrap.ready")
    private let diffWrapEnabledLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.diffWrap.wrapEnabled")
    private let diffWrapFragmentCountLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.diffWrap.fragmentCount")
    private let diffWrapHeadIndentLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.diffWrap.headIndentHundredths")
    private let diffWrapSecondXLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.diffWrap.secondXHundredths")
    private let diffWrapExpectedXLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.diffWrap.expectedXHundredths")
    private let embeddedBackLabel = FullScreenReviewCommentHarnessViewController.makeDiagnosticLabel(id: "diag.embedded.backCount")
    private let selectButton = UIButton(type: .system)
    private var embeddedBackCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(ThemeID.dark.palette.bgDark)
        installCodeController()
        installHarnessControls()
        updateDiagnostics()
        scheduleDiffWrappingDiagnosticRefreshes()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDiagnostics()
    }

    func updateDiagnostics() {
        setDiagnostic(readyLabel, value: 1)
        setDiagnostic(inlineComposerLabel, value: hasVisibleView(identifier: "review-comment.inline-composer") ? 1 : 0)
        setDiagnostic(embeddedBackLabel, value: embeddedBackCount)
        updateDiffWrappingDiagnostics()
    }

    private func installCodeController() {
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in },
            inlineSave: { _, _ in true },
            inlineQuickComments: [.fix]
        )
        let content: FullScreenCodeContent
        let context: ReviewCommentSelectionContext
        if Self.diffWrappingModeEnabled {
            FullScreenReaderPreferencesStore.shared.setPreferences(
                FullScreenReaderPreferences(textScale: 0.95, wrapsText: true),
                for: .diff
            )
            let filePath = "server/tests/architecture-layer-rules.test.ts"
            let newText = Self.diffWrappingLines
                .compactMap { line -> String? in
                    if case .removed = line.kind { return nil }
                    return line.text
                }
                .joined(separator: "\n")
            content = .diff(
                oldText: "",
                newText: newText,
                filePath: filePath,
                precomputedLines: Self.diffWrappingLines
            )
            context = ReviewCommentSelectionContext(
                dispatcher: router,
                sessionId: "session-1",
                sourceLabel: "Diff Wrapping",
                filePath: filePath,
                languageHint: "typescript"
            )
        } else {
            content = .code(
                content: Self.fixtureCode,
                language: "bash",
                filePath: "scripts/oppi.sh",
                startLine: 193
            )
            context = ReviewCommentSelectionContext(
                dispatcher: router,
                sessionId: "session-1",
                sourceLabel: "Full Screen Code",
                filePath: "scripts/oppi.sh",
                languageHint: "bash"
            )
        }
        let presentationMode: FullScreenCodeViewController.PresentationMode = Self.embeddedModeEnabled
            ? .embedded(onDismiss: { [weak self] in
                guard let self else { return }
                self.embeddedBackCount += 1
                self.updateDiagnostics()
            })
            : .sheet
        let controller = FullScreenCodeViewController.makeHarnessController(
            content: content,
            presentationMode: presentationMode,
            reviewCommentSelectionContext: context,
            navigationActions: Self.diffWrappingModeEnabled ? [] : [
                FullScreenViewerNavigationAction(
                    id: "edit-in-session",
                    title: "Edit",
                    accessibilityLabel: "Edit in Oppi Session",
                    handler: {}
                ),
                FullScreenViewerNavigationAction(
                    id: "staged-comments",
                    systemImage: "text.bubble",
                    accessibilityLabel: "Staged Comments",
                    accessibilityValue: "0 staged comments",
                    handler: {}
                ),
            ]
        )
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
        selectButton.isHidden = Self.diffWrappingModeEnabled
        selectButton.addAction(UIAction { [weak self] _ in
            self?.selectFixtureRange()
        }, for: .touchUpInside)
        view.addSubview(selectButton)

        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 1
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsStack.isAccessibilityElement = false
        diagnosticsStack.alpha = 0.02
        [
            readyLabel,
            inlineComposerLabel,
            diffWrapReadyLabel,
            diffWrapEnabledLabel,
            diffWrapFragmentCountLabel,
            diffWrapHeadIndentLabel,
            diffWrapSecondXLabel,
            diffWrapExpectedXLabel,
            embeddedBackLabel,
        ].forEach(diagnosticsStack.addArrangedSubview)
        view.addSubview(diagnosticsStack)

        NSLayoutConstraint.activate([
            selectButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            selectButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            diagnosticsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            diagnosticsStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
        ])
    }

    private func scheduleDiffWrappingDiagnosticRefreshes() {
        guard Self.diffWrappingModeEnabled else { return }
        for delay in [0.1, 0.3, 0.6, 1.0, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.updateDiagnostics()
            }
        }
    }

    private func updateDiffWrappingDiagnostics() {
        guard Self.diffWrappingModeEnabled,
              let diffBody = firstNativeFullScreenDiffBody(in: view),
              let diagnostics = diffBody.diffWrappingDiagnosticsForTesting()
        else {
            setDiagnostic(diffWrapReadyLabel, value: 0)
            setDiagnostic(diffWrapEnabledLabel, value: 0)
            setDiagnostic(diffWrapFragmentCountLabel, value: -1)
            setDiagnostic(diffWrapHeadIndentLabel, value: -1)
            setDiagnostic(diffWrapSecondXLabel, value: -1)
            setDiagnostic(diffWrapExpectedXLabel, value: -1)
            return
        }

        let secondX = diagnostics.secondFragmentX ?? -1
        let aligned = diagnostics.wrapsText
            && diagnostics.textContainerLineBreakMode == .byCharWrapping
            && diagnostics.paragraphLineBreakMode == .byCharWrapping
            && diagnostics.fragmentCount >= 2
            && abs(diagnostics.paragraphHeadIndent - diagnostics.expectedCodeColumnX) <= 0.5
            && abs(secondX - diagnostics.expectedCodeColumnX) <= 1.0

        setDiagnostic(diffWrapReadyLabel, value: aligned ? 1 : 0)
        setDiagnostic(diffWrapEnabledLabel, value: diagnostics.wrapsText ? 1 : 0)
        setDiagnostic(diffWrapFragmentCountLabel, value: diagnostics.fragmentCount)
        setDiagnostic(diffWrapHeadIndentLabel, value: Int((diagnostics.paragraphHeadIndent * 100).rounded()))
        setDiagnostic(diffWrapSecondXLabel, value: Int((secondX * 100).rounded()))
        setDiagnostic(diffWrapExpectedXLabel, value: Int((diagnostics.expectedCodeColumnX * 100).rounded()))
    }

    private func firstNativeFullScreenDiffBody(in root: UIView) -> NativeFullScreenDiffBody? {
        if let diffBody = root as? NativeFullScreenDiffBody {
            return diffBody
        }
        for subview in root.subviews {
            if let match = firstNativeFullScreenDiffBody(in: subview) {
                return match
            }
        }
        return nil
    }

    private func selectFixtureRange() {
        view.layoutIfNeeded()
        guard let textView = firstFullScreenReviewCommentTextView(in: view) else {
            updateDiagnostics()
            return
        }
        let text = (textView.attributedText?.string ?? textView.text ?? "") as NSString
        var range = text.range(of: "local cache_root=\"${OPPI_FIXTURE_CACHE_DIR:-$TMPDIR/oppi-fixture-cache}\"")
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
