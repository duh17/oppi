import Foundation
import Testing
@testable import Oppi

@Suite("SessionActivityStore")
@MainActor
struct SessionActivityStoreTests {

    // MARK: - recordToolStart / lastActivity

    @Test func recordToolStart_storesActivity() {
        let store = SessionActivityStore()
        store.recordToolStart(
            sessionId: "s1",
            tool: "Read",
            args: ["path": .string("src/main.swift")]
        )

        let activity = store.lastActivity(for: "s1")
        #expect(activity != nil)
        #expect(activity?.toolName == "Read")
        #expect(activity?.keyArg == "src/main.swift")
    }

    @Test func recordToolStart_overwritesPrevious() {
        let store = SessionActivityStore()
        store.recordToolStart(
            sessionId: "s1",
            tool: "Read",
            args: ["path": .string("file1.swift")]
        )
        store.recordToolStart(
            sessionId: "s1",
            tool: "Edit",
            args: ["path": .string("file2.swift")]
        )

        let activity = store.lastActivity(for: "s1")
        #expect(activity?.toolName == "Edit")
        #expect(activity?.keyArg == "file2.swift")
    }

    @Test func lastActivity_returnsNilForUnknownSession() {
        let store = SessionActivityStore()
        #expect(store.lastActivity(for: "unknown") == nil)
    }

    @Test func separateSessionsTrackedIndependently() {
        let store = SessionActivityStore()
        store.recordToolStart(
            sessionId: "s1",
            tool: "Read",
            args: ["path": .string("a.swift")]
        )
        store.recordToolStart(
            sessionId: "s2",
            tool: "Write",
            args: ["path": .string("b.swift")]
        )

        #expect(store.lastActivity(for: "s1")?.toolName == "Read")
        #expect(store.lastActivity(for: "s2")?.toolName == "Write")
    }

    // MARK: - clear

    @Test func clear_removesActivity() {
        let store = SessionActivityStore()
        store.recordToolStart(
            sessionId: "s1",
            tool: "Bash",
            args: ["command": .string("ls -la")]
        )

        store.clear(sessionId: "s1")
        #expect(store.lastActivity(for: "s1") == nil)
    }

    @Test func clear_doesNotAffectOtherSessions() {
        let store = SessionActivityStore()
        store.recordToolStart(
            sessionId: "s1",
            tool: "Read",
            args: ["path": .string("a.swift")]
        )
        store.recordToolStart(
            sessionId: "s2",
            tool: "Read",
            args: ["path": .string("b.swift")]
        )

        store.clear(sessionId: "s1")
        #expect(store.lastActivity(for: "s1") == nil)
        #expect(store.lastActivity(for: "s2") != nil)
    }

    // MARK: - extractKeyArg

    @Test func extractKeyArg_readUsesPath() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "Read",
            args: ["path": .string("server/src/types.ts"), "offset": .number(10)]
        )
        #expect(result == "server/src/types.ts")
    }

    @Test func extractKeyArg_writeUsesPath() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "Write",
            args: ["path": .string("new-file.swift"), "content": .string("import Foundation")]
        )
        #expect(result == "new-file.swift")
    }

    @Test func extractKeyArg_editUsesPath() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "edit",
            args: ["path": .string("Config.swift"), "oldText": .string("x"), "newText": .string("y")]
        )
        #expect(result == "Config.swift")
    }

    @Test func extractKeyArg_bashTruncatesLongCommand() {
        let longCmd = String(repeating: "a", count: 80)
        let result = SessionActivityStore.extractKeyArg(
            tool: "Bash",
            args: ["command": .string(longCmd)]
        )
        #expect(result != nil)
        #expect(result!.count == 43) // 40 chars + "..."
        #expect(result!.hasSuffix("..."))
    }

    @Test func extractKeyArg_bashKeepsShortCommand() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "bash",
            args: ["command": .string("ls -la")]
        )
        #expect(result == "ls -la")
    }

    @Test func extractKeyArg_executeUsesBashPath() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "execute",
            args: ["command": .string("npm test")]
        )
        #expect(result == "npm test")
    }

    @Test func extractKeyArg_unknownToolUsesFirstStringArg() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "CustomTool",
            args: ["alpha": .string("hello"), "beta": .number(42)]
        )
        #expect(result == "hello")
    }

    @Test func extractKeyArg_unknownToolTruncatesLongArg() {
        let longArg = String(repeating: "b", count: 100)
        let result = SessionActivityStore.extractKeyArg(
            tool: "CustomTool",
            args: ["data": .string(longArg)]
        )
        #expect(result != nil)
        #expect(result!.count == 63) // 60 chars + "..."
        #expect(result!.hasSuffix("..."))
    }

    @Test func extractKeyArg_noStringArgs_returnsNil() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "CustomTool",
            args: ["count": .number(5), "flag": .bool(true)]
        )
        #expect(result == nil)
    }

    @Test func extractKeyArg_emptyArgs_returnsNil() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "Read",
            args: [:]
        )
        #expect(result == nil)
    }

    @Test func extractKeyArg_caseInsensitive() {
        let result = SessionActivityStore.extractKeyArg(
            tool: "READ",
            args: ["path": .string("file.txt")]
        )
        #expect(result == "file.txt")
    }
}
