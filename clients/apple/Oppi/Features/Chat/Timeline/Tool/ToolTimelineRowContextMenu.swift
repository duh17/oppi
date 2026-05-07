import UIKit

enum BashCommandPolicyRuleDecision: String, CaseIterable, Sendable {
    case ask
    case allow
    case deny

    var menuTitle: String {
        switch self {
        case .ask:
            String(localized: "Ask Before Running")
        case .allow:
            String(localized: "Approve Automatically")
        case .deny:
            String(localized: "Deny Automatically")
        }
    }

    var systemImageName: String {
        switch self {
        case .ask:
            "questionmark.circle"
        case .allow:
            "checkmark.circle"
        case .deny:
            "xmark.circle"
        }
    }

    func ruleLabel(for command: String) -> String {
        let compact = command
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let display = compact.count > 96 ? String(compact.prefix(95)) + "…" : compact

        switch self {
        case .ask:
            return "Ask before bash: \(display)"
        case .allow:
            return "Approve bash: \(display)"
        case .deny:
            return "Deny bash: \(display)"
        }
    }
}

@MainActor
enum ToolTimelineRowContextMenuBuilder {
    typealias ContextMenuTarget = ToolTimelineRowContentView.ContextMenuTarget

    static func menu(
        target: ContextMenuTarget,
        hasCommand: Bool,
        hasOutput: Bool,
        canShowFullScreenContent: Bool,
        hasPreviewImage: Bool,
        onCopyCommand: @escaping (ContextMenuTarget) -> Void,
        onCopyOutput: @escaping (ContextMenuTarget) -> Void,
        onAddBashCommandPolicyRule: ((BashCommandPolicyRuleDecision) -> Void)?,
        onOpenFullScreenContent: @escaping () -> Void,
        onViewFullScreenImage: @escaping () -> Void,
        onCopyImage: @escaping () -> Void,
        onSaveImage: @escaping () -> Void
    ) -> UIMenu? {
        var actions: [UIMenuElement] = []

        switch target {
        case .command:
            if hasCommand {
                actions.append(
                    UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                        onCopyCommand(.command)
                    }
                )
            }

            if hasOutput {
                actions.append(
                    UIAction(title: String(localized: "Copy Output"), image: UIImage(systemName: "doc.on.doc")) { _ in
                        onCopyOutput(.command)
                    }
                )
            }

            if let onAddBashCommandPolicyRule {
                actions.append(policyRuleMenu(onAdd: onAddBashCommandPolicyRule))
            }

        case .output, .expanded:
            guard hasOutput else {
                return nil
            }

            if canShowFullScreenContent {
                actions.append(
                    UIAction(
                        title: String(localized: "Open Full Screen"),
                        image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                    ) { _ in
                        onOpenFullScreenContent()
                    }
                )
            }

            actions.append(
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    onCopyOutput(target)
                }
            )

            if hasCommand {
                actions.append(
                    UIAction(title: String(localized: "Copy Command"), image: UIImage(systemName: "terminal")) { _ in
                        onCopyCommand(target)
                    }
                )
            }

        case .imagePreview:
            guard hasPreviewImage else { return nil }

            actions.append(
                UIAction(
                    title: String(localized: "View Full Screen"),
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { _ in
                    onViewFullScreenImage()
                }
            )

            actions.append(
                UIAction(title: String(localized: "Copy Image"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    onCopyImage()
                }
            )

            actions.append(
                UIAction(title: String(localized: "Save to Photos"), image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    onSaveImage()
                }
            )
        }

        guard !actions.isEmpty else {
            return nil
        }

        return UIMenu(title: "", children: actions)
    }

    private static func policyRuleMenu(
        onAdd: @escaping (BashCommandPolicyRuleDecision) -> Void
    ) -> UIMenu {
        UIMenu(
            title: String(localized: "Add Policy Rule"),
            image: UIImage(systemName: "shield"),
            children: BashCommandPolicyRuleDecision.allCases.map { decision in
                UIAction(
                    title: decision.menuTitle,
                    image: UIImage(systemName: decision.systemImageName),
                    attributes: decision == .deny ? [.destructive] : []
                ) { _ in
                    onAdd(decision)
                }
            }
        )
    }
}

// MARK: - Targeting

@MainActor
enum ToolTimelineRowContextMenuTargeting {
    typealias ContextMenuTarget = ToolTimelineRowContentView.ContextMenuTarget

    static func target(
        for interactionView: UIView?,
        commandContainer: UIView,
        outputContainer: UIView,
        expandedContainer: UIView,
        imagePreviewContainer: UIView
    ) -> ContextMenuTarget? {
        guard let interactionView else {
            return nil
        }

        if interactionView === commandContainer {
            return .command
        }

        if interactionView === outputContainer {
            return .output
        }

        if interactionView === expandedContainer {
            return .expanded
        }

        if interactionView === imagePreviewContainer {
            return .imagePreview
        }

        return nil
    }

    static func feedbackView(
        for target: ContextMenuTarget,
        commandContainer: UIView,
        outputContainer: UIView,
        expandedContainer: UIView,
        imagePreviewContainer: UIView
    ) -> UIView {
        switch target {
        case .command:
            commandContainer
        case .output:
            outputContainer
        case .expanded:
            expandedContainer
        case .imagePreview:
            imagePreviewContainer
        }
    }
}
