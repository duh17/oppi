import UIKit

/// What an icon stands for: an Agent, Pi, a workspace, a model provider, a model,
/// or a paired server. The app has one set of entities and one owner that draws
/// them (`EntityIcon`), so a list row, a pill, a menu, and the Usage mark show
/// the same artwork for the same thing.
enum IconEntity: Hashable {
    case agent(IconChoice?)
    case pi
    case workspace(IconChoice?, sandbox: Bool)
    case provider(String)
    case model(String)
    case server(PairedServer.ID, ServerBadgeIcon)
}

extension Notification.Name {
    /// Artwork finished loading, so anything that drew `EntityIcon`'s fallback
    /// symbol can draw the real icon now.
    static let oppiEntityIconDidLoad = Notification.Name("\(AppIdentifiers.subsystem).oppiEntityIconDidLoad")
}

/// The one owner of entity artwork.
///
/// `image` draws now and never waits: an Agent's or workspace's Genmoji comes
/// from the server's icon cache when it is decoded, and until then the entity's
/// fallback symbol draws and the load starts (`.oppiEntityIconDidLoad` announces
/// the pixels; `loadGeneration` is the redraw key for a row that compares its
/// inputs). Every image is drawn always-original — a symbol's own tint survives
/// a `UIMenu`, which templates gray — and every entity's fallback symbol, emoji
/// raster, Genmoji lookup, provider mark, and sandbox mark exists only here.
@MainActor
enum EntityIcon {
    /// An SF Symbol or emoji takes 0.78 of the box it is asked for: the size a
    /// pill, row, or menu slot was laid out with is the room, not the glyph.
    private static let glyphShare: CGFloat = 0.78
    /// A sandbox workspace's icon leaves the bottom-trailing corner to its mark.
    private static let sandboxContentShare: CGFloat = 0.75
    private static let sandboxMarkShare: CGFloat = 0.34
    private static let sandboxMarkMinimum: CGFloat = 9
    /// Emoji, Genmoji, and provider letters raster at twice the points asked for,
    /// because a menu scales an action image down and keeps the pixels sharp.
    private static let supersample: CGFloat = 2

    /// Bumped when artwork arrives. A row that compares its inputs puts it in the
    /// key, so the row that drew a fallback redraws with the Genmoji.
    private(set) static var loadGeneration = 0

    private static let rasters = NSCache<NSString, UIImage>()
    private static var loadsInFlight: Set<String> = []

    /// The entity's icon, in a box `size` points square.
    static func image(_ entity: IconEntity, size: CGFloat, assets: IconAssetCache? = nil) -> UIImage {
        let size = max(1, size)
        // An entity still waiting for its Genmoji is never cached: the fallback it
        // draws now is replaced the moment the artwork arrives.
        let key = waitsForArtwork(entity, size: size, assets: assets) ? nil : cacheKey(entity, size: size)
        if let key, let cached = rasters.object(forKey: key as NSString) {
            return cached
        }
        // Baked, not template: a `UIMenu` draws a template image in its own gray,
        // so every entity keeps the colors drawn here.
        let image = draw(entity, size: size, assets: assets).withRenderingMode(.alwaysOriginal)
        if let key {
            rasters.setObject(image, forKey: key as NSString)
        }
        return image
    }

    /// The symbol an entity falls back to when it has no artwork of its own, and
    /// the SF Symbol a menu shows for it when it has room for no other image.
    static func fallbackSymbol(_ entity: IconEntity) -> String {
        switch entity {
        case .agent:
            return "person.crop.circle"
        // Pi always draws its avatar from `PiAvatarRenderer`, so this symbol is a
        // stand-in for a caller that can only name one, never a drawing.
        case .pi:
            return "p.circle.fill"
        case .workspace:
            return "square.grid.2x2"
        // A provider draws its logo or its monogram; the mark is a symbol only
        // where something needs an SF Symbol name.
        case .provider, .model:
            return "cpu"
        case .server(_, let badge):
            return badge.symbolName
        }
    }

    // MARK: - Drawing

