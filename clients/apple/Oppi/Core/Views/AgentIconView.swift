import SwiftUI
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

struct IconAssetViewLoadIdentity: Equatable {
    let key: IconAssetLoadKey
    let requestID: UUID
}

@MainActor
func loadIconAssetForView(
    assetId: String,
    size: CGFloat,
    cache: IconAssetCache,
    identity: IconAssetViewLoadIdentity,
    currentIdentity: @MainActor () -> IconAssetViewLoadIdentity?,
    assign: @MainActor (UIImage?) -> Void
) async {
    guard currentIdentity() == identity else { return }
    assign(nil)

    do {
        let image = try await cache.image(assetId: assetId, size: size)
        try Task.checkCancellation()
        guard currentIdentity() == identity else { return }
        assign(image)
    } catch is CancellationError {
        // A replacement `.task(id:)` owns the state now. Never let the
        // cancelled request clear a newer image.
    } catch {
        guard !Task.isCancelled, currentIdentity() == identity else { return }
        assign(nil)
    }
}

enum ChatAgentIconStyle {
    /// Agent artwork often includes more internal whitespace than the Pi mark.
    /// Scale it optically on chat surfaces without changing layout geometry.
    static let compactVisualScale: CGFloat = 1.18
    static let heroVisualScale: CGFloat = 1.45
}

enum AgentIconRenderStyle: Equatable {
    case standard
    case chatTitle
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

enum IconChoiceRenderPurpose {
    case agent
    case workspace

    var defaultSymbolName: String {
        switch self {
        case .agent: return "person.crop.circle"
        case .workspace: return "square.grid.2x2"
        }
    }

    var defaultAccessibilityDescription: String {
        switch self {
        case .agent: return "Agent icon"
        case .workspace: return "Default workspace icon"
        }
    }
}

/// Shared committed-value renderer for saved Agent and workspace icons.
/// Purpose supplies only the visible Default; media rendering stays generic.
struct IconChoiceView: View {
    let value: IconChoice?
    let purpose: IconChoiceRenderPurpose
    let size: CGFloat
    let frameSize: CGFloat?
    let isDecorative: Bool
    let assetCache: IconAssetCache?
    let visualScale: CGFloat
    let renderStyle: AgentIconRenderStyle

    @Environment(\.iconAssetCache) private var environmentAssetCache
    @State private var loadedGenmoji: UIImage?
    @State private var activeLoadIdentity: IconAssetViewLoadIdentity?
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 20

