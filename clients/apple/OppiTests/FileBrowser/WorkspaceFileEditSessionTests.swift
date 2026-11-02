import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

// swiftlint:disable force_unwrapping

/// Scripted `/files/current` seam. Writes stay pending until the test resolves
/// them, so in-flight ordering is observable.
@MainActor
private final class ScriptedEditTransport {
    struct PendingWrite {
        let bytes: Data
        let condition: WorkspaceFileWriteCondition
        let continuation: CheckedContinuation<WorkspaceFileWriteOutcome, Never>
    }

    private(set) var pending: [PendingWrite] = []
    private(set) var writeLog: [(bytes: Data, condition: WorkspaceFileWriteCondition)] = []
    var reads: [WorkspaceFileReadOutcome] = []
    private(set) var readCount = 0

    var transport: WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { _ in
                await MainActor.run {
                    self.readCount += 1
                    return self.reads.isEmpty ? .failed : self.reads.removeFirst()
                }
            },
            write: { _, bytes, condition in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self.writeLog.append((bytes, condition))
                        self.pending.append(PendingWrite(
                            bytes: bytes,
                            condition: condition,
                            continuation: continuation
                        ))
                    }
                }
            }
        )
    }

    func resolveNext(_ outcome: WorkspaceFileWriteOutcome) {
        let write = pending.removeFirst()
        write.continuation.resume(returning: outcome)
    }
}

@MainActor
private func eventually(
    _ timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func tag(_ character: Character) -> String {
    "\"sha256-\(String(repeating: character, count: 64))\""
}

@MainActor
private final class Harness {
    let identity = WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: "wt-1", path: "notes.md")
    let store: WorkspaceFileDraftStore
    let scripted = ScriptedEditTransport()
    var buffer: String

    init(initial: String = "hello", draftDirectory: URL? = nil) {
        store = WorkspaceFileDraftStore(
            directory: draftDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("edit-tests-\(UUID().uuidString)", isDirectory: true)
        )
        buffer = initial
    }

    func open(
        disk: Data? = nil,
        etag: String? = tag("a"),
        creatable: Bool = false,
        idleDelay: Duration = .seconds(60),
        retryDelay: Duration = .milliseconds(20),
        autoSave: Bool = true
    ) -> WorkspaceFileEditSession {
        let session = WorkspaceFileEditSession(
            identity: identity,
            disk: WorkspaceFileDiskSnapshot(bytes: disk ?? Data(buffer.utf8), etag: etag, creatable: creatable),
            maxBytes: 64,
            transport: scripted.transport,
            draftStore: store,
            idleDelay: idleDelay,
            retryDelay: retryDelay,
            isAutoSaveOn: Self.autoSave(autoSave)
        )!
        buffer = session.currentText
        // harness outlives the editor callback; weak would hide a use-after-free with an empty buffer
        // swiftlint:disable:next unowned_variable_capture
        session.attachEditor { [unowned self] in self.buffer }
        return session
    }

    /// The editor's Auto-Save setting for a session this test opens. These
    /// suites are about the session's own writes, so they run with it on unless
    /// the test is about Auto-Save off.
    static func autoSave(_ isOn: Bool = true) -> @MainActor () -> Bool { { isOn } }

    func type(_ text: String, into session: WorkspaceFileEditSession) {
        buffer += text
        session.noteEdit()
    }
}

@Suite("Workspace file edit core")
@MainActor
struct WorkspaceFileEditSessionTests {
    // MARK: Byte fidelity

    @Test func exactBytesSurviveDecodeTextViewAndEncode() throws {
        let samples: [Data] = [
            Data([0xEF, 0xBB, 0xBF]) + Data("# BOM\r\nCRLF line\r\nno trailing newline".utf8),
            Data("e\u{0301} NFD and \u{00E9} NFC\n\n\n".utf8),
            Data("{\"b\":1,   \"a\" : [ 2 ]}".utf8),
            Data("mixed\r\nendings\nand\rcr\u{2028}ls".utf8),
            Data("emoji 👩‍👩‍👧 tab\tend".utf8),
        ]
        for bytes in samples {
            let text = try #require(WorkspaceFileTextCodec.decode(bytes))
            #expect(WorkspaceFileTextCodec.encode(text) == bytes)
            let textView = UITextView(usingTextLayoutManager: true)
            textView.text = text
            #expect(WorkspaceFileTextCodec.encode(textView.text) == bytes, "UITextView changed bytes")
        }
        #expect(WorkspaceFileTextCodec.decode(Data([0xC3, 0x28])) == nil, "invalid UTF-8 is not editable")
        #expect(WorkspaceFileTextCodec.decode(Data("a\u{0}b".utf8)) == nil, "NUL is not editable")
    }

