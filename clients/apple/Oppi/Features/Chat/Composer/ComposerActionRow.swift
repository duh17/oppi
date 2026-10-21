import UIKit

/// Action-row pills the composer owns. Hosts pass data and callbacks, never views.
struct ComposerActionRow {
    var leading: [ComposerAction] = []
    var trailing: [ComposerAction] = []
    var leadingScrolls = false
}

struct ComposerAction: Identifiable {
    enum Icon {
        case image(UIImage)
        case symbol(String)
        case monogram(String)
    }

    enum Chrome {
        case toolbar
        case chip
        case cancel
    }

    final class Handler {
        let run: () -> Void
        init(_ run: @escaping () -> Void) {
            self.run = run
        }
    }

    enum Kind {
        case tap(Handler)
        case menu(UIMenu)
        case picker(ComposerActionPopover)
    }

    let id: String
    var icon: Icon?
    var title: String
    var tint: UIColor?
    var accessibilityLabel: String
    var accessibilityValue: String?
    var showsChevron = true
    var chrome: Chrome = .toolbar
    var kind: Kind
}

struct ComposerActionPopover {
    var preferredWidth: CGFloat = 220
    var make: @MainActor () -> UIViewController
    var update: (@MainActor (UIViewController) -> Void)?

    /// The thinking-level picker a thinking pill opens, refreshed while it is
    /// open, as `ComposerThinkingPickerController` itself presents it.
    @MainActor
    static func thinking(
        levels: [ThinkingLevel],
        selected: ThinkingLevel,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) -> ComposerActionPopover {
        ComposerActionPopover(
            preferredWidth: 220,
            make: {
                ComposerThinkingPickerController.make(
                    levels: levels,
                    selected: selected,
                    colors: colors,
                    onSelect: onSelect,
                    onSaveDefault: onSaveDefault
                )
            },
            update: { screen in
                (screen as? ComposerThinkingPickerController)?.apply(
                    levels: levels,
                    selected: selected,
                    onSelect: onSelect,
                    onSaveDefault: onSaveDefault
                )
            }
        )
    }
}

struct ComposerOptionRow {
    var id: String
    var title: String
    var subtitle: String?
    var icon: UIImage?
    var isSelected: Bool
    var accessibilityIdentifier: String
    var accessibilityLabel: String?
}

@MainActor
extension ComposerAction {
    static func model(
        title: String,
        provider: String?,
        colors: ComposerThemeColors,
        onTap: @escaping () -> Void
    ) -> ComposerAction {
        ComposerAction(
            id: "session.toolbar.model",
            icon: provider.map { .image(ComposerProviderIconRenderer.image(provider: $0, size: 11, colors: colors)) },
            title: title,
            tint: colors.fg,
            accessibilityLabel: "Model",
            accessibilityValue: title,
            showsChevron: true,
            chrome: .toolbar,
            kind: .tap(.init(onTap))
        )
    }

    static func thinking(
        level: ThinkingLevel,
        supported: [ThinkingLevel],
        tint: UIColor,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) -> ComposerAction {
        ComposerAction(
            id: "session.toolbar.thinking",
            icon: .symbol("sparkle"),
            title: level.compactTitle,
            tint: tint,
            accessibilityLabel: "Thinking level",
            accessibilityValue: level.displayTitle,
            showsChevron: true,
            chrome: .toolbar,
            kind: .picker(.thinking(
                levels: supported,
                selected: level,
                colors: colors,
                onSelect: onSelect,
                onSaveDefault: onSaveDefault
            ))
        )
    }

