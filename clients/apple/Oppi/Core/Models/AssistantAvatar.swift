import Foundation
import UIKit

/// Avatar style for the assistant icon in chat bubbles and empty state.
enum AssistantAvatar: Equatable, Sendable {
    /// Official Pi logo mark from pi.dev.
    case officialPi
    /// Classic π text character.
    case piText
    /// Game of Life grid forming π — unique per session.
    case golGrid
    /// User-chosen emoji character.
    case emoji(String)
    /// Apple Genmoji — stored as NSAdaptiveImageGlyph image data.
    @available(iOS 18.0, *)
    case genmoji(Data)

    var displayName: String {
        switch self {
        case .officialPi: return "Official Pi"
        case .piText: return "Classic π"
        case .golGrid: return "Grid π"
        case .emoji(let char): return char
        case .genmoji: return "Genmoji"
        }
    }

    var pickerDescription: String? {
        switch self {
        case .officialPi:
            return "Official Pi logo"
        case .piText:
            return "Monospaced assistant glyph"
        case .golGrid:
            return "Game of Life grid with spark cells"
        case .emoji, .genmoji:
            return nil
        }
    }

    var cacheIdentifier: String {
        switch self {
        case .officialPi:
            return "officialPi"
        case .piText:
            return "piText"
        case .golGrid:
            return "golGrid"
        case .emoji(let char):
            return "emoji:\(char)"
        case .genmoji(let data):
            return "genmoji:\(data.count):\(data.hashValue)"
        }
    }

    /// Built-in choices for the picker (not including user-set emoji/genmoji).
    static let builtinCases: [AssistantAvatar] = [.officialPi, .piText, .golGrid]

    // MARK: - Persistence

    private static let typeKey = "assistantAvatarType"
    private static let emojiKey = "assistantAvatarEmoji"
    private static let genmojiKey = "assistantAvatarGenmoji"

    static var current: AssistantAvatar {
        let defaults = UserDefaults.standard
        let type = defaults.string(forKey: typeKey) ?? "piText"
        switch type {
        case "officialPi": return .officialPi
        case "piText": return .piText
        case "golGrid": return .golGrid
        case "emoji":
            let char = defaults.string(forKey: emojiKey) ?? "🤖"
            return .emoji(char)
        case "genmoji":
            if #available(iOS 18.0, *),
               let data = defaults.data(forKey: genmojiKey) {
                return .genmoji(data)
            }
            return .golGrid
        default: return .golGrid
        }
    }

    @MainActor
    static func setCurrent(_ avatar: AssistantAvatar) {
        let defaults = UserDefaults.standard
        switch avatar {
        case .officialPi:
            defaults.set("officialPi", forKey: typeKey)
        case .piText:
            defaults.set("piText", forKey: typeKey)
        case .golGrid:
            defaults.set("golGrid", forKey: typeKey)
        case .emoji(let char):
            defaults.set("emoji", forKey: typeKey)
            defaults.set(char, forKey: emojiKey)
        case .genmoji(let data):
            defaults.set("genmoji", forKey: typeKey)
            defaults.set(data, forKey: genmojiKey)
        }
        NotificationCenter.default.post(name: .assistantAvatarDidChange, object: nil)
    }
}
