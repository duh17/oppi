import Foundation

/// A user-configurable action that appears in the π text-selection menu.
///
/// Replaces the old hardcoded `SelectedTextPiActionKind` enum. Users can
/// add, edit, reorder, and delete actions. Ships with sensible defaults
/// matching the original five actions.
struct PiQuickAction: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var systemImage: String
    var promptPrefix: String
    var behavior: PiQuickActionBehavior
    var sortOrder: Int

    /// True when this action should not prepend a prefix line to the snippet.
    var isRawInsert: Bool {
        promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// How a pi action dispatches the selected text.
enum PiQuickActionBehavior: String, Codable, CaseIterable, Equatable, Hashable {
    /// Append to the active session's composer input.
    case currentSession
    /// Open the Quick Session sheet with the text pre-filled.
    case newSession
}

// MARK: - Built-in Defaults

extension PiQuickAction {
    // Stable UUIDs for built-in defaults so they can be referenced by the
    // backward-compatibility shim without force unwrapping.
    // swiftlint:disable identifier_name
    private static let _id1 = UUID(uuidString: "A0000001-0000-0000-0000-000000000001") ?? UUID()
    private static let _id2 = UUID(uuidString: "A0000001-0000-0000-0000-000000000002") ?? UUID()
    private static let _id3 = UUID(uuidString: "A0000001-0000-0000-0000-000000000003") ?? UUID()
    private static let _id4 = UUID(uuidString: "A0000001-0000-0000-0000-000000000004") ?? UUID()
    private static let _id5 = UUID(uuidString: "A0000001-0000-0000-0000-000000000005") ?? UUID()
    private static let _id6 = UUID(uuidString: "A0000001-0000-0000-0000-000000000006") ?? UUID()
    // swiftlint:enable identifier_name

    /// The factory defaults, matching the original hardcoded actions.
    static let builtInDefaults: [PiQuickAction] = [
        PiQuickAction(
            id: _id1,
            title: "Explain",
            systemImage: "questionmark.bubble",
            promptPrefix: "Explain this:",
            behavior: .currentSession,
            sortOrder: 0
        ),
        PiQuickAction(
            id: _id2,
            title: "Do it",
            systemImage: "play.circle",
            promptPrefix: "Do this:",
            behavior: .currentSession,
            sortOrder: 1
        ),
        PiQuickAction(
            id: _id3,
            title: "Fix",
            systemImage: "wrench.and.screwdriver",
            promptPrefix: "Fix this:",
            behavior: .currentSession,
            sortOrder: 2
        ),
        PiQuickAction(
            id: _id4,
            title: "Refactor",
            systemImage: "arrow.triangle.branch",
            promptPrefix: "Refactor this:",
            behavior: .currentSession,
            sortOrder: 3
        ),
        PiQuickAction(
            id: _id5,
            title: "Add to Prompt",
            systemImage: "plus.bubble",
            promptPrefix: "",
            behavior: .currentSession,
            sortOrder: 4
        ),
        PiQuickAction(
            id: _id6,
            title: "New Session",
            systemImage: "plus.message",
            promptPrefix: "",
            behavior: .newSession,
            sortOrder: 5
        ),
    ]
}

// MARK: - Store

import SwiftUI

/// Persists and vends the user's configured π quick actions.
///
/// Observable so the edit-menu builders and settings UI react to changes.
/// Reads/writes JSON to UserDefaults. Falls back to built-in defaults
/// on first launch or corrupt data.
@MainActor @Observable
final class PiQuickActionStore {
    private static let defaultsKey = "\(AppIdentifiers.subsystem).piQuickActions"

    private(set) var actions: [PiQuickAction]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([PiQuickAction].self, from: data),
           !decoded.isEmpty {
            actions = decoded.sorted { $0.sortOrder < $1.sortOrder }
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
