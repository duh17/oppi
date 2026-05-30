import Foundation
import SwiftUI

/// A user-configurable shortcut shown inside the review-comment composer.
struct QuickCommentTemplate: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var systemImage: String
    var promptPrefix: String
    var sortOrder: Int

    /// Text inserted into the comment composer when this template is tapped.
    var quickCommentText: String {
        promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when this decoded value should be shown as a quick comment.
    ///
    /// Older releases persisted selected-text actions with extra routing fields.
    /// Swift's decoder ignores those extra fields; keeping only non-empty text
    /// preserves customized quick-comment templates while dropping legacy actions.
    var isQuickCommentTemplate: Bool {
        !quickCommentText.isEmpty
    }
}

// MARK: - Built-in Defaults

extension QuickCommentTemplate {
    // Stable UUIDs for built-in defaults.
    // swiftlint:disable identifier_name
    private static let _id1 = UUID(uuidString: "A0000001-0000-0000-0000-000000000001") ?? UUID()
    private static let _id2 = UUID(uuidString: "A0000001-0000-0000-0000-000000000002") ?? UUID()
    private static let _id3 = UUID(uuidString: "A0000001-0000-0000-0000-000000000003") ?? UUID()
    private static let _id4 = UUID(uuidString: "A0000001-0000-0000-0000-000000000004") ?? UUID()
    // swiftlint:enable identifier_name

    static let explain = QuickCommentTemplate(
        id: _id1,
        title: "Explain",
        systemImage: "questionmark.bubble",
        promptPrefix: "Explain this.",
        sortOrder: 0
    )

    static let doIt = QuickCommentTemplate(
        id: _id2,
        title: "Do it",
        systemImage: "play.circle",
        promptPrefix: "Do this.",
        sortOrder: 1
    )

    static let fix = QuickCommentTemplate(
        id: _id3,
        title: "Fix",
        systemImage: "wrench.and.screwdriver",
        promptPrefix: "Fix this.",
        sortOrder: 2
    )

    static let refactor = QuickCommentTemplate(
        id: _id4,
        title: "Refactor",
        systemImage: "arrow.triangle.branch",
        promptPrefix: "Refactor this.",
        sortOrder: 3
    )

    /// Configurable quick comments shown on the comment composer sheet.
    static func quickCommentTemplates(_ templates: [QuickCommentTemplate]) -> [QuickCommentTemplate] {
        templates
            .filter { $0.isQuickCommentTemplate }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The factory defaults for quick comments.
    static let builtInDefaults: [QuickCommentTemplate] = [
        explain,
        doIt,
        fix,
        refactor,
    ]
}

// MARK: - Store

/// Persists and vends the user's configured quick comment templates.
///
/// Observable so the comment composer and settings UI react to changes.
/// Reads/writes JSON to UserDefaults. Falls back to built-in defaults on first
/// launch, corrupt data, or legacy selected-text action data with no templates.
@MainActor @Observable
final class QuickCommentTemplateStore {
    /// Keep the historical key so existing customized quick comments survive
    /// the selected-text action cleanup.
    private static let defaultsKey = "\(AppIdentifiers.subsystem).piQuickActions"

    private(set) var templates: [QuickCommentTemplate]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([QuickCommentTemplate].self, from: data) {
            let migratedTemplates = Self.normalizedTemplates(decoded)
            templates = migratedTemplates.isEmpty ? QuickCommentTemplate.builtInDefaults : migratedTemplates
        } else {
            templates = QuickCommentTemplate.builtInDefaults
        }
    }

    // periphery:ignore
    /// Test seam: initialize with specific templates.
    init(templates: [QuickCommentTemplate]) {
        self.templates = Self.normalizedTemplates(templates)
    }

    // MARK: - Mutations

    func add(_ template: QuickCommentTemplate) {
        var newTemplate = template
        let maxOrder = templates.map(\.sortOrder).max() ?? -1
        newTemplate.sortOrder = maxOrder + 1
        templates.append(newTemplate)
        persist()
    }

    func update(_ template: QuickCommentTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        persist()
    }

    func delete(at offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        reindex()
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
        reindex()
        persist()
    }

    func resetToDefaults() {
        templates = QuickCommentTemplate.builtInDefaults
        persist()
    }

    // MARK: - Private

    private static func normalizedTemplates(_ templates: [QuickCommentTemplate]) -> [QuickCommentTemplate] {
        var normalized = QuickCommentTemplate.quickCommentTemplates(templates).map(migratingLegacyBuiltInText)
        for i in normalized.indices {
            normalized[i].sortOrder = i
        }
        return normalized
    }

    private static func migratingLegacyBuiltInText(_ template: QuickCommentTemplate) -> QuickCommentTemplate {
        var migrated = template
        if template.id == QuickCommentTemplate.explain.id, template.quickCommentText == "Explain this:" {
            migrated.promptPrefix = QuickCommentTemplate.explain.promptPrefix
        } else if template.id == QuickCommentTemplate.doIt.id, template.quickCommentText == "Do this:" {
            migrated.promptPrefix = QuickCommentTemplate.doIt.promptPrefix
        } else if template.id == QuickCommentTemplate.fix.id, template.quickCommentText == "Fix this:" {
            migrated.promptPrefix = QuickCommentTemplate.fix.promptPrefix
        } else if template.id == QuickCommentTemplate.refactor.id, template.quickCommentText == "Refactor this:" {
            migrated.promptPrefix = QuickCommentTemplate.refactor.promptPrefix
        }
        return migrated
    }

    private func reindex() {
        for i in templates.indices {
            templates[i].sortOrder = i
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
