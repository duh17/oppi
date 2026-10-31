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

    /// A blue mark for a menu: a gated server's lock, or a destination's
    /// symbol. Entity artwork is `EntityIcon.image(_:size:)`; this is for the
    /// marks that are not an entity's own, in the same blue a menu's artwork
    /// carries (a menu draws a template image in its own gray).
    static func menuMark(
        _ symbolName: String,
        pointSize: CGFloat = 17,
        weight: UIImage.SymbolWeight = .medium
    ) -> UIImage? {
        UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        )?.withTintColor(ThemeRuntimeState.currentUIKitPalette().blue, renderingMode: .alwaysOriginal)
    }

    /// The entity's icon, drawn in a `size`-point frame. A sandbox workspace's
    /// mark sits in the frame's bottom-trailing corner and its icon takes
    /// `contentSize` (`size` when the caller wants the whole frame), because a
    /// row keeps its glyph size and the Guided pill steps it back for the mark.
    static func image(
        _ entity: IconEntity,
        size: CGFloat,
        contentSize: CGFloat? = nil,
        assets: IconAssetCache? = nil
    ) -> UIImage {
        let size = max(1, size)
        let content = max(1, contentSize ?? size)
        let key = cacheKey(entity, size: size, content: content, assets: assets)
        if let cached = rasters.object(forKey: key as NSString) {
            return cached
        }
        let drawn = draw(entity, frame: size, content: content, assets: assets)
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
        frame: CGFloat,
        content: CGFloat,
        assets: IconAssetCache?
    ) -> (image: UIImage, isFinal: Bool) {
        switch entity {
        case .pi:
            return (PiAvatarRenderer.render(size: frame), true)
        case .server(_, let badge):
            return (symbol(badge.symbolName, size: frame) ?? UIImage(), true)
        case .provider(let provider):
            return (providerMark(provider, size: frame), true)
        case .model(let model):
            return (providerMark(modelProviderKey(model) ?? model, size: frame), true)
        case .agent(let choice):
            return iconChoice(choice, fallback: fallbackSymbol(entity), box: content, assets: assets)
        case .workspace(let choice, let sandbox):
            guard sandbox else {
                return iconChoice(choice, fallback: fallbackSymbol(entity), box: content, assets: assets)
            }
            let glyph = iconChoice(choice, fallback: fallbackSymbol(entity), box: content, assets: assets)
            let image = raster(frame) { rect in
                drawCentred(glyph.image, in: rect)
                drawSandboxMark(in: rect)
            }
            return (image, glyph.isFinal)
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
            guard let assets, !assets.hasFailedLoad(assetId: assetId) else {
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
        let mark = sandboxMarkRect(inFrame: rect.width)
        colors.orange.setFill()
        UIBezierPath(ovalIn: mark).fill()
        colors.bg.setStroke()
        let ring = UIBezierPath(ovalIn: mark.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let lock = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: mark.width * 0.52, weight: .bold)
        )?.withTintColor(colors.bg, renderingMode: .alwaysOriginal)
        guard let lock else { return }
        lock.draw(at: CGPoint(x: mark.midX - lock.size.width / 2, y: mark.midY - lock.size.height / 2))
    }

    /// Where a sandbox workspace's mark draws in a frame: max(11, frame * 0.34)
    /// points against the bottom-trailing corner, the corner main let it overhang.
    /// A raster cannot draw past its bounds, so this is as far out as it reaches.
    static func sandboxMarkRect(inFrame frame: CGFloat) -> CGRect {
        let side = max(sandboxMarkMinimum, frame * sandboxMarkShare)
        return CGRect(x: frame - side, y: frame - side, width: side, height: side)
    }

    /// Where an icon's content draws in a frame: centred at the size its caller
    /// lays out, which a sandbox workspace never shrinks on its own.
    static func contentRect(inFrame frame: CGFloat, content: CGFloat) -> CGRect {
        CGRect(
            x: (frame - content) / 2,
            y: (frame - content) / 2,
            width: content,
            height: content
        )
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

    /// Centred at its own size, in the rect its caller's content box gives it.
    private static func drawCentred(_ content: UIImage, in rect: CGRect) {
        let box = contentRect(inFrame: rect.width, content: content.size.width)
        content.draw(at: CGPoint(x: box.midX - content.size.width / 2, y: box.midY - content.size.height / 2))
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

    private static func startLoad(assetId: String, size: CGFloat, assets: IconAssetCache) {
        // One load per asset, size, and cache: a replaced cache is a different
        // server's artwork, so it loads on its own.
        let request = "\(assetId):\(Int(size)):\(ObjectIdentifier(assets))"
        guard loadsInFlight.insert(request).inserted else { return }
        Task { @MainActor in
            defer { loadsInFlight.remove(request) }
            do {
                _ = try await assets.image(assetId: assetId, size: size)
            } catch {
                // The cache remembers the failure (and ignores a cancel), so its
                // fallback is final with nothing announced and nothing refetched.
                return
            }
            loadGeneration += 1
            NotificationCenter.default.post(name: .oppiEntityIconDidLoad, object: assetId)
        }
    }

    // MARK: - Cache key

    /// Keyed by the exact sizes asked for: a 15.38 pt box and a 16 pt box are
    /// different rasters, whichever caller runs first.
    private static func cacheKey(
        _ entity: IconEntity,
        size: CGFloat,
        content: CGFloat,
        assets: IconAssetCache?
    ) -> String {
        let cache = assets.map { "\(ObjectIdentifier($0))" } ?? "none"
        return "\(entity)|\(size)|\(content)|\(ThemeRuntimeState.currentThemeID().rawValue)|\(cache)"
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
