import Foundation

struct MacAppKeybindingHelpEntry: Equatable, Sendable, Identifiable {
    var id: String { "\(action)|\(shortcut)" }
    let action: String
    let shortcut: String
}

struct MacAppKeybindingHelpSection: Equatable, Sendable, Identifiable {
    var id: String { title }
    let title: String
    let entries: [MacAppKeybindingHelpEntry]
}

/// Cheat-sheet rows derived from the live configuration: app commands from
/// `MacKeybindingStore`, timeline rows from the shared catalog preset.
enum MacAppKeybindingHelp {
    @MainActor
    static func sections(store: MacKeybindingStore) -> [MacAppKeybindingHelpSection] {
        commandSections(shortcut: store.shortcut(for:))
            + [
                timelineSection(mode: store.timelinePreset),
                documentSection(mode: store.timelinePreset),
                mouseSection,
            ]
    }

    static func commandSections(
        shortcut: (MacAppCommand) -> MacKeyShortcut?
    ) -> [MacAppKeybindingHelpSection] {
        MacAppCommand.Category.allCases.map { category in
            MacAppKeybindingHelpSection(
                title: category.rawValue,
                entries: MacAppCommand.commands(in: category).map { command in
                    MacAppKeybindingHelpEntry(
                        action: command.title,
                        shortcut: shortcut(command)?.displayString ?? "—"
                    )
                }
            )
        }
    }

    static func timelineSection(mode: KeybindingMode) -> MacAppKeybindingHelpSection {
        var entries = catalogEntries(mode: mode, focus: .timeline)
        if MacTimelineKeybinding.composerEscapeFocusesTimeline(mode: mode) {
            entries.append(.init(action: "Leave Composer for Timeline", shortcut: "Esc"))
        }
        return MacAppKeybindingHelpSection(title: "Timeline (\(mode.displayName))", entries: entries)
    }

    static func documentSection(mode: KeybindingMode) -> MacAppKeybindingHelpSection {
        MacAppKeybindingHelpSection(
            title: "Document",
            entries: catalogEntries(mode: mode, focus: .viewer)
        )
    }

    static let mouseSection = MacAppKeybindingHelpSection(
        title: "Mouse",
        entries: [
            .init(action: "Expand or Collapse Tool Row", shortcut: "Click"),
            .init(action: "Open Tool Row in Document View", shortcut: "Double-click"),
        ]
    )

    /// One row per action; chords for the same action join with " / ".
    private static func catalogEntries(
        mode: KeybindingMode,
        focus: KeybindingFocus
    ) -> [MacAppKeybindingHelpEntry] {
        var order: [KeybindingAction] = []
        var chords: [KeybindingAction: [String]] = [:]
        for binding in KeybindingCatalog.bindings(mode: mode, focus: focus) {
            if chords[binding.action] == nil {
                order.append(binding.action)
            }
            chords[binding.action, default: []].append(binding.chord.displayString)
        }
        return order.map { action in
            MacAppKeybindingHelpEntry(
                action: action.displayTitle,
                shortcut: chords[action, default: []].joined(separator: " / ")
            )
        }
    }
}
