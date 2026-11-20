import UIKit

enum AgentIconContent: Equatable {
    case symbol(String)
    case text(String)
    case genmoji(assetId: String, contentDescription: String)
    case image(assetId: String)
    case fallback

    static func resolve(_ value: IconChoice?) -> Self {
        switch value ?? .defaultValue {
        case .defaultValue:
            return .fallback
        case .emoji(let emoji):
            return .text(emoji)
        case .symbol(let name, _):
            return UIImage(systemName: name) == nil ? .fallback : .symbol(name)
        case .genmoji(let assetId, let contentDescription):
            return .genmoji(assetId: assetId, contentDescription: contentDescription)
        case .image(let assetId):
            return .image(assetId: assetId)
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .symbol(let name):
            return IconSymbolCatalog.label(for: name) ?? "Symbol icon"
        case .text(let emoji):
            return "Emoji \(emoji)"
        case .genmoji(_, let contentDescription):
            return contentDescription
        case .image:
            return "Image icon"
        case .fallback:
            return "Agent icon"
        }
    }
}

enum AssistantIdentityPresentation: Equatable {
    case globalAvatar
    case agent(AgentIconContent)

    static func resolve(agentId: String?, agentIcon: IconChoice?) -> Self {
        guard agentId?.isEmpty == false else { return .globalAvatar }
        return .agent(AgentIconContent.resolve(agentIcon))
    }
}
