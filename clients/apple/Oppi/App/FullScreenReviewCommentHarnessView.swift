#if DEBUG
import SwiftUI
import UIKit

enum WikiLineAnchorHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--wiki-line-anchor-harness")
            || processInfo.environment["PI_WIKI_LINE_ANCHOR_HARNESS"] == "1"
#else
        return false
#endif
    }
}

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

    private static let diffWrappingRemovedLine = "- If `date +%s` is less than `1787464800` (2026-08-22 23:00:00 PDT) and `opencode-go/x-preview-f-free` (Ox Alpha) is eligible and clears the task floor, use that exact model for the new launch. Once `now >= 1787464800`, the override is expired: refresh `oppi models --json` and resume the durable rules. Do not keep preferring Ox Alpha."
    private static let diffWrappingAddedLine = "- If `date +%s` is less than `1787554799` (2026-08-23 23:59:59 PDT) and `openai-codex/gpt-5.6-sol` is eligible and clears the task floor, use that exact model for new implementation and review launches. This directive is the review route too; do not pick a second reviewer model just to differ. Once `now >= 1787554799`, the override is expired: refresh `oppi models --json` and resume the durable rules. Do not keep preferring Sol."

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
            DiffLine(kind: .removed, text: diffWrappingRemovedLine, oldLineNumber: 220, newLineNumber: nil),
            DiffLine(kind: .added, text: diffWrappingAddedLine, oldLineNumber: nil, newLineNumber: 220),
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

struct WikiLineAnchorHarnessView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WikiLineAnchorHarnessViewController {
        WikiLineAnchorHarnessViewController()
    }

    func updateUIViewController(_ uiViewController: WikiLineAnchorHarnessViewController, context: Context) {
        uiViewController.updateDiagnostics()
    }
}

final class WikiLineAnchorHarnessViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private static let fixtureCode = (1...80)
        .map { "let fixtureValue\($0) = \($0)" }
        .joined(separator: "\n")

    private static let fixtureMarkdown = """
    # Intro

    Before the focused blocks.

    ## Focused heading

    First focused block.

    Second focused block.

    After the focused blocks.
    """

    private let markdownView = AssistantMarkdownContentView()
    private let diagnosticsStack = UIStackView()
    private let readyLabel = makeDiagnosticLabel(id: "harness.ready")
    private let codeOpenedLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.codeOpened")
    private let codeHighlightEnclosureCountLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.codeHighlightEnclosureCount")
    private let codeHighlightGeometryLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.codeHighlightGeometry")
    private let codeGutterMarkerCountLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.codeGutterMarkerCount")
    private let codeFocusYLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.codeFocusYHundredths")
    private let codeUpperThirdLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.codeUpperThird")
    private let markdownOpenedLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownOpened")
    private let markdownHighlightCountLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownHighlightCount")
    private let markdownHighlightEnclosureCountLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownHighlightEnclosureCount")
    private let markdownHighlightAlignedLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownHighlightAligned")
    private let markdownVisibleHighlightCountLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownVisibleHighlightCount")
    private let markdownVisibleHighlightGeometryCountLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownVisibleHighlightGeometryCount")
    private let markdownHighlightAreaLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownHighlightAreaHundredths")
    private let markdownHighlightFrontmostLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownHighlightFrontmost")
    private let markdownFocusYLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownFocusYHundredths")
    private let markdownUpperThirdLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.markdownUpperThird")
    private let noticeLabel = makeDiagnosticLabel(id: "diag.wikiAnchor.notice")

    private var resourceObserver: NSObjectProtocol?
    private var presentedViewer: FullScreenCodeViewController?
    private var diagnosticsConstraints: [NSLayoutConstraint] = []

    private func installResourceObserver() {
        guard resourceObserver == nil else { return }
        resourceObserver = NotificationCenter.default.addObserver(
            forName: .resourceReferenceTapped,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let reference = notification.object as? ResourceReference else { return }
            self?.open(reference: reference)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "wiki-line-anchor.harness"
        view.backgroundColor = UIColor(ThemeID.dark.palette.bgDark)
        installLinkSurface()
        installDiagnostics()
        installResourceObserver()
        updateDiagnostics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installResourceObserver()
        if let presentedViewer, presentedViewer.presentingViewController == nil {
            moveDiagnostics(to: view)
            self.presentedViewer = nil
            updateDiagnostics()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let resourceObserver {
            NotificationCenter.default.removeObserver(resourceObserver)
            self.resourceObserver = nil
        }
    }

    func updateDiagnostics() {
        setDiagnostic(readyLabel, value: 1)
        setDiagnostic(codeOpenedLabel, value: 0)
        setDiagnostic(codeHighlightEnclosureCountLabel, value: 0)
        setDiagnostic(codeHighlightGeometryLabel, value: 0)
        setDiagnostic(codeGutterMarkerCountLabel, value: 0)
        setDiagnostic(codeFocusYLabel, value: -1)
        setDiagnostic(codeUpperThirdLabel, value: 0)
        setDiagnostic(markdownOpenedLabel, value: 0)
        setDiagnostic(markdownHighlightCountLabel, value: 0)
        setDiagnostic(markdownHighlightEnclosureCountLabel, value: 0)
        setDiagnostic(markdownHighlightAlignedLabel, value: 0)
        setDiagnostic(markdownVisibleHighlightCountLabel, value: 0)
        setDiagnostic(markdownVisibleHighlightGeometryCountLabel, value: 0)
        setDiagnostic(markdownHighlightAreaLabel, value: 0)
        setDiagnostic(markdownHighlightFrontmostLabel, value: 0)
        setDiagnostic(markdownFocusYLabel, value: -1)
        setDiagnostic(markdownUpperThirdLabel, value: 0)

        guard let viewer = presentedViewer,
              let body = viewer.installedBodyViewForTesting else { return }
        if let codeBody = body as? NativeFullScreenCodeBody {
            setDiagnostic(codeOpenedLabel, value: 1)
            setDiagnostic(codeHighlightEnclosureCountLabel, value: codeBody.debugLineAnchorHighlightRectCountForTesting)
            setDiagnostic(codeHighlightGeometryLabel, value: codeBody.debugLineAnchorHighlightHasVisibleGeometryForTesting ? 1 : 0)
            setDiagnostic(codeGutterMarkerCountLabel, value: codeBody.debugLineAnchorGutterMarkerCountForTesting)
            if let rect = codeBody.debugLineAnchorFirstHighlightRectForTesting {
                let visibleY = rect.midY - codeBody.debugLineAnchorScrollOffsetForTesting.y
                setDiagnostic(codeFocusYLabel, value: Int((visibleY * 100).rounded()))
                let upperThird = abs(visibleY - codeBody.debugLineAnchorViewportHeightForTesting / 3)
                    <= codeBody.debugLineAnchorViewportHeightForTesting * 0.18
                setDiagnostic(codeUpperThirdLabel, value: upperThird ? 1 : 0)
            }
        } else if let markdownBody = body as? NativeFullScreenMarkdownBody {
            setDiagnostic(markdownOpenedLabel, value: 1)
            setDiagnostic(
                markdownHighlightCountLabel,
                value: markdownBody.debugLineAnchorHighlightedSegmentCountForTesting
            )
            setDiagnostic(
                markdownHighlightEnclosureCountLabel,
                value: markdownBody.debugLineAnchorVisibleHighlightEnclosureCountForTesting
            )
            setDiagnostic(
                markdownHighlightAlignedLabel,
                value: markdownBody.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting ? 1 : 0
            )
            setDiagnostic(
                markdownVisibleHighlightCountLabel,
                value: markdownBody.debugLineAnchorVisibleHighlightedCellCountForTesting
            )
            setDiagnostic(
                markdownVisibleHighlightGeometryCountLabel,
                value: markdownBody.debugLineAnchorVisibleHighlightGeometryCountForTesting
            )
            setDiagnostic(
                markdownHighlightAreaLabel,
                value: Int((markdownBody.debugLineAnchorVisibleHighlightAreaForTesting * 100).rounded())
            )
            setDiagnostic(
                markdownHighlightFrontmostLabel,
                value: markdownBody.debugLineAnchorVisibleHighlightOverlaysFrontmostForTesting ? 1 : 0
            )
            if let visibleY = markdownBody.debugLineAnchorFirstVisibleTargetMidYForTesting {
                setDiagnostic(markdownFocusYLabel, value: Int((visibleY * 100).rounded()))
                let upperThird = abs(visibleY - markdownBody.debugLineAnchorViewportHeightForTesting / 3)
                    <= markdownBody.debugLineAnchorViewportHeightForTesting * 0.18
                setDiagnostic(markdownUpperThirdLabel, value: upperThird ? 1 : 0)
            }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        moveDiagnostics(to: view)
        presentedViewer = nil
        updateDiagnostics()
    }

    private func installLinkSurface() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "wiki-line-anchor.links"
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let title = UILabel()
        title.text = "Wiki-link line-anchor harness"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = UIColor(ThemeID.dark.palette.fg)
        title.accessibilityIdentifier = "wiki-line-anchor.title"
        stack.addArrangedSubview(title)

        let instructions = UILabel()
        instructions.text = "Tap either rendered wiki link to open its anchored document."
        instructions.numberOfLines = 0
        instructions.textColor = UIColor(ThemeID.dark.palette.fgDim)
        stack.addArrangedSubview(instructions)

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.accessibilityIdentifier = "wiki-line-anchor.markdown"
        markdownView.apply(configuration: .make(
            content: "Code: [[fixtures/anchor.swift#L32-L35|Open code lines]]\n\nMarkdown: [[fixtures/anchor.md#L6-L11|Open markdown lines]]",
            isStreaming: false,
            themeID: .dark,
            textSelectionEnabled: true,
            serverID: "wiki-anchor-server",
            workspaceID: "wiki-anchor-workspace",
            sessionID: "wiki-anchor-session"
        ))
        stack.addArrangedSubview(markdownView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func installDiagnostics() {
        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 1
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsStack.isAccessibilityElement = false
        diagnosticsStack.alpha = 0.02
        [
            readyLabel,
            codeOpenedLabel,
            codeHighlightEnclosureCountLabel,
            codeHighlightGeometryLabel,
            codeGutterMarkerCountLabel,
            codeFocusYLabel,
            codeUpperThirdLabel,
            markdownOpenedLabel,
            markdownHighlightCountLabel,
            markdownHighlightEnclosureCountLabel,
            markdownHighlightAlignedLabel,
            markdownVisibleHighlightCountLabel,
            markdownVisibleHighlightGeometryCountLabel,
            markdownHighlightAreaLabel,
            markdownHighlightFrontmostLabel,
            markdownFocusYLabel,
            markdownUpperThirdLabel,
            noticeLabel,
        ].forEach(diagnosticsStack.addArrangedSubview)
        moveDiagnostics(to: view)
    }

    private func moveDiagnostics(to host: UIView) {
        NSLayoutConstraint.deactivate(diagnosticsConstraints)
        diagnosticsConstraints.removeAll()
        diagnosticsStack.removeFromSuperview()
        host.addSubview(diagnosticsStack)
        diagnosticsConstraints = [
            diagnosticsStack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
            diagnosticsStack.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 2),
        ]
        NSLayoutConstraint.activate(diagnosticsConstraints)
    }

    private func open(reference: ResourceReference) {
        guard let anchor = reference.lineAnchor,
              let path = reference.fileCandidatePath,
              presentedViewer == nil else { return }

        let content: FullScreenCodeContent
        if path.hasSuffix(".md") {
            content = .markdown(
                content: Self.fixtureMarkdown,
                filePath: path
            )
        } else {
            content = .code(
                content: Self.fixtureCode,
                language: "swift",
                filePath: path,
                startLine: 1
            )
        }

        let viewer = FullScreenCodeViewController.makeHarnessController(
            content: content,
            presentationMode: .sheet,
            reviewCommentSelectionContext: nil,
            lineAnchor: anchor,
            lineAnchorNotice: { [weak self] _ in
                self?.setDiagnostic(self?.noticeLabel, value: 1)
            }
        )
        viewer.modalPresentationStyle = .fullScreen
        presentedViewer = viewer
        present(viewer, animated: false) { [weak self] in
            viewer.presentationController?.delegate = self
            self?.moveDiagnostics(to: viewer.view)
            self?.updateDiagnostics()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.updateDiagnostics()
            }
        }
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

    private func setDiagnostic(_ label: UILabel?, value: Int) {
        guard let label else { return }
        let text = String(value)
        label.text = text
        label.accessibilityValue = text
    }
}
#endif