    @Test func untaggedOrOversizeReadIsNotEditable() {
        let harness = Harness()
        let untagged = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data("x".utf8), etag: nil),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store
        )
        #expect(untagged == nil)
        let oversize = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data(repeating: 0x61, count: 65), etag: tag("a")),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store
        )
        #expect(oversize == nil)
    }

    /// A file the server offers to create: an empty base whose first save is
    /// conditioned on the file still not existing.
    @Test func aCreatableBaseCreatesOnItsFirstSaveAndExtendsAfter() async throws {
        let harness = Harness()
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data(), etag: nil, creatable: true),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store,
            idleDelay: .milliseconds(30), retryDelay: .milliseconds(20),
            isAutoSaveOn: Harness.autoSave()
        )
        let created = try #require(session)
        harness.buffer = created.currentText
        created.attachEditor { harness.buffer }
        #expect(created.baseCondition == .absent)

        harness.type("# Pi\n", into: created)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[0].condition == .absent, "the first save creates the file")
        #expect(harness.store.load(harness.identity)?.baseEtag == "*", "a draft keeps the creation it extends")

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { created.status == .saved })
        #expect(created.baseCondition == .version(tag("b")), "the file exists now: the next save overwrites")

        harness.type("more\n", into: created)
        created.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[1].condition == .version(tag("b")))
    }

    /// An untouched seed is not an edit: Done writes nothing, so a document that
    /// does not exist stays absent until someone changes it.
    @Test func anUntouchedCreatableBaseWritesNothing() async {
        let harness = Harness()
        let seed = Data("You are a coding agent.".utf8)
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: seed, etag: nil, creatable: true),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store,
            idleDelay: .milliseconds(20), retryDelay: .milliseconds(20),
            isAutoSaveOn: Harness.autoSave()
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }
        #expect(session.currentText == "You are a coding agent.")
        #expect(session.hasUnsavedChanges == false)
        session.detachEditor()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(harness.scripted.writeLog.isEmpty, "nothing to create: no request")
        #expect(session.status == .saved)
        #expect(session.baseCondition == .absent, "the file is still not there")
    }

    /// The first real edit of a seeded creatable base creates the file with the
    /// edited seed.
    @Test func aCreatableBaseSendsTheEditedSeedAsACreate() async {
        let harness = Harness()
        let seed = Data("You are a coding agent.".utf8)
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: seed, etag: nil, creatable: true),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store,
            idleDelay: .milliseconds(20), retryDelay: .milliseconds(20),
            isAutoSaveOn: Harness.autoSave()
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }
        harness.type(" Ship it.", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[0].condition == .absent)
        #expect(
            harness.scripted.writeLog[0].bytes == Data("You are a coding agent. Ship it.".utf8),
            "the created file holds the edited seed, not an empty prompt"
        )
    }

    @Test func identityKeysSeparateWorktreeAndServer() {
        let main = WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: nil, path: "a.md")
        let blank = WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: "  ", path: "a.md")
        let worktree = WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: "wt", path: "a.md")
        let otherServer = WorkspaceFileEditIdentity(serverId: "t", workspaceId: "w", worktreeId: nil, path: "a.md")
        #expect(main.storageKey == blank.storageKey)
        #expect(main.storageKey != worktree.storageKey)
        #expect(main.storageKey != otherServer.storageKey)
        // A Skill id that equals a workspace id is still a different file.
        let skill = WorkspaceFileEditIdentity(serverId: "s", skillId: "w", path: "a.md")
        #expect(skill.storageKey != main.storageKey)
        // A record's prompt is its own draft: per server, per record, and apart
        // from any file whose id happens to match.
        let agent = WorkspaceFileEditIdentity(serverId: "s", agentId: "w")
        let schedule = WorkspaceFileEditIdentity(serverId: "s", scheduleId: "w")
        #expect(agent.storageKey != main.storageKey)
        #expect(agent.storageKey != skill.storageKey)
        #expect(agent.storageKey != schedule.storageKey)
        #expect(agent.storageKey != WorkspaceFileEditIdentity(serverId: "t", agentId: "w").storageKey)
        #expect(schedule.storageKey != WorkspaceFileEditIdentity(serverId: "t", scheduleId: "w").storageKey)
    }

    /// A prompt's draft key is its own namespace, and the file keys drafts
    /// already on disk are stored under are byte-identical.
    @Test func promptDraftKeysAreANewNamespaceAndFileKeysAreUnchanged() {
        let agent = WorkspaceFileEditIdentity(serverId: "srv", agentId: "agent-design")
        let schedule = WorkspaceFileEditIdentity(serverId: "srv", scheduleId: "schedule-nightly")

        func digest(_ parts: [String]) -> String {
            let raw = parts.joined(separator: "\u{0}")
            return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(agent.storageKey == digest(["agent-v1", "srv", "agent-design"]))
        #expect(schedule.storageKey == digest(["schedule-v1", "srv", "schedule-nightly"]))
        // The old namespaces still produce the old keys.
        #expect(WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md").storageKey
            == digest(["v1", "srv", "w1", "", "notes.md"]))
        #expect(WorkspaceFileEditIdentity(serverId: "srv", skillId: "skill_1", path: "refs/a.md").storageKey
            == digest(["skill-v1", "srv", "skill_1", "refs/a.md"]))
    }

    /// A prompt identity round-trips through the draft store's encoding, and the
    /// path it carries is its own name (the prompt text is not in the key).
    @Test func promptIdentitiesRoundTrip() throws {
        let agent = WorkspaceFileEditIdentity(serverId: "srv", agentId: "agent-design")
        let schedule = WorkspaceFileEditIdentity(serverId: "srv", scheduleId: "schedule-nightly")
        let decodedAgent = try JSONDecoder().decode(
            WorkspaceFileEditIdentity.self,
            from: JSONEncoder().encode(agent)
        )
        let decodedSchedule = try JSONDecoder().decode(
            WorkspaceFileEditIdentity.self,
            from: JSONEncoder().encode(schedule)
        )
        #expect(decodedAgent == agent)
        #expect(decodedSchedule == schedule)
        #expect(agent.path == "Instructions.md")
        #expect(schedule.path == "Prompt.md")
    }

    @Test func draftsStoredBeforeSkillFilesStillDecodeAndSkillDraftsRoundTrip() throws {
        let legacy = Data(#"{"serverId":"s","workspaceId":"w","worktreeId":"wt","path":"a.md"}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceFileEditIdentity.self, from: legacy)
        #expect(decoded == WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: "wt", path: "a.md"))

        let skill = WorkspaceFileEditIdentity(serverId: "s", skillId: "skill_1", path: "refs/a.md")
        let store = WorkspaceFileDraftStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("edit-tests-\(UUID().uuidString)", isDirectory: true)
        )
        let draft = WorkspaceFileDraft(identity: skill, baseEtag: tag("a"), bytes: Data("x".utf8), updatedAt: Date())
        try store.save(draft)
        #expect(store.loadResult(skill) == .draft(draft))
    }

    /// The key format existing drafts are stored under. A change here strands
    /// every draft on every device, so the digests are pinned.
    @Test func draftKeysAreTheOnesExistingDraftsUse() throws {
        let workspace = WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md")
        let worktree = WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: "wt-1", path: "notes.md")
        let skill = WorkspaceFileEditIdentity(serverId: "srv", skillId: "skill_1", path: "refs/a.md")

        #expect(workspace.storageKey == "38fbdc66ee984456cb9e2cc52148ab18fb2bda8ffc9918d4bfbded4f5831342f")
        #expect(worktree.storageKey == "54f0fc06518331abc3d6b3490901a7e8f860d429a790e43352d8dcc4ebe72e7d")
        #expect(skill.storageKey == "25c4e2c6e5078f8f2016d6f49243ec27fc5d99657e061dc2d0023ec925a86691")

        // The file an earlier build left behind, read back through today's store.
        let store = WorkspaceFileDraftStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("edit-tests-\(UUID().uuidString)", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let draft = WorkspaceFileDraft(
            identity: workspace,
            baseEtag: tag("a"),
            bytes: Data("kept words".utf8),
            updatedAt: Date()
        )
        try JSONEncoder().encode(draft).write(
            to: store.directory
                .appendingPathComponent("38fbdc66ee984456cb9e2cc52148ab18fb2bda8ffc9918d4bfbded4f5831342f.draft")
        )
        #expect(store.loadResult(workspace) == .draft(draft), "an existing workspace draft still loads")
    }

    // MARK: Autosave and generations

    @Test func idleAutosaveSendsOneTaggedWriteAndClearsDraft() async {
        let harness = Harness()
        let session = harness.open(idleDelay: .milliseconds(30))
        harness.type(" world", into: session)
        harness.type("!", into: session)
        #expect(session.status == .pending)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.store.load(harness.identity)?.bytes == Data("hello world!".utf8), "draft checkpointed before the write")
        #expect(harness.scripted.writeLog[0].condition == .version(tag("a")))
        #expect(harness.scripted.writeLog[0].bytes == Data("hello world!".utf8))
        #expect(session.status == .saving)

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
        #expect(session.baseCondition == .version(tag("b")))
        #expect(harness.store.load(harness.identity) == nil)
        #expect(harness.scripted.writeLog.count == 1, "two keystrokes inside one idle window make one write")
    }

    @Test func oneWriteInFlightAndLateAckKeepsNewerEdits() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" 1", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })

        harness.type(" 2", into: session)
        session.flush()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.scripted.writeLog.count == 1, "a second write must wait for the first")

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(session.hasUnsavedChanges || session.status == .saving)
        #expect(harness.scripted.writeLog[1].condition == .version(tag("b")), "follow-up write extends the acknowledged tag")
        #expect(harness.scripted.writeLog[1].bytes == Data("hello 1 2".utf8))
        #expect(harness.store.load(harness.identity)?.baseEtag == tag("b"))

        harness.scripted.resolveNext(.saved(etag: tag("c")))
        #expect(await eventually { session.status == .saved })
        #expect(harness.store.load(harness.identity) == nil)
    }

    @Test func undoingBackToDiskNeedsNoWrite() async {
        let harness = Harness()
        let session = harness.open()
        harness.type("x", into: session)
        harness.buffer = "hello"
        session.noteEdit()
        session.flush()
        #expect(session.status == .saved)
        #expect(harness.scripted.writeLog.isEmpty)
    }

    /// A background save that outlives the budget, or one that finishes first:
    /// the background task ends exactly once and the draft is kept until saved.
    @Test(arguments: [true, false])
    func backgroundSaveEndsItsTaskOnce(expiresBeforeTheWrite: Bool) async {
        let harness = Harness()
        let tasks = FakeBackgroundTasks()
        let registry = WorkspaceFileEditSessionRegistry(observesBackground: false, backgroundTasks: tasks)
        let session = harness.open()
        registry.register(session)
        harness.type(" slow", into: session)

        registry.flushAllForBackground()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        if expiresBeforeTheWrite {
            tasks.expire()
            #expect(tasks.endedIDs == [tasks.identifier])
            #expect(harness.store.load(harness.identity)?.bytes == Data("hello slow".utf8))
        }

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved && tasks.endedCount > 0 })
        tasks.expire()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(tasks.endedIDs == [tasks.identifier])
    }

    // MARK: Conflict, deletion, and refusal

    @Test func staleWriteStopsAutosaveKeepsDraftAndTyping() async {
        let harness = Harness()
        let session = harness.open(idleDelay: .milliseconds(10))
        harness.type(" mine", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })

        harness.type(" more", into: session)
        try? await Task.sleep(for: .milliseconds(60))
        session.flush()
        #expect(harness.scripted.writeLog.count == 1, "412 stops autosave")
        #expect(session.status == .conflict)
        let draft = harness.store.load(harness.identity)
        #expect(draft?.bytes == Data("hello mine more".utf8))
        #expect(draft?.baseEtag == tag("a"), "draft keeps the stale base so recovery still sees conflict")
    }

    @Test func replaceUsesTheReviewedDiskTag() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" mine", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })

        session.replaceDiskVersion()
        #expect(harness.scripted.writeLog.count == 1, "Replace requires a reviewed disk version")

        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("theirs".utf8), etag: tag("d")))]
        await session.reviewDisk()
        #expect(session.reviewedDisk?.etag == tag("d"))
        session.replaceDiskVersion()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[1].condition == .version(tag("d")))
        #expect(harness.scripted.writeLog[1].bytes == Data("hello mine".utf8))

        // Disk moved again after review: back to conflict, no silent clobber.
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })
        #expect(session.reviewedDisk == nil)
    }

    @Test func reviewThatFindsDiskEqualToBufferResolves() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" same", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })
        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("hello same".utf8), etag: tag("e")))]
        await session.reviewDisk()
        #expect(session.status == .saved)
        #expect(session.baseCondition == .version(tag("e")))
        #expect(harness.store.load(harness.identity) == nil)
    }

    @Test func deletedFileIsNeverRecreated() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" gone", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.missing)
        #expect(await eventually { session.status == .deleted })

        harness.scripted.reads = [.missing]
        await session.reviewDisk()
        session.replaceDiskVersion()
        harness.type("!", into: session)
        session.flush()
        #expect(harness.scripted.writeLog.count == 1, "no write after 404")
        #expect(harness.store.load(harness.identity)?.bytes == Data("hello gone!".utf8))

        harness.scripted.reads = [.missing]
        #expect(await session.useDiskVersion() == .missing)
        #expect(harness.store.load(harness.identity) == nil)
    }

    @Test func useDiskVersionReplacesBufferAndDropsDraft() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" mine", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })
        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("theirs\r\n".utf8), etag: tag("f")))]
        #expect(await session.useDiskVersion() == .replaced("theirs\r\n"))
        harness.buffer = "theirs\r\n"
        #expect(session.status == .saved)
        #expect(session.baseCondition == .version(tag("f")))
        #expect(harness.store.load(harness.identity) == nil)

        harness.type("+", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[1].condition == .version(tag("f")), "autosave resumes from the disk version")
    }

    @Test func serverRefusalStopsAutosaveAndKeepsDraft() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" x", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.rejected(status: 403, message: "Path outside sandbox workspace"))
        #expect(await eventually { session.status == .failed("Path outside sandbox workspace") })
        harness.type("y", into: session)
        session.flush()
        #expect(harness.scripted.writeLog.count == 1)
        #expect(harness.store.load(harness.identity) != nil)
    }

    @Test func oversizeBufferIsNotSentAndRecoversOnEdit() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(String(repeating: "z", count: 80), into: session)
        session.flush()
        #expect(session.status == .tooLarge)
        #expect(harness.scripted.writeLog.isEmpty)
        harness.buffer = "hello small"
        session.noteEdit()
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
    }

    // MARK: Transport failure

    @Test func notSentRetriesWithTheSameTag() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" offline", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.notSent)
        #expect(await eventually { session.status == .offline || harness.scripted.pending.count == 1 })
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[1].condition == .version(tag("a")))
        #expect(harness.scripted.readCount == 0, "a request that never left needs no re-read")
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
    }

    @Test func unknownOutcomeThatLandedIsAcknowledgedWithoutResend() async {
        let harness = Harness()
        let session = harness.open()
        harness.type(" landed", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("hello landed".utf8), etag: tag("b")))]
        harness.scripted.resolveNext(.unknown)
        #expect(await eventually { session.status == .saved })
        #expect(harness.scripted.readCount == 1)
        #expect(harness.scripted.writeLog.count == 1)
        #expect(session.baseCondition == .version(tag("b")))
    }

    @Test func unknownOutcomeRereadsBeforeRetryAndNeverClobbers() async {
        // Not landed: disk still has the base tag, so the same write is retried.
        let harness = Harness()
        let session = harness.open()
        harness.type(" retry", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.reads = [.failed, .snapshot(WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: tag("a")))]
        harness.scripted.resolveNext(.unknown)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.readCount == 2, "a failed re-read is retried before any write")
        #expect(harness.scripted.writeLog[1].condition == .version(tag("a")))
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })

        // Someone else wrote: conflict, draft kept, no write.
        let other = Harness()
        let second = other.open()
        other.type(" mine", into: second)
        second.flush()
        #expect(await eventually { other.scripted.pending.count == 1 })
        other.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("agent".utf8), etag: tag("z")))]
        other.scripted.resolveNext(.unknown)
        #expect(await eventually { second.status == .conflict })
        #expect(other.scripted.writeLog.count == 1)
        #expect(other.store.load(other.identity)?.bytes == Data("hello mine".utf8))
    }

    /// A create whose answer was lost, and the file is still absent: the create
    /// did not land, so the same save goes again instead of stranding the editor.
    @Test func unknownOutcomeOfACreateRetriesTheCreate() async {
        let harness = Harness()
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data(), etag: nil, creatable: true),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store,
            idleDelay: .milliseconds(20), retryDelay: .milliseconds(20),
            isAutoSaveOn: Harness.autoSave()
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }
        harness.type("# Pi\n", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })

        harness.scripted.reads = [.creatable]
        harness.scripted.resolveNext(.unknown)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog.count == 2, "the create is sent again")
        #expect(harness.scripted.writeLog[1].condition == .absent)
        #expect(harness.scripted.writeLog[1].bytes == Data("# Pi\n".utf8))
        #expect(session.status != .conflict, "a lost create is not a conflict")

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
        #expect(session.baseCondition == .version(tag("b")))
    }

    /// The file a create would write is there first: 412 is the editor's
    /// conflict, Review finds the disk version, and Use Disk Version takes it.
    @Test func aStaleCreateReviewsAndTakesTheDiskVersion() async {
        let harness = Harness()
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data(), etag: nil, creatable: true),
            maxBytes: 64, transport: harness.scripted.transport, draftStore: harness.store,
            idleDelay: .seconds(60), retryDelay: .milliseconds(20),
            isAutoSaveOn: Harness.autoSave()
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }
        harness.type("mine\n", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })

        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("theirs\n".utf8), etag: tag("b")))]
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })

        let reviewed = await session.reviewDisk()
        #expect(reviewed == .snapshot(WorkspaceFileDiskSnapshot(bytes: Data("theirs\n".utf8), etag: tag("b"))))
        #expect(session.status == .conflict, "Review keeps the conflict until the person chooses")

        let result = await session.useDiskVersion()
        // The editor owns the live buffer, so the disk text comes back as the
        // replacement the page applies; the session's own bytes are the disk's.
        #expect(result == .replaced("theirs\n"))
        #expect(session.status == .saved)
        #expect(session.baseCondition == .version(tag("b")))
        #expect(session.hasUnsavedChanges == false)
    }

    /// A draft kept for a file that was never created reopens on the creation it
    /// extends, so its next save is still a create — and reopening writes nothing:
    /// recovery is not consent.
    @Test func aKeptDraftWithTheCreationBaseReopensAsACreate() async {
        let harness = Harness()
        try? harness.store.save(WorkspaceFileDraft(
            identity: harness.identity, baseEtag: "*", bytes: Data("kept words".utf8), updatedAt: Date()
        ))
        let reopened = harness.open(
            disk: Data(),
            etag: nil,
            creatable: true,
            idleDelay: .milliseconds(20),
            autoSave: false
        )
        #expect(reopened.recoveredDraft)
        #expect(reopened.currentText == "kept words")
        #expect(reopened.baseCondition == .absent)
        #expect(reopened.status == .pending, "the kept draft is unsaved")

        try? await Task.sleep(for: .milliseconds(120))
        #expect(harness.scripted.writeLog.isEmpty, "reopening a creatable draft never creates the file")

        reopened.saveNow()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog.count == 1)
        #expect(harness.scripted.writeLog[0].condition == .absent, "the kept draft still extends the create")
        #expect(harness.scripted.writeLog[0].bytes == Data("kept words".utf8))
    }

    // MARK: Auto-Save

    /// The walk-through with Auto-Save off: typing and its idle timer, a background
    /// flush, the page going away, an answer nothing could read, and Review of a
    /// create that never landed all write nothing. Reopening the kept draft writes
    /// nothing either, and only a person's Save writes — once.
    @Test func autoSaveOffWritesNothingUntilAPersonSaves() async {
        let harness = Harness()
        let session = harness.open(
            disk: Data(),
            etag: nil,
            creatable: true,
            idleDelay: .milliseconds(20),
            autoSave: false
        )
        harness.type(" edited", into: session)
        #expect(session.status == .pending)

        // The idle deadline came and went: nothing was sent, and the draft has it.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(harness.scripted.writeLog.isEmpty, "no idle save with Auto-Save off")
        #expect(harness.store.load(harness.identity)?.bytes == Data(" edited".utf8), "the draft keeps it")

        // Backgrounding flushes; the page going away detaches. Both checkpoint.
        session.flush()
        session.detachEditor()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.isEmpty, "a flush and a detach only checkpoint")

        // An answer nothing could read, then Review of a create that never landed.
        session.attachEditor { harness.buffer }
        harness.scripted.reads = [.failed]
        _ = await session.reviewDisk()
        harness.scripted.reads = [.creatable]
        _ = await session.reviewDisk()
        #expect(session.status == .pending)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.isEmpty, "Review never sends a create the person did not ask for")

        // Reopening the kept draft: still nothing written.
        let reopened = harness.open(
            disk: Data(),
            etag: nil,
            creatable: true,
            idleDelay: .milliseconds(20),
            autoSave: false
        )
        #expect(reopened.recoveredDraft)
        #expect(reopened.currentText == " edited")
        #expect(reopened.baseCondition == .absent)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(harness.scripted.writeLog.isEmpty, "reopening with a draft never creates")

        // Done → Save: exactly one write, and no second one after it.
        reopened.saveNow()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog.count == 1)
        #expect(harness.scripted.writeLog[0].condition == .absent)
        #expect(harness.scripted.writeLog[0].bytes == Data(" edited".utf8))
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { reopened.status == .saved })
        reopened.flush()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.count == 1, "a confirmed save does not repeat itself")
    }

    /// Done → Discard Changes: nothing is written and the kept draft goes.
    @Test func discardingWritesNothingAndDropsTheDraft() async {
        let harness = Harness()
        let session = harness.open(idleDelay: .milliseconds(20), autoSave: false)
        harness.type(" thrown away", into: session)
        // The idle timer is a checkpoint with Auto-Save off: the draft has it.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.store.load(harness.identity) != nil)
        #expect(harness.scripted.writeLog.isEmpty)

        session.discardChanges()

        #expect(harness.scripted.writeLog.isEmpty, "Discard Changes writes nothing")
        #expect(harness.store.load(harness.identity) == nil, "the draft is gone")
        #expect(session.hasUnsavedChanges == false)
        #expect(session.hasUnconfirmedChanges == false)
        #expect(session.status == .saved)
    }

    /// The editor's text view is `currentText` while it is attached, so
    /// discarding has to drop that buffer too: restoring the disk bytes alone
    /// left the discarded edits on screen and handed them back to the reader.
    @Test func discardingDropsTheEditorsOwnBuffer() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" thrown away", into: session)
        #expect(session.currentText == "hello thrown away")

        #expect(session.discardChanges())
        // What the page does next: the editor goes away, and the reader reads
        // the session's text.
        session.detachEditor()

        #expect(session.currentText == "hello", "the discarded edits are gone, not just unsent")
        #expect(session.hasUnsavedChanges == false)
        #expect(session.hasUnconfirmedChanges == false, "Done has nothing left to ask")
    }

    /// A write in flight holds the bytes it is writing, so a discard now would
    /// show disk while the server takes the buffer: it is refused, and the
    /// notice says why. (A write that carries every edit is the exception; see
    /// `discardingClosesWhenTheFlightCarriesEveryEdit`.)
    @Test func discardingIsRefusedWhileAWriteIsInFlight() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        session.saveNow()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        // Typed after the save went: these bytes are not in the write out.
        harness.type(" two", into: session)

        #expect(session.discardChanges() == false, "a write in flight refuses the discard")
        #expect(session.status == .saving)
        #expect(session.currentText == "hello one two", "the edits stay")
        #expect(session.draftNotice != nil, "the notice line says why")

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .pending })
        #expect(session.discardChanges(), "and it goes once the write landed")
    }

    /// A person's save that arrives during a write waits for it and goes next,
    /// as their own: exactly two writes, and the second one carries the newer
    /// bytes.
    @Test func aSaveDuringAWriteIsSentAfterIt() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        #expect(session.saveNow())
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[0].bytes == Data("hello one".utf8))

        // ⌘S again, with newer edits, while the first write is still out.
        harness.type(" two", into: session)
        #expect(session.saveNow(), "their save is queued, not dropped")
        #expect(harness.scripted.writeLog.count == 1, "one write at a time")

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { harness.scripted.writeLog.count == 2 })
        #expect(harness.scripted.writeLog[1].bytes == Data("hello one two".utf8))
        #expect(harness.scripted.writeLog[1].condition == .version(tag("b")), "against the tag it just got")
        harness.scripted.resolveNext(.saved(etag: tag("c")))
        #expect(await eventually { session.status == .saved })
        #expect(session.hasUnconfirmedChanges == false)
        #expect(harness.scripted.writeLog.count == 2, "and nothing more")
    }

    /// A save that cannot go says so instead of closing: Done keeps the editor
    /// open and its banner is what the person reads.
    @Test func saveNowReportsWhenNothingWasSent() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(String(repeating: "x", count: 80), into: session)

        #expect(session.saveNow() == false, "over the server's limit")
        #expect(session.status == .tooLarge)
        #expect(harness.scripted.writeLog.isEmpty)
    }

    /// A retry resends the bytes it started with, never the buffer: a person's
    /// save stays the save they asked for.
    @Test func aConfirmedRetryResendsItsOwnBytes() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        session.saveNow()
        #expect(await eventually { harness.scripted.pending.count == 1 })

        harness.scripted.resolveNext(.notSent)
        #expect(await eventually { session.status == .offline })
        // Typed while the retry waits: the retry still sends what was confirmed.
        harness.type(" two", into: session)

        #expect(await eventually { harness.scripted.writeLog.count == 2 })
        #expect(harness.scripted.writeLog[1].bytes == Data("hello one".utf8))
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .pending }, "the newer edits are still unsaved")
        #expect(session.currentText == "hello one two")
    }

    /// A retry that Auto-Save no longer allows is not owed: the edits are
    /// unsaved, not unreachable, and the banner stops saying Offline.
    @Test func aGatedRetryLeavesTheEditsPending() async {
        let harness = Harness()
        var isOn = true
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: tag("a")),
            maxBytes: 64,
            transport: harness.scripted.transport,
            draftStore: harness.store,
            idleDelay: .milliseconds(20),
            retryDelay: .milliseconds(120),
            isAutoSaveOn: { isOn }
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }
        harness.type(" one", into: session)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.notSent)
        #expect(await eventually { session.status == .offline })

        isOn = false
        #expect(await eventually { session.status == .pending }, "the retry is not owed with Auto-Save off")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.count == 1, "nothing was retried")
        #expect(harness.store.load(harness.identity)?.bytes == Data("hello one".utf8))
    }

    /// Editing back to the disk bytes is clean: the save has nothing to send,
    /// and Done does not ask.
    @Test func revertingToTheDiskBytesIsClean() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" x", into: session)
        harness.buffer = "hello"
        session.noteEdit()

        #expect(session.saveNow())
        #expect(harness.scripted.writeLog.isEmpty, "nothing to send")
        #expect(session.status == .saved)
        #expect(session.hasUnsavedChanges == false)
        #expect(session.hasUnconfirmedChanges == false, "Done has nothing left to ask")
    }

    /// A queued save belongs to the version it was made against. When the write
    /// ahead of it comes back stale, that save must never be sent: Replace (or
    /// Use Disk, then a save) decides what the buffer becomes, and a stranded
    /// queue would otherwise write the old bytes over the reviewed version.
    @Test func aStaleFlightDropsTheQueuedSave() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        #expect(session.saveNow())
        #expect(await eventually { harness.scripted.pending.count == 1 })

        // A second save, queued behind the first, and then more typing: the
        // queued bytes are already older than the buffer.
        harness.type(" two", into: session)
        #expect(session.saveNow())
        #expect(harness.scripted.writeLog.count == 1)
        harness.type(" three", into: session)

        // The first write lost: someone else wrote the file.
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })

        // Review, then Replace: exactly one more write, with the buffer.
        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("theirs".utf8), etag: tag("c")))]
        _ = await session.reviewDisk()
        session.replaceDiskVersion()
        #expect(await eventually { harness.scripted.writeLog.count == 2 })
        harness.scripted.resolveNext(.saved(etag: tag("d")))
        #expect(await eventually { session.status == .saved })

        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.count == 2, "the queued save must not outlive the conflict")
        #expect(
            harness.scripted.writeLog[1].bytes == Data("hello one two three".utf8),
            "Replace writes the buffer the person kept"
        )
    }

    /// Use Disk drops a queued save too: the bytes it would have sent are the
    /// ones the person just discarded. The write that follows is the session's
    /// own (Auto-Save on), so nothing else clears the queue for it.
    @Test func useDiskDropsTheQueuedSave() async {
        let harness = Harness()
        let session = harness.open(idleDelay: .milliseconds(20), autoSave: true)
        harness.type(" one", into: session)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        // The idle save is in flight; this save waits behind it.
        harness.type(" two", into: session)
        #expect(session.saveNow())
        #expect(harness.scripted.writeLog.count == 1)

        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })
        harness.scripted.reads = [.snapshot(WorkspaceFileDiskSnapshot(bytes: Data("theirs".utf8), etag: tag("c")))]
        let result = await session.useDiskVersion()
        #expect(result == .replaced("theirs"))
        // The page applies the replacement to its text view; the harness's buffer
        // is that text view.
        harness.buffer = "theirs"

        // Typing again, and the idle save writes what is on screen now.
        harness.type(" more", into: session)
        #expect(await eventually { harness.scripted.writeLog.count == 2 })
        harness.scripted.resolveNext(.saved(etag: tag("d")))
        #expect(await eventually { session.status == .saved })

        try? await Task.sleep(for: .milliseconds(120))
        #expect(harness.scripted.writeLog.count == 2, "the queued save must not outlive Use Disk")
        #expect(harness.scripted.writeLog[1].bytes == Data("theirs more".utf8))
        #expect(harness.scripted.writeLog.allSatisfy { $0.bytes != Data("hello one two".utf8) })
    }

    /// A queued save is not the session's own write: turning Auto-Save off while
    /// its flight fails must not strand it.
    @Test func aGatedRetrySendsTheQueuedSave() async {
        let harness = Harness()
        var isOn = true
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: tag("a")),
            maxBytes: 64,
            transport: harness.scripted.transport,
            draftStore: harness.store,
            idleDelay: .milliseconds(20),
            retryDelay: .seconds(60),
            isAutoSaveOn: { isOn }
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }

        // The idle save is in flight when the person saves over it.
        harness.type(" one", into: session)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.type(" two", into: session)
        #expect(session.saveNow(), "queued behind the idle save")

        isOn = false
        harness.scripted.resolveNext(.notSent)
        #expect(
            await eventually { harness.scripted.writeLog.count == 2 },
            "the person's save goes even though the retry is gated"
        )
        #expect(harness.scripted.writeLog[1].bytes == Data("hello one two".utf8))
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
    }

    /// A buffer over the limit stays Too Large after the flight ahead of it
    /// lands: the acknowledge must not call it saved.
    @Test func tooLargeSurvivesTheFlightItWaitedFor() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        #expect(session.saveNow())
        #expect(await eventually { harness.scripted.pending.count == 1 })

        harness.type(String(repeating: "x", count: 80), into: session)
        #expect(session.saveNow() == false, "over the server's limit")
        #expect(session.status == .tooLarge)

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.status == .tooLarge, "the banner still says why the save did not go")
        #expect(harness.scripted.writeLog.count == 1)
    }

    /// Quitting without saving closes when the write out already carries every
    /// edit: nothing would be lost.
    @Test func discardingClosesWhenTheFlightCarriesEveryEdit() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        #expect(session.saveNow())
        #expect(await eventually { harness.scripted.pending.count == 1 })

        #expect(session.discardChanges(from: .commandLine), "the write out is this buffer")
        #expect(session.draftNotice == nil, "nothing to warn about")
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
    }

    /// A refused Discard says so in its own words (Done's, or Vim's), and the
    /// notice goes once the write it waited for lands.
    @Test func aRefusedDiscardNoticeClearsWhenTheWriteLands() async {
        let harness = Harness()
        let session = harness.open(autoSave: false)
        harness.type(" one", into: session)
        #expect(session.saveNow())
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.type(" two", into: session)

        #expect(session.discardChanges() == false)
        let fromPage = session.draftNotice
        #expect(fromPage?.contains("Discard Changes") == true, "Done's wording: \(fromPage ?? "none")")

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .pending })
        #expect(session.draftNotice == nil, "the notice described a moment that is over")

        // Vim's own wording, on the same refusal.
        #expect(session.saveNow())
        #expect(await eventually { harness.scripted.writeLog.count == 2 })
        harness.type(" three", into: session)
        #expect(session.discardChanges(from: .commandLine) == false)
        #expect(session.draftNotice?.contains("quit") == true, "Vim's wording: \(session.draftNotice ?? "none")")
        harness.scripted.resolveNext(.saved(etag: tag("c")))
        #expect(await eventually { session.draftNotice == nil })
    }

    /// ⌘S and Vim's `:w` are the person's save: one write, and Done then closes
    /// without asking again.
    @Test func aConfirmedSaveWritesOnceAndIsNotAskedForTwice() async {
        let harness = Harness()
        let session = harness.open(idleDelay: .seconds(60), autoSave: false)
        harness.type(" one", into: session)
        #expect(session.hasUnconfirmedChanges, "Done would ask for this edit")

        session.saveNow()

        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog.count == 1)
        #expect(harness.scripted.writeLog[0].bytes == Data("hello one".utf8))
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
        #expect(session.hasUnconfirmedChanges == false)
        session.flush()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.count == 1, "nothing is written again after the confirmed save")
    }

    /// Auto-Save on is today's behaviour: the idle save runs unchanged.
    @Test func autoSaveOnStillWritesAfterTheIdleDelay() async {
        let harness = Harness()
        let session = harness.open(idleDelay: .milliseconds(20), autoSave: true)
        harness.type(" autosaved", into: session)
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[0].bytes == Data("hello autosaved".utf8))
    }

    /// Toggling while the editor is open takes effect at once: on starts the idle
    /// save unsaved edits are owed, and off cancels the timer and keeps the draft.
    @Test func togglingAutoSaveWhileOpenStartsAndStopsTheIdleSave() async {
        let harness = Harness()
        var isOn = false
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: tag("a")),
            maxBytes: 64,
            transport: harness.scripted.transport,
            draftStore: harness.store,
            idleDelay: .milliseconds(20),
            retryDelay: .milliseconds(20),
            isAutoSaveOn: { isOn }
        )!
        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }

        harness.type(" kept", into: session)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.scripted.writeLog.isEmpty, "off: no save is scheduled")
        #expect(session.status == .pending)

        isOn = true
        session.autoSaveSettingChanged(isOn: true)
        #expect(await eventually { harness.scripted.pending.count == 1 }, "on: the idle save starts at once")
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })

        isOn = false
        harness.type(" more", into: session)
        session.autoSaveSettingChanged(isOn: false)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(harness.scripted.writeLog.count == 1, "off: the idle timer is cancelled")
        #expect(session.status == .pending)
        #expect(harness.store.load(harness.identity)?.bytes == Data("hello kept more".utf8), "the draft keeps it")
    }

    // MARK: Drafts and recovery

    @Test func draftRecoveryResumesOrOpensInConflict() throws {
        let harness = Harness()
        try harness.store.save(WorkspaceFileDraft(
            identity: harness.identity, baseEtag: tag("a"), bytes: Data("draft".utf8), updatedAt: Date()
        ))
        let resumed = harness.open(disk: Data("hello".utf8), etag: tag("a"))
        #expect(resumed.recoveredDraft)
        #expect(resumed.currentText == "draft")
        #expect(resumed.status == .pending)

        let moved = Harness()
        try moved.store.save(WorkspaceFileDraft(
            identity: moved.identity, baseEtag: tag("a"), bytes: Data("draft".utf8), updatedAt: Date()
        ))
        let conflicted = moved.open(disk: Data("agent".utf8), etag: tag("x"))
        #expect(conflicted.recoveredDraft)
        #expect(conflicted.status == .conflict)
        #expect(conflicted.currentText == "draft")

        let same = Harness()
        try same.store.save(WorkspaceFileDraft(
            identity: same.identity, baseEtag: tag("q"), bytes: Data("hello".utf8), updatedAt: Date()
        ))
        let clean = same.open(disk: Data("hello".utf8), etag: tag("a"))
        #expect(!clean.recoveredDraft)
        #expect(same.store.load(same.identity) == nil, "a draft equal to disk is discarded")
    }

    @Test func draftsAreProtectedFilesNotDefaults() throws {
        let harness = Harness()
        let draft = WorkspaceFileDraft(
            identity: harness.identity, baseEtag: tag("a"), bytes: Data("secret\r\n".utf8), updatedAt: Date()
        )
        try harness.store.save(draft)
        #expect(harness.store.load(harness.identity) == draft)
        let url = harness.store.fileURL(for: harness.identity)
        #expect(try Data(contentsOf: url).count > draft.bytes.count, "draft is a file on disk")
#if !targetEnvironment(simulator)
        // The Simulator reports no class for a file written with a protection option (one
        // set afterwards through `setResourceValue` it does report); devices do.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen)
#endif
        #expect(!url.lastPathComponent.contains("notes"), "file names do not leak paths")

        // The shared store lives in Application Support, and a save through it
        // leaves no trace of the draft in UserDefaults.
        let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let shared = WorkspaceFileDraftStore.shared
        #expect(shared.directory.standardizedFileURL.path.hasPrefix(appSupport.standardizedFileURL.path))
        let marker = "draft-marker-\(UUID().uuidString)"
        let probeWorkspaceId = UUID().uuidString
        let probe = WorkspaceFileEditIdentity(serverId: "probe", workspaceId: probeWorkspaceId, worktreeId: nil, path: "p.md")
        try shared.save(WorkspaceFileDraft(identity: probe, baseEtag: tag("a"), bytes: Data(marker.utf8), updatedAt: Date()))
        defer { shared.remove(probe) }
        #expect(FileManager.default.fileExists(atPath: shared.fileURL(for: probe).path))
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        #expect(!defaults.keys.contains { $0.contains(probe.storageKey) || $0.contains(probeWorkspaceId) })
        #expect(!defaults.values.contains { value in
            if let data = value as? Data { return data.range(of: Data(marker.utf8)) != nil }
            if let string = value as? String { return string.contains(marker) }
            return false
        }, "draft bytes must not reach UserDefaults")
        let other = WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md")
        #expect(harness.store.load(other) == nil, "main checkout never reads the worktree draft")
    }
}

