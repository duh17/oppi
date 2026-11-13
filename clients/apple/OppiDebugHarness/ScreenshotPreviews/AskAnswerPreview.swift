#if DEBUG
import UIKit

// MARK: - Ask Answer Preview

/// `SCREENSHOT_SCREEN=ask-answer`: the answered-question receipts the timeline
/// inserts for an `ask` tool result, drawn by the live user row from the same
/// formatter the reducer calls: one single-select, one multi-select, and one
/// answered with typed text that matches no option.
final class AskAnswerPreviewController: PreviewRootController {
    init(root: AppRootEnvironment) {
        super.init(root: root, themeStore: root.themeStore, content: AskAnswerContentController())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class AskAnswerContentController: UIViewController {
    private static func question(
        _ id: String, _ text: String, multiSelect: Bool = false, options: [(String, String, String?)]
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "question": .string(text),
            "multiSelect": .bool(multiSelect),
            "options": .array(options.map { value, label, description in
                var option: [String: JSONValue] = ["value": .string(value), "label": .string(label)]
                if let description { option["description"] = .string(description) }
                return .object(option)
            }),
        ])
    }

    private static let receipts: [JSONValue] = [
        .object([
            "questions": .array([question("scope", "Which scope should I use?", options: [
                ("minimal_patch", "Minimal patch", "Smallest safe change"),
                ("full_refactor", "Full refactor", nil),
                ("rewrite", "Rewrite from scratch", "Highest risk"),
            ])]),
            "answers": .object(["scope": .string("minimal_patch")]),
            "allIgnored": .bool(false),
        ]),
        .object([
            "questions": .array([question("checks", "Which checks should run?", multiSelect: true, options: [
                ("lint", "Lint", nil),
                ("unit", "Unit tests", nil),
                ("e2e", "End-to-end tests", "Slow"),
            ])]),
            "answers": .object(["checks": .array([.string("lint"), .string("e2e")])]),
            "allIgnored": .bool(false),
        ]),
        .object([
            "questions": .array([question("branch", "Where should this land?", options: [
                ("main", "main", nil),
                ("feature", "A feature branch", nil),
            ])]),
            "answers": .object(["branch": .string("Open a draft PR instead")]),
            "allIgnored": .bool(false),
        ]),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeRuntimeState.currentPalette().ui.bgDark
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for details in Self.receipts {
            let row = UserTimelineRowConfiguration(
                text: TimelineReducer.formatAskAnswers(details: details),
                images: [],
                canFork: false,
                onFork: nil
            ).makeContentView()
            stack.addArrangedSubview(row)
        }
    }
}
#endif
