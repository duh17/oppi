import Foundation
import Testing
import UIKit
@testable import Oppi

/// The edit entry's rule, without a server: what opens the pencil, what the "…"
/// offers, and the draft keys existing drafts are stored under.
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

    /// A scripted transport: the owner never gets past the read in these tests.
    private var idleTransport: WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { _ in .failed },
            write: { _, _, _ in .notSent }
        )
    }

    /// Counts the tagged reads, so a test can prove the owner never asks a
    /// server that does not edit the file.
    @MainActor
    private final class ReadSpy {
        private(set) var count = 0

        func note() { count += 1 }
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
        readError: Error? = nil,
        agentAction: DocumentAgentEditAction? = nil,
        placement: DocumentEditOwner.Placement = .screenBar,
        draftStore: WorkspaceFileDraftStore? = nil,
        readSpy: ReadSpy? = nil
    ) -> DocumentEditOwner {
        let transport = idleTransport
        let backend = DocumentEditOwner.Backend(
            capability: { _ in capability },
            read: { _ in
                await readSpy?.note()
                if let readError { throw readError }
                return snapshot
            },
            transport: transport
        )
        return DocumentEditOwner(
            subject: subject,
            placement: placement,
            agentAction: agentAction,
            source: .backend(backend),
            draftStore: draftStore ?? self.draftStore(),
            registry: registry(),
            onChange: {}
        )
    }

    private var capability: ServerInfo.WorkspaceFileEditingCapability {
        ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: 1_048_576)
    }

    private func identifiers(_ owner: DocumentEditOwner) -> [String] {
        owner.barItems.map(\.accessibilityIdentifier).compactMap { $0 }
    }

    // MARK: The editability rule

    @Test func capabilityOffLeavesNoPencilButKeepsEditWithSession() async throws {
        let spy = ReadSpy()
        let owner = owner(
            subject: workspaceSubject(),
            capability: nil,
            agentAction: DocumentAgentEditAction { },
            readSpy: spy
        )
        let read = try await owner.read()

        #expect(read == .ownRead, "no capability: the reader loads the file its own way")
        #expect(spy.count == 0, "a server that does not edit the file gets no tagged read")
        #expect(identifiers(owner) == ["document.edit.more"], "no capability means no pencil, only the overflow item")
        #expect(owner.barItems.first?.menu?.children.count == 1)
    }

    @Test func untaggedReadLeavesNoPencil() async throws {
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: nil)
        )
        let read = try await owner.read()

        #expect(read == .bytes(WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: nil), draftText: nil))
        #expect(owner.barItems.isEmpty, "bytes the server did not offer for editing have no edit entry")
    }

    @Test func binaryBytesLeaveNoPencil() async throws {
        let bytes = Data([0xC3, 0x28])
        let owner = owner(
            subject: workspaceSubject(path: "notes.txt", fileType: .plain),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: bytes, etag: "\"sha256-a\"")
        )
        _ = try await owner.read()

        #expect(owner.barItems.isEmpty, "bytes that are not UTF-8 text cannot open the editor")
    }

    @Test func oversizedBytesLeaveNoPencil() async throws {
        let bytes = Data(repeating: 0x61, count: 8)
        let small = ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: 4)
        let owner = owner(
            subject: workspaceSubject(),
            capability: small,
            snapshot: WorkspaceFileDiskSnapshot(bytes: bytes, etag: "\"sha256-a\"")
        )
        _ = try await owner.read()

        #expect(owner.barItems.isEmpty, "a file over the server's limit cannot open the editor")
    }

    @Test func nonTextFileHasNoEditEntry() async throws {
        let owner = owner(
            subject: workspaceSubject(path: "photo.png", fileType: .image),
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )
        let read = try await owner.read()

        #expect(read == .ownRead)
        #expect(identifiers(owner) == ["document.edit.more"], "an image has no pencil, only the session route")
    }

    @Test func snapshotIsNeverEditable() async throws {
        let owner = owner(
            subject: .snapshot,
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )
        let read = try await owner.read()

        #expect(read == .ownRead)
        #expect(identifiers(owner) == ["document.edit.more"], "a prompt reader offers only Edit with Session")
    }

    @Test func snapshotWithoutAnAgentActionOffersNothing() async throws {
        let owner = owner(subject: .snapshot, capability: capability)
        _ = try await owner.read()

        #expect(owner.barItems.isEmpty)
    }

    /// The three conditions together: identity, capability, tagged UTF-8 read.
    @Test func taggedTextReadOffersBothControls() async throws {
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            agentAction: DocumentAgentEditAction { }
        )
        let read = try await owner.read()

        #expect(read == .bytes(WorkspaceFileDiskSnapshot(bytes: Data("hello".utf8), etag: "\"sha256-a\""), draftText: nil))
        #expect(identifiers(owner) == ["document.edit.more", "workspace-file-editor.edit"])

        let pencil = try #require(owner.barItems.last)
        #expect(pencil.title == DocumentEditLabels.edit)
        #expect(pencil.accessibilityLabel == DocumentEditLabels.editFile)
        let more = try #require(owner.barItems.first)
        #expect(more.image == UIImage(systemName: "ellipsis.circle"))
        let edit = try #require(more.menu?.children.first as? UIAction)
        #expect(edit.title == DocumentEditLabels.editWithSession)
        #expect(edit.accessibilityIdentifier == "controlFile.editInSession")
    }

    @Test func readerBarKeepsTheReadersPencilIdentifier() async throws {
        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            placement: .readerBar
        )
        _ = try await owner.read()

        #expect(identifiers(owner) == ["fullscreen-code.action.workspace-file-edit"])
    }

    @Test func skillFileReadsThroughItsSkillIdentity() async throws {
        let owner = owner(subject: skillSubject(), capability: capability)
        _ = try await owner.read()

        #expect(owner.identity == WorkspaceFileEditIdentity(serverId: "srv", skillId: "release", path: "SKILL.md"))
        #expect(identifiers(owner) == ["workspace-file-editor.edit"])
    }

    @Test func hostFileOutsideASkillHasNoEditEntry() async throws {
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
        let read = try await owner.read()

        #expect(read == .ownRead)
        #expect(owner.barItems.isEmpty)
    }

    @Test func startingAgentActionDisablesEditWithSession() async throws {
        let owner = owner(
            subject: .snapshot,
            capability: capability,
            agentAction: DocumentAgentEditAction(isStarting: true) { }
        )
        _ = try await owner.read()

        let more = try #require(owner.barItems.first)
        let edit = try #require(more.menu?.children.first as? UIAction)
        #expect(edit.title == DocumentEditLabels.startingSession)
        #expect(edit.attributes.contains(.disabled))
    }

    // MARK: Draft keys

    /// A draft saved before this slice must still load: the workspace and Skill
    /// keys are the ones the app has always written.
    @Test func existingDraftKeysStillLoad() throws {
        let workspace = WorkspaceFileEditIdentity(
            serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md"
        )
        let worktree = WorkspaceFileEditIdentity(
            serverId: "srv", workspaceId: "w1", worktreeId: "wt-1", path: "notes.md"
        )
        let skill = WorkspaceFileEditIdentity(serverId: "srv", skillId: "skill_1", path: "refs/a.md")

        #expect(workspace.storageKey == "38fbdc66ee984456cb9e2cc52148ab18fb2bda8ffc9918d4bfbded4f5831342f")
        #expect(worktree.storageKey == "54f0fc06518331abc3d6b3490901a7e8f860d429a790e43352d8dcc4ebe72e7d")
        #expect(skill.storageKey == "25c4e2c6e5078f8f2016d6f49243ec27fc5d99657e061dc2d0023ec925a86691")

        // The file an earlier build left behind, read back through today's store.
        let store = draftStore()
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

    /// A kept draft wins over disk and opens the editor on it.
    @Test func keptDraftReopensInTheEditor() async throws {
        let store = draftStore()
        let identity = WorkspaceFileEditIdentity(
            serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md"
        )
        let draft = WorkspaceFileDraft(
            identity: identity,
            baseEtag: tag("a"),
            bytes: Data("draft words".utf8),
            updatedAt: Date()
        )
        try store.save(draft)

        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            snapshot: WorkspaceFileDiskSnapshot(bytes: Data("disk words".utf8), etag: tag("a")),
            draftStore: store
        )
        let read = try await owner.read()

        guard case .bytes(_, let draftText) = read else {
            Issue.record("expected the tagged read, got \(read)")
            return
        }
        #expect(draftText == "draft words", "the kept draft is what the reader shows")
        #expect(owner.isEditing, "a recovered draft opens the editor")
    }

    /// The file is gone: its kept draft reopens in the non-writing state.
    @Test func deletedFileKeepsItsDraft() async throws {
        let store = draftStore()
        let identity = WorkspaceFileEditIdentity(
            serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md"
        )
        try store.save(WorkspaceFileDraft(
            identity: identity,
            baseEtag: tag("a"),
            bytes: Data("kept after delete".utf8),
            updatedAt: Date()
        ))

        let owner = owner(
            subject: workspaceSubject(),
            capability: capability,
            readError: APIError.server(status: 404, message: "not found"),
            draftStore: store
        )
        let read = try await owner.read()

        #expect(read == .deletedDraft("kept after delete"))
        #expect(owner.isEditing)
        #expect(owner.session?.status == .deleted)
    }
}
