import Foundation
import Testing
@testable import Oppi

@Suite("VoiceInputRouteResolver")
@MainActor
struct VoiceInputRoutingTests {
    @Test func onDeviceKeepsClassicDictationWhenAvailable() async {
        let resolver = VoiceInputRouteResolver { engine, _ in
            engine == .classicDictation || engine == .modernSpeech
        }

        let resolved = await resolver.resolveEngine(
            mode: .onDevice,
            fallback: .classicDictation,
            locale: Locale(identifier: "en-US")
        )

        #expect(resolved == .classicDictation)
    }

    @Test func onDeviceKeepsModernSpeechWhenAvailable() async {
        let resolver = VoiceInputRouteResolver { engine, _ in
            engine == .modernSpeech
        }

        let resolved = await resolver.resolveEngine(
            mode: .onDevice,
            fallback: .modernSpeech,
            locale: Locale(identifier: "en-US")
        )

        #expect(resolved == .modernSpeech)
    }

    @Test func onDeviceFallsBackToClassicDictation() async {
        let resolver = VoiceInputRouteResolver { engine, _ in
            engine == .classicDictation
        }

        let resolved = await resolver.resolveEngine(
            mode: .onDevice,
            fallback: .modernSpeech,
            locale: Locale(identifier: "en-US")
        )

        #expect(resolved == .classicDictation)
    }

    @Test func onDeviceKeepsPreferredEngineWhenNeitherEngineIsAvailable() async {
        let resolver = VoiceInputRouteResolver { _, _ in false }

        let resolved = await resolver.resolveEngine(
            mode: .onDevice,
            fallback: .modernSpeech,
            locale: Locale(identifier: "zz-ZZ")
        )

        #expect(resolved == .modernSpeech)
    }

    @Test func onDeviceCanFallForwardFromClassicToModernSpeech() async {
        let resolver = VoiceInputRouteResolver { engine, _ in
            engine == .modernSpeech
        }

        let resolved = await resolver.resolveEngine(
            mode: .onDevice,
            fallback: .classicDictation,
            locale: Locale(identifier: "en-US")
        )

        #expect(resolved == .modernSpeech)
    }

    @Test func remoteModeDoesNotProbeOnDeviceCapabilities() async {
        var probeCount = 0
        let resolver = VoiceInputRouteResolver { _, _ in
            probeCount += 1
            return true
        }

        let resolved = await resolver.resolveEngine(
            mode: .remote,
            fallback: .modernSpeech,
            locale: Locale(identifier: "en-US"),
            serverDictationAvailable: true
        )

        #expect(resolved == .serverDictation)
        #expect(probeCount == 0)
    }

    /// Engine Server or the legacy Auto while the server's dictation backend is not ready:
    /// on-device dictation takes the recording.
    @Test(arguments: [VoiceInputManager.EngineMode.remote, .auto])
    func serverModesFallBackOnDeviceWithoutServerDictation(mode: VoiceInputManager.EngineMode) async {
        let resolver = VoiceInputRouteResolver { engine, _ in
            engine == .classicDictation
        }

        let resolved = await resolver.resolveEngine(
            mode: mode,
            fallback: .modernSpeech,
            locale: Locale(identifier: "en-US"),
            serverDictationAvailable: false
        )

        #expect(resolved == .classicDictation)
    }

    @Test func autoWithServerDoesNotProbeOnDeviceCapabilities() async {
        var probeCount = 0
        let resolver = VoiceInputRouteResolver { _, _ in
            probeCount += 1
            return true
        }

        let resolved = await resolver.resolveEngine(
            mode: .auto,
            fallback: .modernSpeech,
            locale: Locale(identifier: "en-US"),
            serverDictationAvailable: true
        )

        #expect(resolved == .serverDictation)
        #expect(probeCount == 0)
    }
}

/// The stored dictation engine decides whether audio leaves the phone. A new install has
/// no stored value and must stay on-device; an existing choice must survive.
@Suite("AppPreferences.Voice engine mode", .serialized)
@MainActor
struct VoiceEngineModePreferenceTests {
    private let key = AppPreferenceStore.Voice.engineModeKey

    private func withStoredValue(_ value: String?, _ body: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        body()
    }

    @Test func newInstallDictatesOnDevice() {
        withStoredValue(nil) {
            #expect(AppPreferences.Voice.engineMode == .onDevice)
            #expect(VoiceInputManager().engineMode == .onDevice)
        }
    }

    @Test func storedServerChoiceIsKept() {
        withStoredValue("remote") {
            #expect(AppPreferences.Voice.engineMode == .remote)
            #expect(VoiceInputManager().engineMode == .remote)
        }
    }

    @Test func storedOnDeviceChoiceIsKept() {
        withStoredValue("onDevice") {
            #expect(AppPreferences.Voice.engineMode == .onDevice)
        }
    }

    /// `auto` was only written when someone picked "Automatic" (server when connected,
    /// else on-device), so it stays Server rather than becoming the new-install default.
    @Test func storedAutomaticChoiceStaysServer() {
        withStoredValue("auto") {
            #expect(AppPreferences.Voice.engineMode == .remote)
        }
    }
}
