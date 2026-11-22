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

/// The shape an icon draws in: the rounded square every row, pill, and menu
/// shows, or the circle an Agent's own page shows its icon as.
enum IconShape: Hashable, Sendable {
    case tile
    case circle
}

/// The one owner of entity artwork.
///
/// An Agent, Pi, or workspace icon sits in one tile: a rounded square (or, on its
/// own page, a circle) in the theme's tint that fills the frame it is asked for,
/// with a symbol, an emoji, a Genmoji, or the Pi mark centred on it and an
/// imported image filling it edge to edge. A circle draws that content a little
/// smaller than a tile, lights its fill from the top, and rings its edge with a
/// hairline. Every kind has the same shape and size in a given place, and the tint
/// follows the theme (the raster cache keys on it and on the shape).
///
/// `image` draws now and never waits: a Genmoji or an imported image (its first
/// frame) comes from the server's icon cache
/// when it is decoded, and until then the fallback symbol draws and the load
/// starts. `.oppiEntityIconDidLoad` announces pixels that arrived, and
/// `loadGeneration` is the redraw key for a row that compares its inputs. A load
/// that fails leaves the fallback final for that cache: no redraw, no second
/// fetch. Every image is drawn always-original, so a `UIMenu` keeps its colors.
@MainActor
enum EntityIcon {
    /// A provider's or server's symbol takes 0.78 of the box it is asked for.
    private static let glyphShare: CGFloat = 0.78
    /// On a tile, a symbol's point size, an emoji's font size, and a Genmoji's
    /// or the Pi mark's box, as shares of the tile's side.
    private static let tileSymbolShare: CGFloat = 0.5
    private static let tileEmojiShare: CGFloat = 0.6
    private static let tileArtworkShare: CGFloat = 0.72
    private static let tileCornerShare: CGFloat = 0.26
    private static let sandboxMarkShare: CGFloat = 0.34
    private static let sandboxMarkMinimum: CGFloat = 11

    /// A circle's own drawing, in one place so every circle (a session row at
    /// any of its sizes, a chat's title, an Agent's page, an empty chat) matches:
    /// its content steps in from a tile's share, its fill is lit from the top,
    /// and a hairline ring marks the edge against the background.
    private struct CircleStyle {
        /// What a circle keeps of a tile's symbol, emoji, and mark shares: a round
        /// edge reads tighter than a square's at the same size. On a 56 pt circle
        /// the Pi mark then covers about 57% of the diameter (a tile draws it at
        /// 65%), a symbol 50%, and an emoji 54%.
        let contentScale: CGFloat
        /// The fill's tint at its top and bottom (the tile's blue alpha, lit).
        let tintTop: CGFloat
        let tintBottom: CGFloat
        /// The ring's alpha on the theme's foreground: a hairline, never a hard line.
        let ringAlpha: CGFloat
        /// A soft sheen just inside the ring's top edge, so the circle has depth.
        let highlightAlpha: CGFloat
        /// The ring's width in points, thin enough to read as a hairline at 2x.
        let ringWidth: CGFloat

