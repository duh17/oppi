#if DEBUG
import SwiftUI
import UIKit

enum SemanticPickHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--semantic-pick-harness")
            || processInfo.environment["PI_SEMANTIC_PICK_HARNESS"] == "1"
#else
        return false
#endif
    }
}

struct SemanticPickHarnessView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SemanticPickHarnessViewController {
        SemanticPickHarnessViewController()
    }

    func updateUIViewController(_ uiViewController: SemanticPickHarnessViewController, context: Context) {}
}

final class SemanticPickHarnessViewController: UIViewController {
    private let diagramContainer = UIView()
    private let diagnosticsStack = UIStackView()
    private let readyLabel = SemanticPickHarnessViewController.makeDiagnosticLabel(id: "harness.ready")
    private let stagedCountLabel = SemanticPickHarnessViewController.makeDiagnosticLabel(id: "diag.semantic.stagedCount")
    private let promptLabel = SemanticPickHarnessViewController.makeDiagnosticLabel(id: "diag.semantic.prompt")
    private var reviewComments: ChatReviewCommentsController?
    private var router: ReviewCommentSelectionRouter?
    private var diagramBody: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(ThemeID.dark.palette.bgDark)
        installComments()
        installChrome()
        showDiagram(.flowchart)
        updateDiagnostics()
    }

    private func installComments() {
        let suiteName = "semantic-pick-harness"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: suiteName)
        )
        comments.load(localScopeId: "harness", sessionId: "session-1")
        reviewComments = comments
        router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in },
            inlineSave: { [weak self] body, request in
                let didSave = comments.save(
                    body: body,
                    request: request,
                    localScopeId: "harness",
                    sessionId: "session-1"
                ) == nil
                self?.updateDiagnostics()
                return didSave
            },
            inlineQuickComments: [.fix],
            stash: comments
        )
    }

    private func installChrome() {
        let switcher = UIStackView()
        switcher.axis = .horizontal
        switcher.spacing = 8
        switcher.translatesAutoresizingMaskIntoConstraints = false
        for kind in SemanticPickHarnessDiagram.allCases {
            let button = UIButton(type: .system)
            button.setTitle(kind.title, for: .normal)
            button.accessibilityIdentifier = kind.identifier
            button.addAction(UIAction { [weak self] _ in
                self?.showDiagram(kind)
            }, for: .touchUpInside)
            switcher.addArrangedSubview(button)
        }
        view.addSubview(switcher)

        diagramContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagramContainer)

        diagnosticsStack.axis = .vertical
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsStack.isAccessibilityElement = false
        diagnosticsStack.alpha = 0.02
        diagnosticsStack.addArrangedSubview(readyLabel)
        diagnosticsStack.addArrangedSubview(stagedCountLabel)
        diagnosticsStack.addArrangedSubview(promptLabel)
        view.addSubview(diagnosticsStack)

        NSLayoutConstraint.activate([
            switcher.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            switcher.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            diagramContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            diagramContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diagramContainer.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8),
            diagramContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            diagnosticsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            diagnosticsStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
        ])
    }

    private func showDiagram(_ kind: SemanticPickHarnessDiagram) {
        diagramBody?.removeFromSuperview()
        guard let router else { return }
        let body: UIView
        if kind == .ambiguity {
            let targets = (1...20).map {
                SemanticTarget(
                    id: "slice:\($0)",
                    kind: "pie.slice",
                    label: "Slice \($0)",
                    displayKey: "choice \($0)",
                    spans: [],
                    sourceOrigin: .source,
                    sourceRevision: "ambiguity-revision"
                )
            }
            let map = SemanticAnnotationMap(
                sourceRevision: "ambiguity-revision",
                targets: targets,
                regions: targets.map {
                    SemanticRegion(
                        targetID: $0.id,
                        geometry: .rectangle(CGRect(x: 120, y: 160, width: 80, height: 80)),
                        precedence: 1
                    )
                }
            )
            let picker = ZoomableGraphicalView(size: CGSize(width: 320, height: 480), draw: { _, _ in })
            picker.configureSemanticPick(map: map) { _ in }
            body = picker
        } else {
            body = NativeFullScreenRenderedDocumentBody(
                content: .mermaid(kind.source),
                themeID: .dark,
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: router,
                reviewCommentSourceContext: ReviewCommentSourceContext(
                    sessionId: "session-1",
                    surface: .fullScreenCode,
                    sourceLabel: kind.title,
                    filePath: kind.fileName,
                    languageHint: "mermaid",
                    timelineItemId: kind.identifier
                )
            )
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        diagramContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: diagramContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: diagramContainer.trailingAnchor),
            body.topAnchor.constraint(equalTo: diagramContainer.topAnchor),
            body.bottomAnchor.constraint(equalTo: diagramContainer.bottomAnchor),
        ])
        diagramBody = body
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        setDiagnostic(readyLabel, value: "1")
        setDiagnostic(stagedCountLabel, value: String(reviewComments?.stagedCount ?? 0))
        let prompt = reviewComments?.appendReviewBlock(to: "") ?? ""
        setDiagnostic(promptLabel, value: prompt.isEmpty ? "empty" : prompt)
    }

    private static func makeDiagnosticLabel(id: String) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = id
        label.isAccessibilityElement = true
        label.font = .systemFont(ofSize: 1)
        label.textColor = .white
        label.numberOfLines = 0
        label.text = "0"
        label.accessibilityLabel = id
        label.accessibilityValue = "0"
        return label
    }

    private func setDiagnostic(_ label: UILabel, value: String) {
        label.text = value
        label.accessibilityValue = value
    }
}

enum SemanticPickHarnessDiagram: CaseIterable {
    case flowchart
    case pie
    case sequence
    case ambiguity

    var title: String {
        switch self {
        case .flowchart: return "Flowchart"
        case .pie: return "Pie"
        case .sequence: return "Sequence"
        case .ambiguity: return "Ambiguity"
        }
    }

    var identifier: String {
        switch self {
        case .flowchart: return "semantic-pick.diagram.flowchart"
        case .pie: return "semantic-pick.diagram.pie"
        case .sequence: return "semantic-pick.diagram.sequence"
        case .ambiguity: return "semantic-pick.diagram.ambiguity"
        }
    }

    var fileName: String {
        switch self {
        case .flowchart: return "flow.mmd"
        case .pie: return "pie.mmd"
        case .sequence: return "sequence.mmd"
        case .ambiguity: return "ambiguity.mmd"
        }
    }

    var source: String {
        switch self {
        case .flowchart:
            return """
            flowchart TD
            A[Start] --> B[End]
            """
        case .pie:
            return """
            pie showData
            title Pets
            "Cats" : 40
            "Dogs" : 60
            """
        case .sequence:
            return """
            sequenceDiagram
            participant Alice as Host
            participant Bob
            Alice->>Bob: hello
            """
        case .ambiguity:
            return "flowchart TD\nA[Ambiguity harness]"
        }
    }
}
#endif
