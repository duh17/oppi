import Foundation
import Testing
@testable import Oppi

@Suite("SpinnerStyle")
struct SpinnerStyleTests {
    @Test func displayNameMapping() {
        #expect(SpinnerStyle.working.displayName == "Orbiting")
        #expect(SpinnerStyle.searching.displayName == "Searching")
        #expect(SpinnerStyle.solving.displayName == "Solving")
        #expect(SpinnerStyle.brailleDots.displayName == "Pi")
        #expect(SpinnerStyle.gameOfLife.displayName == "GoL")
    }

    @Test func allCasesKeepsLegacyStylesAndAddsMetalOrbs() {
        #expect(SpinnerStyle.allCases == [
            .working,
            .searching,
            .solving,
            .brailleDots,
            .gameOfLife,
        ])
    }

    @Test func rawValueRoundTrip() {
        for style in SpinnerStyle.allCases {
            let recovered = SpinnerStyle(rawValue: style.rawValue)
            #expect(recovered == style)
        }
    }
}

@Suite("DictationIndicatorStyle")
struct DictationIndicatorStyleTests {
    @Test func displayNameMapping() {
        #expect(DictationIndicatorStyle.composing.displayName == "Composing")
        #expect(DictationIndicatorStyle.breathing.displayName == "Breathing")
        #expect(DictationIndicatorStyle.ring.displayName == "Ring")
    }

    @Test func allCasesKeepsLegacyRingAndAddsVoiceOrbs() {
        #expect(DictationIndicatorStyle.allCases == [
            .ring,
            .breathing,
            .composing,
        ])
    }

    @Test func rawValueRoundTrip() {
        for style in DictationIndicatorStyle.allCases {
            let recovered = DictationIndicatorStyle(rawValue: style.rawValue)
            #expect(recovered == style)
        }
    }
}

/// The style preferences read and write a defaults suite of their own, never the
/// app's: other suites draw spinners from the shared store while these run.
@Suite("AppPreferenceStore.Appearance styles")
struct AppearanceStylePreferenceTests {
    private typealias Store = AppPreferenceStore.Appearance

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AppearanceStylePreferenceTests.\(UUID().uuidString)"))
    }

    @Test func unsetSpinnerDefaultsToWorking() throws {
        #expect(Store.spinnerStyle(in: try makeDefaults()) == .working)
    }

    @Test func invalidSpinnerDefaultsToWorking() throws {
        let defaults = try makeDefaults()
        defaults.set("not-a-spinner", forKey: Store.spinnerStyleKey)
        #expect(Store.spinnerStyle(in: defaults) == .working)
    }

    @Test func preservedSpinnerChoiceStaysSelectable() throws {
        let defaults = try makeDefaults()
        Store.setSpinnerStyle(.brailleDots, in: defaults)
        #expect(Store.spinnerStyle(in: defaults) == .brailleDots)
        Store.setSpinnerStyle(.gameOfLife, in: defaults)
        #expect(Store.spinnerStyle(in: defaults) == .gameOfLife)
        Store.setSpinnerStyle(.searching, in: defaults)
        #expect(Store.spinnerStyle(in: defaults) == .searching)
        #expect(defaults.string(forKey: Store.spinnerStyleKey) == "searching")
    }

    @Test func unsetDictationDefaultsToRing() throws {
        #expect(Store.dictationIndicatorStyle(in: try makeDefaults()) == .ring)
    }

    @Test func invalidDictationDefaultsToRing() throws {
        let defaults = try makeDefaults()
        defaults.set("not-a-dictation-style", forKey: Store.dictationIndicatorStyleKey)
        #expect(Store.dictationIndicatorStyle(in: defaults) == .ring)
    }

    @Test func preservedRingChoiceStaysSelectable() throws {
        let defaults = try makeDefaults()
        Store.setDictationIndicatorStyle(.breathing, in: defaults)
        #expect(Store.dictationIndicatorStyle(in: defaults) == .breathing)
        Store.setDictationIndicatorStyle(.ring, in: defaults)
        #expect(Store.dictationIndicatorStyle(in: defaults) == .ring)
        #expect(defaults.string(forKey: Store.dictationIndicatorStyleKey) == "ring")
    }
}
