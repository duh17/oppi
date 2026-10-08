import Foundation
import GhosttyVt
import Testing
@testable import Oppi

private typealias Store = SSHTerminalProgramStatusStore

private func report(
    _ state: GhosttyProgramStatusState, id: String = "", kind: GhosttyProgramStatusKind = GHOSTTY_PROGRAM_STATUS_KIND_NONE,
    app: String = "", title: String = "", message: String = "", progress: Int = -1
) -> Store.Report {
    .init(state: state, kind: kind, progress: progress, id: id, app: app, title: title, message: message)
}

private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

@Suite("SSH terminal program status store", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalProgramStatusStoreTests {
    @Test func reportReplacesItsWholeRecord() {
        let store = Store()
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: GHOSTTY_PROGRAM_STATUS_KIND_QUESTION,
                           app: "pi", title: "Pi", message: "Pick one", progress: 30))
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING))
        let root = store.root
        #expect(root?.state == GHOSTTY_PROGRAM_STATUS_STATE_WORKING)
        #expect(root?.kind == GHOSTTY_PROGRAM_STATUS_KIND_NONE)
        #expect(root?.app == "")
        #expect(root?.title == "")
        #expect(root?.message == "")
        #expect(root?.progress == -1)
        #expect(store.records.count == 1)
    }

    @Test func kindOnlyBelongsToBlockedAndProgressStaysInRange() {
        let store = Store()
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, kind: GHOSTTY_PROGRAM_STATUS_KIND_AUTH, progress: 101))
        #expect(store.root?.kind == GHOSTTY_PROGRAM_STATUS_KIND_NONE)
        #expect(store.root?.progress == -1)
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: GHOSTTY_PROGRAM_STATUS_KIND_AUTH, progress: 100))
        #expect(store.root?.kind == GHOSTTY_PROGRAM_STATUS_KIND_AUTH)
        #expect(store.root?.progress == 100)
    }

    @Test func clearRemovesTheIdAndItsSubtreeOnly() {
        let store = Store()
        for id in ["", "a", "a/b", "a/b/c", "ab", "b/a"] {
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: id))
        }
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, id: "nope"))
        #expect(store.records.count == 6)
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, id: "a"))
        #expect(Set(store.records.keys) == ["", "ab", "b/a"])
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, id: "b/a"))
        #expect(Set(store.records.keys) == ["", "ab"])
    }

    @Test func clearWithoutIdRemovesEveryRecord() {
        let store = Store()
        for id in ["", "a", "a/b"] { store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_DONE, id: id)) }
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_CLEAR))
        #expect(store.records.isEmpty)
    }

    @Test func appComesFromTheNearestAncestorAndIsNotCopied() {
        let store = Store()
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, app: "deploy"))
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "eu/web"))
        #expect(store.app(of: "eu/web") == "deploy") // "eu" never reported.
        #expect(store.record(id: "eu/web")?.app == "")
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "eu", app: "terraform"))
        #expect(store.app(of: "eu/web") == "terraform")
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "eu/web", app: "own"))
        #expect(store.app(of: "eu/web") == "own")
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, id: "eu"))
        #expect(store.app(of: "eu/web") == "deploy")
        #expect(Store().app(of: "x") == "")
    }

    @Test func leastRecentlyUpdatedRecordIsEvictedAtTheCap() {
        let store = Store()
        for index in 0..<Store.maximumRecords {
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "r\(index)"))
        }
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_DONE, id: "r0")) // Refreshed: r1 is now oldest.
        #expect(store.records.count == Store.maximumRecords)
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "new"))
        #expect(store.records.count == Store.maximumRecords)
        #expect(store.record(id: "r1") == nil)
        #expect(store.record(id: "r0")?.state == GHOSTTY_PROGRAM_STATUS_STATE_DONE)
        #expect(store.record(id: "new") != nil)
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: "new2"))
        #expect(store.record(id: "r2") == nil)
        #expect(store.record(id: "r3") != nil)
    }

    @Test func promptStartAndProcessEndKeepOnlyDoneAndError() {
        for event in [{ (store: Store) in store.promptStarted() }, { (store: Store) in store.processEnded() }] {
            let store = Store()
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING))
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, id: "a", kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION))
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_IDLE, id: "b"))
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_DONE, id: "c"))
            store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_ERROR, id: "d"))
            event(store)
            #expect(Set(store.records.keys) == ["c", "d"])
        }
    }

    @Test func displayTextLosesFormattingCharactersAndIsBounded() {
        let store = Store()
        store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_DONE, title: "ok\u{202e}evil\u{200b}",
                           message: String(repeating: "m", count: 1000)))
        #expect(store.root?.title == "okevil")
        #expect(store.root?.message == String(repeating: "m", count: SSHTerminalDisplayText.messageLimit))
    }

    @Test func childrenAndSubtreeFollowTheIdHierarchy() {
        let store = Store()
        for id in ["", "a", "a/b", "a/b/c", "ab", "x/y"] { store.apply(report(GHOSTTY_PROGRAM_STATUS_STATE_WORKING, id: id)) }
        #expect(store.children().map(\.id) == ["a", "ab"])
        #expect(store.children(of: "a").map(\.id) == ["a/b"])
        #expect(store.subtree(of: "a").map(\.id) == ["a/b", "a/b/c"])
        #expect(store.subtree().map(\.id) == ["a", "a/b", "a/b/c", "ab", "x/y"])
    }
}

