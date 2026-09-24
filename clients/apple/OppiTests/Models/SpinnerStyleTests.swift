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

@Suite("AppPreferenceStore.Appearance styles", .serialized)
struct AppearanceStylePreferenceTests {
    @Test func unsetSpinnerDefaultsToWorking() {
        withClearedKey(AppPreferenceStore.Appearance.spinnerStyleKey) {
            #expect(AppPreferenceStore.Appearance.spinnerStyle == .working)
            #expect(SpinnerStyle.current == .working)
        }
    }

    @Test func invalidSpinnerDefaultsToWorking() {
        withRestoredKey(AppPreferenceStore.Appearance.spinnerStyleKey) { key in
            UserDefaults.standard.set("not-a-spinner", forKey: key)
            #expect(AppPreferenceStore.Appearance.spinnerStyle == .working)
        }
    }

    @Test func preservedSpinnerChoiceStaysSelectable() {
        withRestoredKey(AppPreferenceStore.Appearance.spinnerStyleKey) { _ in
            AppPreferenceStore.Appearance.setSpinnerStyle(.brailleDots)
            #expect(AppPreferenceStore.Appearance.spinnerStyle == .brailleDots)
            AppPreferenceStore.Appearance.setSpinnerStyle(.gameOfLife)
            #expect(SpinnerStyle.current == .gameOfLife)
            AppPreferenceStore.Appearance.setSpinnerStyle(.searching)
            #expect(SpinnerStyle.current == .searching)
        }
    }

    @Test func unsetDictationDefaultsToRing() {
        withClearedKey(AppPreferenceStore.Appearance.dictationIndicatorStyleKey) {
            #expect(AppPreferenceStore.Appearance.dictationIndicatorStyle == .ring)
            #expect(DictationIndicatorStyle.current == .ring)
        }
    }

    @Test func invalidDictationDefaultsToRing() {
        withRestoredKey(AppPreferenceStore.Appearance.dictationIndicatorStyleKey) { key in
            UserDefaults.standard.set("not-a-dictation-style", forKey: key)
            #expect(AppPreferenceStore.Appearance.dictationIndicatorStyle == .ring)
        }
    }

    @Test func preservedRingChoiceStaysSelectable() {
        withRestoredKey(AppPreferenceStore.Appearance.dictationIndicatorStyleKey) { key in
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.breathing)
            #expect(DictationIndicatorStyle.current == .breathing)
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.ring)
            #expect(AppPreferenceStore.Appearance.dictationIndicatorStyle == .ring)
            #expect(UserDefaults.standard.string(forKey: key) == "ring")
        }
    }
}

private func withClearedKey(_ key: String, _ body: () -> Void) {
    withRestoredKey(key) { restoredKey in
        UserDefaults.standard.removeObject(forKey: restoredKey)
        body()
    }
}

private func withRestoredKey(_ key: String, _ body: (String) -> Void) {
    let original = UserDefaults.standard.object(forKey: key)
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    body(key)
}