@Suite("Workspace file edit persistence and recovery")
@MainActor
struct WorkspaceFileEditRecoveryTests {
    private func bannerLines(_ session: WorkspaceFileEditSession) -> [String] {
        WorkspaceFileEditStatusPresentation.bannerLines(
            status: session.status,
            maxBytes: session.maxBytes,
            draftPersistenceError: session.draftPersistenceError,
            draftNotice: session.draftNotice,
            recovered: session.recoveredDraft
        )
    }

    @Test func failedCheckpointIsSurfacedAndNeverClaimsEditsAreKept() async throws {
        // A regular file where the draft directory should be: every save fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("draft-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let harness = Harness(draftDirectory: blocker.appendingPathComponent("drafts", isDirectory: true))
        let session = harness.open()
        harness.type(" offline", into: session)
        session.flush()
        #expect(session.draftPersistenceError != nil, "a failed checkpoint must be visible")
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.notSent)
        #expect(await eventually { session.status == .offline })

        let offline = bannerLines(session).joined(separator: " ")
        #expect(!offline.contains("kept"), "offline banner claimed a draft that was never stored: \(offline)")
        #expect(offline.contains("could not be stored"))

        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.stale)
        #expect(await eventually { session.status == .conflict })
        let conflict = bannerLines(session).joined(separator: " ")
        #expect(!conflict.contains("kept"), "conflict banner claimed a draft that was never stored: \(conflict)")
        #expect(conflict.contains("could not be stored"))

        // Control: with a writable store, the same states do claim the draft.
        let writable = Harness()
        let saved = writable.open()
        writable.type(" x", into: saved)
        saved.flush()
        #expect(await eventually { writable.scripted.pending.count == 1 })
        writable.scripted.resolveNext(.stale)
        #expect(await eventually { saved.status == .conflict })
        #expect(saved.draftPersistenceError == nil)
        #expect(bannerLines(saved).joined().contains("kept on this device"))
    }

    @Test func unreadableDraftIsMovedAsideNeverDeleted() throws {
        // Corrupt draft file.
        let corrupt = Harness()
        try FileManager.default.createDirectory(at: corrupt.store.directory, withIntermediateDirectories: true)
        let garbage = Data([0x7B, 0xFF, 0x00, 0x42])
        try garbage.write(to: corrupt.store.fileURL(for: corrupt.identity))
        let session = corrupt.open()
        #expect(session.draftNotice != nil)
        #expect(!session.recoveredDraft)
        let moved = corrupt.store.quarantinedFiles(for: corrupt.identity)
        #expect(moved.count == 1)
        #expect(try Data(contentsOf: try #require(moved.first)) == garbage, "quarantine keeps the exact bytes")
        #expect(corrupt.store.loadResult(corrupt.identity) == .none)

        // Later checkpoints use the live slot and never touch the quarantined file.
        corrupt.type(" new", into: session)
        session.checkpoint()
        #expect(corrupt.store.load(corrupt.identity)?.bytes == Data("hello new".utf8))
        #expect(try Data(contentsOf: moved[0]) == garbage)

        // Draft bytes that are not UTF-8.
        let invalid = Harness()
        try invalid.store.save(WorkspaceFileDraft(
            identity: invalid.identity, baseEtag: tag("a"), bytes: Data([0xC3, 0x28]), updatedAt: Date()
        ))
        let reopened = invalid.open()
        #expect(reopened.draftNotice != nil)
        #expect(invalid.store.quarantinedFiles(for: invalid.identity).count == 1)
    }

    @Test func refusedNulDraftIsRecoveredNotDropped() async throws {
        let harness = Harness()
        let nulDraft = Data("keep\u{0}me".utf8)
        try harness.store.save(WorkspaceFileDraft(
            identity: harness.identity, baseEtag: tag("a"), bytes: nulDraft, updatedAt: Date()
        ))
        let session = harness.open()
        #expect(session.recoveredDraft)
        #expect(WorkspaceFileTextCodec.encode(session.currentText) == nulDraft)
        #expect(session.status == .pending)
        #expect(harness.store.load(harness.identity)?.bytes == nulDraft, "draft stays until the server accepts bytes")

        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.rejected(status: 415, message: "Invalid UTF-8"))
        #expect(await eventually { session.status == .failed("Invalid UTF-8") })
        #expect(harness.store.load(harness.identity)?.bytes == nulDraft)
    }

    private func liveTooLarge(_ harness: Harness) async -> WorkspaceFileEditSession {
        let session = harness.open()
        harness.type(String(repeating: "z", count: 80), into: session)
        session.flush()
        #expect(session.status == .tooLarge)
        return session
    }

    private func liveOffline(_ harness: Harness) async -> WorkspaceFileEditSession {
        // Long enough to observe .offline; the caller waits past it to prove
        // the retry was cancelled.
        let session = harness.open(retryDelay: .milliseconds(150))
        harness.type(" offline", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        harness.scripted.resolveNext(.notSent)
        #expect(await eventually { session.status == .offline })
        return session
    }

    @Test func deletedFileDraftReopensWithoutWriting() async throws {
        let harness = Harness()
        let registry = WorkspaceFileEditSessionRegistry(observesBackground: false)
        #expect(WorkspaceFileEditRecovery.sessionForMissingFile(
            identity: harness.identity, maxBytes: 64, transport: harness.scripted.transport,
            registry: registry, draftStore: harness.store
        ) == nil, "no draft: nothing to recover")

        try harness.store.save(WorkspaceFileDraft(
            identity: harness.identity, baseEtag: tag("a"), bytes: Data("orphan".utf8), updatedAt: Date()
        ))
        let session = try #require(WorkspaceFileEditRecovery.sessionForMissingFile(
            identity: harness.identity, maxBytes: 64, transport: harness.scripted.transport,
            registry: registry, draftStore: harness.store
        ))
        #expect(registry.session(for: harness.identity) === session)
        #expect(session.status == .deleted)
        #expect(session.currentText == "orphan")
        #expect(WorkspaceFileEditStatusPresentation.offersConflictActions(session.status), "Review is offered")

        harness.buffer = session.currentText
        session.attachEditor { harness.buffer }
        harness.type("!", into: session)
        session.flush()
        harness.scripted.reads = [.missing]
        await session.reviewDisk()
        session.replaceDiskVersion()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.scripted.writeLog.isEmpty, "a deleted file is never written or recreated")
        #expect(session.status == .deleted)
        #expect(harness.store.load(harness.identity)?.bytes == Data("orphan!".utf8))

        // A live unsaved session that is too large or offline takes the same
        // transition: deleted, no write, Review offered, draft retained.
        for makeLive in [liveTooLarge, liveOffline] {
            let live = Harness()
            let liveRegistry = WorkspaceFileEditSessionRegistry(observesBackground: false)
            let liveSession = await makeLive(live)
            liveRegistry.register(liveSession)
            let writesBefore = live.scripted.writeLog.count
            let reopened = try #require(WorkspaceFileEditRecovery.sessionForMissingFile(
                identity: live.identity, maxBytes: 64, transport: live.scripted.transport,
                registry: liveRegistry, draftStore: live.store
            ))
            #expect(reopened === liveSession)
            #expect(reopened.status == .deleted)
            #expect(WorkspaceFileEditStatusPresentation.offersConflictActions(reopened.status))
            #expect(live.store.load(live.identity)?.bytes == WorkspaceFileTextCodec.encode(live.buffer))
            live.type("?", into: reopened)
            reopened.flush()
            try? await Task.sleep(for: .milliseconds(400))
            #expect(live.scripted.writeLog.count == writesBefore, "no write or retry after a missing-file open")
            #expect(reopened.status == .deleted)
            #expect(live.store.load(live.identity)?.bytes == WorkspaceFileTextCodec.encode(live.buffer))
        }

        // An unreadable draft for a missing file is left in place. Fresh
        // registry: the live session above has the same identity.
        let unreadable = Harness()
        try FileManager.default.createDirectory(at: unreadable.store.directory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: unreadable.store.fileURL(for: unreadable.identity))
        #expect(WorkspaceFileEditRecovery.sessionForMissingFile(
            identity: unreadable.identity, maxBytes: 64, transport: unreadable.scripted.transport,
            registry: WorkspaceFileEditSessionRegistry(observesBackground: false), draftStore: unreadable.store
        ) == nil)
        #expect(try Data(contentsOf: unreadable.store.fileURL(for: unreadable.identity)) == Data([0x01]))
    }

    /// The write in flight answers after the file went missing. The session
    /// already cancelled that write, so its answer belongs to nothing: the
    /// queue's token guard drops it. A late `.saved` must not mark the edits
    /// saved and remove the draft they are kept in, and a late `.notSent` must
    /// not arm a retry that writes a file the server says is gone.
    @Test(arguments: [WorkspaceFileWriteOutcome.saved(etag: tag("b")), .notSent])
    func lateWriteAnswerAfterFileWentMissingChangesNothing(lateAnswer: WorkspaceFileWriteOutcome) async {
        let harness = Harness()
        let session = harness.open(retryDelay: .milliseconds(150))
        harness.type(" gone", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(session.status == .saving)

        session.noteFileMissing()
        #expect(session.status == .deleted)
        let keptDraft = harness.store.load(harness.identity)
        #expect(keptDraft?.bytes == Data("hello gone".utf8), "the edits are kept as a draft")

        harness.scripted.resolveNext(lateAnswer)
        // Well past the retry delay a late `.notSent` would have waited out.
        try? await Task.sleep(for: .milliseconds(400))

        #expect(session.status == .deleted, "the late answer is dropped")
        #expect(harness.store.load(harness.identity) == keptDraft, "the kept draft is untouched")
        #expect(harness.scripted.writeLog.count == 1, "no retry against a deleted file")
        #expect(session.hasUnsavedChanges)
    }
}

