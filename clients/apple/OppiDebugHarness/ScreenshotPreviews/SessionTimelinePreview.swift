#if DEBUG
import UIKit

// MARK: - Session Timeline Preview

/// `SCREENSHOT_SCREEN=session-timeline`: the Session Outline at the root of a
/// router stack, as chat presents it, over the tool-inspection fixture and a
/// six-entry tree. Tree navigation never reaches a server: the request is
/// captured into the "Last tree navigate" label above the stack
/// (`session-timeline.last-navigation`), then refused.
final class SessionTimelinePreviewController: PreviewRootController {
    private let captureLabel: InsetLabel

    init(root: AppRootEnvironment) {
        let fixture = ToolInspectionPreviewFixture.makeReducer()
        let captureLabel = InsetLabel(insets: UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10), capsule: false)
        self.captureLabel = captureLabel
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) {
                SessionOutlineViewController(
                    items: fixture.items,
                    toolArgsStore: fixture.toolArgsStore,
                    toolDetails: { fixture.toolDetailsStore.details(for: $0) },
                    onSelect: { _ in },
                    onFork: { _ in },
                    onNavigateTreeNode: { request in
                        let summary = Self.summary(of: request)
                        await MainActor.run { Self.show(summary, in: captureLabel) }
                        throw PreviewNavigationCaptureError(message: "Captured \(summary)")
                    },
                    initialTreeSnapshot: Self.previewTreeSnapshot,
                    onClose: {}
                )
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        captureLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
        )
        captureLabel.textColor = .themeComment
        captureLabel.backgroundColor = UIColor.themeBgDark.withAlphaComponent(0.9)
        captureLabel.layer.cornerRadius = 8
        captureLabel.layer.cornerCurve = .continuous
        captureLabel.accessibilityIdentifier = "session-timeline.last-navigation"
        Self.show("none", in: captureLabel)
        captureLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureLabel)
        NSLayoutConstraint.activate([
            captureLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            captureLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            captureLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
        ])
    }

    private static func show(_ capture: String, in label: UILabel) {
        label.text = "Last tree navigate: \(capture)"
    }

    private static func summary(of request: SessionTreeNavigationRequest) -> String {
        let mode: String
        if !request.summarize {
            mode = "none"
        } else if request.customInstructions?.isEmpty == false {
            mode = "custom"
        } else {
            mode = "default"
        }
        return "mode=\(mode) instructions=\(request.customInstructions ?? "-")"
    }

    private struct PreviewNavigationCaptureError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private static let previewTreeSnapshot = SessionTreeSnapshot(
        leafId: "entry-6",
        nodes: [
            SessionTreeNodeSnapshot(
                id: "entry-1",
                parentId: nil,
                type: "message",
                timestamp: "2026-04-19T17:10:00.000Z",
                depth: 0,
                isLeafPath: true,
                role: "user",
                textPreview: "Plan rollout for timeline branch/fork UX on mobile.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-2",
                parentId: "entry-1",
                type: "message",
                timestamp: "2026-04-19T17:10:06.000Z",
                depth: 1,
                isLeafPath: true,
                role: "assistant",
                textPreview: "Drafted a migration plan and test checklist.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-3",
                parentId: "entry-2",
                type: "message",
                timestamp: "2026-04-19T17:10:12.000Z",
                depth: 2,
                isLeafPath: false,
                role: "user",
                textPreview: "Ship list mode first.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-4",
                parentId: "entry-3",
                type: "message",
                timestamp: "2026-04-19T17:10:18.000Z",
                depth: 3,
                isLeafPath: false,
                role: "assistant",
                textPreview: "List mode shipped.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-5",
                parentId: "entry-2",
                type: "message",
                timestamp: "2026-04-19T17:11:00.000Z",
                depth: 2,
                isLeafPath: true,
                role: "user",
                textPreview: "Actually add a tree tab in Session Timeline.",
                label: nil
            ),
            SessionTreeNodeSnapshot(
                id: "entry-6",
                parentId: "entry-5",
                type: "message",
                timestamp: "2026-04-19T17:11:08.000Z",
                depth: 3,
                isLeafPath: true,
                role: "assistant",
                textPreview: "Tree mode is live and searchable.",
                label: nil
            ),
        ]
    )
}
#endif
