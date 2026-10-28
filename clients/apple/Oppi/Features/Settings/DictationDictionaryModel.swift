import Foundation
import Observation

/// How the Dictation Dictionary reaches a server: the same authenticated lists
/// `oppi dictionary` edits. `APIClient` is the live one; a test passes a fake.
protocol DictationDictionaryService: Sendable {
    func dictationDictionary(workspaceId: String?) async throws -> DictationDictionaryList
    func saveDictationDictionary(workspaceId: String?, revision: Int, phrases: [String]) async throws -> DictationDictionaryList
}

extension APIClient: DictationDictionaryService {}

/// The Dictation Dictionary page's state: the server's All Workspaces list and,
/// when the page is opened from a workspace, that workspace's list, each as the
/// last saved copy and a draft the person edits. Nothing is cached on the
/// device. Save writes whichever drafts changed, both validated first, so a
/// rejected draft never leaves the server half-updated; a failed save keeps
/// the drafts.
@MainActor @Observable
final class DictationDictionaryModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        /// The lists could not be read. The text says why and what to do.
        case failed(String)
    }

    let serverId: String
    let serverName: String
    let workspaceId: String?
    let workspaceName: String?

    private(set) var loadState: LoadState = .loading
    private(set) var global: DictationDictionaryList?
    private(set) var workspace: DictationDictionaryList?
    private(set) var globalDraft: [String] = []
    private(set) var workspaceDraft: [String] = []
    /// What the phrase being added or edited says, and where it goes.
    var phrase = ""
    var addsToWorkspace = false
    private(set) var editing: DictationDictionaryDraft.Editing?
    /// Whether the phrase editor is open (Add Phrase, or a tapped row).
    private(set) var isComposing = false
    /// Changes whenever the editor opens or closes, so the field row knows its text was replaced.
    private(set) var composeGeneration = 0
    /// A problem with the last edit, save, or delete. The lists stay as they are.
    private(set) var notice: String?
    private(set) var isSaving = false

    @ObservationIgnored private let service: (any DictationDictionaryService)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        serverId: String,
        serverName: String,
        workspaceId: String? = nil,
        workspaceName: String? = nil,
        service: (any DictationDictionaryService)?
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.service = service
    }

    // MARK: - Derived

    var selection: DictationDictionarySelection {
        .make(workspace: workspaceDraft, global: globalDraft)
    }

    /// Whether a draft differs from what the server has.
    var hasChanges: Bool {
        globalDraft != global?.phrases || workspaceDraft != (workspace?.phrases ?? [])
    }

    var canSave: Bool { !isSaving && global != nil && hasChanges }

    var canAddPhrase: Bool { !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Load

    /// Reads both lists. A newer call replaces one still running, so an answer
    /// that arrives late never overwrites what a retry loaded.
    func load() {
        loadTask?.cancel()
        global = nil
        workspace = nil
        notice = nil
        loadState = .loading
        let task = Task { await fetch() }
        loadTask = task
    }

    /// Reads both lists, finishing when they are loaded or have failed.
    func fetch() async {
        guard let service else {
            loadState = .failed(String(localized: "Connect to \(serverName) to edit its dictionary."))
            return
        }
        do {
            let all = try await service.dictationDictionary(workspaceId: nil)
            var local: DictationDictionaryList?
            if let workspaceId { local = try await service.dictationDictionary(workspaceId: workspaceId) }
            guard !Task.isCancelled else { return }
            global = all
            workspace = local
            globalDraft = all.phrases
            workspaceDraft = local?.phrases ?? []
            cancelComposing()
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(String(localized: "The dictionary is unavailable. Nothing was changed. Retry once \(serverName) is reachable."))
        }
    }

    // MARK: - Edit

    func beginAdding() {
        editing = nil
        phrase = ""
        addsToWorkspace = workspaceId != nil
        isComposing = true
        composeGeneration += 1
    }

    func beginEditing(workspaceScope: Bool, index: Int) {
        let list = workspaceScope ? workspaceDraft : globalDraft
        guard list.indices.contains(index) else { return }
        editing = .init(workspace: workspaceScope, index: index, phrase: list[index])
        addsToWorkspace = workspaceScope
        phrase = list[index]
        isComposing = true
        composeGeneration += 1
    }

    func cancelComposing() {
        phrase = ""
        editing = nil
        isComposing = false
        composeGeneration += 1
    }

    func addPhrase() {
        let value = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard DictationDictionaryDraft.add(
            value, workspaceScope: addsToWorkspace,
            global: &globalDraft, workspace: &workspaceDraft, editing: &editing
        ) else {
            notice = String(localized: "Phrase was not added: it already exists in that list, or the edited row changed.")
            return
        }
        notice = nil
        cancelComposing()
    }

    func deletePhrase(workspaceScope: Bool, index: Int) {
        let list = workspaceScope ? workspaceDraft : globalDraft
        guard list.indices.contains(index) else { return }
        DictationDictionaryDraft.delete(
            offsets: IndexSet(integer: index), workspaceScope: workspaceScope,
            global: &globalDraft, workspace: &workspaceDraft, editing: &editing
        )
        cancelComposing()
    }

    // MARK: - Save

    /// Writes the drafts that changed. Both are validated before either is
    /// sent. On failure the drafts stay, and the notice says so.
    func save() async {
        guard canSave, let service, let global else { return }
        if let reason = DictationDictionaryDraft.saveError(global: globalDraft, workspace: workspaceDraft) {
            notice = reason
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if globalDraft != global.phrases {
                self.global = try await service.saveDictationDictionary(
                    workspaceId: nil, revision: global.revision, phrases: globalDraft
                )
            }
            if let workspaceId, let workspace, workspaceDraft != workspace.phrases {
                self.workspace = try await service.saveDictationDictionary(
                    workspaceId: workspaceId, revision: workspace.revision, phrases: workspaceDraft
                )
            }
            notice = nil
        } catch {
            notice = String(localized: "Save failed, or the list changed on \(serverName). Your edits stay here. Retry reloads the lists from \(serverName) and discards them.")
        }
    }

    /// Deletes this workspace's phrases on the server. The All Workspaces draft
    /// must be valid, and nothing changes here unless the server accepts it.
    func deleteWorkspacePhrases() async {
        guard !isSaving, let service, let workspaceId, let workspace else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await DictationDictionaryDraft.deleteWorkspacePhrases(global: globalDraft) {
                try await service.saveDictationDictionary(workspaceId: workspaceId, revision: workspace.revision, phrases: [])
            }
            self.workspace = saved
            workspaceDraft = saved.phrases
            if editing?.workspace == true { cancelComposing() }
            notice = nil
        } catch let error as DictationDictionaryDraft.DeleteBlocked {
            notice = error.reason
        } catch {
            notice = String(localized: "Delete failed, or the list changed on \(serverName). This workspace's edits stay here.")
        }
    }
}

