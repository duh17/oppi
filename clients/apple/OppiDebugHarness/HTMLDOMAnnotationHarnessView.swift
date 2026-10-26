#if DEBUG
import SwiftUI
import UIKit

/// Simulator-only launch surface for finger-input proof of the production HTML
/// picker, inline composer, router, and persisted review-comment store.
enum HTMLDOMAnnotationHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--html-dom-annotation-harness")
            || processInfo.environment["PI_HTML_DOM_ANNOTATION_HARNESS"] == "1"
#else
        return false
#endif
    }
}

struct HTMLDOMAnnotationHarnessView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HTMLDOMAnnotationHarnessViewController {
        HTMLDOMAnnotationHarnessViewController()
    }

    func updateUIViewController(_ uiViewController: HTMLDOMAnnotationHarnessViewController, context: Context) {
        uiViewController.updateDiagnostics()
    }
}

@MainActor
private enum HTMLDOMHarnessFirstResponder {
    static weak var current: UIResponder?
}

private extension UIResponder {
    @objc func oppiHTMLHarnessCaptureFirstResponder() {
        HTMLDOMHarnessFirstResponder.current = self
    }
}

@MainActor
final class HTMLDOMAnnotationHarnessViewController: UIViewController {
    private static let fixtureHTML = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
    <body style="margin:0;min-height:1800px;font-family:-apple-system;background:#f5f5f7;color:#111">
      <label for="name" style="position:absolute;left:24px;top:210px">Keyboard ownership</label>
      <input id="name" aria-label="Harness page input" type="text"
             style="position:absolute;left:24px;top:242px;width:230px;height:44px;font-size:18px">
      <div id="input-mirror" aria-label="Harness input value" style="position:absolute;left:24px;top:298px">Input value: empty</div>
      <div id="inner" style="position:absolute;left:44px;top:780px;width:240px;height:150px;padding:30px;background:#b8d8ff">
        <button id="leaf" aria-label="Leaf target" style="width:150px;height:62px;font-size:20px">Leaf target</button>
      </div>
      <div id="event-summary" aria-label="Leaf event summary" style="position:absolute;left:24px;top:960px">Leaf events: 0</div>
      <div style="position:absolute;top:1200px;height:500px">Scroll extent</div>
      <script>
        window.__leafEvents = [];
        const leaf = document.getElementById('leaf');
        const summary = document.getElementById('event-summary');
        const types = ['pointerdown','pointerup','touchstart','touchend','mousedown','mouseup','click','focus','focusin'];
        types.forEach(type => leaf.addEventListener(type, event => {
          window.__leafEvents.push(event.type);
          summary.textContent = 'Leaf events: ' + window.__leafEvents.length + ' ' + window.__leafEvents.join(',');
        }, true));
        const input = document.getElementById('name');
        const mirror = document.getElementById('input-mirror');
        input.addEventListener('input', () => { mirror.textContent = 'Input value: ' + input.value; });
      </script>
    </body></html>
    """

    private let readyLabel = makeDiagnosticLabel(id: "diag.html.ready")
    private let eventLabel = makeDiagnosticLabel(id: "diag.html.pageEvents")
    private let inputLabel = makeDiagnosticLabel(id: "diag.html.inputValue")
    private let responderLabel = makeDiagnosticLabel(id: "diag.html.nativePageResponder")
    private let pageZoomLabel = makeDiagnosticLabel(id: "diag.html.pageZoomPercent")
    private let selectedIDLabel = makeDiagnosticLabel(id: "diag.html.selectedID")
    private let selectionLabel = makeDiagnosticLabel(id: "diag.html.selection")
    private let selectionStatusLabel = makeDiagnosticLabel(id: "diag.html.selectionStatus")
    private let targetRectLabel = makeDiagnosticLabel(id: "diag.html.targetRect")
    private let viewportMetricsLabel = makeDiagnosticLabel(id: "diag.html.viewportMetrics")
    private let lookupSerialLabel = makeDiagnosticLabel(id: "diag.html.lookupSerial")
    private let stagedLabel = makeDiagnosticLabel(id: "diag.html.stagedCount")
    private let diagnosticsStack = UIStackView()
    private let readerControls = UIStackView()
    private var renderView: HTMLRenderView?
    private var reviewComments: ChatReviewCommentsController?
    private var diagnosticsTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installProductionHTMLFlow()
        installDiagnostics()
        diagnosticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateDiagnostics()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    deinit {
        diagnosticsTask?.cancel()
    }

    func updateDiagnostics() {
        guard let renderView else { return }
        setDiagnostic(readyLabel, value: renderView.isRenderReady ? "1" : "0")
        setDiagnostic(stagedLabel, value: String(reviewComments?.stagedCount ?? 0))
        setDiagnostic(pageZoomLabel, value: String(Int((renderView.webViewForTesting.pageZoom * 100).rounded())))
        let picker = renderView.htmlDOMPickControllerForTesting
        setDiagnostic(selectedIDLabel, value: picker.snapshotForTesting?.element.elementId ?? "none")
        setDiagnostic(selectionLabel, value: picker.snapshotForTesting?.element.readableLabel ?? "none")
        setDiagnostic(selectionStatusLabel, value: picker.statusTextForTesting ?? "none")
        setDiagnostic(lookupSerialLabel, value: String(picker.completedLookupSerial))
        let scrollView = renderView.webViewForTesting.scrollView
        setDiagnostic(
            viewportMetricsLabel,
            value: "page=\(renderView.webViewForTesting.pageZoom),scroll=\(scrollView.zoomScale),inset=\(scrollView.adjustedContentInset.top)"
        )
        HTMLDOMHarnessFirstResponder.current = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.oppiHTMLHarnessCaptureFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        let ownsPageKeyboard = HTMLDOMHarnessFirstResponder.current
            .map { responderIsInside($0, view: renderView.webViewForTesting) } ?? false
        setDiagnostic(responderLabel, value: ownsPageKeyboard ? "1" : "0")

        guard renderView.isRenderReady else { return }
        Task { @MainActor [weak self, weak renderView] in
            guard let self, let renderView else { return }
            let result = try? await renderView.webViewForTesting.callAsyncJavaScript(
                """
                return {
                  events: Array.isArray(window.__leafEvents) ? window.__leafEvents.join(',') : 'missing',
                  input: document.getElementById('name') ? document.getElementById('name').value : 'missing',
                  viewport: window.visualViewport ? [window.visualViewport.scale, window.visualViewport.offsetTop].join(',') : 'missing',
                  targetRect: (() => {
                    const node = document.getElementById('leaf');
                    if (!node) return 'missing';
                    const rect = node.getBoundingClientRect();
                    return [rect.x, rect.y, rect.width, rect.height].map(value => Math.round(value * 100) / 100).join(',');
                  })()
                };
                """,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard let values = HTMLDOMSanitizer.dictionary(result) else { return }
            let events = HTMLDOMSanitizer.string(values["events"]) ?? "missing"
            self.setDiagnostic(self.eventLabel, value: events.isEmpty ? "none" : events)
            self.setDiagnostic(self.inputLabel, value: HTMLDOMSanitizer.string(values["input"]) ?? "missing")
            self.setDiagnostic(self.targetRectLabel, value: HTMLDOMSanitizer.string(values["targetRect"]) ?? "missing")
            let visual = HTMLDOMSanitizer.string(values["viewport"]) ?? "missing"
            self.setDiagnostic(self.viewportMetricsLabel, value: self.viewportMetricsLabel.accessibilityValue.map { "\($0),visual=\(visual)" } ?? visual)
        }
    }

    private func installProductionHTMLFlow() {
        let suiteName = "html-dom-annotation-harness"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: suiteName)
        )
        comments.load(localScopeId: "html-harness", sessionId: "html-harness-session")
        reviewComments = comments

        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in },
            inlineSave: { [weak self] body, request in
                let saved = comments.save(
                    body: body,
                    request: request,
                    localScopeId: "html-harness",
                    sessionId: "html-harness-session"
                ) == nil
                self?.updateDiagnostics()
                return saved
            },
            inlineQuickComments: [.fix],
            stash: comments
        )
        let source = ReviewCommentSourceContext(
            sessionId: "html-harness-session",
            surface: .fullScreenSource,
            filePath: "fixtures/html-dom-annotation.html"
        )
        let htmlView = HTMLRenderView(
            htmlString: Self.fixtureHTML,
            reviewCommentRouter: router,
            sourceContext: source
        )
        htmlView.accessibilityIdentifier = "html.annotation.surface"
        htmlView.webViewForTesting.accessibilityIdentifier = "html.annotation.webview"
        htmlView.onRenderStateChange = { [weak self, weak htmlView] in
            guard let self, let htmlView, htmlView.isRenderReady else { return }
            htmlView.applyReaderPreferences(FullScreenReaderPreferences(textScale: 1, wrapsText: true))
            self.updateDiagnostics()
        }
        htmlView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(htmlView)
        NSLayoutConstraint.activate([
            htmlView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            htmlView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            htmlView.topAnchor.constraint(equalTo: view.topAnchor),
            htmlView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        renderView = htmlView

        readerControls.axis = .horizontal
        readerControls.spacing = 6
        readerControls.translatesAutoresizingMaskIntoConstraints = false
        for (label, scale) in [("100", CGFloat(1)), ("125", CGFloat(1.25)), ("135", CGFloat(1.35))] {
            let button = UIButton(type: .system)
            button.setTitle(label, for: .normal)
            button.accessibilityIdentifier = "html.reader.zoom.\(label)"
            button.accessibilityLabel = "HTML text size \(label) percent"
            button.addAction(UIAction { [weak self] _ in
                self?.renderView?.applyReaderPreferences(
                    FullScreenReaderPreferences(textScale: scale, wrapsText: true)
                )
                self?.updateDiagnostics()
            }, for: .touchUpInside)
            readerControls.addArrangedSubview(button)
        }
        view.addSubview(readerControls)
        NSLayoutConstraint.activate([
            readerControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            readerControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    private func installDiagnostics() {
        diagnosticsStack.axis = .vertical
        diagnosticsStack.spacing = 1
        diagnosticsStack.alpha = 0.02
        diagnosticsStack.isUserInteractionEnabled = false
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        [
            readyLabel, eventLabel, inputLabel, responderLabel, pageZoomLabel,
            selectedIDLabel, selectionLabel, selectionStatusLabel, targetRectLabel, viewportMetricsLabel,
            lookupSerialLabel, stagedLabel,
        ]
            .forEach(diagnosticsStack.addArrangedSubview)
        view.addSubview(diagnosticsStack)
        NSLayoutConstraint.activate([
            diagnosticsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            diagnosticsStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
        ])
    }

    private func responderIsInside(_ responder: UIResponder, view: UIView) -> Bool {
        if responder === view { return true }
        guard let responderView = responder as? UIView else { return false }
        return responderView.isDescendant(of: view)
    }

    private static func makeDiagnosticLabel(id: String) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = id
        label.accessibilityLabel = id
        label.accessibilityValue = ""
        label.isAccessibilityElement = true
        label.font = .systemFont(ofSize: 1)
        label.text = ""
        return label
    }

    private func setDiagnostic(_ label: UILabel, value: String) {
        label.text = value
        label.accessibilityValue = value
    }
}
#endif
