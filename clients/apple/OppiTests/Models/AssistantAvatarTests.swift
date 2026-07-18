import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("AssistantAvatar", .serialized)
@MainActor
struct AssistantAvatarTests {

    @Test("builtin cases include the official Pi logo, piText, and golGrid")
    func builtinCases() {
        #expect(AssistantAvatar.builtinCases.contains(.officialPi))
        #expect(AssistantAvatar.builtinCases.contains(.piText))
        #expect(AssistantAvatar.builtinCases.contains(.golGrid))
        #expect(AssistantAvatar.builtinCases.count == 3)
    }

    @Test("display names")
    func displayNames() {
        #expect(AssistantAvatar.officialPi.displayName == "Official Pi")
        #expect(AssistantAvatar.piText.displayName == "Classic π")
        #expect(AssistantAvatar.golGrid.displayName == "Grid π")
        #expect(AssistantAvatar.emoji("🤖").displayName == "🤖")
        #expect(AssistantAvatar.emoji("🧠").displayName == "🧠")
    }

    @Test("invalid persisted value falls back to grid")
    func invalidPersistedValueFallsBackToGrid() {
        UserDefaults.standard.set("totally-unknown", forKey: "assistantAvatarType")
        #expect(AssistantAvatar.current == .golGrid)
        UserDefaults.standard.removeObject(forKey: "assistantAvatarType")
    }

    @Test("default is piText")
    func defaultAvatar() {
        // Clear any stored preference
        UserDefaults.standard.removeObject(forKey: "assistantAvatarType")
        let avatar = AssistantAvatar.current
        #expect(avatar == .piText)
    }

    @Test("persistence round-trip for officialPi announces the change")
    func persistOfficialPi() async {
        await confirmation("avatar change notification") { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: .assistantAvatarDidChange,
                object: nil,
                queue: nil
            ) { _ in
                confirm()
            }
            defer {
                NotificationCenter.default.removeObserver(observer)
                AssistantAvatar.setCurrent(.piText)
            }

            AssistantAvatar.setCurrent(.officialPi)
            #expect(AssistantAvatar.current == .officialPi)
        }
    }

    @Test("official Pi renderer preserves the mark, counter, and theme color")
    func officialPiRendering() throws {
        let darkImage = AssistantAvatarRenderer.render(
            avatar: .officialPi,
            sessionId: "renderer-test",
            size: 800,
            themeID: .dark
        )
        let lightImage = AssistantAvatarRenderer.render(
            avatar: .officialPi,
            sessionId: "renderer-test",
            size: 800,
            themeID: .light
        )

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

    @Test("persistence round-trip for piText")
    func persistPiText() {
        AssistantAvatar.setCurrent(.piText)
        #expect(AssistantAvatar.current == .piText)
    }

    @Test("persistence round-trip for golGrid")
    func persistGolGrid() {
        AssistantAvatar.setCurrent(.golGrid)
        #expect(AssistantAvatar.current == .golGrid)
        // Restore default
        AssistantAvatar.setCurrent(.piText)
    }

    @Test("persistence round-trip for emoji")
    func persistEmoji() {
        AssistantAvatar.setCurrent(.emoji("🦊"))
        let restored = AssistantAvatar.current
        #expect(restored == .emoji("🦊"))
        // Restore default
        AssistantAvatar.setCurrent(.piText)
    }

    @Test("emoji equality")
    func emojiEquality() {
        #expect(AssistantAvatar.emoji("🤖") == .emoji("🤖"))
        #expect(AssistantAvatar.emoji("🤖") != .emoji("🧠"))
        #expect(AssistantAvatar.emoji("🤖") != .piText)
    }

    @Test("cache identifiers distinguish emoji values")
    func cacheIdentifiers() {
        #expect(AssistantAvatar.officialPi.cacheIdentifier == "officialPi")
        #expect(AssistantAvatar.piText.cacheIdentifier == "piText")
        #expect(AssistantAvatar.golGrid.cacheIdentifier == "golGrid")
        #expect(AssistantAvatar.emoji("🤖").cacheIdentifier != AssistantAvatar.emoji("🧠").cacheIdentifier)
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
