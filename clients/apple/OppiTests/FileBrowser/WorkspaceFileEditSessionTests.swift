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
        let ifMatch: String
        let continuation: CheckedContinuation<WorkspaceFileWriteOutcome, Never>
    }

    private(set) var pending: [PendingWrite] = []
    private(set) var writeLog: [(bytes: Data, ifMatch: String)] = []
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
            write: { _, bytes, ifMatch in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self.writeLog.append((bytes, ifMatch))
                        self.pending.append(PendingWrite(bytes: bytes, ifMatch: ifMatch, continuation: continuation))
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
        etag: String = tag("a"),
        idleDelay: Duration = .seconds(60),
        retryDelay: Duration = .milliseconds(20)
    ) -> WorkspaceFileEditSession {
        let session = WorkspaceFileEditSession(
            identity: identity,
            disk: WorkspaceFileDiskSnapshot(bytes: disk ?? Data(buffer.utf8), etag: etag),
            maxBytes: 64,
            transport: scripted.transport,
            draftStore: store,
            idleDelay: idleDelay,
            retryDelay: retryDelay
        )!
        buffer = session.currentText
        session.attachEditor { [unowned self] in self.buffer }
        return session
    }

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

    @Test func identityKeysSeparateWorktreeAndServer() {
        let main = WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: nil, path: "a.md")
        let blank = WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: "  ", path: "a.md")
        let worktree = WorkspaceFileEditIdentity(serverId: "s", workspaceId: "w", worktreeId: "wt", path: "a.md")
        let otherServer = WorkspaceFileEditIdentity(serverId: "t", workspaceId: "w", worktreeId: nil, path: "a.md")
        #expect(main.storageKey == blank.storageKey)
        #expect(main.storageKey != worktree.storageKey)
        #expect(main.storageKey != otherServer.storageKey)
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
        #expect(harness.scripted.writeLog[0].ifMatch == tag("a"))
        #expect(harness.scripted.writeLog[0].bytes == Data("hello world!".utf8))
        #expect(session.status == .saving)

        harness.scripted.resolveNext(.saved(etag: tag("b")))
        #expect(await eventually { session.status == .saved })
        #expect(session.baseEtag == tag("b"))
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
        #expect(harness.scripted.writeLog[1].ifMatch == tag("b"), "follow-up write extends the acknowledged tag")
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
        #expect(harness.scripted.writeLog[1].ifMatch == tag("d"))
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
        #expect(session.baseEtag == tag("e"))
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
        #expect(session.baseEtag == tag("f"))
        #expect(harness.store.load(harness.identity) == nil)

        harness.type("+", into: session)
        session.flush()
        #expect(await eventually { harness.scripted.pending.count == 1 })
        #expect(harness.scripted.writeLog[1].ifMatch == tag("f"), "autosave resumes from the disk version")
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
        #expect(harness.scripted.writeLog[1].ifMatch == tag("a"))
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
        #expect(session.baseEtag == tag("b"))
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
        #expect(harness.scripted.writeLog[1].ifMatch == tag("a"))
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
        // The simulator does not report data-protection classes; devices do.
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
        let probe = WorkspaceFileEditIdentity(serverId: "probe", workspaceId: UUID().uuidString, worktreeId: nil, path: "p.md")
        try shared.save(WorkspaceFileDraft(identity: probe, baseEtag: tag("a"), bytes: Data(marker.utf8), updatedAt: Date()))
        defer { shared.remove(probe) }
        #expect(FileManager.default.fileExists(atPath: shared.fileURL(for: probe).path))
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        #expect(!defaults.keys.contains { $0.contains(probe.storageKey) || $0.contains(probe.workspaceId) })
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
        session.attachEditor { [unowned harness] in harness.buffer }
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
}

@Suite("Workspace file editor surface")
@MainActor
struct WorkspaceFileEditorSurfaceTests {
    private func makeController(_ harness: Harness) -> (WorkspaceFileEditorViewController, UIWindow) {
        let session = WorkspaceFileEditSession(
            identity: harness.identity,
            disk: WorkspaceFileDiskSnapshot(bytes: Data("# Title\r\nbody".utf8), etag: tag("a")),
            maxBytes: 1_024,
            transport: harness.scripted.transport,
            draftStore: harness.store
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
        defer { window.isHidden = true }
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
        defer { window.isHidden = true }
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

    @Test func finishEditingDetachesAndFlushesWithoutWaiting() async {
        let harness = Harness()
        let (controller, window) = makeController(harness)
        defer { window.isHidden = true }
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
        defer { window.isHidden = true }
        let textView = controller.textView
        #expect(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        let generation = controller.session.editGeneration

        returnKey(in: textView, delegate: controller)

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
        let caret = textView.selectedRange.location
        #expect(markdown.textView(textView, shouldChangeTextIn: NSRange(location: caret, length: 0), replacementText: "\n"))
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
        returnKey(in: plain.textView, delegate: plain)
        #expect(plain.textView.text == "- item\n")
    }

    /// The keyboard's Return: ask the delegate, then insert only if allowed.
    private func returnKey(in textView: UITextView, delegate: UITextViewDelegate) {
        let range = textView.selectedRange
        if delegate.textView?(textView, shouldChangeTextIn: range, replacementText: "\n") ?? true {
            textView.insertText("\n")
        }
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
    /// The tree pane hides the reader's UIKit bar, so Edit must be a SwiftUI
    /// toolbar item. The editor mount and autosave in this layout are covered
    /// by the iPad landscape E2E.
    @Test func treePaneTextWithEditBaseShowsToolbarEdit() async throws {
        let client = TreePaneEditURLProtocol.makeClient()
        _ = try await client.serverInfo()
        let content = UIHostingController(rootView: FileBrowserContentView(
            workspaceId: "w-tree",
            serverId: "srv-tree-\(UUID().uuidString)",
            filePath: "notes.md",
            fileName: "notes.md",
            chromeMode: .treePane
        )
        .environment(\.apiClient, client))
        let host = UINavigationController(rootViewController: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

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
            return Self.barButtonItem(titled: "Done", in: content) != nil
                && Self.barButtonItem(titled: "Edit", in: content) == nil
        }
        #expect(editing, "Edit did not switch to the editing toolbar; items: \(Self.titles(in: content))")
    }

    /// SwiftUI hosts toolbar buttons as custom views titled by their label.
    private static func barButtonItem(titled title: String, in controller: UIViewController) -> UIBarButtonItem? {
        barButtonItems(in: controller).first { $0.title == title && $0.customView != nil }
    }

    private static func barButtonItems(in controller: UIViewController) -> [UIBarButtonItem] {
        (controller.navigationItem.rightBarButtonItems ?? [])
            + controller.navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
    }

    private static func titles(in controller: UIViewController) -> String {
        barButtonItems(in: controller).map { $0.title ?? "-" }.joined(separator: ", ")
    }

    /// SwiftUI wires a hosted toolbar button's tap as the item's target-action.
    private static func activate(_ item: UIBarButtonItem) -> Bool {
        guard let action = item.action else { return false }
        return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
    }
}
