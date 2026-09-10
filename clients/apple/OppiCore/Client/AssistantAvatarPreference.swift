import Foundation

/// UIKit-free assistant avatar preference shared by Apple clients.
///
/// Keys match iOS `AssistantAvatar` persistence. Mac paints SwiftUI/AppKit and
/// does not decode Genmoji; a stored Genmoji type reads as Official Pi without
/// rewriting the blob.
enum AssistantAvatarPreference: Equatable, Sendable {
    case officialPi
    case golGrid
    case emoji(String)

    var displayName: String {
        switch self {
        case .officialPi: return "Official Pi"
        case .golGrid: return "Grid π"
        case .emoji(let char): return char
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .officialPi, .golGrid:
            return displayName
        case .emoji(let value):
            return "Emoji \(value)"
        }
    }

    var pickerDescription: String? {
        switch self {
        case .officialPi:
            return "Official Pi logo"
        case .golGrid:
            return "Game of Life grid with spark cells"
        case .emoji:
            return nil
        }
    }

    /// Built-in choices for the picker (not including user-set emoji).
    static let builtinCases: [AssistantAvatarPreference] = [.officialPi, .golGrid]

    enum PersistenceError: LocalizedError, Equatable {
        case invalidEmoji

        var errorDescription: String? {
            "Choose exactly one Unicode emoji."
        }
    }

    static let typeKey = "assistantAvatarType"
    static let emojiKey = "assistantAvatarEmoji"
    static let genmojiKey = "assistantAvatarGenmoji"
    static let genmojiDescriptionKey = "assistantAvatarGenmojiDescription"
    static let didChangeNotification = Notification.Name(
        "\(AppIdentifiers.subsystem).assistantAvatarDidChange"
    )

    @MainActor private static let store = AssistantAvatarPreferenceStore(defaults: .standard)

    @MainActor
    static var current: AssistantAvatarPreference {
        store.current
    }

    @MainActor
    static func reloadAfterExternalChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    @MainActor
    @discardableResult
    static func setCurrent(_ avatar: AssistantAvatarPreference) throws -> AssistantAvatarPreference {
        let persisted = try store.setCurrent(avatar)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return persisted
    }
}

/// Owns device-local assistant-avatar persistence for UIKit-free cases.
@MainActor
struct AssistantAvatarPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var current: AssistantAvatarPreference {
        load()
    }

    @discardableResult
    func setCurrent(_ avatar: AssistantAvatarPreference) throws -> AssistantAvatarPreference {
        let prepared = try prepare(avatar)
        persist(prepared)
        return prepared
    }

    private func load() -> AssistantAvatarPreference {
        let type = defaults.string(forKey: AssistantAvatarPreference.typeKey) ?? "officialPi"
        switch type {
        case "officialPi":
            return .officialPi
        case "piText":
            // Retired Classic avatar: migrate the stored choice on first load.
            return normalizeToOfficialPi()
        case "golGrid":
            return .golGrid
        case "emoji":
            guard case .emoji(let emoji) = AgentIconValue.classify(
                defaults.string(forKey: AssistantAvatarPreference.emojiKey)
            ) else {
                return normalizeToOfficialPi()
            }
            return .emoji(emoji)
        case "genmoji":
            // Mac does not paint Genmoji. Leave the stored blob intact.
            return .officialPi
        default:
            return normalizeToOfficialPi()
        }
    }

    private func prepare(_ avatar: AssistantAvatarPreference) throws -> AssistantAvatarPreference {
        switch avatar {
        case .officialPi, .golGrid:
            return avatar
        case .emoji(let rawValue):
            guard case .emoji(let emoji) = AgentIconValue.classify(rawValue) else {
                throw AssistantAvatarPreference.PersistenceError.invalidEmoji
            }
            return .emoji(emoji)
        }
    }

    private func persist(_ avatar: AssistantAvatarPreference) {
        switch avatar {
        case .officialPi:
            persistBuiltin("officialPi")
        case .golGrid:
            persistBuiltin("golGrid")
        case .emoji(let emoji):
            defaults.set("emoji", forKey: AssistantAvatarPreference.typeKey)
            defaults.set(emoji, forKey: AssistantAvatarPreference.emojiKey)
            clearGenmojiPersistence()
        }
    }

    private func persistBuiltin(_ type: String) {
        defaults.set(type, forKey: AssistantAvatarPreference.typeKey)
        defaults.removeObject(forKey: AssistantAvatarPreference.emojiKey)
        clearGenmojiPersistence()
    }

    private func clearGenmojiPersistence() {
        defaults.removeObject(forKey: AssistantAvatarPreference.genmojiKey)
        defaults.removeObject(forKey: AssistantAvatarPreference.genmojiDescriptionKey)
    }

    private func normalizeToOfficialPi() -> AssistantAvatarPreference {
        persistBuiltin("officialPi")
        return .officialPi
    }
}