@Suite("Workspace file editor surface")
@MainActor
struct WorkspaceFileEditorSurfaceTests {
    private func makeController(_ harness: Harness, autoSave: Bool = true) -> (WorkspaceFileEditorViewController, UIWindow) {
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data("# Title\r\nbody".utf8), etag: tag("a")),
            maxBytes: 1_024,
            transport: harness.scripted.transport,
            draftStore: harness.store,
            // This suite drives the editor with the session's own saves on, so a
            // flush on the way out still writes (the Auto-Save gate's off case is
            // `WorkspaceFileEditSessionTests`').
            isAutoSaveOn: Harness.autoSave(autoSave)
        )!
        let controller = WorkspaceFileEditorViewController(session: session, themeID: .dark) { text in
            let preview = UIViewController()
            let label = UILabel()
            label.text = text
            label.accessibilityIdentifier = "preview-text"
            preview.view.addSubview(label)
            return preview
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.textView.selectedRange = NSRange(location: (controller.textView.text as NSString).length, length: 0)
        return (controller, window)
    }

    @Test func themeRecolorKeepsTheSameTextViewSelectionAndUndo() async throws {
        let harness = Harness()
        let (controller, window) = makeController(harness)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.insertText(" edited")
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.session.status == .pending, "typing reaches the session")
        let undoManager = try #require(textView.undoManager)
        #expect(undoManager.canUndo)
        let selection = textView.selectedRange

        controller.applyThemeIfNeeded(.light)
        #expect(controller.textView === textView)
        #expect(textView.superview === controller.view)
        #expect(textView.text == "# Title\r\nbody edited")
        #expect(textView.selectedRange == selection)
        #expect(textView.undoManager?.canUndo == true, "recolor must not clear undo")
        #expect(textView.isFirstResponder)

        undoManager.undo()
        #expect(textView.text == "# Title\r\nbody")
    }

    @Test func previewShowsCurrentDraftAndReturnsToTheSameTextView() async throws {
        let harness = Harness()
        let (controller, window) = makeController(harness)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        textView.becomeFirstResponder()
        textView.insertText("draft ")
        controller.setShowingPreview(true)
        let label = try #require(controller.view.subviews.lazy
            .flatMap(\.subviews)
            .compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "preview-text" })
        #expect(label.text == controller.session.currentText)
        #expect(textView.isHidden)
        controller.setShowingPreview(false)
        #expect(controller.textView === textView)
        #expect(!textView.isHidden)
        #expect(textView.undoManager?.canUndo == true)
    }

    @Test func saveStateIndicatorMapsEveryStatusToLockedGlyphAndSpokenWord() {
        let statuses: [WorkspaceFileEditSession.Status] = [
            .saved, .pending, .saving, .offline, .verifying,
            .conflict, .deleted, .tooLarge, .failed("disk full"),
        ]
        for status in statuses {
            let (label, indicator) = Self.lockedSaveState(status)
            #expect(WorkspaceFileEditStatusPresentation.label(for: status) == label)
            #expect(WorkspaceFileEditStatusPresentation.indicator(for: status) == indicator)
        }
        #expect(WorkspaceFileEditStatusPresentation.label(for: .pending) != "Saved")
        #expect(WorkspaceFileEditStatusPresentation.label(for: .verifying) != "Saved")
        // A file that is not there yet is not "Saved": the editor says so.
        #expect(WorkspaceFileEditStatusPresentation.label(for: .saved, createsFile: true) == "New")
        #expect(WorkspaceFileEditStatusPresentation.label(for: .saved) == "Saved")
    }

    /// Astra lock: spoken words stay; the glyph is shape-only.
    private static func lockedSaveState(
        _ status: WorkspaceFileEditSession.Status
    ) -> (String, WorkspaceFileEditStatusPresentation.Indicator) {
        switch status {
        case .saved: ("Saved", .symbol("checkmark.circle"))
        case .pending: ("Edited", .symbol("pencil.circle"))
        case .saving: ("Saving…", .progress)
        case .offline: ("Offline", .symbol("wifi.slash"))
        case .verifying: ("Checking…", .progress)
        case .conflict: ("Conflict", .symbol("exclamationmark.triangle"))
        case .deleted: ("Deleted", .symbol("exclamationmark.triangle"))
        case .tooLarge: ("Too Large", .symbol("exclamationmark.triangle"))
        case .failed: ("Not Saved", .symbol("exclamationmark.triangle"))
        }
    }

    /// ⌘S is the person's save: with Auto-Save off it writes what is on screen,
    /// once, and asks nothing.
    @Test func commandSSavesAtOnceWithAutoSaveOff() async {
        let harness = Harness()
        let (controller, window) = makeController(harness, autoSave: false)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        textView.becomeFirstResponder()
        textView.insertText(" saved")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.session.hasUnconfirmedChanges)

        controller.codeEditor(textView, perform: "save")

        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog.count == 1)
        #expect(harness.scripted.writeLog[0].bytes == Data("# Title\r\nbody saved".utf8))
        #expect(controller.presentedViewController == nil, "⌘S writes: it is the save, not a question")
        #expect(controller.session.hasUnsavedChanges, "the write is not acknowledged yet")
        #expect(!controller.session.hasUnconfirmedChanges, "the person confirmed these bytes")
    }

    @Test func finishEditingDetachesAndFlushesWithoutWaiting() async {
        let harness = Harness()
        let (controller, window) = makeController(harness)
        defer { hideTestWindow(window) }
        controller.textView.becomeFirstResponder()
        controller.textView.insertText("!")
        controller.finishEditing()
        #expect(!controller.session.isEditorAttached)
        #expect(harness.store.load(harness.identity) != nil, "Done checkpoints synchronously")
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(controller.session.currentText.hasSuffix("!"))
        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { controller.session.status == .saved })
    }
}

