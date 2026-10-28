import Foundation
import Testing
@testable import Oppi

/// The Dictation Dictionary page's state over a fake server: loading, the
/// retry after a failure, and the saves and deletes that must leave the server
/// and the drafts in a known place when they fail.
@Suite("Dictation Dictionary model")
@MainActor
struct DictationDictionaryModelTests {
    private struct Offline: Error {}

    /// A server holding both lists, recording every write.
    private final class FakeServer: DictationDictionaryService, @unchecked Sendable {
        var global = DictationDictionaryList(revision: 1, phrases: ["Oppi", "Tailscale"], provider: "xai")
        var workspace = DictationDictionaryList(revision: 4, phrases: ["oppi-dev"], provider: nil)
        var reads = 0
        var writes: [(workspaceId: String?, revision: Int, phrases: [String])] = []
        var failReads = false
        var failWritesFor: Set<String?> = []

        func dictationDictionary(workspaceId: String?) async throws -> DictationDictionaryList {
            reads += 1
            if failReads { throw Offline() }
            return workspaceId == nil ? global : workspace
        }

        func saveDictationDictionary(workspaceId: String?, revision: Int, phrases: [String]) async throws -> DictationDictionaryList {
            if failWritesFor.contains(workspaceId) { throw Offline() }
            writes.append((workspaceId, revision, phrases))
            let saved = DictationDictionaryList(revision: revision + 1, phrases: phrases, provider: workspaceId == nil ? global.provider : nil)
            if workspaceId == nil { global = saved } else { workspace = saved }
            return saved
        }
    }

    private func makeModel(_ server: FakeServer?, workspace: Bool = true) -> DictationDictionaryModel {
        DictationDictionaryModel(
            serverId: "s1", serverName: "mac-studio",
            workspaceId: workspace ? "w1" : nil, workspaceName: workspace ? "oppi" : nil,
            service: server
        )
    }

    @Test("A failed load says so and keeps nothing; Retry loads both lists")
    func failedLoadThenRetry() async {
        let server = FakeServer()
        server.failReads = true
        let model = makeModel(server)

        await model.fetch()
        guard case .failed(let reason) = model.loadState else {
            Issue.record("expected a failed load, got \(model.loadState)")
            return
        }
        #expect(reason.contains("mac-studio"))
        #expect(model.global == nil)

        server.failReads = false
        await model.fetch()
        #expect(model.loadState == .loaded)
        #expect(model.globalDraft == ["Oppi", "Tailscale"])
        #expect(model.workspaceDraft == ["oppi-dev"])
        #expect(!model.hasChanges)
    }

    @Test("With no connection the page says which server to connect to, and cannot save")
    func noConnection() async {
        let model = makeModel(nil)
        await model.fetch()
        guard case .failed(let reason) = model.loadState else {
            Issue.record("expected a failed load")
            return
        }
        #expect(reason.contains("mac-studio"))
        #expect(!model.canSave)
    }

    @Test("Saving from a workspace writes both lists when both changed, each against its own revision")
    func saveWritesBothChangedLists() async {
        let server = FakeServer()
        let model = makeModel(server)
        await model.fetch()
        model.beginAdding()
        model.phrase = "Ghostty"
        model.addsToWorkspace = false
        model.addPhrase()
        model.beginAdding()
        model.phrase = "herdr"
        model.addPhrase()   // a workspace phrase: beginAdding defaults to This Workspace
        #expect(model.canSave)

        await model.save()

        #expect(server.writes.count == 2)
        #expect(server.writes.first { $0.workspaceId == nil }?.revision == 1)
        #expect(server.writes.first { $0.workspaceId == nil }?.phrases == ["Oppi", "Tailscale", "Ghostty"])
        #expect(server.writes.first { $0.workspaceId == "w1" }?.revision == 4)
        #expect(server.writes.first { $0.workspaceId == "w1" }?.phrases == ["oppi-dev", "herdr"])
        #expect(!model.hasChanges)
        #expect(model.notice == nil)
    }

