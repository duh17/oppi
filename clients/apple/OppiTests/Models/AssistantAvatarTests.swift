import Foundation
import Testing
@testable import Oppi

@Suite("AssistantAvatar")
struct AssistantAvatarTests {

    @Test("builtin cases include piText and golGrid")
    func builtinCases() {
        #expect(AssistantAvatar.builtinCases.contains(.piText))
        #expect(AssistantAvatar.builtinCases.contains(.golGrid))
        #expect(AssistantAvatar.builtinCases.count == 2)
    }

    @Test("display names")
    func displayNames() {
        #expect(AssistantAvatar.piText.displayName == "Classic π")
        #expect(AssistantAvatar.golGrid.displayName == "Grid π")
        #expect(AssistantAvatar.emoji("🤖").displayName == "🤖")
        #expect(AssistantAvatar.emoji("🧠").displayName == "🧠")
    }

    @Test("invalid persisted value falls back to grid")
    func invalidPersistedValueFallsBackToGrid() {
        UserDefaults.standard.set("totally-unknown", forKey: "assistantAvatarType")
        #expect(AssistantAvatar.current == .golGrid)
        UserDefaults.standard.removeObject(forKey: "assistantAvatarType")
    }

    @Test("default is piText")
    func defaultAvatar() {
        // Clear any stored preference
        UserDefaults.standard.removeObject(forKey: "assistantAvatarType")
        let avatar = AssistantAvatar.current
        #expect(avatar == .piText)
    }

    @Test("persistence round-trip for piText")
    func persistPiText() {
        AssistantAvatar.setCurrent(.piText)
        #expect(AssistantAvatar.current == .piText)
    }

    @Test("persistence round-trip for golGrid")
    func persistGolGrid() {
        AssistantAvatar.setCurrent(.golGrid)
        #expect(AssistantAvatar.current == .golGrid)
        // Restore default
        AssistantAvatar.setCurrent(.piText)
    }

    @Test("persistence round-trip for emoji")
    func persistEmoji() {
        AssistantAvatar.setCurrent(.emoji("🦊"))
        let restored = AssistantAvatar.current
        #expect(restored == .emoji("🦊"))
        // Restore default
        AssistantAvatar.setCurrent(.piText)
    }

    @Test("emoji equality")
    func emojiEquality() {
        #expect(AssistantAvatar.emoji("🤖") == .emoji("🤖"))
        #expect(AssistantAvatar.emoji("🤖") != .emoji("🧠"))
        #expect(AssistantAvatar.emoji("🤖") != .piText)
    }

    @Test("cache identifiers distinguish emoji values")
    func cacheIdentifiers() {
        #expect(AssistantAvatar.piText.cacheIdentifier == "piText")
        #expect(AssistantAvatar.golGrid.cacheIdentifier == "golGrid")
        #expect(AssistantAvatar.emoji("🤖").cacheIdentifier != AssistantAvatar.emoji("🧠").cacheIdentifier)
    }
}
