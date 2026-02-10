import Foundation

/// Slash command metadata returned by pi RPC `get_commands`.
struct SlashCommand: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case builtIn = "builtin"
        case `extension`
        case prompt
        case skill

        var sortRank: Int {
            switch self {
            case .builtIn: return 0
            case .extension: return 1
            case .prompt: return 2
            case .skill: return 3
            }
        }

        var label: String {
            switch self {
            case .builtIn: return "Built-in"
            case .extension: return "Extension"
            case .prompt: return "Prompt"
            case .skill: return "Skill"
            }
        }
    }

    enum Location: String, Sendable, Equatable {
        case user
        case project
        case path
    }

    let name: String
    let description: String?
    let source: Source
    let location: Location?
    let path: String?

    init(
        name: String,
        description: String?,
        source: Source,
        location: Location? = nil,
        path: String? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.location = location
        self.path = path
    }

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
        location = object["location"]?.stringValue.flatMap(Location.init(rawValue:))
        path = object["path"]?.stringValue
    }
}
