import UIKit

enum AgentIconContent: Equatable {
    case symbol(String)
    case text(String)
    case genmoji(assetId: String, contentDescription: String)
    case fallback

    static func resolve(_ value: IconChoice?) -> Self {
        switch value ?? .defaultValue {
        case .defaultValue:
            return .fallback
        case .emoji(let emoji):
            return .text(emoji)
        case .symbol(let name):
            return UIImage(systemName: name) == nil ? .fallback : .symbol(name)
        case .genmoji(let assetId, let contentDescription):
            return .genmoji(assetId: assetId, contentDescription: contentDescription)
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

enum ChatAgentIconStyle {
    /// Agent artwork often includes more internal whitespace than the Pi mark.
    /// Scale it optically on chat surfaces without changing layout geometry.
    static let compactVisualScale: CGFloat = 1.18
    static let heroVisualScale: CGFloat = 1.45
}

enum AgentIconSizingPolicy {
    static let titleSlotSize: CGFloat = 24
    static let titleVisualEnvelope: CGFloat = 22
    static let titleTextMinimum: CGFloat = 20
    static let titleTextMaximum: CGFloat = 21

    static func titleTextSize(for scaledSize: CGFloat) -> CGFloat {
        min(max(scaledSize, titleTextMinimum), titleTextMaximum)
    }

    static func contentSize(
        baseSize: CGFloat,
        scaledSize: CGFloat,
        frameSize: CGFloat?
    ) -> CGFloat {
        let layoutBox = frameSize ?? baseSize
        return min(scaledSize, baseSize * 1.4, layoutBox * 0.78)
    }
}
