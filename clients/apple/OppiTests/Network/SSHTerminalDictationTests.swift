import Foundation
import Testing
@testable import Oppi

/// The terminal's Dictate button on the composer's pipeline: a take types its
/// settled words once, when it stops; a take dropped by leaving types nothing;
/// and every start reads the Voice engine preference as it is then.
@Suite("SSH terminal dictation", .serialized)
@MainActor
struct SSHTerminalDictationTests {
    private let engineKey = AppPreferenceStore.Voice.engineModeKey

    private struct Rig {
        let dictation: SSHTerminalDictation
        let manager: VoiceInputManager
        let sessions: () -> [MockVoiceSession]
    }

    private func rig() -> Rig {
        var made: [MockVoiceSession] = []
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in
            let session = MockVoiceSession()
            made.append(session)
            return session
        }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: MockVoiceInputSystemAccess()
        )
        return Rig(dictation: SSHTerminalDictation(manager: manager), manager: manager, sessions: { made })
    }

    private func withStoredEngine(_ value: String, _ body: () async throws -> Void) async rethrows {
        let original = UserDefaults.standard.object(forKey: engineKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: engineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: engineKey)
            }
        }
        UserDefaults.standard.set(value, forKey: engineKey)
        try await body()
    }

    @Test func aTakeTypesItsSettledWordsOnceWhenItStops() async throws {
        try await withStoredEngine("onDevice") {
            let rig = rig()
            var typed: [String] = []
            rig.dictation.type = { typed.append($0) }

            await rig.dictation.toggle(connection: nil)
            #expect(rig.dictation.presentation.isRecording, "the button shows the take")
            let session = try #require(rig.sessions().last)
            session.yieldEvent(.partialTranscript("git sta"))
            #expect(await waitForMainActorCondition { rig.manager.currentTranscript == "git sta" })
            session.yieldEvent(.appendFinalTranscript("git status"))
            #expect(await waitForMainActorCondition { rig.manager.currentTranscript == "git status" })
            #expect(typed.isEmpty, "nothing reaches the shell while the person speaks")

            await rig.dictation.toggle(connection: nil)
            #expect(typed == ["git status"])
            #expect(!rig.dictation.presentation.isRecording)
            rig.dictation.release()
        }
    }

    @Test func leavingTheTerminalDropsTheTakeAndTypesNothing() async throws {
        try await withStoredEngine("onDevice") {
            let rig = rig()
            var typed: [String] = []
            rig.dictation.type = { typed.append($0) }
            await rig.dictation.toggle(connection: nil)
            let session = try #require(rig.sessions().last)
            session.yieldEvent(.appendFinalTranscript("rm -rf build"))
            #expect(await waitForMainActorCondition { rig.manager.currentTranscript == "rm -rf build" })

            rig.dictation.release()
            #expect(await waitForMainActorCondition { rig.manager.state == .idle })
            #expect(typed.isEmpty)
        }
    }

    @Test func everyStartFollowsTheEnginePreferenceAsItIsThen() async throws {
        let rig = rig()
        for (stored, expected) in [("remote", VoiceInputManager.EngineMode.remote), ("onDevice", .onDevice), ("remote", .remote)] {
            await withStoredEngine(stored) {
                await rig.dictation.toggle(connection: nil)
                #expect(rig.manager.engineMode == expected, "a take started with \(stored) stored")
                if rig.manager.isRecording { await rig.dictation.toggle(connection: nil) }
                #expect(await waitForMainActorCondition { rig.manager.state == .idle || rig.manager.state.isError })
            }
        }
        rig.dictation.release()
    }
}

private extension VoiceInputManager.State {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
