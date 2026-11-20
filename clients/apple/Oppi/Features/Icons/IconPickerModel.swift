import Foundation
import Observation
import UIKit

// The icon picker's state and the SF Symbol catalog it offers. The screen is
// `IconPickerViewController`.

// MARK: - Purpose and state

/// Whose icon the picker edits. An Agent's and a workspace's icon are the same
/// primitive with the same picker: these name the owner, and nothing else
/// differs.
enum IconPickerPurpose: Sendable {
    case agent
    case workspace

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

    /// The prefix of every identifier in the picker, e.g. `agent.iconPicker.save`.
    var accessibilityPrefix: String {
        switch self {
        case .agent: return "agent.iconPicker"
        case .workspace: return "workspace.iconPicker"
        }
    }

    /// The one page where the icon animates, besides the picker.
    var ownPage: String {
        switch self {
        case .agent: return String(localized: "the Agent’s page")
        case .workspace: return String(localized: "the workspace’s page")
        }
    }

    /// The icon's spoken value on its owner's page.
    func description(_ value: IconChoice) -> String {
        switch AgentIconContent.resolve(value) {
        case .text(let emoji): return "Emoji \(emoji)"
        case .symbol(let name):
            let label = IconSymbolCatalog.label(for: name) ?? "SF Symbol"
            guard case .symbol(_, let effect?) = value else { return label }
            return "\(label), \(effect.title)"
        case .genmoji(_, let contentDescription): return contentDescription
        case .image: return "Image"
        case .fallback:
            switch self {
            case .agent: return "Default"
            case .workspace: return "Default workspace icon"
            }
        }
    }
}

enum IconPickerDraft<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case genmoji(data: Data, contentDescription: String)
    /// Imported image bytes, already prepared for upload (`IconImageImport`).
    case image(data: Data)
}

extension IconPickerDraft: Hashable where Value: Hashable {}

enum IconPickerCustomChoice: Equatable, Sendable {
    case emoji(String)
    case genmoji(String)
    case image

    var accessibilityDescription: String {
        switch self {
        case .emoji(let value): return "Emoji \(value)"
        case .genmoji(let contentDescription): return "Genmoji \(contentDescription)"
        case .image: return "Imported image"
        }
    }
}

@MainActor @Observable
final class IconPickerModel<Value: Equatable & Sendable> {
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
        savedValue: Value,
        defaultValue: Value,
        customChoice: @escaping (Value) -> IconPickerCustomChoice? = { _ in nil },
        valueValidation: @escaping (Value) -> String? = { _ in nil }
    ) {
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

    /// An imported image's prepared bytes.
    @discardableResult
    func selectImage(data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        draft = .image(data: data)
        customInputText = ""
        selectedCustomChoice = .image
        clearFeedback()
        return true
    }

    func save(
        prepareGenmoji: (Data, String) async throws -> Value,
        prepareImage: (Data) async throws -> Value,
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
            case .image(let data):
                value = try await prepareImage(data)
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
