import Foundation

/// A user-configurable quick comment template shown on the review-comment sheet.
///
/// The text-selection edit menu intentionally exposes one action only: Comment.
/// These templates are the configurable shortcuts inside that comment flow.
struct PiQuickAction: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var systemImage: String
    var promptPrefix: String
    var behavior: PiQuickActionBehavior
    var sortOrder: Int

    /// True when this legacy action would insert only the selected snippet.
    var isRawInsert: Bool {
        promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Text inserted into the comment composer when this quick comment is tapped.
    var quickCommentText: String {
        promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when this action can be shown as a quick comment template.
    ///
    /// Legacy `.newSession` actions with non-empty text are kept during
    /// migration so customized templates are not lost on upgrade.
    var isQuickCommentTemplate: Bool {
        behavior != .reviewComment && !quickCommentText.isEmpty
    }
}

/// Legacy dispatch behavior for stored actions.
///
/// New selection routing no longer exposes these behaviors directly: selected text
/// has one edit-menu action, Comment. The cases remain so existing persisted JSON
/// decodes safely and so older routing tests can describe compatibility paths.
enum PiQuickActionBehavior: String, Codable, CaseIterable, Equatable, Hashable {
    /// Legacy: append to the active session's composer input.
    case currentSession
    /// Legacy: open the Quick Session sheet with the text pre-filled.
    case newSession
    /// Save the selected text as a staged review comment.
    case reviewComment
}

// MARK: - Built-in Defaults

extension PiQuickAction {
    // Stable UUIDs for built-in defaults and legacy actions.
    // swiftlint:disable identifier_name
    private static let _id1 = UUID(uuidString: "A0000001-0000-0000-0000-000000000001") ?? UUID()
    private static let _id2 = UUID(uuidString: "A0000001-0000-0000-0000-000000000002") ?? UUID()
    private static let _id3 = UUID(uuidString: "A0000001-0000-0000-0000-000000000003") ?? UUID()
    private static let _id4 = UUID(uuidString: "A0000001-0000-0000-0000-000000000004") ?? UUID()
    private static let _id5 = UUID(uuidString: "A0000001-0000-0000-0000-000000000005") ?? UUID()
    private static let _id6 = UUID(uuidString: "A0000001-0000-0000-0000-000000000006") ?? UUID()
    private static let _id7 = UUID(uuidString: "A0000001-0000-0000-0000-000000000007") ?? UUID()
    // swiftlint:enable identifier_name

    static let explainAction = PiQuickAction(
        id: _id1,
        title: "Explain",
        systemImage: "questionmark.bubble",
        promptPrefix: "Explain this.",
        behavior: .currentSession,
        sortOrder: 0
    )

    static let doItAction = PiQuickAction(
        id: _id2,
        title: "Do it",
        systemImage: "play.circle",
        promptPrefix: "Do this.",
        behavior: .currentSession,
        sortOrder: 1
    )

    static let fixAction = PiQuickAction(
        id: _id3,
        title: "Fix",
        systemImage: "wrench.and.screwdriver",
        promptPrefix: "Fix this.",
        behavior: .currentSession,
        sortOrder: 2
    )

    static let refactorAction = PiQuickAction(
        id: _id4,
        title: "Refactor",
        systemImage: "arrow.triangle.branch",
        promptPrefix: "Refactor this.",
        behavior: .currentSession,
        sortOrder: 3
    )

    /// Legacy action kept for compatibility with persisted settings/tests.
    static let addToPromptAction = PiQuickAction(
        id: _id5,
        title: "Add to Prompt",
        systemImage: "plus.bubble",
        promptPrefix: "",
        behavior: .currentSession,
        sortOrder: 4
    )

    /// Legacy action kept for compatibility; no longer appears in the selection menu.
    static let newSessionAction = PiQuickAction(
        id: _id6,
        title: "New Session",
        systemImage: "plus.message",
        promptPrefix: "",
        behavior: .newSession,
        sortOrder: 5
    )

    static let reviewCommentAction = PiQuickAction(
        id: _id7,
        title: "Comment",
        systemImage: "text.bubble",
        promptPrefix: "",
        behavior: .reviewComment,
        sortOrder: 100
    )

    /// The only action shown in text-selection menus.
    static func sortedForSelectionMenu(_ actions: [PiQuickAction]) -> [PiQuickAction] {
        _ = actions
        return [reviewCommentAction]
    }

    /// Configurable quick comments shown on the comment composer sheet.
    static func quickCommentTemplates(_ actions: [PiQuickAction]) -> [PiQuickAction] {
        actions
            .filter { $0.isQuickCommentTemplate }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The factory defaults for quick comments.
    static let builtInDefaults: [PiQuickAction] = [
        explainAction,
        doItAction,
        fixAction,
        refactorAction,
    ]
}

// MARK: - Store

import SwiftUI

/// Persists and vends the user's configured quick comment templates.
///
/// Observable so the comment composer and settings UI react to changes.
/// Reads/writes JSON to UserDefaults. Falls back to built-in defaults on first
/// launch, corrupt data, or legacy data that only contains non-comment actions.
@MainActor @Observable
final class PiQuickActionStore {
    private static let defaultsKey = "\(AppIdentifiers.subsystem).piQuickActions"

    private(set) var actions: [PiQuickAction]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([PiQuickAction].self, from: data) {
            let templates = Self.normalizedTemplates(decoded)
            actions = templates.isEmpty ? PiQuickAction.builtInDefaults : templates
        } else {
            actions = PiQuickAction.builtInDefaults
        }
    }

    // periphery:ignore
    /// Test seam: initialize with specific actions.
    init(actions: [PiQuickAction]) {
        self.actions = actions
    }

    // MARK: - Mutations

    func add(_ action: PiQuickAction) {
        var newAction = action
        let maxOrder = actions.map(\.sortOrder).max() ?? -1
        newAction.sortOrder = maxOrder + 1
        actions.append(newAction)
        persist()
    }

    func update(_ action: PiQuickAction) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[index] = action
        persist()
    }

    func delete(at offsets: IndexSet) {
        actions.remove(atOffsets: offsets)
        reindex()
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
        reindex()
        persist()
    }

    func resetToDefaults() {
        actions = PiQuickAction.builtInDefaults
        persist()
    }

    // MARK: - Private

    private static func normalizedTemplates(_ actions: [PiQuickAction]) -> [PiQuickAction] {
        var templates = PiQuickAction.quickCommentTemplates(actions).map(migratingLegacyBuiltInText)
        for i in templates.indices {
            templates[i].sortOrder = i
        }
        return templates
    }

    private static func migratingLegacyBuiltInText(_ action: PiQuickAction) -> PiQuickAction {
        var migrated = action
        if action.id == PiQuickAction.explainAction.id, action.quickCommentText == "Explain this:" {
            migrated.promptPrefix = PiQuickAction.explainAction.promptPrefix
        } else if action.id == PiQuickAction.doItAction.id, action.quickCommentText == "Do this:" {
            migrated.promptPrefix = PiQuickAction.doItAction.promptPrefix
        } else if action.id == PiQuickAction.fixAction.id, action.quickCommentText == "Fix this:" {
            migrated.promptPrefix = PiQuickAction.fixAction.promptPrefix
        } else if action.id == PiQuickAction.refactorAction.id, action.quickCommentText == "Refactor this:" {
            migrated.promptPrefix = PiQuickAction.refactorAction.promptPrefix
        }
        return migrated
    }

    private func reindex() {
        for i in actions.indices {
            actions[i].sortOrder = i
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