    init(
        value: IconChoice?,
        purpose: IconChoiceRenderPurpose,
        size: CGFloat,
        frameSize: CGFloat? = nil,
        isDecorative: Bool = true,
        assetCache: IconAssetCache? = nil,
        visualScale: CGFloat = 1,
        renderStyle: AgentIconRenderStyle = .standard
    ) {
        self.value = value
        self.purpose = purpose
        self.size = size
        self.frameSize = frameSize
        self.isDecorative = isDecorative
        self.assetCache = assetCache
        self.visualScale = visualScale
        self.renderStyle = renderStyle
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var displaySize: CGFloat {
        AgentIconSizingPolicy.contentSize(
            baseSize: size,
            scaledSize: scaledSize,
            frameSize: frameSize
        )
    }

    private var layoutSize: CGFloat {
        switch renderStyle {
        case .standard:
            return frameSize ?? size
        case .chatTitle:
            return AgentIconSizingPolicy.titleSlotSize
        }
    }

    private var visualEnvelope: CGFloat {
        min(AgentIconSizingPolicy.titleVisualEnvelope, layoutSize)
    }

    private var contentFontSize: CGFloat {
        switch renderStyle {
        case .standard:
            return displaySize
        case .chatTitle:
            return AgentIconSizingPolicy.titleTextSize(for: scaledSize)
        }
    }

    private var assetRenderSize: CGFloat {
        switch renderStyle {
        case .standard:
            return displaySize
        case .chatTitle:
            return visualEnvelope
        }
    }

    private var accessibilityDescription: String {
        switch AgentIconContent.resolve(value) {
        case .symbol(let name):
            return IconSymbolCatalog.label(for: name) ?? "Symbol icon"
        case .text(let emoji):
            return "Emoji \(emoji)"
        case .genmoji(_, let contentDescription):
            return contentDescription
        case .fallback:
            return purpose.defaultAccessibilityDescription
        }
    }

    var body: some View {
        Group {
            if renderStyle == .chatTitle {
                renderedContent
                    .frame(width: layoutSize, height: layoutSize)
                    .clipped()
            } else {
                renderedContent
                    .frame(width: layoutSize, height: layoutSize)
                    .scaleEffect(visualScale)
            }
        }
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(isDecorative ? "" : accessibilityDescription)
        .task(id: IconAssetLoadKey(
            assetId: value?.assetId,
            cache: assetCache ?? environmentAssetCache
        )) {
            let cache = assetCache ?? environmentAssetCache
            let identity = IconAssetViewLoadIdentity(
                key: IconAssetLoadKey(assetId: value?.assetId, cache: cache),
                requestID: UUID()
            )
            activeLoadIdentity = identity
            guard case .genmoji(let assetId, _) = value,
                  let cache else {
                loadedGenmoji = nil
                return
            }
            await loadIconAssetForView(
                assetId: assetId,
                size: assetRenderSize * 2,
                cache: cache,
                identity: identity,
                currentIdentity: { activeLoadIdentity },
                assign: { loadedGenmoji = $0 }
            )
        }
    }

    private var renderedContent: some View {
        Group {
            switch AgentIconContent.resolve(value) {
            case .symbol(let name):
                if renderStyle == .chatTitle {
                    Image(systemName: name)
                        .resizable()
                        .scaledToFit()
                        .font(.system(size: contentFontSize, weight: .medium))
                        .frame(width: visualEnvelope, height: visualEnvelope)
                        .foregroundStyle(.themeBlue)
                } else {
                    Image(systemName: name)
                        .foregroundStyle(.themeBlue)
                }
            case .text(let text):
                Text(text)
            case .genmoji:
                if let loadedGenmoji {
                    Image(uiImage: loadedGenmoji)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: renderStyle == .chatTitle ? visualEnvelope : nil,
                            height: renderStyle == .chatTitle ? visualEnvelope : nil
                        )
                } else {
                    defaultIcon
                }
            case .fallback:
                defaultIcon
            }
        }
        .font(.system(size: contentFontSize))
    }

    @ViewBuilder
    private var defaultIcon: some View {
        if renderStyle == .chatTitle {
            Image(systemName: purpose.defaultSymbolName)
                .resizable()
                .scaledToFit()
                .frame(width: visualEnvelope, height: visualEnvelope)
                .foregroundStyle(.themeBlue)
        } else {
            Image(systemName: purpose.defaultSymbolName)
                .foregroundStyle(.themeBlue)
        }
    }
}

struct AgentIconView: View {
    let value: IconChoice?
    let size: CGFloat
    let frameSize: CGFloat?
    let isDecorative: Bool
    let assetCache: IconAssetCache?
    let visualScale: CGFloat
    let renderStyle: AgentIconRenderStyle

    init(
        value: IconChoice?,
        size: CGFloat,
        frameSize: CGFloat? = nil,
        isDecorative: Bool = true,
        assetCache: IconAssetCache? = nil,
        visualScale: CGFloat = 1,
        renderStyle: AgentIconRenderStyle = .standard
    ) {
        self.value = value
        self.size = size
        self.frameSize = frameSize
        self.isDecorative = isDecorative
        self.assetCache = assetCache
        self.visualScale = visualScale
        self.renderStyle = renderStyle
    }

    var body: some View {
        IconChoiceView(
            value: value,
            purpose: .agent,
            size: size,
            frameSize: frameSize,
            isDecorative: isDecorative,
            assetCache: assetCache,
            visualScale: visualScale,
            renderStyle: renderStyle
        )
    }
}

@MainActor
enum AgentIconRenderer {
    static func render(value: IconChoice?, size: CGFloat) -> UIImage {
        switch AgentIconContent.resolve(value) {
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.78, weight: .medium)
            return UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(UIColor(ThemeRuntimeState.currentPalette().blue), renderingMode: .alwaysOriginal)
                ?? fallback(size: size)
        case .text(let emoji):
            return renderText(emoji, size: size)
        case .genmoji, .fallback:
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
