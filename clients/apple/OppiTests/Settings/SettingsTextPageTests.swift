import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Text over the real page: a slider moves in whole steps and writes
/// the font preference once per step, and every control keeps the id it has.
@Suite("Settings Text page", .serialized)
@MainActor
struct SettingsTextPageTests {
    private struct Harness {
        let page: SettingsTextViewController
        let window: UIWindow
        let restore: () -> Void
    }

    private func makeHarness() throws -> Harness {
        let codeScale = FontPreferences.codeTextScale
        let messageScale = FontPreferences.messageTextScale
        let mono = FontPreferences.useMonoForMessages
        let font = FontPreferences.codeFont
        let page = SettingsTextViewController()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1200)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return Harness(page: page, window: window) {
            FontPreferences.setCodeTextScale(codeScale)
            FontPreferences.setMessageTextScale(messageScale)
            FontPreferences.setUseMonoForMessages(mono)
            FontPreferences.setCodeFont(font)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func cell(_ item: SettingsTextViewController.Item, in page: SettingsTextViewController) -> UICollectionViewCell? {
        page.view.layoutIfNeeded()
        return page.dataSource?.indexPath(for: item).flatMap { page.collectionView.cellForItem(at: $0) }
    }

    private func slider(_ item: SettingsTextViewController.Item, in page: SettingsTextViewController) -> UISlider? {
        cell(item, in: page)?.accessibilityElements?.first as? UISlider
    }

    @Test("The sliders carry their ids and the percent as their spoken value")
    func slidersAreNamedAndSpeakAPercent() async throws {
        let h = try makeHarness()
        defer { h.restore() }
        FontPreferences.setCodeTextScale(1.1)
        #expect(await waitForMainActorCondition { slider(.codeSize, in: h.page) != nil && slider(.messageSize, in: h.page) != nil })
        let code = try #require(slider(.codeSize, in: h.page))
        #expect(code.accessibilityIdentifier == "settings.text.codeSize")
        #expect(code.accessibilityLabel == "Code Text Size")
        #expect(code.accessibilityValue == "110 percent")
        #expect(try #require(slider(.messageSize, in: h.page)).accessibilityIdentifier == "settings.text.messageSize")
    }

    @Test("Dragging a slider writes the size in whole steps, and VoiceOver adjusts it one step at a time")
    func sliderWritesInSteps() async throws {
        let h = try makeHarness()
        defer { h.restore() }
        FontPreferences.setCodeTextScale(1.0)
        #expect(await waitForMainActorCondition { slider(.codeSize, in: h.page) != nil })
        let code = try #require(slider(.codeSize, in: h.page))

        code.value = 1.12
        code.sendActions(for: .valueChanged)
        #expect(abs(FontPreferences.codeTextScale - 1.1) < 0.001, "1.12 rests on the 1.10 step")
        #expect(abs(code.value - 1.1) < 0.001)

        code.accessibilityIncrement()
        #expect(abs(FontPreferences.codeTextScale - 1.15) < 0.001)
        code.accessibilityDecrement()
        code.accessibilityDecrement()
        #expect(abs(FontPreferences.codeTextScale - 1.05) < 0.001)
        #expect(await waitForMainActorCondition { slider(.codeSize, in: h.page)?.accessibilityValue == "105 percent" })
    }

    @Test("A slider cannot be pushed past the sizes the app allows")
    func sliderStaysInRange() async throws {
        let h = try makeHarness()
        defer { h.restore() }
        #expect(await waitForMainActorCondition { slider(.messageSize, in: h.page) != nil })
        let message = try #require(slider(.messageSize, in: h.page))
        #expect(abs(CGFloat(message.minimumValue) - FontPreferences.minimumMessageTextScale) < 0.001)
        #expect(abs(CGFloat(message.maximumValue) - FontPreferences.maximumMessageTextScale) < 0.001)
        message.value = message.maximumValue
        message.sendActions(for: .valueChanged)
        for _ in 0..<5 { message.accessibilityIncrement() }
        #expect(FontPreferences.messageTextScale <= FontPreferences.maximumMessageTextScale + 0.001)
    }

    @Test("Monospaced Messages writes its preference and the code font menu picks a family")
    func toggleAndFontMenu() async throws {
        let h = try makeHarness()
        defer { h.restore() }
        FontPreferences.setUseMonoForMessages(false)
        #expect(await waitForMainActorCondition { cell(.monospacedMessages, in: h.page) != nil })
        let switches = Self.switches(in: try #require(cell(.monospacedMessages, in: h.page)))
        let toggle = try #require(switches.first)
        #expect(toggle.accessibilityIdentifier == "settings.text.monospacedMessages")
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        #expect(FontPreferences.useMonoForMessages)

        let fontButton = try #require(cell(.codeFont, in: h.page)?.accessibilityElements?.first as? UIButton)
        #expect(fontButton.accessibilityIdentifier == "settings.text.codeFont")
        let family = try #require(FontPreferences.CodeFontFamily.allCases.first { $0 != FontPreferences.codeFont })
        let pick = try #require(fontButton.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == family.displayName })
        pick.performWithSender(nil, target: nil)
        #expect(FontPreferences.codeFont == family)
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        ((view as? UISwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches)
    }
}