// MARK: - Markdown list continuation

@Suite("Markdown list continuation")
struct MarkdownListContinuationTests {
    /// `|` marks the caret before and after Return.
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let before: String
        let after: String?

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "dash bullet", before: "- item|", after: "- item\n- |"),
        Case(name: "star bullet keeps indent", before: "  * item|", after: "  * item\n  * |"),
        Case(name: "plus bullet keeps spacing", before: "+   item|", after: "+   item\n+   |"),
        Case(name: "ordered dot increments", before: "3. item|", after: "3. item\n4. |"),
        Case(name: "ordered paren increments", before: "9) item|", after: "9) item\n10) |"),
        Case(name: "unchecked task", before: "- [ ] task|", after: "- [ ] task\n- [ ] |"),
        Case(name: "checked task continues unchecked", before: "- [x] done|", after: "- [x] done\n- [ ] |"),
        Case(name: "ordered task", before: "1. [ ] task|", after: "1. [ ] task\n2. [ ] |"),
        Case(name: "caret mid-item splits it", before: "- fo|o", after: "- fo\n- |o"),
        Case(name: "empty bullet exits", before: "a\n- item\n- |", after: "a\n- item\n|"),
        Case(name: "empty nested bullet exits", before: "- item\n  - |", after: "- item\n|"),
        Case(name: "empty task exits", before: "- [ ] |", after: "|"),
        Case(name: "empty ordered exits", before: "1. one\n2. |\nnext", after: "1. one\n|\nnext"),
        Case(name: "CRLF line ending", before: "# T\r\n- item|\r\nnext", after: "# T\r\n- item\r\n- |\r\nnext"),
        Case(name: "CRLF from previous line", before: "# T\r\n- item|", after: "# T\r\n- item\r\n- |"),
        Case(name: "LF stays LF", before: "# T\n- item|\nnext", after: "# T\n- item\n- |\nnext"),
        Case(name: "plain line", before: "plain|", after: nil),
        Case(name: "caret before marker", before: "|- item", after: nil),
        Case(name: "caret inside marker", before: "-| item", after: nil),
        Case(name: "marker without space", before: "-item|", after: nil),
        Case(name: "inside fenced code", before: "```\n- item|", after: nil),
        Case(name: "after closed fence", before: "~~~\ncode\n~~~\n- item|", after: "~~~\ncode\n~~~\n- item\n- |"),
    ]

    @Test(arguments: cases)
    func returnContinuesMarkdownLists(_ testCase: Case) throws {
        let caret = (testCase.before as NSString).range(of: "|").location
        let text = testCase.before.replacingOccurrences(of: "|", with: "") as NSString
        let edit = MarkdownListContinuation.edit(in: text, caret: caret)
        guard let expected = testCase.after else {
            #expect(edit == nil)
            return
        }
        let applied = try #require(edit)
        let result = text.replacingCharacters(in: applied.range, with: applied.replacement)
        let resultCaret = applied.range.location + (applied.replacement as NSString).length
        let rendered = (result as NSString).replacingCharacters(
            in: NSRange(location: resultCaret, length: 0),
            with: "|"
        )
        #expect(rendered == expected)
    }
}