    static func agent(
        title: String,
        icon: UIImage,
        colors: ComposerThemeColors,
        rows: [ComposerOptionRow],
        isLoading: Bool,
        onSelect: @escaping (String?) -> Void
    ) -> ComposerAction {
        ComposerAction(
            id: "quickSession.agentPicker",
            icon: .image(icon),
            title: title,
            tint: colors.fg,
            accessibilityLabel: title == "Pi"
                ? "Agent picker, Pi with no agent"
                : "Agent picker, current agent \(title)",
            accessibilityValue: title,
            showsChevron: true,
            chrome: .toolbar,
            kind: .picker(ComposerActionPopover(
                preferredWidth: 280,
                make: {
                    ComposerOptionListController(
                        rows: rows,
                        isLoading: isLoading,
                        emptyMessage: "No saved Agents on this server.",
                        colors: colors,
                        preferredWidth: 280,
                        onSelect: { id in onSelect(id == "pi" ? nil : id) }
                    )
                },
                update: { screen in
                    (screen as? ComposerOptionListController)?.apply(
                        rows: rows,
                        isLoading: isLoading,
                        emptyMessage: "No saved Agents on this server.",
                        onSelect: { id in onSelect(id == "pi" ? nil : id) }
                    )
                }
            ))
        )
    }

    static func workspace(
        title: String,
        icon: UIImage?,
        identifier: String,
        menu: UIMenu,
        colors: ComposerThemeColors
    ) -> ComposerAction {
        ComposerAction(
            id: identifier,
            icon: icon.map { .image($0) } ?? .symbol("folder"),
            title: title,
            tint: colors.fg,
            accessibilityLabel: "Workspace picker, current workspace \(title)",
            accessibilityValue: title,
            showsChevron: true,
            chrome: .toolbar,
            kind: .menu(menu)
        )
    }

    static func reviewChip(id: String, title: String, systemImage: String, onTap: @escaping () -> Void) -> ComposerAction {
        ComposerAction(
            id: id,
            icon: .symbol(systemImage),
            title: title,
            tint: nil,
            accessibilityLabel: title,
            accessibilityValue: nil,
            showsChevron: false,
            chrome: .chip,
            kind: .tap(.init(onTap))
        )
    }

    static func reviewCancel(onTap: @escaping () -> Void) -> ComposerAction {
        ComposerAction(
            id: "chat.reviewComment.cancel",
            icon: .symbol("xmark"),
            title: "",
            tint: nil,
            accessibilityLabel: "Cancel comment",
            accessibilityValue: nil,
            showsChevron: false,
            chrome: .cancel,
            kind: .tap(.init(onTap))
        )
    }
}

@MainActor
extension ComposerActionRow {
    static var previewModelThinking: ComposerActionRow {
        ComposerActionRow(
            leading: [
                ComposerAction(
                    id: "session.toolbar.model",
                    icon: nil,
                    title: "gpt-5.5",
                    tint: nil,
                    accessibilityLabel: "Model",
                    accessibilityValue: "gpt-5.5",
                    showsChevron: false,
                    kind: .tap(.init {})
                ),
                ComposerAction(
                    id: "session.toolbar.thinking",
                    icon: nil,
                    title: "max",
                    tint: UIColor(red: 0.75, green: 0.62, blue: 1, alpha: 1),
                    accessibilityLabel: "Thinking level",
                    accessibilityValue: "Max",
                    showsChevron: false,
                    kind: .tap(.init {})
                ),
            ]
        )
    }

    static func sessionToolbar(
        modelTitle: String,
        modelProvider: String?,
        thinkingLevel: ThinkingLevel,
        thinkingTint: UIColor,
        supportedThinkingLevels: [ThinkingLevel],
        colors: ComposerThemeColors,
        onModelTap: @escaping () -> Void,
        onThinkingSelect: @escaping (ThinkingLevel) -> Void,
        onSaveThinkingAsDefault: (() -> Void)?
    ) -> ComposerActionRow {
        ComposerActionRow(
            trailing: [
                .model(title: modelTitle, provider: modelProvider, colors: colors, onTap: onModelTap),
                .thinking(
                    level: thinkingLevel,
                    supported: supportedThinkingLevels,
                    tint: thinkingTint,
                    colors: colors,
                    onSelect: onThinkingSelect,
                    onSaveDefault: onSaveThinkingAsDefault
                ),
            ]
        )
    }
}
