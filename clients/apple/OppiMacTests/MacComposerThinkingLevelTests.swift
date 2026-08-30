import Testing
@testable import Oppi

@Suite("Thinking level session value parse")
struct ThinkingLevelSessionValueTests {

    @Test func defaultsUnknownOrMissingSessionValuesToMedium() {
        #expect(ThinkingLevel(sessionValue: nil) == .medium)
        #expect(ThinkingLevel(sessionValue: "") == .medium)
        #expect(ThinkingLevel(sessionValue: "turbo") == .medium)
    }

    @Test func normalizesStoredSessionValues() {
        #expect(ThinkingLevel(sessionValue: " HIGH ") == .high)
        #expect(ThinkingLevel(sessionValue: "xhigh") == .xhigh)
        #expect(ThinkingLevel(sessionValue: "max") == .max)
        #expect(ThinkingLevel(sessionValue: "minimal") == .minimal)
    }
}
