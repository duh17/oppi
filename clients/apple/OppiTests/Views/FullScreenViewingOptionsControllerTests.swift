import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("FullScreenViewingOptionsController")
struct FullScreenViewingOptionsControllerTests {
    private final class Calls {
        var textScales: [CGFloat] = []
        var wraps: [Bool] = []
        var spacings: [FullScreenReaderSpacing] = []
        var resets = 0
    }

    private func make(
        family: FullScreenReaderContentFamily,
        preferences: FullScreenReaderPreferences = FullScreenReaderPreferences()
    ) -> (FullScreenViewingOptionsController, Calls) {
        let calls = Calls()
        let controller = FullScreenViewingOptionsController(
            family: family,
            preferences: preferences,
            onTextScaleChanged: { calls.textScales.append($0) },
            onWrappingChanged: { calls.wraps.append($0) },
            onSpacingChanged: { calls.spacings.append($0) },
            onReset: { calls.resets += 1 }
        )
        controller.loadViewIfNeeded()
        controller.updateProperties()
        return (controller, calls)
    }

    private func find<T: UIView>(_ type: T.Type, _ id: String, in controller: UIViewController) throws -> T {
        func search(_ view: UIView) -> T? {
            if let match = view as? T, match.accessibilityIdentifier == id { return match }
            for subview in view.subviews {
                if let match = search(subview) { return match }
            }
            return nil
        }
        return try #require(search(controller.view), "no \(id)")
    }

    /// Whether `view` and every superview up to the controller's view is visible.
    private func isShown(_ view: UIView, in controller: UIViewController) -> Bool {
        var current: UIView? = view
        while let candidate = current, candidate !== controller.view {
            if candidate.isHidden { return false }
            current = candidate.superview
        }
        return true
    }

    @Test func textScaleSnapsToTheFivePercentGridInsideTheReaderRange() {
        let snap = FullScreenViewingOptionsController.snappedTextScale
        #expect(abs(snap(1.2347) - 1.25) < 1e-6)
        #expect(abs(snap(1.02) - 1.0) < 1e-6)
        #expect(snap(0.1) == FullScreenReaderPreferences.minimumTextScale)
        #expect(snap(9) == FullScreenReaderPreferences.maximumTextScale)
    }

    @Test func sliderReportsTheSnappedScaleAndSpeaksThePercent() throws {
        let (controller, calls) = make(family: .code, preferences: FullScreenReaderPreferences(textScale: 1.1))
        let slider = try find(UISlider.self, "fullscreen.viewingOptions.textSize", in: controller)
        #expect(abs(slider.value - 1.1) < 1e-5)
        #expect(slider.accessibilityValue == "110 percent")

        slider.value = 1.2347
        slider.sendActions(for: .valueChanged)
        #expect(calls.textScales.count == 1)
        #expect(abs((calls.textScales.first ?? 0) - 1.25) < 1e-6)
        #expect(abs(slider.value - 1.25) < 1e-5)
    }

    @Test func aDragInsideOneStepReportsTheScaleOnce() throws {
        let (controller, calls) = make(family: .code, preferences: FullScreenReaderPreferences(textScale: 1.1))
        let slider = try find(UISlider.self, "fullscreen.viewingOptions.textSize", in: controller)

        func drag(to value: Float) {
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }
        // Still on the 1.10 step: nothing to save.
        drag(to: 1.11)
        drag(to: 1.09)
        #expect(calls.textScales.isEmpty)

        // Several raw values that all round to 1.25 report it once.
        drag(to: 1.23)
        drag(to: 1.24)
        drag(to: 1.26)
        #expect(calls.textScales.count == 1)
        #expect(abs((calls.textScales.first ?? 0) - 1.25) < 1e-6)

        // The next step reports again.
        drag(to: 1.31)
        #expect(calls.textScales.count == 2)
        #expect(abs((calls.textScales.last ?? 0) - 1.3) < 1e-6)
    }

    @Test func codeFamilyOffersWrapButNotSpacing() throws {
        let (controller, calls) = make(family: .code)
        let toggle = try find(UISwitch.self, "fullscreen.viewingOptions.wrap", in: controller)
        let spacing = try find(UISegmentedControl.self, "fullscreen.viewingOptions.spacing", in: controller)
        #expect(isShown(toggle, in: controller))
        #expect(!isShown(spacing, in: controller))

        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        #expect(calls.wraps == [true])
    }

    @Test func markdownFamilyOffersSpacingButNotWrap() throws {
        let (controller, calls) = make(family: .markdown)
        let toggle = try find(UISwitch.self, "fullscreen.viewingOptions.wrap", in: controller)
        let spacing = try find(UISegmentedControl.self, "fullscreen.viewingOptions.spacing", in: controller)
        #expect(!isShown(toggle, in: controller))
        #expect(isShown(spacing, in: controller))
        #expect(spacing.selectedSegmentIndex == FullScreenReaderSpacing.allCases.firstIndex(of: .standard))

        let relaxed = try #require(FullScreenReaderSpacing.allCases.firstIndex(of: .relaxed))
        spacing.selectedSegmentIndex = relaxed
        spacing.sendActions(for: .valueChanged)
        #expect(calls.spacings == [.relaxed])
    }

    @Test func applyingNewPreferencesRefreshesTheControls() throws {
        let (controller, _) = make(family: .code)
        let slider = try find(UISlider.self, "fullscreen.viewingOptions.textSize", in: controller)
        let toggle = try find(UISwitch.self, "fullscreen.viewingOptions.wrap", in: controller)

        controller.apply(
            family: .code,
            preferences: FullScreenReaderPreferences(textScale: 1.3, wrapsText: true)
        )
        controller.updateProperties()

        #expect(abs(slider.value - 1.3) < 1e-5)
        #expect(slider.accessibilityValue == "130 percent")
        #expect(toggle.isOn)
    }

    @Test func resetViewRunsTheOwnersReset() throws {
        let (controller, calls) = make(family: .code)
        let reset = try find(UIButton.self, "fullscreen.viewingOptions.reset", in: controller)
        reset.sendActions(for: .primaryActionTriggered)
        #expect(calls.resets == 1)
    }

    @Test func accessibilityTextSizesStackThePercentUnderTheTitleInsteadOfBreakingWords() throws {
        let (controller, _) = make(family: .code)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 340, height: 900))
        window.rootViewController = controller
        window.isHidden = false
        defer { hideTestWindow(window) }

        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.view.layoutIfNeeded()
        controller.updateProperties()
        controller.view.layoutIfNeeded()

        func labels(in view: UIView) -> [UILabel] {
            (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels)
        }
        let all = labels(in: controller.view)
        let title = try #require(all.first { $0.text == "Text Size" })
        let percent = try #require(all.first { $0.text == "100%" })
        // "Text Size" wraps by word (two lines at most), not a letter per line.
        #expect(title.bounds.height < title.font.lineHeight * 2.5)
        let titleFrame = title.convert(title.bounds, to: controller.view)
        let percentFrame = percent.convert(percent.bounds, to: controller.view)
        #expect(percentFrame.minY >= titleFrame.maxY - 0.5)
    }

    @Test func aLargerTextSizeMakesThePanelTaller() {
        let (controller, _) = make(family: .markdown)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { hideTestWindow(window) }

        let regular = controller.preferredSheetHeight
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.view.layoutIfNeeded()
        controller.updateProperties()
        controller.view.layoutIfNeeded()
        #expect(controller.preferredSheetHeight > regular)
    }
}
