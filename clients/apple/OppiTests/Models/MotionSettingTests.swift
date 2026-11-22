import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("MotionSetting")
struct MotionSettingTests {
    @Test func displayNameMapping() {
        #expect(MotionSetting.full.displayName == "Full")
        #expect(MotionSetting.moments.displayName == "Moments only")
        #expect(MotionSetting.off.displayName == "Off")
    }

    /// Full is every animation, Moments only drops the decorative loops, Off
    /// drops the moments too.
    @Test func capabilitiesNarrowFromFullToOff() {
        #expect(MotionSetting.full.playsLoops && MotionSetting.full.playsMoments)
        #expect(!MotionSetting.moments.playsLoops && MotionSetting.moments.playsMoments)
        #expect(!MotionSetting.off.playsLoops && !MotionSetting.off.playsMoments)
    }

    @Test func rawValueRoundTrip() {
        for setting in MotionSetting.allCases {
            #expect(MotionSetting(rawValue: setting.rawValue) == setting)
        }
        #expect(MotionSetting.allCases == [.full, .moments, .off])
    }
}

/// The setting reads and writes a defaults suite of its own, never the app's:
/// other suites draw spinners from the shared store while these run.
@Suite("Motion preference")
struct MotionPreferenceTests {
    private typealias Store = AppPreferenceStore.Appearance

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "MotionPreferenceTests.\(UUID().uuidString)"))
    }

    @Test func nothingStoredIsEveryAnimation() throws {
        #expect(Store.motion(in: try makeDefaults()) == .full)
    }

    @Test func anUnreadableValueIsEveryAnimation() throws {
        let defaults = try makeDefaults()
        defaults.set("some-future-setting", forKey: Store.motionKey)
        #expect(Store.motion(in: defaults) == .full)
    }

    @Test func everyChoiceIsStoredAndReadBack() throws {
        let defaults = try makeDefaults()
        for setting in MotionSetting.allCases {
            defaults.set(setting.rawValue, forKey: Store.motionKey)
            #expect(Store.motion(in: defaults) == setting)
        }
    }
}

/// The app's one motion answer: the setting, held still by the system's own
/// switches. Every animating view asks this instead of reading either itself.
@Suite("MotionPolicy")
@MainActor
struct MotionPolicyTests {
    @Test func theSystemSwitchesEachHoldEverythingStill() {
        for setting in MotionSetting.allCases {
            #expect(MotionPolicy.effective(setting: setting, reduceMotion: true) == .off)
            #expect(MotionPolicy.effective(setting: setting, lowPowerMode: true) == .off)
            #expect(MotionPolicy.effective(setting: setting, animatedImages: false) == .off)
            #expect(MotionPolicy.effective(setting: setting) == setting)
        }
    }

    @Test func momentsKeepOneBurstAndLoseTheLoops() {
        #expect(MotionPolicy.effective(setting: .moments).playsMoments)
        #expect(!MotionPolicy.effective(setting: .moments).playsLoops)
        #expect(!MotionPolicy.effective(setting: .off).playsMoments)
        #expect(!MotionPolicy.effective(setting: .full, reduceMotion: true).playsMoments)
    }
}
