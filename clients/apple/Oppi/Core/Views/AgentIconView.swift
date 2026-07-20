import SwiftUI
import UIKit

enum AgentIconContent: Equatable {
    case symbol(String)
    case text(String)
    case fallback

    static func resolve(_ value: String?) -> Self {
        switch AgentIconValue.classify(value) {
        case .emoji(let emoji):
            return .text(emoji)
        case .symbolCandidate(let name):
            return UIImage(systemName: name) == nil ? .fallback : .symbol(name)
        case .invalid:
            return .fallback
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .symbol(let name):
            return "SF Symbol \(name.replacingOccurrences(of: ".", with: " "))"
        case .text(let emoji):
            return "Emoji \(emoji)"
        case .fallback:
            return "Default Agent icon"
        }
    }
}

enum AssistantIdentityPresentation: Equatable {
    case globalAvatar
    case agent(AgentIconContent)

    static func resolve(agentId: String?, agentIcon: String?) -> Self {
        guard agentId?.isEmpty == false else { return .globalAvatar }
        return .agent(AgentIconContent.resolve(agentIcon))
    }
}

enum AgentIconSizingPolicy {
    static func contentSize(
        baseSize: CGFloat,
        scaledSize: CGFloat,
        frameSize: CGFloat?
    ) -> CGFloat {
        let layoutBox = frameSize ?? baseSize
        return min(scaledSize, baseSize * 1.4, layoutBox * 0.78)
    }
}

struct AgentIconView: View {
    let value: String?
    let size: CGFloat
    let frameSize: CGFloat?
    let isDecorative: Bool
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 20

    init(
        value: String?,
        size: CGFloat,
        frameSize: CGFloat? = nil,
        isDecorative: Bool = true
    ) {
        self.value = value
        self.size = size
        self.frameSize = frameSize
        self.isDecorative = isDecorative
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var displaySize: CGFloat {
        AgentIconSizingPolicy.contentSize(
            baseSize: size,
            scaledSize: scaledSize,
            frameSize: frameSize
        )
    }

    var body: some View {
        Group {
            switch AgentIconContent.resolve(value) {
            case .symbol(let name):
                Image(systemName: name)
                    .foregroundStyle(.themeBlue)
            case .text(let text):
                Text(text)
            case .fallback:
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.themeBlue)
            }
        }
        .font(.system(size: displaySize))
        .frame(width: frameSize ?? size, height: frameSize ?? size)
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(isDecorative ? "" : AgentIconContent.resolve(value).accessibilityDescription)
    }
}

@MainActor
enum AgentIconRenderer {
    static func render(value: String?, size: CGFloat) -> UIImage {
        switch AgentIconContent.resolve(value) {
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .medium)
            return UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(UIColor(ThemeRuntimeState.currentPalette().blue), renderingMode: .alwaysOriginal)
                ?? fallback(size: size)
        case .text(let emoji):
            return renderText(emoji, size: size)
        case .fallback:
            return fallback(size: size)
        }
    }

    private static func fallback(size: CGFloat) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .medium)
        return UIImage(systemName: "person.crop.circle", withConfiguration: configuration)?
            .withTintColor(UIColor(ThemeRuntimeState.currentPalette().blue), renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    private static func renderText(_ text: String, size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.78),
            ]
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
