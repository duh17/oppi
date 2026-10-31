import Foundation
import Testing
import UIKit
@testable import Oppi

/// The edit entry's rule, without a server: what opens the pencil, what the "…"
/// offers, and what an open editor leaves behind.
@Suite("Document edit owner")
@MainActor
struct DocumentEditOwnerTests {
    // MARK: Fixtures

    private func tag(_ character: Character) -> String {
        "\"sha256-\(String(repeating: character, count: 64))\""
    }

    private func draftStore() -> WorkspaceFileDraftStore {
        WorkspaceFileDraftStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("document-edit-owner-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func workspaceSubject(
        path: String = "notes.md",
        fileType: FileType = .markdown
    ) -> DocumentEditSubject {
        .file(
            serverId: "srv",
            source: .workspaceFile,
            workspaceId: "w1",
            worktreeId: nil,
            path: path,
            skillFile: nil,
            fileType: fileType
        )
    }

    private func skillSubject(path: String = "SKILL.md") -> DocumentEditSubject {
        .file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: "/Users/preview/.pi/agent/skills/release/\(path)",
            skillFile: SkillFileEditTarget(skillId: "release", path: path),
            fileType: .markdown
        )
    }

    /// The transport a test never gets to: the owner only reads here.
    private var idleTransport: WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(read: { _ in .failed }, write: { _, _, _ in .notSent })
    }

    private var savedTransport: WorkspaceFileEditTransport {
        let saved = tag("b")
        return WorkspaceFileEditTransport(read: { _ in .failed }, write: { _, _, _ in .saved(etag: saved) })
    }

    /// Counts the tagged reads, so a test can prove the owner never asks a
    /// server that does not edit the file.
    @MainActor
    private final class ReadSpy {
        private(set) var count = 0
        func note() { count += 1 }
    }

    /// Holds a read open, so a test can move the reader to another file first.
    private actor ReadGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        private var didEnter = false
        private var entered: CheckedContinuation<Void, Never>?

        func enter() async {
            didEnter = true
            entered?.resume()
            entered = nil
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Resolves once a read has entered, so the test knows it is in flight.
        func waitForReader() async {
            guard !didEnter else { return }
            await withCheckedContinuation { entered = $0 }
        }

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    private func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Sessions live in their own registry per test, so one test's open editor
    /// never answers another's read.
    private func registry() -> WorkspaceFileEditSessionRegistry {
        WorkspaceFileEditSessionRegistry(observesBackground: false)
    }

    private func owner(
        subject: DocumentEditSubject,
        capability: ServerInfo.WorkspaceFileEditingCapability?,
        snapshot: WorkspaceFileDiskSnapshot = WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: "\"sha256-a\""),
        outcome: WorkspaceFileReadOutcome? = nil,
        agentAction: DocumentAgentEditAction? = nil,
        placement: DocumentEditOwner.Placement = .screenBar,
        transport: WorkspaceFileEditTransport? = nil,
        draftStore: WorkspaceFileDraftStore? = nil,
        sessionRegistry: WorkspaceFileEditSessionRegistry? = nil,
        readSpy: ReadSpy? = nil,
        handlers: DocumentEditOwner.Handlers = .init(),
        onChange: @escaping @MainActor () -> Void = {}
    ) -> DocumentEditOwner {
        let transport = transport ?? idleTransport
        let backend = DocumentEditOwner.Backend(
            capability: { _ in capability },
            read: { _ in
                await readSpy?.note()
                return outcome ?? .snapshot(snapshot)
            },
            transport: transport
        )
        return DocumentEditOwner(
            subject: subject,
            placement: placement,
            agentAction: agentAction,
            backend: { backend },
            draftStore: draftStore ?? self.draftStore(),
            registry: sessionRegistry ?? self.registry(),
            handlers: handlers,
            onChange: onChange
        )
    }

    private var capability: ServerInfo.WorkspaceFileEditingCapability {
        ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: 1_048_576)
    }

    private func identifiers(_ owner: DocumentEditOwner) -> [String] {
        owner.barItems.map(\.accessibilityIdentifier).compactMap { $0 }
    }

    // MARK: The editability rule

    @Test func capabilityOffLeavesNoPencilButKeepsEditWithSession() async {
        let spy = ReadSpy()
        let owner = owner(
            subject: workspaceSubject(),
            capability: nil,
            agentAction: DocumentAgentEditAction { },
            readSpy: spy
        )

        #expect(await owner.read() == .ownRead, "no capability: the reader loads the file its own way")
        #expect(spy.count == 0, "a server that does not edit the file gets no tagged read")
        #expect(identifiers(owner) == ["document.edit.more"])
        #expect(owner.barItems.first?.menu?.children.count == 1)
    }

    @Test func untaggedReadLeavesNoPencil() async {
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: nil)
        )

        #expect(await owner.read() == .bytes(WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: nil), draftText: nil))
        #expect(owner.barItems.isEmpty, "bytes the server did not offer for editing have no edit entry")
    }

    @Test func binaryBytesLeaveNoPencil() async {
        let owner = owner(
            subject: workspaceSubject(path: "notes.txt", fileType: .plain),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data([0xC3, 0x28]), etag: "\"sha256-a\"")
        )
        _ = await owner.read()

        #expect(owner.barItems.isEmpty, "bytes that are not UTF-8 text cannot open the editor")
    }

    /// The limit is the server's: one byte under it edits, one over does not.
    @Test func theServerLimitIsTheBoundary() async {
        let limit = 8
        let small = ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: limit)
        let atLimit = owner(
            subject: workspaceSubject(),
            capability: small,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data(repeating: 0x61, count: limit), etag: "\"sha256-a\"")
        )
        let overLimit = owner(
            subject: workspaceSubject(),
            capability: small,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data(repeating: 0x61, count: limit + 1), etag: "\"sha256-a\"")
        )

        _ = await atLimit.read()
        _ = await overLimit.read()
        #expect(identifiers(atLimit) == ["workspace-file-editor.edit"])
        #expect(overLimit.barItems.isEmpty)
    }

    @Test func nonTextFileHasNoPencil() async {
        let owner = owner(
            subject: workspaceSubject(path: "photo.png", fileType: .image),
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )

        #expect(await owner.read() == .ownRead)
        #expect(identifiers(owner) == ["document.edit.more"], "an image has no pencil, only the session route")
    }

    @Test func snapshotIsNeverEditable() async {
        let owner = owner(subject: .snapshot, capability: capability)
        _ = await owner.read()

        #expect(owner.barItems.isEmpty)
    }

    /// The three conditions together: identity, capability, tagged UTF-8 read.
    @Test func taggedTextReadOffersBothControls() async {
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )

        #expect(await owner.read() == .bytes(WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: "\"sha256-a\""), draftText: nil))
        #expect(identifiers(owner) == ["document.edit.more", "workspace-file-editor.edit"])
        let edit = owner.barItems.first?.menu?.children.first as? UIAction
        #expect(edit?.accessibilityIdentifier == "controlFile.editInSession")
    }

    @Test func skillFileReadsThroughItsSkillIdentity() async {
        let owner = owner(subject: skillSubject(), capability: capability)
        _ = await owner.read()

        #expect(owner.identity == WorkspaceFileEditIdentity(serverId: "srv", skillId: "release", path: "SKILL.md"))
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])
    }

    @Test func hostFileOutsideASkillHasNoEditEntry() async {
        let subject = DocumentEditSubject.file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: "/Users/preview/.pi/agent/prompts/SYSTEM.md",
            skillFile: nil,
            fileType: .markdown
        )
        let owner = owner(subject: subject, capability: capability)

        #expect(await owner.read() == .ownRead)
        #expect(owner.barItems.isEmpty)
    }

    // MARK: A read that the reader has moved on from

    /// File A's read may finish after the reader began B; it must not write B's
    /// state, or the pencil on B would open A.
    @Test func aReadForThePreviousDocumentNeverApplies() async {
        let gate = ReadGate()
        let snapshot = WorkspaceFileDiskSnapshot(bytes: Data("A".utf8), etag: "\"sha256-a\"")
        let backend = DocumentEditOwner.Backend(
            capability: { _ in ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: 1_024) },
            read: { _ in
                await gate.enter()
                return .snapshot(snapshot)
            },
            transport: idleTransport
        )
        let owner = DocumentEditOwner(
            subject: workspaceSubject(path: "a.md"),
            placement: .screenBar,
            backend: { backend },
            draftStore: draftStore(),
            registry: registry(),
            onChange: {}
        )

        let readA = Task { await owner.read() }
        await gate.waitForReader()
        owner.begin(subject: workspaceSubject(path: "b.md"))
        await gate.open()

        #expect(await readA.value == .ownRead, "A's read finished after B began")
        #expect(owner.identity == nil, "A's identity did not leak into B")
        #expect(owner.barItems.isEmpty)
    }

    // MARK: Editing

    @Test func beginEditingCreatesAndRegistersASession() async {
        let sessions = registry()
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            transport: savedTransport,
            sessionRegistry: sessions
        )
        _ = await owner.read()
        owner.beginEditing()

        let session = owner.session
        #expect(session != nil)
        #expect(sessions.session(for: WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md")) === session)
        #expect(owner.isEditing)
    }

    /// Another document arriving while the editor is open hands the buffer back:
    /// the session must hold the typed text and detach from the page's text view.
    @Test func beginningAnotherDocumentKeepsTheOpenEditorsBuffer() async {
        let owner = owner(subject: workspaceSubject(), capability: capability, transport: savedTransport)
        _ = await owner.read()
        owner.beginEditing()
        let page = owner.makeEditorPage()
        page?.loadViewIfNeeded()
        let session = owner.session
        page?.editor.textView.text = "typed words"
        session?.noteEdit()
        #expect(owner.isEditing)

        owner.begin(subject: workspaceSubject(path: "other.md"))

        #expect(!owner.isEditing, "the previous document's editor is closed")
        #expect(session?.currentText == "typed words", "the buffer came back from the editor")
        #expect(session?.isEditorAttached == false, "the session no longer holds a freed text view")
        #expect(await eventually { session?.isSettled == true }, "the detached session saves and settles")
    }

    /// The file is gone: its kept draft reopens in the non-writing state, and
    /// once Done closes it the pencil opens it again.
    @Test func deletedFilesDraftReopensFromThePencil() async {
        let store = draftStore()
        let identity = WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md")
        try? store.save(WorkspaceFileDraft(
            identity: identity,
            baseEtag: tag("a"),
            bytes: Data("kept after delete".utf8),
            updatedAt: Date()
        ))
        var shown: [String] = []
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            outcome: .missing,
            transport: savedTransport,
            draftStore: store,
            handlers: .init(didShowText: { shown.append($0) })
        )

        #expect(await owner.read() == .deletedDraft("kept after delete"))
        #expect(owner.isEditing)
        #expect(owner.session?.status == .deleted)

        owner.endEditing()
        #expect(shown == ["kept after delete"])
        #expect(identifiers(owner) == ["workspace-file-editor.edit"], "a deleted file's kept draft has a pencil")

        owner.beginEditing()
        #expect(owner.isEditing)
        #expect(owner.session?.status == .deleted, "reopening never writes")
    }
}