@Suite("Markdown list continuation in the editor")
@MainActor
struct WorkspaceFileEditorListContinuationTests {
    private func makeController(
        path: String,
        text: String,
        store: WorkspaceFileDraftStore,
        transport: WorkspaceFileEditTransport
    ) -> (WorkspaceFileEditorViewController, UIWindow) {
        let session = WorkspaceFileEditSession(
            identity: WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: path),
            disk: WorkspaceFileDiskSnapshot(bytes: Data(text.utf8), etag: tag("a")),
            maxBytes: 1_024,
            transport: transport,
            draftStore: store,
            idleDelay: .seconds(60)
        )!
        let controller = WorkspaceFileEditorViewController(session: session, themeID: .dark) { _ in UIViewController() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        return (controller, window)
    }

    @Test func returnContinuesAsOneUndoableEditAndReachesTheSession() throws {
        let harness = Harness()
        let (controller, window) = makeController(
            path: "notes.md",
            text: "# T\r\n- item",
            store: harness.store,
            transport: harness.scripted.transport
        )
        defer { hideTestWindow(window) }
        let textView = controller.textView
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        let generation = controller.session.editGeneration

        // The keyboard's Return arrives as `insertText`.
        textView.insertText("\n")

        #expect(textView.text == "# T\r\n- item\r\n- ")
        #expect(textView.selectedRange == NSRange(location: (textView.text as NSString).length, length: 0))
        #expect(controller.session.editGeneration > generation, "continuation must reach the save machine")
        #expect(controller.session.status == .pending)

        let undoManager = try #require(textView.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(textView.text == "# T\r\n- item", "one undo reverts the whole continuation")
    }

