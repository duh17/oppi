import UIKit

/// What an icon stands for: an Agent, Pi, a workspace, a model provider, a model,
/// or a paired server. One owner draws them all, so a list row, a pill, a menu,
/// and the Usage mark show the same artwork for the same thing.
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
/// `image` draws now and never waits: a Genmoji comes from the server's icon cache
/// when it is decoded, and until then the fallback symbol draws and the load
/// starts. `.oppiEntityIconDidLoad` announces pixels that arrived, and
/// `loadGeneration` is the redraw key for a row that compares its inputs. A load
/// that fails leaves the fallback final for that cache: no redraw, no second
/// fetch. Every image is drawn always-original, so a `UIMenu` keeps its colors.
@MainActor
enum EntityIcon {
    /// An SF Symbol or emoji takes 0.78 of the box it is asked for.
    private static let glyphShare: CGFloat = 0.78
    /// A sandbox workspace's icon leaves the bottom-trailing corner to its mark.
    private static let sandboxContentShare: CGFloat = 0.75
    private static let sandboxMarkShare: CGFloat = 0.34
    private static let sandboxMarkMinimum: CGFloat = 11

    /// Bumped when artwork arrives. A row that compares its inputs puts it in the
    /// key, so the row that drew a fallback redraws with the Genmoji.
    private(set) static var loadGeneration = 0

    private static let rasters: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()
    private static var loadsInFlight: Set<String> = []
    /// Loads that failed, per asset and cache: the fallback is what that cache
    /// will ever draw.
    private static var failedLoads: Set<String> = []

    /// The entity's icon, in a box `size` points square.
    static func image(_ entity: IconEntity, size: CGFloat, assets: IconAssetCache? = nil) -> UIImage {
        let size = max(1, size)
        let key = cacheKey(entity, size: size, assets: assets)
        if let cached = rasters.object(forKey: key as NSString) {
            return cached
        }
        let drawn = draw(entity, size: size, assets: assets)
        // Baked, not template: a `UIMenu` draws a template image in its own gray.
        let image = drawn.image.withRenderingMode(.alwaysOriginal)
        // A drawing that may still become artwork is not kept, so the next pass
        // after `.oppiEntityIconDidLoad` draws the real icon.
        if drawn.isFinal {
            rasters.setObject(image, forKey: key as NSString)
        }
        return image
    }

    /// The box that draws a glyph `pointSize` tall, for a view that lays its icons
    /// out by the glyph rather than by the box.
    static func box(forGlyph pointSize: CGFloat) -> CGFloat {
        pointSize / glyphShare
    }

    // MARK: - Drawing

    private static func draw(
        _ entity: IconEntity,
        size: CGFloat,
        assets: IconAssetCache?
    ) -> (image: UIImage, isFinal: Bool) {
        switch entity {
        case .pi:
            return (PiAvatarRenderer.render(size: size), true)
        case .server(_, let badge):
            return (symbol(badge.symbolName, size: size) ?? UIImage(), true)
        case .provider(let provider):
            return (providerMark(provider, size: size), true)
        case .model(let model):
            return (providerMark(modelProviderKey(model) ?? model, size: size), true)
        case .agent(let choice):
            return iconChoice(choice, fallback: fallbackSymbol(entity), box: size, assets: assets)
        case .workspace(let choice, let sandbox):
            guard sandbox else {
                return iconChoice(choice, fallback: fallbackSymbol(entity), box: size, assets: assets)
            }
            let content = iconChoice(
                choice,
                fallback: fallbackSymbol(entity),
                box: size * sandboxContentShare,
                assets: assets
            )
            let image = raster(size) { rect in
                drawCentred(content.image, in: rect)
                drawSandboxMark(in: rect)
            }
            return (image, content.isFinal)
        }
    }

    private static func iconChoice(
        _ choice: IconChoice?,
        fallback: String,
        box: CGFloat,
        assets: IconAssetCache?
    ) -> (image: UIImage, isFinal: Bool) {
        switch AgentIconContent.resolve(choice) {
        case .symbol(let name):
            return (symbol(name, size: box) ?? symbol(fallback, size: box) ?? UIImage(), true)
        case .text(let emoji):
            return (centred(emoji, in: box, font: .systemFont(ofSize: box * glyphShare)), true)
        case .genmoji(let assetId, _):
            if let assets, let artwork = assets.cachedImage(assetId: assetId, size: artworkSize(box)) {
                let image = raster(box) { rect in
                    artwork.draw(in: aspectFit(artwork.size, in: rect))
                }
                return (image, true)
            }
            // No cache can load it, or this cache's load already failed: the
            // fallback is final.
            guard let assets, !failedLoads.contains(loadKey(assetId, assets)) else {
                return (symbol(fallback, size: box) ?? UIImage(), true)
            }
            startLoad(assetId: assetId, size: artworkSize(box), assets: assets)
            return (symbol(fallback, size: box) ?? UIImage(), false)
        case .fallback:
            return (symbol(fallback, size: box) ?? UIImage(), true)
        }
    }

