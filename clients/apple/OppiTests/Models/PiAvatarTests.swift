import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("PiAvatar")
@MainActor
struct PiAvatarTests {
    @Test("ordinary session identity is labeled Pi")
    func ordinarySessionIdentityIsLabeledPi() {
        let view = SessionGridBadgeView()
        view.configure(
            sessionId: "mounted-row",
            agentId: nil,
            agentIcon: nil,
            iconAssetCache: nil
        )
        #expect(view.accessibilityLabel == "Pi")
        #expect(PiAvatar.accessibilityLabel == "Pi")
    }

    @Test("renderer fills its box with the mark and keeps the counter open")
    func rendererFillsBoxAndKeepsCounterOpen() throws {
        let image = PiAvatarRenderer.render(size: 800)

        let corner = try #require(pixel(in: image, normalizedX: 0.10, normalizedY: 0.10))
        let counter = try #require(pixel(in: image, normalizedX: 0.40, normalizedY: 0.40))
        let dot = try #require(pixel(in: image, normalizedX: 0.90, normalizedY: 0.90))
        let margin = try #require(pixel(in: image, normalizedX: 0.90, normalizedY: 0.10))

        #expect(corner.alpha > 0.9)
        #expect(counter.alpha < 0.01)
        #expect(dot.alpha > 0.9)
        #expect(margin.alpha < 0.01)
    }

    @Test("monochrome paints only the theme foreground; color paints several hues")
    func monochromeIsThemeForegroundAndColorIsNot() throws {
        let themeID = ThemeID.dark
        var fg: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        themeID.palette.ui.fg.getRed(&fg.0, green: &fg.1, blue: &fg.2, alpha: &fg.3)

        // Interior of each of the three brand-colored parts.
        let points: [(CGFloat, CGFloat)] = [(0.30, 0.12), (0.20, 0.90), (0.90, 0.90)]

        let mono = PiAvatarRenderer.render(size: 400, style: .monochrome, themeID: themeID)
        for (x, y) in points {
            let p = try #require(pixel(in: mono, normalizedX: x, normalizedY: y))
            #expect(p.alpha > 0.99)
            #expect(abs(p.red - fg.0) < 0.02 && abs(p.green - fg.1) < 0.02 && abs(p.blue - fg.2) < 0.02)
        }

        let color = PiAvatarRenderer.render(size: 400, style: .color, themeID: themeID)
        let hues = try points.map { x, y -> Int in
            let p = try #require(pixel(in: color, normalizedX: x, normalizedY: y))
            return Int(p.red * 255) << 16 | Int(p.green * 255) << 8 | Int(p.blue * 255)
        }
        #expect(Set(hues).count == 3)
    }

    private func pixel(in image: UIImage, normalizedX: CGFloat, normalizedY: CGFloat) -> Pixel? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let x = CGFloat(cgImage.width) * normalizedX
        let y = CGFloat(cgImage.height) * normalizedY
        context.translateBy(x: -x, y: y - CGFloat(cgImage.height) + 1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        return Pixel(
            red: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255,
            alpha: CGFloat(bytes[3]) / 255
        )
    }
}

private struct Pixel {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}