/// User-visible dictionary copy. Never name a local ASR implementation.
enum DictationDictionaryCopy {
    static func consentFooter(serverName: String, provider: String) -> String {
        let service = provider == "xai"
            ? "xAI speech-to-text service"
            : "speech-to-text service"
        return "When enabled, selected phrases leave this device for paired server \(serverName) and its configured \(service). Default off. On-device dictation can use phrases without sending them. Selected does not mean applied; the speech provider may ignore hints."
    }

    /// The All Workspaces section's footer: whose list it is, and, from a
    /// workspace, that editing it here changes it for every workspace.
    static func globalFooter(serverName: String, workspaceName: String?) -> String {
        guard let workspaceName else {
            return String(localized: "The list every workspace on \(serverName) uses, on every device. Save writes it to \(serverName).")
        }
        return String(localized: "The list every workspace on \(serverName) uses. Editing it here changes it for all of them, not only \(workspaceName).")
    }

    static func workspaceFooter(serverName: String) -> String {
        String(localized: "Added to All Workspaces when you dictate in this workspace. Kept on \(serverName).")
    }

    static func exclusion(_ reason: DictationDictionarySelection.Exclusion) -> String {
        switch reason {
        case .duplicate: String(localized: "Excluded: already selected in This Workspace")
        case .phraseBytes: String(localized: "Excluded: over 256 UTF-8 bytes")
        case .phraseCount: String(localized: "Excluded: over 100 selected phrases")
        case .totalBytes: String(localized: "Excluded: over 8192 total UTF-8 bytes")
        }
    }
}

/// Draft operations shared by row actions and validation; never remove the
/// source until the destination is known to accept the edit.
enum DictationDictionaryDraft {
    struct DeleteBlocked: Error {
        let reason: String
    }

    /// Sends the empty list for a workspace, unless the All Workspaces draft
    /// would not save. The caller keeps its draft until this returns.
    @MainActor
    static func deleteWorkspacePhrases(
        global: [String],
        put: () async throws -> DictationDictionaryList
    ) async throws -> DictationDictionaryList {
        if let reason = saveError(global: global, workspace: []) {
            throw DeleteBlocked(reason: reason)
        }
        return try await put()
    }

    struct Editing: Equatable {
        let workspace: Bool
        let index: Int
        let phrase: String
    }

    static func delete(
        offsets: IndexSet, workspaceScope: Bool,
        global: inout [String], workspace: inout [String], editing: inout Editing?
    ) {
        editing = nil
        if workspaceScope { workspace.remove(atOffsets: offsets) } else { global.remove(atOffsets: offsets) }
    }

    @discardableResult
    static func add(
        _ value: String, workspaceScope: Bool,
        global: inout [String], workspace: inout [String], editing: inout Editing?
    ) -> Bool {
        if let editing {
            let source = editing.workspace ? workspace : global
            guard source.indices.contains(editing.index), source[editing.index] == editing.phrase else {
                return false
            }
        }
        if let editing, editing.workspace == workspaceScope, editing.phrase == value {
            return true // Unchanged edit must not reorder the list.
        }
        let destination = workspaceScope ? workspace : global
        // Renaming to an existing destination must leave the original intact.
        guard !destination.contains(value) else { return false }
        if let editing {
            if editing.workspace { workspace.remove(at: editing.index) } else { global.remove(at: editing.index) }
        }
        if workspaceScope { workspace.append(value) } else { global.append(value) }
        return true
    }

    static func saveError(global: [String], workspace: [String]) -> String? {
        for (name, phrases) in [("All Workspaces", global), ("This Workspace", workspace)] {
            if phrases.count > DictationContextualStrings.maxPhraseCount {
                return "Not saved: \(name) exceeds 100 saved phrases. Remove excluded rows before saving."
            }
            var seen = Set<String>()
            for phrase in phrases {
                if phrase.utf8.count > DictationContextualStrings.maxPhraseUTF8Bytes {
                    return "Not saved: \(name) has a phrase over 256 UTF-8 bytes. Remove or shorten it before saving."
                }
                if phrase.isEmpty || phrase != phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    || phrase.hasPrefix("\u{FEFF}") || phrase.hasSuffix("\u{FEFF}")
                    || phrase.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }) {
                    return "Not saved: \(name) has an empty, whitespace-padded, or control-character phrase."
                }
                if !seen.insert(phrase).inserted {
                    return "Not saved: \(name) has a duplicate phrase."
                }
            }
        }
        return nil
    }
}
