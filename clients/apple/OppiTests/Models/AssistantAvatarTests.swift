import Foundation
import ImageIO
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
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

    @Test("malformed persisted emoji and unknown types normalize to classic pi")
    func malformedPersistedValuesNormalizeToPiText() throws {
        let cases: [(type: String, emoji: String?)] = [
            ("emoji", ""),
            ("emoji", "plain text"),
            ("emoji", "🤖🦊"),
            ("emoji", "🤖-"),
            ("totally-unknown", "🤖"),
        ]

        for fixture in cases {
            let suiteName = "AssistantAvatarTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
            defaults.set(fixture.type, forKey: "assistantAvatarType")
            if let emoji = fixture.emoji {
                defaults.set(emoji, forKey: "assistantAvatarEmoji")
            }

            let persistence = AssistantAvatarPersistence(defaults: defaults)
            #expect(persistence.current == .piText)
            #expect(defaults.string(forKey: "assistantAvatarType") == "piText")
        }
    }

    @Test("valid persisted builtins and a single emoji are preserved")
    func validPersistedValuesArePreserved() throws {
        let cases: [(type: String, emoji: String?, expected: AssistantAvatar)] = [
            ("officialPi", nil, .officialPi),
            ("piText", nil, .piText),
            ("golGrid", nil, .golGrid),
            ("emoji", "🦊", .emoji("🦊")),
        ]

        for fixture in cases {
            let suiteName = "AssistantAvatarTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
            defaults.set(fixture.type, forKey: "assistantAvatarType")
            if let emoji = fixture.emoji {
                defaults.set(emoji, forKey: "assistantAvatarEmoji")
            }

            #expect(AssistantAvatarPersistence(defaults: defaults).current == fixture.expected)
        }
    }

    @Test("default is piText")
    func defaultAvatar() {
        // Clear any stored preference
        UserDefaults.standard.removeObject(forKey: "assistantAvatarType")
        AssistantAvatar.reloadAfterExternalChange()
        let avatar = AssistantAvatar.current
        #expect(avatar == .piText)
    }

    @Test("persistence round-trip for officialPi announces the change")
    func persistOfficialPi() async throws {
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
                try? AssistantAvatar.setCurrent(.piText)
            }

            do {
                try AssistantAvatar.setCurrent(.officialPi)
            } catch {
                Issue.record("Unexpected persistence rejection: \(error)")
                return
            }
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
    func persistPiText() throws {
        try AssistantAvatar.setCurrent(.piText)
        #expect(AssistantAvatar.current == .piText)
    }

    @Test("persistence round-trip for golGrid")
    func persistGolGrid() throws {
        try AssistantAvatar.setCurrent(.golGrid)
        #expect(AssistantAvatar.current == .golGrid)
        // Restore default
        try AssistantAvatar.setCurrent(.piText)
    }

    @Test("persistence round-trip for emoji")
    func persistEmoji() throws {
        try AssistantAvatar.setCurrent(.emoji("🦊"))
        let restored = AssistantAvatar.current
        #expect(restored == .emoji("🦊"))
        // Restore default
        try AssistantAvatar.setCurrent(.piText)
    }

    @Test("persisted Genmoji decodes once and shares its cached image")
    func persistedGenmojiDecodesOnceAndSharesCachedImage() throws {
        let suiteName = "AssistantAvatarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("genmoji", forKey: "assistantAvatarType")
        defaults.set(try genericHEICFixture(), forKey: "assistantAvatarGenmoji")
        defaults.set("Pink square", forKey: "assistantAvatarGenmojiDescription")

        let decodedImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        var decodeCount = 0
        let persistence = AssistantAvatarPersistence(defaults: defaults) { _ in
            decodeCount += 1
            return decodedImage
        }

        let first = persistence.current
        let second = persistence.current
        #expect(first == second)
        #expect(decodeCount == 1)
        #expect(persistence.image(for: first) === decodedImage)
        #expect(persistence.image(for: second) === decodedImage)

        try persistence.setCurrent(.piText)
        #expect(persistence.current == .piText)
        #expect(decodeCount == 1)
        #expect(persistence.image(for: .piText) == nil)
    }

    @Test("cached persisted snapshot keeps ordinary row updates off persistence")
    func cachedSnapshotAvoidsPersistenceWorkForOrdinaryRows() throws {
        let decodedImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let source = AssistantAvatarPersistence.Source(
            type: "genmoji",
            emoji: nil,
            genmojiData: try genericHEICFixture(),
            genmojiDescription: "Pink square"
        )
        var readCount = 0
        var fingerprintCount = 0
        var decodeCount = 0
        let persistence = AssistantAvatarPersistence(
            read: {
                readCount += 1
                return source
            },
            fingerprint: { _ in
                fingerprintCount += 1
                return "persisted-pink-square"
            },
            decode: { _ in
                decodeCount += 1
                return decodedImage
            }
        )
        let badge = SessionGridBadgeView()
        badge.assistantAvatarProvider = { persistence.snapshot }

        badge.configure(sessionId: "ordinary-row", agentId: nil, agentIcon: nil, iconAssetCache: nil)
        #expect((readCount, fingerprintCount, decodeCount) == (1, 1, 1))

        for _ in 0..<5 {
            badge.configure(sessionId: "ordinary-row", agentId: nil, agentIcon: nil, iconAssetCache: nil)
        }

        #expect((readCount, fingerprintCount, decodeCount) == (1, 1, 1))
    }

    @Test("prepared Genmoji persists without a second decode")
    func preparedGenmojiPersistsWithoutSecondDecode() throws {
        let suiteName = "AssistantAvatarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let decodedImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        var decodeCount = 0
        let persistence = AssistantAvatarPersistence(defaults: defaults) { _ in
            decodeCount += 1
            return decodedImage
        }
        let draft = AssistantAvatar.genmoji(
            data: try genericHEICFixture(),
            contentDescription: "Pink square"
        )

        let prepared = try persistence.prepare(draft)
        #expect(decodeCount == 1)
        try persistence.setCurrent(prepared)
        #expect(persistence.current == prepared)
        #expect(decodeCount == 1)
        #expect(persistence.image(for: prepared) === decodedImage)
    }

    @Test("corrupt persisted Genmoji falls back to visible pi text")
    func corruptPersistedGenmojiFallsBackToPiText() {
        let defaults = UserDefaults.standard
        defaults.set("genmoji", forKey: "assistantAvatarType")
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "assistantAvatarGenmoji")
        defaults.set("Corrupt glyph", forKey: "assistantAvatarGenmojiDescription")
        defer { clearPersistedAvatar() }
        AssistantAvatar.reloadAfterExternalChange()

        #expect(AssistantAvatar.current == .piText)
    }

    @Test("historical local image record without a description falls back conservatively")
    func historicalLocalImageWithoutDescriptionFallsBackToPiText() throws {
        let defaults = UserDefaults.standard
        defaults.set("genmoji", forKey: "assistantAvatarType")
        defaults.set(try genericHEICFixture(), forKey: "assistantAvatarGenmoji")
        defaults.removeObject(forKey: "assistantAvatarGenmojiDescription")
        defer { clearPersistedAvatar() }
        AssistantAvatar.reloadAfterExternalChange()

        #expect(AssistantAvatar.current == .piText)
    }

    @Test("historical local image record preserves its persisted content description")
    func historicalLocalImagePreservesContentDescription() throws {
        // Generic HEIC intentionally exercises safe raster fallback only.
        let defaults = UserDefaults.standard
        defaults.set("genmoji", forKey: "assistantAvatarType")
        defaults.set(try genericHEICFixture(), forKey: "assistantAvatarGenmoji")
        defaults.set("Pink square", forKey: "assistantAvatarGenmojiDescription")
        defer { clearPersistedAvatar() }
        AssistantAvatar.reloadAfterExternalChange()

        #expect(
            AssistantAvatar.current.accessibilityDescription == "Pink square",
            "Persisted content description must survive relaunch"
        )
    }

    @Test("persisted local image bytes relaunch and render through the safe ImageIO fallback")
    func persistedLocalImageRelaunchesAndRendersSafely() throws {
        // Generic HEIC intentionally exercises safe raster fallback only.
        let defaults = UserDefaults.standard
        defaults.set("genmoji", forKey: "assistantAvatarType")
        defaults.set(try genericHEICFixture(), forKey: "assistantAvatarGenmoji")
        defaults.set("Pink square", forKey: "assistantAvatarGenmojiDescription")
        defer { clearPersistedAvatar() }
        AssistantAvatar.reloadAfterExternalChange()

        let rendered = AssistantAvatarRenderer.render(
            avatar: AssistantAvatar.current,
            sessionId: "relaunch-safe-render",
            size: 64
        )

        #expect(rendered.cgImage != nil)
        #expect(rendered.size.width > 0)
        #expect(rendered.size.height > 0)
    }

    @Test("invalid Genmoji persistence is rejected without replacing the saved avatar")
    func invalidGenmojiPersistenceIsRejected() throws {
        defer { clearPersistedAvatar() }
        try AssistantAvatar.setCurrent(.emoji("🦊"))

        #expect(throws: Error.self) {
            try AssistantAvatar.setCurrent(
                .genmoji(data: Data([0xFF]), contentDescription: "Bad data")
            )
        }

        #expect(AssistantAvatar.current == .emoji("🦊"))
    }

    @Test("persistence rejection leaves the mounted binding consistent")
    func rejectedPersistenceDoesNotMutateBinding() throws {
        defer { clearPersistedAvatar() }
        try AssistantAvatar.setCurrent(.piText)
        var mountedAvatar = AssistantAvatar.piText
        let binding = Binding(
            get: { mountedAvatar },
            set: { mountedAvatar = $0 }
        )

        #expect(throws: Error.self) {
            try AvatarPickerView.persist(
                .genmoji(data: Data([0xFF]), contentDescription: "Bad data"),
                to: binding
            )
        }

        #expect(mountedAvatar == .piText)
        #expect(AssistantAvatar.current == .piText)
    }

    @Test("mounted session identity label refreshes after assistant avatar notification")
    func mountedSessionIdentityLabelRefreshes() throws {
        defer { clearPersistedAvatar() }
        try AssistantAvatar.setCurrent(.piText)
        let view = SessionGridBadgeView()
        view.sessionId = "mounted-row"
        #expect(view.accessibilityLabel == "Classic π")

        try AssistantAvatar.setCurrent(.emoji("🦊"))

        #expect(view.accessibilityLabel == "Emoji 🦊")
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

    private func clearPersistedAvatar() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "assistantAvatarType")
        defaults.removeObject(forKey: "assistantAvatarEmoji")
        defaults.removeObject(forKey: "assistantAvatarGenmoji")
        defaults.removeObject(forKey: "assistantAvatarGenmojiDescription")
        AssistantAvatar.reloadAfterExternalChange()
    }

    private func genericHEICFixture() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        guard let cgImage = image.cgImage else {
            throw FixtureError.image
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.destination
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.finalize
        }
        return output as Data
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

private enum FixtureError: Error {
    case image
    case destination
    case finalize
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
