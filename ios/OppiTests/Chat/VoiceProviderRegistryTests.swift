import Testing
@testable import Oppi

@Suite("VoiceProviderRegistry")
@MainActor
struct VoiceProviderRegistryTests {
    @Test func defaultRegistryIncludesOnDeviceProviders() {
        let registry = VoiceProviderRegistry.makeDefault()

        #expect(registry.provider(for: .classicDictation)?.id == .appleClassicDictation)
        #expect(registry.provider(for: .modernSpeech)?.id == .appleModernSpeech)
        #expect(registry.provider(for: .remoteASR)?.id == .remoteASR)
    }
}