    private static func draw(_ entity: IconEntity, size: CGFloat, assets: IconAssetCache?) -> UIImage {
        switch entity {
        case .pi:
            return PiAvatarRenderer.render(size: size)
        case .server(_, let badge):
            return symbol(badge.symbolName, size: size, color: ThemeRuntimeState.currentUIKitPalette().blue)
                ?? UIImage()
        case .provider(let provider):
            return providerMark(provider, size: size)
        case .model(let model):
            return providerMark(modelProviderKey(model) ?? model, size: size)
        case .agent(let choice):
            return iconChoice(choice, fallback: fallbackSymbol(entity), size: size, assets: assets)
        case .workspace(let choice, let sandbox):
            guard sandbox else {
                return iconChoice(choice, fallback: fallbackSymbol(entity), size: size, assets: assets)
            }
            let content = iconChoice(
                choice,
                fallback: fallbackSymbol(entity),
                size: size * sandboxContentShare,
                assets: assets
            )
            return supersampled(size) { rect in
                content.draw(in: aspectFit(content.size, in: rect))
                drawSandboxMark(in: rect)
            }
        }
    }

    private static func iconChoice(
        _ choice: IconChoice?,
        fallback: String,
        size: CGFloat,
        assets: IconAssetCache?
    ) -> UIImage {
        let blue = ThemeRuntimeState.currentUIKitPalette().blue
        switch AgentIconContent.resolve(choice) {
        case .symbol(let name):
            return symbol(name, size: size, color: blue)
                ?? symbol(fallback, size: size, color: blue)
                ?? UIImage()
        case .text(let text):
            return emoji(text, size: size)
        case .genmoji(let assetId, _):
            if let assets, let artwork = assets.cachedImage(assetId: assetId, size: renderSize(size)) {
                return supersampled(size) { rect in
                    artwork.draw(in: aspectFit(artwork.size, in: rect))
                }
            }
            if let assets {
                startLoad(assetId: assetId, size: renderSize(size), assets: assets)
            }
            return symbol(fallback, size: size, color: blue) ?? UIImage()
        case .fallback:
            return symbol(fallback, size: size, color: blue) ?? UIImage()
        }
    }

