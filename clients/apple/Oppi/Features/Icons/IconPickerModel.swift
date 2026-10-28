import Foundation
import Observation
import UIKit

// The icon picker's state and the SF Symbol catalog it offers. The screen is
// `IconPickerViewController`.

// MARK: - Purpose and state

enum IconPickerMedia: Hashable, Sendable {
    case emoji
    case genmoji
    case symbol
}

enum IconPickerPurpose: Sendable {
    case agent
    case workspace

    var allowedMedia: Set<IconPickerMedia> {
        [.emoji, .genmoji, .symbol]
    }

    var title: String {
        switch self {
        case .agent: return "Agent Icon"
        case .workspace: return "Workspace Icon"
        }
    }

    var symbolSectionTitle: String {
        switch self {
        case .agent: return "Agent Symbols"
        case .workspace: return "Workspace Symbols"
        }
    }
}

enum IconPickerDraft<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case genmoji(data: Data, contentDescription: String)
}

enum IconPickerCustomChoice: Equatable, Sendable {
    case emoji(String)
    case genmoji(String)

    var accessibilityDescription: String {
        switch self {
        case .emoji(let value): return "Emoji \(value)"
        case .genmoji(let contentDescription): return "Genmoji \(contentDescription)"
        }
    }
}

@MainActor @Observable
final class IconPickerModel<Value: Equatable & Sendable> {
    let purpose: IconPickerPurpose
    let defaultValue: Value
    private let customChoice: (Value) -> IconPickerCustomChoice?
    private let valueValidation: (Value) -> String?
    private(set) var savedValue: Value
    private(set) var draft: IconPickerDraft<Value>
    private(set) var customInputText: String
    private(set) var selectedCustomChoice: IconPickerCustomChoice?
    private(set) var validationMessage: String?
    private(set) var errorMessage: String?
    private(set) var isSaving = false

    init(
        purpose: IconPickerPurpose,
        savedValue: Value,
        defaultValue: Value,
        customChoice: @escaping (Value) -> IconPickerCustomChoice? = { _ in nil },
        valueValidation: @escaping (Value) -> String? = { _ in nil }
    ) {
        self.purpose = purpose
        self.savedValue = savedValue
        self.defaultValue = defaultValue
        self.customChoice = customChoice
        self.valueValidation = valueValidation
        draft = .value(savedValue)
        let initialCustomChoice = customChoice(savedValue)
        selectedCustomChoice = initialCustomChoice
        if case .emoji(let emoji)? = initialCustomChoice {
            customInputText = emoji
        } else {
            customInputText = ""
        }
    }

    var hasChanges: Bool {
        draft != .value(savedValue)
    }

    var canSave: Bool {
        hasChanges && validationMessage == nil && !isSaving
    }

    func selectDefault() {
        selectValue(defaultValue)
    }

    func selectValue(_ value: Value) {
        draft = .value(value)
        selectedCustomChoice = customChoice(value)
        if case .emoji(let emoji)? = selectedCustomChoice {
            customInputText = emoji
        } else {
            customInputText = ""
        }
        validationMessage = valueValidation(value)
        errorMessage = nil
    }

    @discardableResult
    func selectEmoji(_ rawValue: String, transform: (String) -> Value) -> Bool {
        guard purpose.allowedMedia.contains(.emoji) else { return false }
        customInputText = rawValue
        switch AgentIconValue.classify(rawValue) {
        case .emoji(let emoji):
            draft = .value(transform(emoji))
            customInputText = emoji
            selectedCustomChoice = .emoji(emoji)
            clearFeedback()
            return true
        case .symbolCandidate, .invalid:
            selectedCustomChoice = nil
            validationMessage = "Enter exactly one Unicode emoji."
            errorMessage = nil
            return false
        }
    }

    @discardableResult
    func selectGenmoji(data: Data, contentDescription: String) -> Bool {
        guard purpose.allowedMedia.contains(.genmoji) else { return false }
        let description = contentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty, !description.isEmpty, description.unicodeScalars.count <= 256 else {
            selectedCustomChoice = nil
            validationMessage = "Choose a Genmoji with a description."
            errorMessage = nil
            return false
        }
        draft = .genmoji(data: data, contentDescription: description)
        customInputText = ""
        selectedCustomChoice = .genmoji(description)
        clearFeedback()
        return true
    }

