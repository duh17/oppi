import Testing
@testable import Oppi

@Suite("Mac composer thinking level")
struct MacComposerThinkingLevelTests {

    @Test func defaultsUnknownOrMissingSessionValuesToMedium() {
        #expect(MacComposerThinkingLevel(sessionValue: nil) == .medium)
        #expect(MacComposerThinkingLevel(sessionValue: "") == .medium)
        #expect(MacComposerThinkingLevel(sessionValue: "turbo") == .medium)
    }

    @Test func normalizesStoredSessionValues() {
        #expect(MacComposerThinkingLevel(sessionValue: " HIGH ") == .high)
        #expect(MacComposerThinkingLevel(sessionValue: "xhigh") == .xhigh)
        #expect(MacComposerThinkingLevel(sessionValue: "max") == .max)
        #expect(MacComposerThinkingLevel(sessionValue: "minimal") == .minimal)
    }

    @Test func mapsToSharedProtocolLevels() {
        #expect(MacComposerThinkingLevel.off.protocolLevel == .off)
        #expect(MacComposerThinkingLevel.minimal.protocolLevel == .minimal)
        #expect(MacComposerThinkingLevel.low.protocolLevel == .low)
        #expect(MacComposerThinkingLevel.medium.protocolLevel == .medium)
        #expect(MacComposerThinkingLevel.high.protocolLevel == .high)
        #expect(MacComposerThinkingLevel.xhigh.protocolLevel == .xhigh)
        #expect(MacComposerThinkingLevel.max.protocolLevel == .max)
        #expect(MacComposerThinkingLevel.max.displayTitle == "Max")
    }
}