        static let standard = Self(
            contentScale: 0.88,
            tintTop: 0.24,
            tintBottom: 0.10,
            ringAlpha: 0.21,
            highlightAlpha: 0.05,
            ringWidth: 0.5
        )
    }

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
        assets: IconAssetCache? = nil,
        shape: IconShape = .tile
    ) -> UIImage {
        let size = max(1, size)
        let content = max(1, contentSize ?? size)
        let key = cacheKey(entity, size: size, content: content, assets: assets, shape: shape)
        if let cached = rasters.object(forKey: key as NSString) {
            return cached
        }
        let drawn = draw(entity, frame: size, content: content, assets: assets, shape: shape)
        // Baked, not template: a `UIMenu` draws a template image in its own gray.
        let image = drawn.image.withRenderingMode(.alwaysOriginal)
        // A drawing that may still become artwork is not kept, so the next pass
        // after `.oppiEntityIconDidLoad` draws the real icon.
        if drawn.isFinal {
            rasters.setObject(image, forKey: key as NSString)
        }
        return image
    }

    // MARK: - Tile

    /// The tile's corner radius for a `side`-point tile (continuous corners).
    static func tileCornerRadius(_ side: CGFloat) -> CGFloat {
        side * tileCornerShare
    }

    /// What a `side`-point icon is clipped to in `shape`: the tile's continuous
    /// corners, or a full circle.
    static func cornerRadius(_ side: CGFloat, shape: IconShape) -> CGFloat {
        switch shape {
        case .tile: tileCornerRadius(side)
        case .circle: side / 2
        }
    }

    /// The tile's colour: the theme's blue, translucent, so it reads on a card,
    /// a page, a pill, and a menu alike.
    static func tileColor(_ palette: ThemeUIKitPalette = ThemeRuntimeState.currentUIKitPalette()) -> UIColor {
        palette.blue.withAlphaComponent(0.16)
    }

    /// A symbol in the tile's tint, at the size the tile draws it, for a view
    /// that plays the symbol's effect over `tile(side:)`.
    static func tileSymbol(_ name: String, side: CGFloat, shape: IconShape = .tile) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * share(tileSymbolShare, shape: shape), weight: .medium)
        )?.withTintColor(ThemeRuntimeState.currentUIKitPalette().blue, renderingMode: .alwaysOriginal)
    }

    /// A kind's share of the box it draws in: the tile's, or the circle's
    /// narrower one.
    private static func share(_ tileShare: CGFloat, shape: IconShape) -> CGFloat {
        shape == .circle ? tileShare * CircleStyle.standard.contentScale : tileShare
    }

    /// The empty tile, for a view that draws live content over it.
    static func tile(side: CGFloat, shape: IconShape = .tile) -> UIImage {
        raster(side) { rect in fillTile(rect, shape: shape) }
    }

    /// An image on the tile, filling it edge to edge: an imported picture before
    /// it is stored, drawn like a stored one.
    static func tile(side: CGFloat, filledWith artwork: UIImage, shape: IconShape = .tile) -> UIImage {
        raster(side) { rect in drawFilling(artwork, in: rect, shape: shape) }
    }

    private static func tilePath(_ rect: CGRect, shape: IconShape) -> UIBezierPath {
        switch shape {
        case .tile: UIBezierPath(roundedRect: rect, cornerRadius: tileCornerRadius(rect.width))
        case .circle: UIBezierPath(ovalIn: rect)
        }
    }

    private static func fillTile(_ rect: CGRect, shape: IconShape) {
        let palette = ThemeRuntimeState.currentUIKitPalette()
        switch shape {
        case .tile:
            tileColor(palette).setFill()
            tilePath(rect, shape: shape).fill()
        case .circle:
            fillCircle(rect, palette: palette)
        }
    }

    /// A circle's fill: the tile's tint, lit from the top, with a soft sheen
    /// inside its top edge and a hairline ring on its edge, so it reads as a lit
    /// disc on the page instead of a flat wash that the content runs into.
    private static func fillCircle(_ rect: CGRect, palette: ThemeUIKitPalette) {
        let style = CircleStyle.standard
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        tilePath(rect, shape: .circle).addClip()
        let tint: [CGColor] = [
            palette.blue.withAlphaComponent(style.tintTop).cgColor,
            palette.blue.withAlphaComponent(style.tintBottom).cgColor,
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: tint as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        }
        let sheen: [CGColor] = [
            palette.fg.withAlphaComponent(style.highlightAlpha).cgColor,
            palette.fg.withAlphaComponent(0).cgColor,
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.45),
                options: []
            )
        }
        context.restoreGState()
        circleRing(rect, palette: palette).stroke()
    }

    /// The circle's hairline edge, inset by half its width so the stroke stays
    /// inside the frame it is drawn in.
    private static func circleRing(_ rect: CGRect, palette: ThemeUIKitPalette) -> UIBezierPath {
        let width = CircleStyle.standard.ringWidth
        let path = UIBezierPath(ovalIn: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        palette.fg.withAlphaComponent(CircleStyle.standard.ringAlpha).setStroke()
        return path
    }

    /// A circle's hairline edge alone, in a clear square: an icon that plays an
    /// image over its drawn circle keeps the same edge.
    static func circleRing(side: CGFloat) -> UIImage {
        raster(side) { rect in
            circleRing(rect, palette: ThemeRuntimeState.currentUIKitPalette()).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The tile, then `artwork` aspect-filled and clipped to it, so a
    /// transparent image keeps the tile behind it.
    private static func drawFilling(_ artwork: UIImage, in rect: CGRect, shape: IconShape) {
        fillTile(rect, shape: shape)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        tilePath(rect, shape: shape).addClip()
        artwork.draw(in: aspectFill(artwork.size, in: rect))
        context.restoreGState()
    }

    /// The tile with `content` centred on it.
    private static func tiled(_ side: CGFloat, shape: IconShape, content: (CGRect) -> Void) -> UIImage {
        raster(side) { rect in
            fillTile(rect, shape: shape)
            content(rect)
        }
    }

    private static func tiledSymbol(_ name: String, side: CGFloat, shape: IconShape) -> UIImage? {
        guard let symbol = tileSymbol(name, side: side, shape: shape) else { return nil }
        return tiled(side, shape: shape) { rect in drawCentred(symbol, in: rect) }
    }

    // MARK: - Drawing

    private static func draw(
        _ entity: IconEntity,
        frame: CGFloat,
        content: CGFloat,
        assets: IconAssetCache?,
        shape: IconShape
    ) -> (image: UIImage, isFinal: Bool) {
        switch entity {
        case .pi:
            let mark = PiAvatarRenderer.render(size: frame * share(tileArtworkShare, shape: shape))
            return (tiled(frame, shape: shape) { rect in drawCentred(mark, in: rect) }, true)
        case .server(_, let badge):
            return (symbol(badge.symbolName, size: frame) ?? UIImage(), true)
        case .provider(let provider):
            return (providerMark(provider, size: frame), true)
        case .model(let model):
            return (providerMark(modelProviderKey(model) ?? model, size: frame), true)
        case .agent(let choice):
            return iconChoice(choice, fallback: fallbackSymbol(entity), box: content, assets: assets, shape: shape)
        case .workspace(let choice, let sandbox):
            guard sandbox else {
                return iconChoice(choice, fallback: fallbackSymbol(entity), box: content, assets: assets, shape: shape)
            }
            let glyph = iconChoice(choice, fallback: fallbackSymbol(entity), box: content, assets: assets, shape: shape)
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
        assets: IconAssetCache?,
        shape: IconShape
    ) -> (image: UIImage, isFinal: Bool) {
        let fallbackTile = tiledSymbol(fallback, side: box, shape: shape) ?? tile(side: box, shape: shape)
        switch AgentIconContent.resolve(choice) {
        case .symbol(let name):
            // A symbol's effect plays only in `IconChoiceUIView`, which animates or bursts it.
            return (tiledSymbol(name, side: box, shape: shape) ?? fallbackTile, true)
        case .text(let emoji):
            let font = UIFont.systemFont(ofSize: box * share(tileEmojiShare, shape: shape))
            return (tiled(box, shape: shape) { rect in drawCentred(emoji, font: font, in: rect) }, true)
        case .genmoji(let assetId, _), .image(let assetId):
            // An animated image draws its first frame here; only
            // `IconChoiceUIView` plays it, when it animates or bursts.
            if let assets, let artwork = assets.cachedImage(assetId: assetId, size: artworkSize(box)) {
                let image = raster(box) { rect in
                    if case .image = choice {
                        drawFilling(artwork, in: rect, shape: shape)
                    } else {
                        fillTile(rect, shape: shape)
                        let inner = contentRect(
                            inFrame: rect.width,
                            content: rect.width * share(tileArtworkShare, shape: shape)
                        )
                        artwork.draw(in: aspectFit(artwork.size, in: inner))
                    }
                }
                return (image, true)
            }
            // No cache can load it, or this cache's load already failed: the
            // fallback is final.
            guard let assets, !assets.hasFailedLoad(assetId: assetId) else {
                return (fallbackTile, true)
            }
            startLoad(assetId: assetId, size: artworkSize(box), assets: assets)
            return (fallbackTile, false)
        case .fallback:
            return (fallbackTile, true)
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
        let tint = providerIconTint(
            ProviderColor.color(forProvider: provider, palette: palette),
            palette: palette
        )
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

    /// A sandbox workspace's mark alone, in a clear `frame`-point square, for a
    /// view that lays it over a playing icon.
    static func sandboxMark(frame: CGFloat) -> UIImage {
        raster(frame) { rect in drawSandboxMark(in: rect) }.withRenderingMode(.alwaysOriginal)
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
        raster(size) { rect in drawCentred(text, font: font, color: color, in: rect) }
    }

    private static func drawCentred(_ text: String, font: UIFont, color: UIColor? = nil, in rect: CGRect) {
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

    private static func aspectFill(_ content: CGSize, in rect: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return rect }
        let scale = max(rect.width / content.width, rect.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The pixel size a Genmoji or image is decoded at for a `box`-point icon.
    private static func artworkSize(_ box: CGFloat) -> CGFloat {
        min(512, (box * max(2, UIGraphicsImageRendererFormat.preferred().scale)).rounded(.up))
    }

    // MARK: - Artwork loads

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
        assets: IconAssetCache?,
        shape: IconShape
    ) -> String {
        let cache = assets.map { "\(ObjectIdentifier($0))" } ?? "none"
        return "\(entity)|\(size)|\(content)|\(shape)|\(ThemeRuntimeState.currentThemeID().rawValue)|\(cache)|\(AppPreferences.Appearance.piIconStyle.rawValue)"
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
            identifier: id.map { Self.Identifier($0) },
            state: selected ? .on : .off
        ) { _ in handler() }
    }
}