    private static func fallbackSymbol(_ entity: IconEntity) -> String {
        switch entity {
        case .agent:
            return "person.crop.circle"
        case .pi:
            return "p.circle.fill"
        case .workspace:
            return "square.grid.2x2"
        case .provider, .model:
            return "cpu"
        case .server(_, let badge):
            return badge.symbolName
        }
    }

    private static func symbol(_ name: String, size: CGFloat) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: size * glyphShare, weight: .medium)
        )?.withTintColor(ThemeRuntimeState.currentUIKitPalette().blue, renderingMode: .alwaysOriginal)
    }

    /// A provider's logo in its brand color, or its monogram when it has no logo.
    private static func providerMark(_ provider: String, size: CGFloat) -> UIImage {
        let palette = ThemeRuntimeState.currentPalette()
        // `ProviderColor` owns the provider aliases (`openai-codex` reads as OpenAI).
        let tint = UIColor(providerIconTint(
            .init(uiColor: ProviderColor.color(forProvider: provider, palette: palette)),
            palette: palette
        ))
        if let assetName = providerLogoAssetName(provider), let logo = UIImage(named: assetName) {
            return raster(size) { rect in
                logo.withTintColor(tint, renderingMode: .alwaysOriginal)
                    .draw(in: aspectFit(logo.size, in: rect))
            }
        }
        return centred(
            providerMonogram(provider),
            in: size,
            font: .systemFont(ofSize: max(8, size * 0.8), weight: .heavy),
            color: tint
        )
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
        ring.lineWidth = 1
        ring.stroke()
        let lock = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.52, weight: .bold)
        )?.withTintColor(colors.bg, renderingMode: .alwaysOriginal)
        guard let lock else { return }
        lock.draw(at: CGPoint(x: mark.midX - lock.size.width / 2, y: mark.midY - lock.size.height / 2))
    }

    // MARK: - Rasterising

    /// A square raster `size` points across, drawn at the screen's own scale (never
    /// below 2×), so a menu that scales the image down keeps sharp pixels.
    private static func raster(_ size: CGFloat, draw: (CGRect) -> Void) -> UIImage {
        let side = max(1, size)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = max(2, format.scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in
                draw(CGRect(x: 0, y: 0, width: side, height: side))
            }
    }

    private static func centred(
        _ text: String,
        in size: CGFloat,
        font: UIFont,
        color: UIColor? = nil
    ) -> UIImage {
        raster(size) { rect in
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let color {
                attributes[.foregroundColor] = color
            }
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }

    /// Centred at its own size: a sandbox workspace's icon must not grow into the
    /// room its mark needs.
    private static func drawCentred(_ content: UIImage, in rect: CGRect) {
        content.draw(
            at: CGPoint(x: rect.midX - content.size.width / 2, y: rect.midY - content.size.height / 2)
        )
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

    /// The pixel size a Genmoji is decoded at for a `box`-point icon.
    private static func artworkSize(_ box: CGFloat) -> CGFloat {
        min(512, (box * max(2, UIGraphicsImageRendererFormat.preferred().scale)).rounded(.up))
    }

    // MARK: - Genmoji loads

    private static func loadKey(_ assetId: String, _ assets: IconAssetCache) -> String {
        "\(assetId):\(ObjectIdentifier(assets))"
    }

    private static func startLoad(assetId: String, size: CGFloat, assets: IconAssetCache) {
        // One load per asset, size, and cache: a replaced cache is a different
        // server's artwork, so it loads on its own.
        let request = "\(loadKey(assetId, assets)):\(Int(size))"
        guard loadsInFlight.insert(request).inserted else { return }
        Task { @MainActor in
            let loaded = try? await assets.image(assetId: assetId, size: size)
            loadsInFlight.remove(request)
            guard loaded != nil else {
                // Nothing announced, nothing refetched: this cache's fallback is
                // what the icon draws from now on.
                failedLoads.insert(loadKey(assetId, assets))
                return
            }
            loadGeneration += 1
            NotificationCenter.default.post(name: .oppiEntityIconDidLoad, object: assetId)
        }
    }

    // MARK: - Cache key

    private static func cacheKey(_ entity: IconEntity, size: CGFloat, assets: IconAssetCache?) -> String {
        let cache = assets.map { "\(ObjectIdentifier($0))" } ?? "none"
        return "\(entity)|\(Int(size.rounded(.up)))|\(ThemeRuntimeState.currentThemeID().rawValue)|\(cache)"
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