    private static func symbol(_ name: String, size: CGFloat, color: UIColor) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: size * glyphShare, weight: .medium)
        )?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private static func emoji(_ text: String, size: CGFloat) -> UIImage {
        supersampled(size) { rect in
            let font = UIFont.systemFont(ofSize: rect.width * glyphShare)
            let string = text as NSString
            let textSize = string.size(withAttributes: [.font: font])
            string.draw(
                at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: [.font: font]
            )
        }
    }

    /// A provider's logo in its brand color, or its monogram when it has no logo.
    private static func providerMark(_ provider: String, size: CGFloat) -> UIImage {
        let palette = ThemeRuntimeState.currentPalette()
        // `ProviderColor` owns the provider aliases (`openai-codex` reads as OpenAI).
        let brand = ProviderColor.color(forProvider: provider, palette: palette)
        let tint = UIColor(providerIconTint(.init(uiColor: brand), palette: palette))
        if let assetName = providerLogoAssetName(provider), let logo = UIImage(named: assetName) {
            return supersampled(size) { rect in
                logo.withTintColor(tint, renderingMode: .alwaysOriginal)
                    .draw(in: aspectFit(logo.size, in: rect))
            }
        }
        let monogram = providerMonogram(provider) as NSString
        return supersampled(size) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(8, size * 0.8) * supersample, weight: .heavy),
                .foregroundColor: tint,
            ]
            let textSize = monogram.size(withAttributes: attributes)
            monogram.draw(
                at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }

    private static func drawSandboxMark(in rect: CGRect) {
        let colors = ThemeRuntimeState.currentUIKitPalette()
        let side = max(sandboxMarkMinimum, rect.width * sandboxMarkShare)
        let mark = CGRect(
            x: rect.maxX - side - rect.width * 0.02,
            y: rect.maxY - side - rect.width * 0.02,
            width: side,
            height: side
        )
        colors.orange.setFill()
        UIBezierPath(ovalIn: mark).fill()
        colors.bg.setStroke()
        let ring = UIBezierPath(ovalIn: mark.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = supersample
        ring.stroke()
        let lock = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.52, weight: .bold)
        )?.withTintColor(colors.bg, renderingMode: .alwaysOriginal)
        guard let lock else { return }
        lock.draw(at: CGPoint(x: mark.midX - lock.size.width / 2, y: mark.midY - lock.size.height / 2))
    }

    /// Pixels at `supersample`× the points asked for, in a square canvas of
    /// `size` points, so the image draws at the size the caller laid out.
    private static func supersampled(_ size: CGFloat, draw: (CGRect) -> Void) -> UIImage {
        let canvas = renderSize(size)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: canvas, height: canvas),
            format: format
        ).image { _ in
            draw(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        }
        guard let cgImage = rendered.cgImage else { return rendered }
        return UIImage(cgImage: cgImage, scale: supersample, orientation: .up)
    }

    private static func aspectFit(_ content: CGSize, in rect: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return rect }
        let scale = min(rect.width / content.width, rect.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func renderSize(_ size: CGFloat) -> CGFloat {
        (size * supersample).rounded(.up)
    }

    // MARK: - Genmoji loads

    private static func startLoad(assetId: String, size: CGFloat, assets: IconAssetCache) {
        // One load per asset, size, and cache: a replaced cache is a different
        // server's artwork, so it loads on its own.
        let request = "\(assetId):\(Int(size)):\(ObjectIdentifier(assets))"
        guard loadsInFlight.insert(request).inserted else { return }
        Task { @MainActor in
            _ = try? await assets.image(assetId: assetId, size: size)
            loadsInFlight.remove(request)
            // Every raster may hold the fallback this load replaces, so they all
            // go; loads are rare and the cache refills on the next pass.
            rasters.removeAllObjects()
            loadGeneration += 1
            NotificationCenter.default.post(name: .oppiEntityIconDidLoad, object: assetId)
        }
    }

    // MARK: - Cache keys

    private static func waitsForArtwork(_ entity: IconEntity, size: CGFloat, assets: IconAssetCache?) -> Bool {
        let choice: IconChoice?
        let contentSize: CGFloat
        switch entity {
        case .agent(let value):
            choice = value
            contentSize = size
        case .workspace(let value, let sandbox):
            choice = value
            contentSize = sandbox ? size * sandboxContentShare : size
        case .pi, .provider, .model, .server:
            return false
        }
        guard case .genmoji(let assetId, _) = choice ?? .defaultValue else { return false }
        guard let assets else { return true }
        return assets.cachedImage(assetId: assetId, size: renderSize(contentSize)) == nil
    }

    private static func cacheKey(_ entity: IconEntity, size: CGFloat) -> String {
        "\(entityKey(entity))|\(Int(size.rounded(.up)))|\(ThemeRuntimeState.currentThemeID().rawValue)"
    }

    private static func entityKey(_ entity: IconEntity) -> String {
        switch entity {
        case .agent(let choice):
            return "agent:\(choiceKey(choice))"
        case .pi:
            return "pi"
        case .workspace(let choice, let sandbox):
            return "workspace:\(choiceKey(choice)):\(sandbox)"
        case .provider(let provider):
            return "provider:\(provider)"
        case .model(let model):
            return "model:\(model)"
        case .server(let id, let badge):
            return "server:\(id):\(badge.id)"
        }
    }

    private static func choiceKey(_ choice: IconChoice?) -> String {
        switch choice ?? .defaultValue {
        case .defaultValue:
            return "default"
        case .emoji(let emoji):
            return "emoji:\(emoji)"
        case .symbol(let name):
            return "symbol:\(name)"
        case .genmoji(let assetId, _):
            return "genmoji:\(assetId)"
        }
    }
}

extension UIAction {
    /// A menu row that chooses `entity`: its artwork, and the menu's own
    /// checkmark through `state`, so the selected row keeps its icon.
    static func choice(
        _ title: String,
        _ entity: IconEntity,
        selected: Bool,
        assets: IconAssetCache?,
        id: String? = nil,
        _ handler: @escaping () -> Void
    ) -> UIAction {
        UIAction(
            title: title,
            image: EntityIcon.image(entity, size: 22, assets: assets),
            identifier: id.map { UIAction.Identifier($0) },
            state: selected ? .on : .off
        ) { _ in handler() }
    }
}
