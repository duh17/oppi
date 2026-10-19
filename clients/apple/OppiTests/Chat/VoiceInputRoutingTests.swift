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