    func save(
        prepareGenmoji: (Data, String) async throws -> Value,
        commit: (Value) async throws -> Void
    ) async -> Bool {
        guard hasChanges, !isSaving else { return false }
        if case .value(let value) = draft,
           let validationMessage = valueValidation(value) {
            self.validationMessage = validationMessage
            errorMessage = nil
            return false
        }
        guard validationMessage == nil else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let value: Value
            switch draft {
            case .value(let selectedValue):
                value = selectedValue
            case .genmoji(let data, let contentDescription):
                value = try await prepareGenmoji(data, contentDescription)
                // Keep the uploaded reference if persistence fails. Retry should
                // commit the same asset instead of uploading duplicate bytes.
                draft = .value(value)
            }

            try await commit(value)
            savedValue = value
            draft = .value(value)
            selectedCustomChoice = customChoice(value) ?? selectedCustomChoice
            if case .emoji(let emoji)? = selectedCustomChoice {
                customInputText = emoji
            } else {
                customInputText = ""
            }
            return true
        } catch {
            errorMessage = "Couldn’t save. \(error.localizedDescription)"
            return false
        }
    }

    private func clearFeedback() {
        validationMessage = nil
        errorMessage = nil
    }
}

// MARK: - Option metadata

struct IconSymbolOption: Identifiable, Equatable {
    let symbolName: String
    let label: String

    var id: String { symbolName }
}

enum IconSymbolCatalog {
    static let options: [IconSymbolOption] = [
        .init(symbolName: "folder", label: "Folder"),
        .init(symbolName: "folder.fill", label: "Folder Filled"),
        .init(symbolName: "square.grid.2x2", label: "Workspace"),
        .init(symbolName: "rectangle.3.group", label: "Project"),
        .init(symbolName: "terminal", label: "Terminal"),
        .init(symbolName: "chevron.left.forwardslash.chevron.right", label: "Code"),
        .init(symbolName: "curlybraces", label: "Braces"),
        .init(symbolName: "command", label: "Command"),
        .init(symbolName: "hammer", label: "Build"),
        .init(symbolName: "wrench.and.screwdriver", label: "Tools"),
        .init(symbolName: "ant", label: "Debug"),
        .init(symbolName: "ladybug", label: "Bug"),
        .init(symbolName: "shippingbox", label: "Package"),
        .init(symbolName: "cube", label: "Module"),
        .init(symbolName: "server.rack", label: "Server"),
        .init(symbolName: "externaldrive", label: "Storage"),
        .init(symbolName: "cloud", label: "Cloud"),
        .init(symbolName: "network", label: "Network"),
        .init(symbolName: "globe", label: "Web"),
        .init(symbolName: "arrow.triangle.branch", label: "Branch"),
        .init(symbolName: "point.3.connected.trianglepath.dotted", label: "Graph"),
        .init(symbolName: "doc.text", label: "Docs"),
        .init(symbolName: "book.closed", label: "Book"),
        .init(symbolName: "books.vertical", label: "Research"),
        .init(symbolName: "text.page", label: "Text"),
        .init(symbolName: "checklist", label: "Checklist"),
        .init(symbolName: "checkmark.shield", label: "Review"),
        .init(symbolName: "tray.full", label: "Archive"),
        .init(symbolName: "brain", label: "AI"),
        .init(symbolName: "brain.head.profile", label: "Thinking"),
        .init(symbolName: "sparkles", label: "Sparkles"),
        .init(symbolName: "magnifyingglass", label: "Search"),
        .init(symbolName: "lightbulb", label: "Idea"),
        .init(symbolName: "bolt", label: "Fast"),
        .init(symbolName: "flame", label: "Hot"),
        .init(symbolName: "star", label: "Favorite"),
        .init(symbolName: "heart", label: "Heart"),
        .init(symbolName: "flag", label: "Flag"),
        .init(symbolName: "tag", label: "Tag"),
        .init(symbolName: "lock", label: "Secure"),
        .init(symbolName: "shield", label: "Shield"),
        .init(symbolName: "person.2", label: "Team"),
        .init(symbolName: "paintbrush", label: "Design"),
        .init(symbolName: "photo", label: "Media"),
        .init(symbolName: "music.note", label: "Audio"),
        .init(symbolName: "gamecontroller", label: "Game"),
        .init(symbolName: "graduationcap", label: "Learning"),
        .init(symbolName: "leaf", label: "Nature"),
        .init(symbolName: "cart", label: "Shop"),
    ]

    static func isAvailable(_ symbolName: String) -> Bool {
        UIImage(systemName: symbolName) != nil
    }

    static func availableOptions(
        matching query: String,
        isAvailable: (String) -> Bool = Self.isAvailable
    ) -> [IconSymbolOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter {
            isAvailable($0.symbolName)
                && FuzzyMatch.matchesAny(query: trimmed, fields: [$0.label, $0.symbolName])
        }
    }

    static func label(for symbolName: String) -> String? {
        options.first { $0.symbolName == symbolName }?.label
    }
}
