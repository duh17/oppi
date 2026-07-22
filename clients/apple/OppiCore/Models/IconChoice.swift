import Foundation

/// Tagged icon value shared by saved Agents, workspaces, and launch snapshots.
/// Unknown or malformed future cases visibly fall back without failing their parent model.
enum IconChoice: Sendable, Equatable, Hashable {
    case defaultValue
    case emoji(String)
    case symbol(String)
    case genmoji(assetId: String, contentDescription: String)

    var assetId: String? {
        guard case .genmoji(let assetId, _) = self else { return nil }
        return assetId
    }

    var accessibilityDescription: String {
        switch self {
        case .defaultValue:
            return "Default icon"
        case .emoji(let value):
            return "Emoji \(value)"
        case .symbol(let name):
            return "SF Symbol \(name.replacingOccurrences(of: ".", with: " "))"
        case .genmoji(_, let contentDescription):
            return contentDescription
        }
    }
}

extension IconChoice {
    var jsonValue: JSONValue {
        switch self {
        case .defaultValue:
            return ["kind": "default"]
        case .emoji(let value):
            return ["kind": "emoji", "value": .string(value)]
        case .symbol(let name):
            return ["kind": "symbol", "name": .string(name)]
        case .genmoji(let assetId, let contentDescription):
            return [
                "kind": "genmoji",
                "assetId": .string(assetId),
                "contentDescription": .string(contentDescription),
            ]
        }
    }
}

extension IconChoice: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, value, name, assetId, contentDescription
    }

    private enum Kind: String, Codable {
        case defaultValue = "default"
        case emoji
        case symbol
        case genmoji
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let kind = try? container.decode(Kind.self, forKey: .kind) else {
            self = .defaultValue
            return
        }

        switch kind {
        case .defaultValue:
            self = .defaultValue
        case .emoji:
            guard let value = try? container.decode(String.self, forKey: .value),
                  case .emoji(let normalized) = AgentIconValue.classify(value) else {
                self = .defaultValue
                return
            }
            self = .emoji(normalized)
        case .symbol:
            guard let name = try? container.decode(String.self, forKey: .name),
                  case .symbolCandidate(let normalized) = AgentIconValue.classify(name) else {
                self = .defaultValue
                return
            }
            self = .symbol(normalized)
        case .genmoji:
            guard let assetId = try? container.decode(String.self, forKey: .assetId),
                  let contentDescription = try? container.decode(String.self, forKey: .contentDescription),
                  Self.isValidAssetID(assetId) else {
                self = .defaultValue
                return
            }
            let description = contentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty, description.unicodeScalars.count <= 256 else {
                self = .defaultValue
                return
            }
            self = .genmoji(assetId: assetId, contentDescription: description)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultValue:
            try container.encode(Kind.defaultValue, forKey: .kind)
        case .emoji(let value):
            try container.encode(Kind.emoji, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .symbol(let name):
            try container.encode(Kind.symbol, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .genmoji(let assetId, let contentDescription):
            try container.encode(Kind.genmoji, forKey: .kind)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(contentDescription, forKey: .contentDescription)
        }
    }

    private static func isValidAssetID(_ value: String) -> Bool {
        guard value.hasPrefix("ia_"), value.count == 46 else { return false }
        return value.dropFirst(3).unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F:
                return true
            default:
                return false
            }
        }
    }
}
