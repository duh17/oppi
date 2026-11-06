import UIKit

/// Shared Pi-agent identity. Ordinary sessions and the pinned Pi agent always
/// paint the official mark from pi.dev; the user chooses color or monochrome.
enum PiAvatar {
    static let accessibilityLabel = "Pi"
}

/// Raster of the official Pi mark in the user's chosen style (`PiIconStyle`):
/// the fixed brand colors, or one color, the theme foreground. Either way the
/// mark is cropped to its own bounds and drawn centred, filling `size` less a
/// small optical inset.
@MainActor
enum PiAvatarRenderer {
    /// The mark spans 165.29...634.72 of the official 800-unit canvas.
    private static let markOrigin: CGFloat = 165.29
    private static let markExtent: CGFloat = 469.43
    private static let inset: CGFloat = 0.06

    /// Official geometry and colors from https://pi.dev/logo.svg.
    private static let parts: [(color: UIColor, path: UIBezierPath)] = [
        (
            UIColor(red: 0xF0 / 255, green: 0x90 / 255, blue: 0x82 / 255, alpha: 1),
            polygon([(165.29, 165.29), (517.36, 165.29), (517.36, 400), (400, 400), (400, 282.65), (165.29, 282.65)])
        ),
        (
            UIColor(red: 0x4D / 255, green: 0x9A / 255, blue: 0xBF / 255, alpha: 1),
            polygon([
                (165.29, 282.65), (282.65, 282.65), (282.65, 400), (400, 400), (400, 517.36),
                (282.65, 517.36), (282.65, 634.72), (165.29, 634.72),
            ])
        ),
        (
            UIColor(red: 0xF1 / 255, green: 0xBE / 255, blue: 0x58 / 255, alpha: 1),
            UIBezierPath(rect: CGRect(x: 517.36, y: 400, width: 117.36, height: 234.72))
        ),
    ]

    /// `style` and `themeID` default to the current preference and theme.
    static func render(size: CGFloat, style: PiIconStyle? = nil, themeID: ThemeID? = nil) -> UIImage {
        let style = style ?? AppPreferences.Appearance.piIconStyle
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let drawn = size * (1 - 2 * inset)
            let scale = drawn / markExtent
            let offset = size * inset
            context.cgContext.translateBy(x: offset, y: offset)
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -markOrigin, y: -markOrigin)

            switch style {
            case .color:
                for part in parts {
                    part.color.setFill()
                    part.path.fill()
                }
            case .monochrome:
                // One fill of the union, so the shared edges leave no seam.
                let union = UIBezierPath()
                for part in parts { union.append(part.path) }
                (themeID ?? ThemeRuntimeState.currentThemeID()).palette.ui.fg.setFill()
                union.fill()
            }
        }
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> UIBezierPath {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: point.0, y: point.1)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.close()
        return path
    }
}
