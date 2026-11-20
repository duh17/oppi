import CoreGraphics
import Foundation

/// Shared Core Graphics geometry and fill helpers for Mermaid renderers:
/// node paths, polyline label anchors, label chips, and fill contrast.
/// Text measuring and drawing stay in `MermaidTextUtils`.
enum MermaidShapes {

    // MARK: - Paths

    static func hexagonPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    // MARK: - Edge labels

    /// Point at half the polyline's total arc length.
    static func arcMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? .zero }
        var total: CGFloat = 0
        for index in 0..<(points.count - 1) {
            total += hypot(
                points[index + 1].x - points[index].x,
                points[index + 1].y - points[index].y
            )
        }
        guard total > 0 else { return points[0] }
        var remaining = total / 2
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            let dy = points[index + 1].y - points[index].y
            let length = hypot(dx, dy)
            if length >= remaining {
                let t = length > 0 ? remaining / length : 0
                return CGPoint(
                    x: points[index].x + dx * t,
                    y: points[index].y + dy * t
                )
            }
            remaining -= length
        }
        return points[points.count - 1]
    }

    /// Edge label centered on `center` over a background-filled chip, so the
    /// line it sits on does not run through the text.
    static func drawLabelChip(
        _ label: MermaidPreparedText,
        centeredAt center: CGPoint,
        padding: CGFloat,
        theme: RenderTheme,
        in ctx: CGContext
    ) {
        let textSize = label.size
        let background = CGRect(
            x: center.x - textSize.width / 2 - padding,
            y: center.y - textSize.height / 2 - padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        ctx.saveGState()
        ctx.setFillColor(theme.background)
        ctx.fill(background)
        ctx.restoreGState()
        label.draw(centeredIn: background, in: ctx)
    }

    // MARK: - Fill contrast

    /// The most readable of theme foreground / background / backgroundDark
    /// against `fill`, so labels on colored fills stay visible in light and dark.
    static func contrastingTextColor(on fill: CGColor, theme: RenderTheme) -> CGColor {
        let candidates = [theme.foreground, theme.background, theme.backgroundDark]
        return candidates.max { lhs, rhs in
            contrastRatio(foreground: lhs, background: fill)
                < contrastRatio(foreground: rhs, background: fill)
        } ?? theme.foreground
    }

    /// WCAG contrast ratio; 1 when either color has no sRGB components.
    static func contrastRatio(foreground: CGColor, background: CGColor) -> CGFloat {
        guard let fg = sRGBComponents(foreground), let bg = sRGBComponents(background) else {
            return 1
        }
        let fgLuminance = relativeLuminance(red: fg.red, green: fg.green, blue: fg.blue)
        let bgLuminance = relativeLuminance(red: bg.red, green: bg.green, blue: bg.blue)
        let lighter = max(fgLuminance, bgLuminance)
        let darker = min(fgLuminance, bgLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    struct SRGBComponents {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    static func sRGBComponents(_ color: CGColor) -> SRGBComponents? {
        let converted = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? color
        guard let components = converted.components else { return nil }
        if components.count >= 3 {
            return SRGBComponents(red: components[0], green: components[1], blue: components[2])
        }
        if components.count >= 1 {
            return SRGBComponents(red: components[0], green: components[0], blue: components[0])
        }
        return nil
    }
}
