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

    @Test("renderer preserves the mark, counter, and theme color")
    func rendererPreservesMarkCounterAndThemeColor() throws {
        let darkImage = PiAvatarRenderer.render(size: 800, themeID: .dark)
        let lightImage = PiAvatarRenderer.render(size: 800, themeID: .light)

        let darkMark = try #require(pixel(in: darkImage, normalizedX: 0.25, normalizedY: 0.25))
        let lightMark = try #require(pixel(in: lightImage, normalizedX: 0.25, normalizedY: 0.25))
        let counter = try #require(pixel(in: darkImage, normalizedX: 0.42, normalizedY: 0.42))
        let dot = try #require(pixel(in: darkImage, normalizedX: 0.72, normalizedY: 0.62))
        let margin = try #require(pixel(in: darkImage, normalizedX: 0.10, normalizedY: 0.10))

        #expect(darkMark.alpha > 0.9)
        #expect(lightMark.alpha > 0.9)
        #expect(darkMark.luminance > lightMark.luminance)
        #expect(counter.alpha < 0.01)
        #expect(dot.alpha > 0.9)
        #expect(margin.alpha < 0.01)
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

    var luminance: CGFloat {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }
}
