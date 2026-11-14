import Foundation
import Testing
@testable import Oppi

/// The terminal's Dictate button on the composer's pipeline: a take types its
/// stable words while the person speaks and the rest when it stops; a take
/// dropped by leaving types nothing more; and every start reads the Voice
/// engine preference as it is then.
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

    @Test func aTakeTypesSettledWordsAsTheyComeAndTheRestWhenItStops() async throws {
        try await withStoredEngine("onDevice") {
            let rig = rig()
            var typed: [String] = []
            rig.dictation.type = { typed.append($0) }

            await rig.dictation.toggle(connection: nil)
            #expect(rig.dictation.presentation.isRecording, "the button shows the take")
            let session = try #require(rig.sessions().last)
            session.yieldEvent(.partialTranscript("git sta"))
            #expect(await waitForMainActorCondition { rig.dictation.provisional == "git sta" })
            #expect(typed.isEmpty, "a guess is shown above the bar, not typed")
            session.yieldEvent(.appendFinalTranscript("git status"))
            #expect(await waitForMainActorCondition { typed == ["git status"] }, "settled words reach the shell while the person speaks")
            session.yieldEvent(.partialTranscript(" --sho"))
            #expect(await waitForMainActorCondition { rig.dictation.provisional == "--sho" })

            await rig.dictation.toggle(connection: nil)
            #expect(typed == ["git status", " --sho"], "Stop types what the shell does not have yet, once")
            #expect(rig.dictation.provisional.isEmpty)
            #expect(!rig.dictation.presentation.isRecording)
            rig.dictation.release()
        }
    }

    @Test func leavingTheTerminalStopsTypingTheTake() async throws {
        try await withStoredEngine("onDevice") {
            let rig = rig()
            var typed: [String] = []
            rig.dictation.type = { typed.append($0) }
            await rig.dictation.toggle(connection: nil)
            let session = try #require(rig.sessions().last)
            session.yieldEvent(.appendFinalTranscript("cd build"))
            #expect(await waitForMainActorCondition { typed == ["cd build"] })
            session.yieldEvent(.partialTranscript(" and remove it"))
            #expect(await waitForMainActorCondition { rig.dictation.provisional == "and remove it" })

            rig.dictation.release()
            #expect(rig.dictation.provisional.isEmpty)
            #expect(await waitForMainActorCondition { rig.manager.state == .idle })
            #expect(typed == ["cd build"], "nothing heard after leaving reaches the shell")
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

/// What of a take reaches the shell, and when: words once stable, never taken
/// back, and the final transcript's rest at the end.
@Suite("SSH terminal dictation committer")
struct SSHTerminalDictationCommitterTests {
    /// The shell's line: every chunk the committer typed, appended.
    private struct Shell {
        var committer = SSHTerminalDictationCommitter()
        var line = ""
        var chunks: [String] = []

        mutating func hear(_ text: String, settled: Int = 0) {
            let chunk = committer.hear(text, settled: settled)
            if !chunk.isEmpty { chunks.append(chunk) }
            line += chunk
        }

        mutating func hearSettled(_ text: String) { hear(text, settled: text.count) }

        mutating func finish(_ text: String) {
            let chunk = committer.finish(text)
            if !chunk.isEmpty { chunks.append(chunk) }
            line += chunk
        }
    }

    @Test func settledWordsAreTypedAndTheChangingTailWaitsAboveTheBar() {
        var shell = Shell()
        shell.hear("git")
        #expect(shell.line.isEmpty)
        #expect(shell.committer.provisional == "git")
        shell.hear("git status", settled: 3)
        #expect(shell.line == "git")
        #expect(shell.committer.provisional == "status")
        shell.hear("git status --short", settled: 10)
        #expect(shell.line == "git status")
        #expect(shell.committer.provisional == "--short")
        shell.finish("git status --short")
        #expect(shell.line == "git status --short")
        #expect(shell.chunks == ["git", " status", " --short"])
        #expect(shell.committer.provisional.isEmpty)
    }

    /// On-device partials carry no settled part until a final result: a word is
    /// typed once three reports in a row agree on it and on what precedes it,
    /// with another word after it. A guess that keeps changing is never typed.
    @Test func wordsTheRecogniserKeepsAreTypedBeforeItSettlesThem() {
        var shell = Shell()
        for partial in ["show", "show me", "show me the"] {
            shell.hear(partial)
        }
        #expect(shell.line.isEmpty, "no word has been followed by another three times")
        shell.hear("show me the get")
        #expect(shell.line == "show")
        shell.hear("show me the git log")
        #expect(shell.line == "show me")
        #expect(shell.committer.provisional == "the git log")
        shell.hearSettled("show me the git log")
        #expect(shell.line == "show me the git log")
        #expect(!shell.chunks.contains { $0.contains("get") }, "the guess the recogniser dropped was never typed")
    }

    /// A shell line cannot take words back: a typed word the recogniser later
    /// changes stays, and typing goes on after its replacement, whether the
    /// change kept the word count, merged two words, or split one.
    @Test(arguments: [
        ("their", "there is a bug", "their is a bug"),
        ("log in", "login with the key", "log in with the key"),
        ("everyday", "every day at noon", "everyday at noon"),
        ("show me the the", "show me the git log", "show me the the git log"),
    ])
    func aRevisedTypedWordStaysAndTheNextWordsFollowIt(typed: String, revised: String, line: String) {
        var shell = Shell()
        shell.hearSettled(typed)
        #expect(shell.line == typed)
        shell.hearSettled(revised)
        #expect(shell.line == line)
        shell.finish(revised)
        #expect(shell.line == line, "the final transcript adds nothing already typed")
        #expect(!shell.line.unicodeScalars.contains { $0 == "\u{7F}" || $0 == "\u{8}" }, "no chunk backspaces")
    }

    @Test func punctuationAndACapitalGrowOntoTheLastTypedWord() {
        var shell = Shell()
        shell.hearSettled("git status")
        shell.hearSettled("Git status, please")
        #expect(shell.line == "git status, please")
        shell.finish("Git status, please.")
        #expect(shell.line == "git status, please.")
        #expect(shell.chunks == ["git status", ", please", "."])
    }

    /// A newline could run what came before it, so live typing stops there and
    /// the rest goes with Stop, through the paste confirmation.
    @Test func aLineBreakWaitsForTheEndOfTheTake() {
        var shell = Shell()
        shell.hearSettled("echo hi\nrm -rf build")
        #expect(shell.line == "echo hi")
        #expect(shell.committer.provisional == "rm -rf build")
        shell.finish("echo hi\nrm -rf build")
        #expect(shell.chunks == ["echo hi", "\nrm -rf build"])
    }

    /// Chinese and Japanese have no spaces: each character is a word, so they
    /// are typed as they settle, with nothing added between chunks.
    @Test func chineseAndJapaneseAreTypedCharacterByCharacterWithoutSpaces() {
        var shell = Shell()
        for partial in ["今天", "今天天气", "今天天气很"] {
            shell.hear(partial)
        }
        #expect(shell.line == "今")
        shell.hear("今天天气很好。", settled: 4)
        #expect(shell.line == "今天天气")
        #expect(shell.committer.provisional == "很好。")
        shell.finish("今天天气很好。")
        #expect(shell.line == "今天天气很好。")

        var mixed = Shell()
        mixed.hear("用git看", settled: 4)
        #expect(mixed.line == "用git", "Latin inside Chinese is one word")
        mixed.finish("用git看日志")
        #expect(mixed.line == "用git看日志")
    }

    @Test func aFinalWithFewerWordsThanWereTypedTypesNothing() {
        var shell = Shell()
        shell.hearSettled("run the tests now")
        shell.finish("run the tests")
        #expect(shell.line == "run the tests now")
        #expect(shell.chunks.count == 1)
    }
}

private extension VoiceInputManager.State {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
