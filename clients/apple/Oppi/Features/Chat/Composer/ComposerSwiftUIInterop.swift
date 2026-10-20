import UIKit

// What the UIKit composer takes from the SwiftUI theme types: the palette's
// colors and provider icon tints.

@MainActor
enum ComposerProviderIconRenderer {
    static func image(provider: String, size: CGFloat, colors: ComposerThemeColors) -> UIImage {
        let tint = UIColor(providerIconTint(
            ProviderIcon.brandColor(for: provider),
            palette: ThemeRuntimeState.currentPalette()
        ))
        if let assetName = ProviderIcon.logoAssetName(for: provider),
           let asset = UIImage(named: assetName) {
            return asset.withTintColor(tint, renderingMode: .alwaysOriginal)
        }
        let mark = ProviderIcon.mark(for: provider) as NSString
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(8, size * 0.8), weight: .heavy),
                .foregroundColor: tint,
            ]
            let textSize = mark.size(withAttributes: attributes)
            mark.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}


extension ComposerThemeColors {
    init(palette: ThemePalette) {
        let elevated = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        let floating = ThemeSurfaceStyle.resolve(.floatingControl, palette: palette)
        self.init(
            bg: UIColor(palette.bg),
            bgDark: UIColor(palette.bgDark),
            bgHighlight: UIColor(palette.bgHighlight),
            fg: UIColor(palette.fg),
            fgDim: UIColor(palette.fgDim),
            comment: UIColor(palette.comment),
            blue: UIColor(palette.blue),
            cyan: UIColor(palette.cyan),
            green: UIColor(palette.green),
            orange: UIColor(palette.orange),
            purple: UIColor(palette.purple),
            red: UIColor(palette.red),
            yellow: UIColor(palette.yellow),
            scrim: UIColor(palette.bgDark.opacity(0.82)),
            elevatedStroke: UIColor(elevated.stroke ?? palette.fg.opacity(0.12)),
            floatingFill: UIColor(floating.fill)
        )
    }
}