@Suite("SSH terminal program status engine", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalProgramStatusEngineTests {
    private let esc = "\u{1b}"

    private func osc(_ body: String, terminator: String = "\u{1b}\\") -> Data { Data("\u{1b}]7501;\(body)\(terminator)".utf8) }

    @Test func realBytesBuildRecordsAndTheQueryReplyPrecedesDeviceAttributes() throws {
        var sent = [Data]()
        let engine = try SSHTerminalEngine { sent.append($0) }
        let store = engine.programStatus
        engine.receive(osc("state=blocked:kind=permission:app=terraform:msg=" + b64("Apply 3 to add, 1 to change?")))
        #expect(store.root?.state == GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED)
        #expect(store.root?.kind == GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION)
        #expect(store.root?.message == "Apply 3 to add, 1 to change?")
        #expect(store.app(of: "") == "terraform")

        engine.receive(osc("state=working:id=build/test:progress=40:title=" + b64("Tests")))
        #expect(store.record(id: "build/test")?.progress == 40)
        #expect(store.record(id: "build/test")?.title == "Tests")
        #expect(store.app(of: "build/test") == "terraform")

        engine.receive(osc("state=clear:id=build"))
        #expect(store.record(id: "build/test") == nil)
        #expect(store.root?.state == GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED)

        // A clipboard query still has no authority, even with the new reply allowed.
        engine.receive(Data("\u{1b}]52;c;?\u{7}\u{1b}]52;p;?\u{1b}\\".utf8))
        #expect(sent.isEmpty)

        engine.receive(osc("?") + Data("\u{1b}[c".utf8))
        #expect(sent.reduce(into: Data(), +=) == Data("\u{1b}]7501;?\u{1b}\\\u{1b}[?62;22c".utf8))
        #expect(sent.count == 2)
        #expect(store.root?.state == GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED) // A query is not a report.
    }

    @Test func lineAndParagraphSeparatorsBecomeSpacesInTitleAndMessage() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{1b}]2;one\u{2028}two\u{2029}three\u{1b}\\".utf8))
        #expect(engine.title == "one two three")
        engine.receive(osc("state=done:msg=" + b64("alpha\u{2028}beta\u{2029}gamma")))
        #expect(engine.programStatus.root?.message == "alpha beta gamma")
    }

    @Test func fullResetClearsTheShownTitle() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{1b}]2;old title\u{1b}\\".utf8))
        #expect(engine.title == "old title")
        engine.receive(Data("\u{1b}c".utf8))
        #expect(engine.title.isEmpty)
        engine.receive(Data("\u{1b}]2;new\u{1b}\\".utf8))
        #expect(engine.title == "new")
        engine.receive(Data("\u{1b}]2;\u{1b}\\".utf8))
        #expect(engine.title.isEmpty)
    }

    @Test func belTerminatedQueryAlsoGetsTheSupportReply() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.receive(osc("?", terminator: "\u{7}") + Data("\u{1b}[c".utf8))
        #expect(sent == Data("\u{1b}]7501;?\u{7}\u{1b}[?62;22c".utf8)) // libghostty echoes the query's terminator.
    }

    @Test func discardedReportsLeaveTheStoreUntouched() throws {
        var sent = [Data]()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.receive(osc("state=working:app=pi:msg=" + b64("Run")))
        engine.receive(osc("state=done:id=keep"))
        let before = engine.programStatus.records
        let bad = [
            "state=done:msg=A",                                      // not decodable base64
            "state=done:msg=" + b64("line\nbreak"),                  // control character
            "state=done:msg=" + b64("c1\u{85}"),                     // C1 control
            "state=sleeping",                                        // unknown state
            "app=pi:msg=" + b64("no state"),                         // missing state
            "state=done:id=a//b",                                    // bad id
            "state=done:id=" + String(repeating: "x", count: 33),    // segment too long
            "state=done:id=1/2/3/4/5/6/7/8/9",                       // too deep
            "state=done:msg=" + String(repeating: "QUJD", count: 800), // msg too long
            "state=clear:id=a//b",                                   // bad id on a clear must not clear all
        ]
        for body in bad { engine.receive(osc(body)) }
        #expect(engine.programStatus.records == before)
        #expect(sent.isEmpty)
    }

    @Test func promptStartExitAndResetFollowTheSpecLifetimes() throws {
        let engine = try SSHTerminalEngine { _ in }
        let store = engine.programStatus
        func seed() {
            engine.receive(osc("state=working:msg=" + b64("Run")))
            engine.receive(osc("state=blocked:kind=question:id=q"))
            engine.receive(osc("state=done:id=d"))
            engine.receive(osc("state=error:id=e"))
        }
        seed()
        engine.receive(Data("\u{1b}]133;B\u{7}\u{1b}]133;C\u{7}".utf8)) // Not a prompt start.
        #expect(store.records.count == 4)
        engine.receive(Data("\u{1b}]133;A\u{7}".utf8))
        #expect(Set(store.records.keys) == ["d", "e"])

        engine.receive(Data("\u{1b}c".utf8)) // RIS
        #expect(store.records.isEmpty)

        seed()
        engine.close()
        #expect(Set(store.records.keys) == ["d", "e"]) // Unseen outcomes outlive the process.
        engine.receive(osc("state=working:id=late"))
        #expect(store.record(id: "late") == nil)
    }

    @Test func onlyTheExactSupportReplyIsApprovedAmongOscReplies() {
        func approved(_ text: String) -> Bool {
            Array(text.utf8).withUnsafeBufferPointer { SSHTerminalEngine.isApprovedReply($0) }
        }
        #expect(approved("\u{1b}]7501;?\u{1b}\\"))
        #expect(approved("\u{1b}]7501;?\u{7}"))
        #expect(approved("\u{1b}[?62;22c"))
        #expect(approved("\u{1b}P>|Oppi\u{1b}\\"))
        for rejected in ["\u{1b}]7501;?", "\u{1b}]7501;?x\u{1b}\\", "\u{1b}]7501;?;a=b\u{7}", "\u{1b}]7501;state=done\u{1b}\\",
                         "\u{1b}]7501;?\u{1b}\\\u{1b}]52;c;\u{7}", "\u{1b}]75011;?\u{7}", "\u{1b}]52;c;\u{1b}\\",
                         "\u{1b}]7501;?\u{1b}", "\u{1b}]7501;?\u{9c}", "]7501;?\u{7}", "\u{1b}", ""] {
            #expect(!approved(rejected), "\(rejected.debugDescription)")
        }
    }
}
