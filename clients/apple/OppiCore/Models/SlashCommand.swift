import Foundation

/// Slash command metadata returned by pi RPC `get_commands`.
struct SlashCommand: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case builtin
        case `extension`
        case prompt
        case skill

        var sortRank: Int {
            switch self {
            case .builtin: return 0
            case .extension: return 1
            case .prompt: return 2
            case .skill: return 3
            }
        }

        var label: String {
            switch self {
            case .builtin: return "Built-in"
            case .extension: return "Extension"
            case .prompt: return "Prompt"
            case .skill: return "Skill"
            }
        }

        var iconName: String {
            switch self {
            case .builtin: return "bolt.circle"
            case .extension: return "puzzlepiece.extension"
            case .prompt: return "text.quote"
            case .skill: return "star"
            }
        }

    }

    let name: String
    let description: String?
    let source: Source

    var id: String {
        name.lowercased()
    }

    var invocation: String {
        "/\(name)"
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let rawName = object["name"]?.stringValue,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawSource = object["source"]?.stringValue,
              let source = Source(rawValue: rawSource) else {
            return nil
        }

        name = rawName

        if let rawDescription = object["description"]?.stringValue,
           !rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            description = rawDescription
        } else {
            description = nil
        }

        self.source = source
    }
}