    @Test("A draft the server would refuse is stopped before either list is sent")
    func invalidDraftSendsNothing() async {
        let server = FakeServer()
        let model = makeModel(server)
        await model.fetch()
        model.beginAdding()
        model.phrase = "ok phrase"
        model.addPhrase()
        // 101 workspace phrases cannot be saved.
        for index in 0...100 {
            model.beginAdding()
            model.phrase = "name\(index)"
            model.addPhrase()
        }

        await model.save()

        #expect(server.writes.isEmpty)
        #expect(model.notice?.contains("This Workspace") == true)
        #expect(model.hasChanges, "the drafts are kept")
    }

    @Test("A failed save keeps every draft and names the server in what to do next")
    func failedSaveKeepsDrafts() async {
        let server = FakeServer()
        server.failWritesFor = [nil]
        let model = makeModel(server, workspace: false)
        await model.fetch()
        model.beginAdding()
        model.phrase = "Ghostty"
        model.addPhrase()

        await model.save()

        #expect(model.globalDraft == ["Oppi", "Tailscale", "Ghostty"])
        #expect(model.global?.phrases == ["Oppi", "Tailscale"])
        #expect(model.notice?.contains("mac-studio") == true)
        #expect(model.canSave, "the person can try again")
    }

    @Test("Delete Workspace Phrases empties only the workspace's list, and only once the server accepts it")
    func deleteWorkspacePhrases() async {
        let server = FakeServer()
        let model = makeModel(server)
        await model.fetch()

        server.failWritesFor = ["w1"]
        await model.deleteWorkspacePhrases()
        #expect(model.workspaceDraft == ["oppi-dev"], "a refused delete keeps the draft")
        #expect(model.notice != nil)

        server.failWritesFor = []
        await model.deleteWorkspacePhrases()
        #expect(model.workspaceDraft.isEmpty)
        #expect(model.workspace?.phrases == [])
        #expect(server.writes.map(\.workspaceId) == ["w1"], "the All Workspaces list is untouched")
        #expect(model.notice == nil)
    }

    @Test("Delete is blocked while the All Workspaces draft could not be saved")
    func deleteBlockedByInvalidGlobalDraft() async {
        let server = FakeServer()
        server.global = DictationDictionaryList(revision: 1, phrases: (0...100).map { "name\($0)" }, provider: nil)
        let model = makeModel(server)
        await model.fetch()

        await model.deleteWorkspacePhrases()

        #expect(server.writes.isEmpty)
        #expect(model.workspaceDraft == ["oppi-dev"])
        #expect(model.notice?.contains("All Workspaces") == true)
    }

    @Test("Adding a phrase that already exists, or whose edited row moved, changes nothing and says why")
    func duplicatePhraseIsRefused() async {
        let server = FakeServer()
        let model = makeModel(server, workspace: false)
        await model.fetch()
        model.beginAdding()
        model.phrase = "Oppi"
        model.addPhrase()
        #expect(model.globalDraft == ["Oppi", "Tailscale"])
        #expect(model.notice != nil)
        #expect(model.isComposing, "the editor stays open to fix it")
    }

    @Test("Editing a phrase renames it in place of the old one; deleting a row closes the editor")
    func editAndDelete() async {
        let server = FakeServer()
        let model = makeModel(server, workspace: false)
        await model.fetch()
        model.beginEditing(workspaceScope: false, index: 1)
        #expect(model.phrase == "Tailscale")
        model.phrase = "Tailnet"
        model.addPhrase()
        #expect(model.globalDraft == ["Oppi", "Tailnet"])

        model.beginEditing(workspaceScope: false, index: 0)
        model.deletePhrase(workspaceScope: false, index: 0)
        #expect(model.globalDraft == ["Tailnet"])
        #expect(!model.isComposing)
    }

    @Test("The consent and scope footers name the server and say where a workspace edit lands")
    func footersNameTheServer() {
        let fromWorkspace = DictationDictionaryCopy.globalFooter(serverName: "mac-studio", workspaceName: "oppi")
        #expect(fromWorkspace.contains("mac-studio"))
        #expect(fromWorkspace.contains("changes it for all of them"))
        let fromSettings = DictationDictionaryCopy.globalFooter(serverName: "mac-studio", workspaceName: nil)
        #expect(fromSettings.contains("Save writes it to mac-studio"))
        #expect(DictationDictionaryCopy.workspaceFooter(serverName: "mac-studio").contains("mac-studio"))
    }
}