    @Test func markedTextAndNonMarkdownKeepThePlainNewline() {
        let harness = Harness()
        let (markdown, markdownWindow) = makeController(
            path: "notes.md",
            text: "- item",
            store: harness.store,
            transport: harness.scripted.transport
        )
        defer { markdownWindow.isHidden = true }
        let textView = markdown.textView
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: 6, length: 0)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        #expect(textView.markedTextRange != nil)
        textView.insertText("\n")
        #expect(!textView.text.contains("\n- "), "composition keeps the plain newline")
        textView.unmarkText()

        let (plain, plainWindow) = makeController(
            path: "notes.txt",
            text: "- item",
            store: harness.store,
            transport: harness.scripted.transport
        )
        defer { plainWindow.isHidden = true }
        plain.textView.becomeFirstResponder()
        plain.textView.selectedRange = NSRange(location: 6, length: 0)
        plain.textView.insertText("\n")
        #expect(plain.textView.text == "- item\n")
    }
}

// MARK: - Tree-pane Edit entry

/// Serves `/server/info` with editing capability and one tagged workspace read.
private final class TreePaneEditURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "tree-pane-edit.test"
    static let body = Data("# Notes\n- first\n".utf8)

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TreePaneEditURLProtocol.self]
        return APIClient(
            environment: OppiClientEnvironment(baseURL: URL(string: "https://\(host)")!, bearerToken: "sk_test"),
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let status: Int
        var headers = ["Content-Type": "application/json"]
        let data: Data
        if url.path == "/server/info" {
            status = 200
            data = Data("""
            {"name":"Test","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":{"currentFiles":{"version":1},"workspaceFileEditing":{"version":1,"maxBytes":1048576}},"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}
            """.utf8)
        } else if url.path == "/files/current" {
            status = 200
            headers = ["Content-Type": "text/markdown; charset=utf-8", "ETag": tag("a")]
            data = Self.body
        } else {
            status = 404
            data = Data(#"{"error":"not found"}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Workspace file edit entry")
@MainActor
struct WorkspaceFileEditEntryTests {
    /// The tree pane hides the reader's own bar, so Edit must be a bar item.
    /// The editor mount and autosave in this layout are covered by the iPad
    /// landscape E2E.
    @Test func treePaneTextWithEditBaseShowsToolbarEdit() async throws {
        let client = TreePaneEditURLProtocol.makeClient()
        _ = try await client.serverInfo()
        let content = FileViewerViewController(
            configuration: .init(
                workspaceId: "w-tree",
                serverId: "srv-tree-\(UUID().uuidString)",
                filePath: "notes.md",
                fileName: "notes.md",
                chromeMode: .treePane
            ),
            services: .init(apiClient: client)
        )
        let host = UINavigationController(rootViewController: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        var edit: UIBarButtonItem?
        let shown = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.layoutIfNeeded()
            edit = Self.barButtonItem(titled: "Edit", in: content)
            return edit != nil
        }
        #expect(shown, "tree-pane reader offered no Edit; items: \(Self.titles(in: content))")
        let item = try #require(edit)

        #expect(Self.activate(item))
        let editing = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.layoutIfNeeded()
            // The Source/Preview toggle only exists while editing.
            return Self.barButtonItem(titled: "Preview", in: content) != nil
                && Self.barButtonItem(titled: "Edit", in: content) == nil
        }
        #expect(editing, "Edit did not switch to the editing toolbar; items: \(Self.titles(in: content))")
    }

    /// The viewer keeps one set of editing bar items while it shows file after
    /// file. Editor Options > Wrap Lines must follow the file that is open when
    /// the menu opens, not the one the items were made for: edit main.swift,
    /// press Done, show notes.md, and the menu would change the code setting.
    @Test func editorOptionsFollowTheOpenFileAfterSwitchingFiles() async throws {
        let client = TreePaneEditURLProtocol.makeClient()
        _ = try await client.serverInfo()
        let content = FileViewerViewController(
            configuration: .init(
                workspaceId: "w-tree",
                serverId: "srv-tree-\(UUID().uuidString)",
                filePath: "main.swift",
                fileName: "main.swift",
                chromeMode: .treePane
            ),
            services: .init(apiClient: client)
        )
        let host = UINavigationController(rootViewController: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        var edit: UIBarButtonItem?
        let shown = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.layoutIfNeeded()
            edit = Self.barButtonItem(titled: "Edit", in: content)
            return edit != nil
        }
        #expect(shown, "tree-pane reader offered no Edit; items: \(Self.titles(in: content))")
        #expect(Self.activate(try #require(edit)))
        var done: UIBarButtonItem?
        let editing = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.layoutIfNeeded()
            done = Self.barButtonItems(in: content).first { $0.accessibilityIdentifier == "workspace-file-editor.done" }
            return done != nil
        }
        #expect(editing, "Edit did not open the editor; items: \(Self.titles(in: content))")
        let name = "editor-options-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CodeEditorPreferences(defaults: defaults)
        #expect(preferences.wrapsText && !preferences.wrapsCode, "the defaults: Markdown wraps, code does not")

        // Wrap Lines in the menu, as it opens now, flips the open file's kind.
        // Each editor's items belong to its own file, so the menu is read from
        // the editor that is open.
        func toggleWrapLines() throws {
            let items = try #require(content.editorBarItemsForTesting)

            func actions(_ elements: [UIMenuElement]) -> [UIAction] {
                elements.flatMap { element -> [UIAction] in
                    if let menu = element as? UIMenu { return actions(menu.children) }
                    return (element as? UIAction).map { [$0] } ?? []
                }
            }
            let wrap = try #require(actions(items.optionsElements(preferences: preferences)).first { $0.title == "Wrap Lines" })
            #expect(Self.activate(UIBarButtonItem(primaryAction: wrap)))
        }
        try toggleWrapLines()
        #expect(preferences.wrapsCode && preferences.wrapsText, "main.swift is code: the code setting turned on")
        try toggleWrapLines()
        #expect(!preferences.wrapsCode, "and back off")

        #expect(Self.activate(try #require(done)))
        content.show(FileBrowserSelection(path: "notes.md", name: "notes.md", size: nil), navigationContext: nil)
        // Edit again, as a person would, then open the menu.
        var editAgain: UIBarButtonItem?
        let reader = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.layoutIfNeeded()
            editAgain = Self.barButtonItem(titled: "Edit", in: content)
            return editAgain != nil
        }
        #expect(reader, "no Edit after Done; items: \(Self.titles(in: content))")
        #expect(Self.activate(try #require(editAgain)))
        let editingAgain = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.view.layoutIfNeeded()
            return Self.barButtonItems(in: content).contains { $0.accessibilityIdentifier == "workspace-file-editor.done" }
        }
        #expect(editingAgain, "Edit did not reopen the editor; items: \(Self.titles(in: content))")
        try toggleWrapLines()
        #expect(!preferences.wrapsText && !preferences.wrapsCode, "notes.md is Markdown: the text setting turned off and the code setting is untouched")
    }

    /// The Files screen shows the open file's Edit in its own bar. Locking
    /// the workspace tears the content down; the file's items must go with
    /// it, or the cover keeps an Edit whose target is gone.
    @Test func filesScreenLockTakesTheOpenFilesBarItems() async throws {
        let client = TreePaneEditURLProtocol.makeClient()
        _ = try await client.serverInfo()
        let serverId = "sha256:files-lock-\(UUID().uuidString)"
        let workspaceId = "w-files-lock"
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: client)
        defer { ScopedLockService.shared.forgetServer(serverId) }
        let files = FileBrowserViewController(
            root: root,
            target: FileBrowserNavTarget(
                serverId: serverId,
                scope: .workspace(workspaceId: workspaceId, worktreeId: nil),
                path: "",
                columnSelectedFile: FileBrowserSelection(path: "notes.md", name: "notes.md", size: nil)
            ),
            showsSidebarToggle: false
        )
        let navigation = UINavigationController(rootViewController: files)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let shown = await waitForMainActorCondition(timeout: .seconds(5)) {
            navigation.view.layoutIfNeeded()
            return Self.barButtonItem(titled: "Edit", in: files) != nil
        }
        #expect(shown, "the Files bar showed no Edit for the open file; items: \(Self.titles(in: files))")

        ScopedLockService.shared.lock(.workspace(serverId: serverId, workspaceId: workspaceId))
        let cleared = await waitForMainActorCondition(timeout: .seconds(5)) {
            navigation.view.layoutIfNeeded()
            return Self.barButtonItems(in: files).isEmpty
        }
        #expect(cleared, "the locked Files screen kept the file's items: \(Self.titles(in: files))")
    }

    private static func barButtonItem(titled title: String, in controller: UIViewController) -> UIBarButtonItem? {
        barButtonItems(in: controller).first { $0.title == title }
    }

    private static func barButtonItems(in controller: UIViewController) -> [UIBarButtonItem] {
        (controller.navigationItem.rightBarButtonItems ?? [])
            + controller.navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
    }

    private static func titles(in controller: UIViewController) -> String {
        barButtonItems(in: controller).map { $0.title ?? "-" }.joined(separator: ", ")
    }

    /// Runs the item's primary action, as a tap does.
    private static func activate(_ item: UIBarButtonItem) -> Bool {
        guard let action = item.primaryAction else { return false }
        UIButton().sendAction(action)
        return true
    }
}
