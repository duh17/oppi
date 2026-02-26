import UIKit

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

        case .output, .expanded:
            guard hasOutput else {
                return nil
            }

            if target == .expanded,
               canShowFullScreenContent {
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
}
