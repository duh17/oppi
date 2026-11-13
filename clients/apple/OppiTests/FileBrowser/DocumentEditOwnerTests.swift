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
        fileKind: FileKind = .markdown
    ) -> DocumentEditSubject {
        .file(
            serverId: "srv",
            source: .workspaceFile,
            workspaceId: "w1",
            worktreeId: nil,
            path: path,
            skillFile: nil,
            fileKind: fileKind
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
            fileKind: .markdown
        )
    }

    /// Pi's own `SYSTEM.md`, the one subject whose file may not exist yet.
    private func piSubject(
        path: String = "SYSTEM.md",
        seedText: String? = nil
    ) -> DocumentEditSubject {
        .piFile(path: path, seedText: seedText)
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
        serverId: String? = nil,
        capability: ServerInfo.WorkspaceFileEditingCapability?,
        snapshot: WorkspaceFileDiskSnapshot = WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: "\"sha256-a\""),
        outcome: WorkspaceFileReadOutcome? = nil,
        agentAction: DocumentAgentEditAction? = nil,
        transport: WorkspaceFileEditTransport? = nil,
        draftStore: WorkspaceFileDraftStore? = nil,
        sessionRegistry: WorkspaceFileEditSessionRegistry? = nil,
        readSpy: ReadSpy? = nil,
        resolve: @escaping @Sendable (FileEditLocation) async -> FileEditResolution = { _ in .unresolved },
        handlers: DocumentEditOwner.Handlers = .init(),
        autoSave: Bool = true,
        onChange: @escaping @MainActor () -> Void = {}
    ) -> DocumentEditOwner {
        let transport = transport ?? idleTransport
        let backend = DocumentEditOwner.Backend(
            capability: { _ in capability },
            transport: WorkspaceFileEditTransport(
                read: { _ in
                    await readSpy?.note()
                    return outcome ?? .snapshot(snapshot)
                },
                write: { identity, bytes, condition in await transport.write(identity, bytes, condition) },
                resolve: resolve
            )
        )
        return DocumentEditOwner(
            subject: subject,
            serverId: { serverId },
            agentAction: agentAction,
            backend: { backend },
            draftStore: draftStore ?? self.draftStore(),
            registry: sessionRegistry ?? self.registry(),
            handlers: handlers,
            isAutoSaveOn: { autoSave },
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
        #expect(identifiers(owner).isEmpty, "no pencil without the capability")
        #expect(owner.menuActions.map { ($0 as? UIAction)?.accessibilityIdentifier } == ["controlFile.editInSession"])
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

    /// A file the server offers to create: the pencil is there, and the editor
    /// starts from the seed the reader supplied. SYSTEM.md replaces Pi's built-in
    /// prompt, so its seed is that prompt — never nothing.
    @Test func aCreatableReadOpensOnTheReadersSeedText() async {
        let owner = owner(
            subject: piSubject(seedText: "You are a coding agent."),
            serverId: "srv",
            capability: capability,
            outcome: .creatable
        )

        let result = await owner.read()
        let seeded = WorkspaceFileDiskSnapshot(
            bytes: Data("You are a coding agent.".utf8),
            etag: nil,
            creatable: true
        )
        #expect(result == .bytes(seeded, draftText: nil))
        #expect(owner.base == seeded)
        #expect(identifiers(owner) == ["workspace-file-editor.edit"], "a file that is not there yet still edits")

        owner.beginEditing()
        #expect(owner.isEditing)
        #expect(owner.session?.currentText == "You are a coding agent.", "the editor opens on the seed")
        #expect(owner.session?.hasUnsavedChanges == false, "an untouched seed is not an edit")
        #expect(owner.session?.baseCondition == .absent, "its first real save creates the file")
    }

    /// A document with no default behind it (a prompt template) starts empty.
    @Test func aCreatableReadWithoutASeedOpensEmpty() async {
        let owner = owner(
            subject: piSubject(path: "prompts/review.md"),
            serverId: "srv",
            capability: capability,
            outcome: .creatable
        )

        let result = await owner.read()
        #expect(result == .bytes(WorkspaceFileDiskSnapshot(bytes: Data(), etag: nil, creatable: true), draftText: nil))
        owner.beginEditing()
        #expect(owner.session?.currentText == "")
    }

    @Test func binaryBytesLeaveNoPencil() async {
        let owner = owner(
            subject: workspaceSubject(path: "notes.txt", fileKind: .plain),
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
            subject: workspaceSubject(path: "photo.png", fileKind: .image),
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )

        #expect(await owner.read() == .ownRead)
        #expect(identifiers(owner).isEmpty, "an image has no pencil")
        #expect(owner.menuActions.count == 1, "…only the session route")
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
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])
        let edit = owner.menuActions.first as? UIAction
        #expect(edit?.accessibilityIdentifier == "controlFile.editInSession")
    }

    @Test func skillFileReadsThroughItsSkillIdentity() async {
        let owner = owner(subject: skillSubject(), capability: capability)
        _ = await owner.read()

        #expect(owner.identity == WorkspaceFileEditIdentity(serverId: "srv", skillId: "release", path: "SKILL.md"))
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])
    }

    // MARK: A session's copy of a workspace file

    /// The Git panel's This session shows the session's copy; its pencil edits the
    /// live file, so the subject resolves the workspace path the session path names.
    @Test func aSessionCopyEditsTheLiveWorkspaceFile() async {
        let subject = DocumentEditSubject.file(
            serverId: "srv",
            source: .sessionTouched(
                SessionTouchedFileOrigin(
                    sessionId: "session-1",
                    workspaceRuntime: .host,
                    hostMount: "/Users/preview/oppi"
                )
            ),
            workspaceId: "w1",
            worktreeId: nil,
            path: "/Users/preview/oppi/src/a.ts",
            skillFile: nil,
            fileKind: .plain
        )
        let owner = owner(subject: subject, serverId: "srv", capability: capability)

        _ = await owner.read()
        #expect(
            owner.identity
                == WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "src/a.ts")
        )
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])
    }

    /// A path the workspace does not hold has no identity: the host's own file, a
    /// sandbox path outside its mount, and a sandbox home path all stay read-only.
    @Test func aSessionPathOutsideTheWorkspaceHasNoPencil() async {
        func sessionSubject(
            path: String,
            runtime: WorkspaceRuntime = .host,
            hostMount: String = "/Users/preview/oppi"
        ) -> DocumentEditSubject {
            .file(
                serverId: "srv",
                source: .sessionTouched(
                    SessionTouchedFileOrigin(
                        sessionId: "session-1",
                        workspaceRuntime: runtime,
                        hostMount: hostMount
                    )
                ),
                workspaceId: "w1",
                worktreeId: nil,
                path: path,
                skillFile: nil,
                fileKind: .markdown
            )
        }

        for path in [
            "/tmp/elsewhere.md",
            "~/notes.md",
            "/Users/preview/oppi/../elsewhere.md",
        ] {
            #expect(sessionSubject(path: path).editIdentity(serverId: "srv") == nil, "\(path) is not the workspace")
        }
        // A sandbox guest path is the workspace origin's own form, taken as it is.
        #expect(
            sessionSubject(path: "/workspace/preview/src/a.ts", runtime: .sandbox)
                .editIdentity(serverId: "srv")
                == WorkspaceFileEditIdentity(
                    serverId: "srv",
                    workspaceId: "w1",
                    worktreeId: nil,
                    path: "/workspace/preview/src/a.ts"
                )
        )
        #expect(
            sessionSubject(path: "/etc/hosts", runtime: .sandbox).editIdentity(serverId: "srv") == nil,
            "a sandbox path outside the mount is not editable"
        )
    }

    /// A worktree session's absolute path names the mount, which is another
    /// checkout, so only its relative paths edit the worktree.
    @Test func aWorktreeSessionDoesNotMapAnAbsolutePathOntoItsWorkspace() async {
        func sessionSubject(path: String, worktreeId: String?) -> DocumentEditSubject {
            .file(
                serverId: "srv",
                source: .sessionTouched(
                    SessionTouchedFileOrigin(
                        sessionId: "session-1",
                        workspaceRuntime: .host,
                        hostMount: "/Users/preview/oppi"
                    )
                ),
                workspaceId: "w1",
                worktreeId: worktreeId,
                path: path,
                skillFile: nil,
                fileKind: .markdown
            )
        }

        // The mount is the main checkout, so mapping this path would edit the
        // worktree's copy of a file the row read from main.
        let absolute = "/Users/preview/oppi/src/a.ts"
        #expect(sessionSubject(path: absolute, worktreeId: "wt-1").editIdentity(serverId: "srv") == nil)
        // A relative path is the checkout's own, whatever the session's worktree.
        #expect(
            sessionSubject(path: "src/a.ts", worktreeId: "wt-1").editIdentity(serverId: "srv")
                == WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: "wt-1", path: "src/a.ts")
        )
        // In the main checkout the same absolute path is that file.
        #expect(
            sessionSubject(path: absolute, worktreeId: nil).editIdentity(serverId: "srv")
                == WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "src/a.ts")
        )
    }

    // MARK: Pi's own agent files

    /// SYSTEM.md is a document like a workspace file: the server advertises the
    /// `pi` origin, the bytes come back tagged, so the pencil opens our editor.
    @Test func piAgentFileReadsThroughItsPiIdentity() async {
        let owner = owner(subject: .piFile(path: "SYSTEM.md", seedText: nil), serverId: "srv", capability: capability)

        _ = await owner.read()
        #expect(owner.identity == WorkspaceFileEditIdentity(serverId: "srv", piPath: "SYSTEM.md"))
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])
    }

    /// The server id and the server's `piFileEditing` are both required: an old
    /// server without the origin keeps the file read-only, and a subject with no
    /// server cannot name a document at all.
    @Test func piAgentFileNeedsAServerThatEditsIt() async {
        let noServer = owner(subject: .piFile(path: "SYSTEM.md", seedText: nil), serverId: nil, capability: capability)
        let noCapability = owner(subject: .piFile(path: "SYSTEM.md", seedText: nil), serverId: "srv", capability: nil)

        #expect(await noServer.read() == .ownRead)
        #expect(noServer.barItems.isEmpty)
        #expect(await noCapability.read() == .ownRead)
        #expect(noCapability.barItems.isEmpty)
    }

    @Test func hostFileOutsideASkillHasNoEditEntry() async {
        let subject = DocumentEditSubject.file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: "/Users/preview/.pi/agent/prompts/SYSTEM.md",
            skillFile: nil,
            fileKind: .markdown
        )
        let owner = owner(subject: subject, capability: capability)

        #expect(await owner.read() == .ownRead)
        #expect(owner.barItems.isEmpty)
    }

    // MARK: A followed link

    /// Records where each owner asked the server who edits its file.
    private actor LocationLog {
        private(set) var locations: [FileEditLocation] = []
        func note(_ location: FileEditLocation) { locations.append(location) }
    }

    /// A chat link to a host path and the workspace tree name one file: the
    /// server answers one identity for both, so the second reader adopts the
    /// editor the first opened instead of starting a second writer.
    @Test func aLinkAndTheWorkspaceTreeShareOneEditor() async {
        let canonical = WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md")
        let snapshot = WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: tag("a"))
        let log = LocationLog()
        let resolve: @Sendable (FileEditLocation) async -> FileEditResolution = { location in
            await log.note(location)
            // A host-context read reports the canonical path; a workspace read does not.
            let hostPath: String? = if case .session = location.origin { "/Users/preview/oppi/notes.md" } else { nil }
            return .editable(canonical, snapshot, resolvedHostPath: hostPath)
        }
        let sessions = registry()
        let spy = ReadSpy()
        let link = DocumentEditSubject.file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "w1",
            worktreeId: nil,
            path: "/Users/preview/oppi/notes.md",
            skillFile: nil,
            fileKind: .markdown,
            context: FileEditReadContext(sessionId: "session-1")
        )
        let fromLink = owner(
            subject: link,
            capability: capability,
            sessionRegistry: sessions,
            readSpy: spy,
            resolve: resolve
        )
        let fromTree = owner(
            subject: workspaceSubject(),
            capability: capability,
            sessionRegistry: sessions,
            readSpy: spy,
            resolve: resolve
        )

        #expect(await fromLink.read() == .bytes(snapshot, draftText: nil))
        #expect(fromLink.identity == canonical)
        #expect(
            fromLink.resolvedHostPath == "/Users/preview/oppi/notes.md",
            "the link's reader keeps the real path its relative links resolve against"
        )
        #expect(identifiers(fromLink) == ["workspace-file-editor.edit"])
        fromLink.beginEditing()
        let session = fromLink.session
        #expect(session != nil)

        #expect(await fromTree.read() == .bytes(snapshot, draftText: nil))
        #expect(fromTree.identity == canonical)
        #expect(fromTree.session === session, "one file, one writer")
        #expect(spy.count == 0, "the resolving read is the editor's base; nothing reads twice")
        // The link read in its session's context, so a sandbox session's link is
        // judged inside that sandbox; the tree read through its workspace.
        #expect(await log.locations == [
            FileEditLocation(serverId: "srv", origin: .session(sessionId: "session-1"), path: "/Users/preview/oppi/notes.md"),
            FileEditLocation(serverId: "srv", origin: .workspace(workspaceId: "w1", worktreeId: nil), path: "notes.md"),
        ])
    }

    /// The server's refusal is the answer for a file with no identity of its
    /// own: no pencil, and no second read.
    @Test func aRefusedLinkIsReadOnly() async {
        let spy = ReadSpy()
        let subject = DocumentEditSubject.file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: "~/.ssh/notes.md",
            skillFile: nil,
            fileKind: .markdown
        )
        let owner = owner(
            subject: subject,
            capability: capability,
            readSpy: spy,
            resolve: { location in
                #expect(location.origin == .host(controlSessionId: nil))
                return .readOnly(reason: "protected")
            }
        )

        #expect(await owner.read() == .ownRead)
        #expect(owner.barItems.isEmpty)
        #expect(spy.count == 0)
    }

    // MARK: A read that the reader has moved on from

    /// File A's read may finish after the reader began B; it must not write B's
    /// state, or the pencil on B would open A.
    @Test func aReadForThePreviousDocumentNeverApplies() async {
        let gate = ReadGate()
        let snapshot = WorkspaceFileDiskSnapshot(bytes: Data("A".utf8), etag: "\"sha256-a\"")
        let backend = DocumentEditOwner.Backend(
            capability: { _ in ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: 1_024) },
            transport: WorkspaceFileEditTransport(
                read: { _ in
                    await gate.enter()
                    return .snapshot(snapshot)
                },
                write: { _, _, _ in .notSent }
            )
        )
        let owner = DocumentEditOwner(
            subject: workspaceSubject(path: "a.md"),
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
        let page = owner.makeEditorPage(checkoutSubtitle: nil)
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
        var finished = 0
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            outcome: .missing,
            transport: savedTransport,
            draftStore: store,
            handlers: .init(didFinishEditing: { finished += 1 })
        )

        #expect(await owner.read() == .deletedDraft("kept after delete"))
        #expect(owner.isEditing)
        #expect(owner.session?.status == .deleted)

        owner.endEditing()
        // The reader hears once the write in flight has landed.
        #expect(await eventually { finished == 1 }, "the reader is told the editor closed")
        #expect(identifiers(owner) == ["workspace-file-editor.edit"], "a deleted file's kept draft has a pencil")

        owner.beginEditing()
        #expect(owner.isEditing)
        #expect(owner.session?.status == .deleted, "reopening never writes")
    }

    // MARK: Auto-Save

    /// Counts the writes the transport saw.
    @MainActor
    private final class WriteCount {
        private(set) var count = 0
        func note() { count += 1 }
    }

    /// Done with Auto-Save off (the editor's default) closes and writes nothing:
    /// the edits stay the person's to save and live in the device draft, and the
    /// reader still hears that the editor closed.
    @Test func doneWithAutoSaveOffWritesNothingAndKeepsTheDraft() async throws {
        let writes = WriteCount()
        let saved = tag("b")
        let transport = WorkspaceFileEditTransport(
            read: { _ in .failed },
            write: { _, _, _ in
                await writes.note()
                return .saved(etag: saved)
            }
        )
        let store = draftStore()
        var finished = 0
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            transport: transport,
            draftStore: store,
            handlers: .init(didFinishEditing: { finished += 1 }),
            autoSave: false
        )

        _ = await owner.read()
        owner.beginEditing()
        let page = try #require(owner.makeEditorPage(checkoutSubtitle: nil))
        page.loadViewIfNeeded()
        let session = try #require(owner.session)
        page.editor.textView.text = "kept words"
        session.noteEdit()

        owner.endEditing()

        #expect(await eventually { finished == 1 }, "the reader hears the editor closed")
        #expect(writes.count == 0, "Done with Auto-Save off writes nothing")
        #expect(session.hasUnconfirmedChanges, "the edits are still the person's to save")
        #expect(session.status == .pending)
        #expect(store.load(session.identity)?.bytes == Data("kept words".utf8), "the draft keeps them")
    }

    // MARK: A record's prompt

    /// An Agent's prompt is a document the owner can open, on its prompt alone:
    /// the mode stays with the Agent's own form, not this editor.
    @Test func agentPromptOpensTheEditorOnItsText() async {
        let owner = owner(
            subject: .agentInstructions(agentId: "agent-1"),
            serverId: "srv",
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data("Review the diff.".utf8), etag: "2"),
            transport: savedTransport
        )

        #expect(await owner.read() == .bytes(
            WorkspaceFileDiskSnapshot(bytes: Data("Review the diff.".utf8), etag: "2"),
            draftText: nil
        ))
        #expect(owner.identity == WorkspaceFileEditIdentity(serverId: "srv", agentId: "agent-1"))
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])

        owner.beginEditing()
        let page = owner.makeEditorPage(checkoutSubtitle: nil)
        page?.loadViewIfNeeded()
        #expect(page?.editor.textView.text == "Review the diff.", "the editor holds the prompt")
    }

    /// A Schedule's prompt opens the same editor, on the schedule's own prompt.
    @Test func schedulePromptOpensTheEditorOnItsPrompt() async {
        let schedule = owner(
            subject: .schedulePrompt(scheduleId: "schedule-1"),
            serverId: "srv",
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data("Summarize.".utf8), etag: "4"),
            transport: savedTransport
        )
        _ = await schedule.read()
        schedule.beginEditing()
        let schedulePage = schedule.makeEditorPage(checkoutSubtitle: nil)
        schedulePage?.loadViewIfNeeded()
        #expect(schedulePage?.editor.textView.text == "Summarize.")
        #expect(schedule.identity == WorkspaceFileEditIdentity(serverId: "srv", scheduleId: "schedule-1"))
    }

    /// Done's confirmation names the document: a file by its own name, a
    /// record's prompt by the subject's word. The editor's own title cannot
    /// answer it — it reads "Edit" for a file, which asked "Save Edit?".
    @Test func theConfirmationNamesTheDocument() {
        func name(_ subject: DocumentEditSubject, _ identity: WorkspaceFileEditIdentity) -> String {
            DocumentEditOwner.saveConfirmationName(subject: subject, identity: identity)
        }

        #expect(name(
            workspaceSubject(path: "dir/notes.md"),
            WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "dir/notes.md")
        ) == "notes.md")
        #expect(name(
            skillSubject(path: "SKILL.md"),
            WorkspaceFileEditIdentity(serverId: "srv", skillId: "release", path: "SKILL.md")
        ) == "SKILL.md")
        #expect(name(
            .piFile(path: "SYSTEM.md", seedText: nil),
            WorkspaceFileEditIdentity(serverId: "srv", piPath: "SYSTEM.md")
        ) == "SYSTEM.md")
        #expect(name(
            .agentInstructions(agentId: "agent-1"),
            WorkspaceFileEditIdentity(serverId: "srv", agentId: "agent-1")
        ) == "System Prompt")
        #expect(name(
            .schedulePrompt(scheduleId: "schedule-1"),
            WorkspaceFileEditIdentity(serverId: "srv", scheduleId: "schedule-1")
        ) == "Prompt")
    }

    /// A prompt subject with no server has nothing to write, so no pencil.
    @Test func promptWithoutAServerHasNoPencil() async {
        let owner = owner(
            subject: .agentInstructions(agentId: "agent-1"),
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )

        #expect(await owner.read() == .ownRead)
        #expect(identifiers(owner).isEmpty)
        #expect(owner.menuActions.count == 1)
    }

    // MARK: Edits from the reader

    /// What the transport was asked to write, and under which version.
    @MainActor
    private final class WriteLog {
        private(set) var bytes: [Data] = []
        private(set) var conditions: [WorkspaceFileWriteCondition] = []
        func note(_ data: Data, _ condition: WorkspaceFileWriteCondition) {
            bytes.append(data)
            conditions.append(condition)
        }
    }

    private func readerEditOwner(
        path: String = "tasks.org",
        fileKind: FileKind = .orgMode,
        text: String,
        log: WriteLog,
        outcome: WorkspaceFileWriteOutcome,
        autoSave: Bool = false
    ) -> DocumentEditOwner {
        let transport = WorkspaceFileEditTransport(
            read: { _ in .failed },
            write: { _, bytes, condition in
                await log.note(bytes, condition)
                return outcome
            }
        )
        return owner(
            subject: workspaceSubject(path: path, fileKind: fileKind),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data(text.utf8), etag: tag("a")),
            transport: transport,
            autoSave: autoSave
        )
    }

    /// A tapped checkbox saves only the edited text, under the version the reader
    /// read, even with Auto-Save off, and the next edit rides the newer version.
    @Test func aReaderEditWritesTheEditedTextUnderTheReadVersion() async {
        let log = WriteLog()
        let owner = readerEditOwner(text: "* TODO a\n- [ ] x\n- [ ] y\n", log: log, outcome: .saved(etag: tag("b")))
        _ = await owner.read()
        #expect(owner.allowsReaderEdits)

        let first = await owner.saveReaderEdit { TaskSourceEdit.toggleCheckbox(in: $0, line: 2, dialect: .org) }
        #expect(first == .saved("* TODO a\n- [X] x\n- [ ] y\n"))
        #expect(log.bytes == [Data("* TODO a\n- [X] x\n- [ ] y\n".utf8)])
        #expect(log.conditions == [.version(tag("a"))])
        #expect(!owner.isEditing, "a saved edit leaves the reader as it was")

        let second = await owner.saveReaderEdit { TaskSourceEdit.toggleCheckbox(in: $0, line: 3, dialect: .org) }
        #expect(second == .saved("* TODO a\n- [X] x\n- [X] y\n"))
        #expect(log.conditions.last == .version(tag("b")), "the second save is conditioned on the first save's version")
    }

    /// A file that changed on disk is a conflict, not an overwrite: the write is
    /// refused by its version check, the editor opens with the edit in its
    /// buffer, and nothing writes again by itself.
    @Test func aReaderEditOnAChangedFileOpensTheEditorOnTheConflict() async {
        let log = WriteLog()
        let owner = readerEditOwner(text: "* TODO a\n- [ ] x\n", log: log, outcome: .stale)
        _ = await owner.read()

        let outcome = await owner.saveReaderEdit { TaskSourceEdit.toggleCheckbox(in: $0, line: 2, dialect: .org) }

        #expect(outcome == .needsAttention)
        #expect(log.conditions == [.version(tag("a"))], "one conditional write, never a retry or an unconditional one")
        #expect(owner.isEditing, "the existing editor shows the conflict banner")
        #expect(owner.session?.status == .conflict)
        #expect(owner.session?.currentText == "* TODO a\n- [X] x\n", "the edit waits in the buffer for the person's choice")
        #expect(!owner.allowsReaderEdits, "the reader's controls rest while the editor is open")
    }

    @Test func anEditThatChangesNothingWritesNothing() async {
        let log = WriteLog()
        let owner = readerEditOwner(text: "* TODO a\n", log: log, outcome: .saved(etag: tag("b")))
        _ = await owner.read()

        #expect(await owner.saveReaderEdit { _ in nil } == .unchanged)
        #expect(await owner.saveReaderEdit { $0 } == .unchanged)
        #expect(log.bytes.isEmpty)
    }

    /// A file the editor cannot save (a host file no server origin claims, or one
    /// the server does not edit) has no controls: the reader never offers what
    /// it cannot keep.
    @Test func aFileTheEditorCannotSaveAllowsNoReaderEdits() async {
        let log = WriteLog()
        let transport = WorkspaceFileEditTransport(
            read: { _ in .failed },
            write: { _, bytes, condition in
                await log.note(bytes, condition)
                return .saved(etag: "x")
            }
        )
        let hostFile = DocumentEditSubject.file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: "/Users/alex/notebook/projects/oppi.org",
            skillFile: nil,
            fileKind: .orgMode
        )
        let host = owner(subject: hostFile, capability: capability, transport: transport)
        #expect(await host.read() == .ownRead)
        #expect(!host.allowsReaderEdits)
        #expect(await host.saveReaderEdit { $0 + "x" } == .unavailable)

        let notEditable = owner(
            subject: workspaceSubject(path: "tasks.org", fileKind: .orgMode),
            capability: nil,
            transport: transport
        )
        _ = await notEditable.read()
        #expect(!notEditable.allowsReaderEdits)

        let untagged = owner(
            subject: workspaceSubject(path: "tasks.org", fileKind: .orgMode),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data("* TODO a".utf8), etag: nil),
            transport: transport
        )
        _ = await untagged.read()
        #expect(!untagged.allowsReaderEdits)
        #expect(await notEditable.saveReaderEdit { $0 + "x" } == .unavailable)
        #expect(await untagged.saveReaderEdit { $0 + "x" } == .unavailable)
        #expect(log.bytes.isEmpty, "nothing is written for a file the reader cannot save")
    }

    /// Controls follow the owner's resolved identity, not the subject's: a home
    /// notebook file the server edits through its host origin gets them, and
    /// writes under the resolving read's version; one it refuses gets none.
    @Test func aHomeFileTheServerEditsGetsReaderEditsAndARefusedOneNone() async {
        let path = "~/notebook/tasks.org"
        let notebook = DocumentEditSubject.file(
            serverId: "srv",
            source: .hostFile,
            workspaceId: "",
            worktreeId: nil,
            path: path,
            skillFile: nil,
            fileKind: .orgMode
        )
        let canonical = WorkspaceFileEditIdentity(serverId: "srv", hostPath: "/Users/alex/notebook/tasks.org")
        let snapshot = WorkspaceFileDiskSnapshot(bytes: Data("* TODO a\n- [ ] x\n".utf8), etag: tag("a"))
        let log = WriteLog()
        let savedTag = tag("b")
        let transport = WorkspaceFileEditTransport(
            read: { _ in .failed },
            write: { _, bytes, condition in
                await log.note(bytes, condition)
                return .saved(etag: savedTag)
            }
        )
        #expect(notebook.editIdentity(serverId: "srv") == nil, "the subject alone names no editor")

        let home = owner(
            subject: notebook,
            capability: capability,
            transport: transport,
            resolve: { _ in .editable(canonical, snapshot, resolvedHostPath: "/Users/alex/notebook/tasks.org") }
        )
        _ = await home.read()
        #expect(home.makeReaderTaskEditing(path: path) { _ in } != nil)
        #expect(await home.saveReaderEdit { TaskSourceEdit.toggleCheckbox(in: $0, line: 2, dialect: .org) } == .saved("* TODO a\n- [X] x\n"))
        #expect(log.conditions == [.version(tag("a"))])

        let refused = owner(
            subject: notebook,
            capability: capability,
            transport: transport,
            resolve: { _ in .readOnly(reason: "protected") }
        )
        #expect(await refused.read() == .ownRead)
        #expect(refused.makeReaderTaskEditing(path: path) { _ in } == nil)
        #expect(await refused.saveReaderEdit { $0 + "x" } == .unavailable)
        #expect(log.bytes.count == 1, "the refused file wrote nothing")
    }
}
