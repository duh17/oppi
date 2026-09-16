import SwiftUI
import UIKit

/// Shared Pi-agent identity. Ordinary sessions and the pinned Pi agent always
/// paint the official mark from pi.dev; there is no user-selectable substitute.
enum PiAvatar {
    static let accessibilityLabel = "Pi"
}

/// Raster of the official Pi mark, filled with the current theme foreground.
@MainActor
enum PiAvatarRenderer {
    static func render(size: CGFloat, themeID: ThemeID? = nil) -> UIImage {
        let palette = (themeID ?? ThemeRuntimeState.currentThemeID()).palette
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let canvasScale = size / 800
            context.cgContext.scaleBy(x: canvasScale, y: canvasScale)
            UIColor(palette.fg).setFill()

            // Official mark geometry from https://pi.dev/logo-auto.svg.
            let pMark = UIBezierPath()
            pMark.move(to: CGPoint(x: 165.29, y: 165.29))
            pMark.addLine(to: CGPoint(x: 517.36, y: 165.29))
            pMark.addLine(to: CGPoint(x: 517.36, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 517.36))
            pMark.addLine(to: CGPoint(x: 282.65, y: 517.36))
            pMark.addLine(to: CGPoint(x: 282.65, y: 634.72))
            pMark.addLine(to: CGPoint(x: 165.29, y: 634.72))
            pMark.close()
            pMark.move(to: CGPoint(x: 282.65, y: 282.65))
            pMark.addLine(to: CGPoint(x: 282.65, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 282.65))
            pMark.close()
            pMark.usesEvenOddFillRule = true
            pMark.fill()

            UIBezierPath(rect: CGRect(x: 517.36, y: 400, width: 117.36, height: 234.72)).fill()
        }
    }
}

struct PiAvatarView: View {
    var size: CGFloat = 28

    @Environment(\.themeID) private var themeID

    var body: some View {
        Image(
            uiImage: PiAvatarRenderer.render(
                size: size * 2,
                themeID: themeID
            )
        )
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size, height: size)
        .background(
            .themeComment.opacity(0.10),
            in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        )
        .accessibilityHidden(true)
    }
}
