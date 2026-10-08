import SwiftUI

/// The same authenticated server list edited by `oppi dictionary`; no local phrase cache.
struct DictationDictionaryView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let workspaceId: String?

    @State private var global: DictationDictionaryList?
    @State private var workspace: DictationDictionaryList?
    @State private var globalDraft: [String] = []
    @State private var workspaceDraft: [String] = []
    @State private var phrase = ""
    @State private var editing: DictationDictionaryDraft.Editing?
    @State private var addToWorkspace = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var sendToServer = false
    @State private var confirmingForget = false

    private var serverId: String? { coordinator.activeServerId }
    private var api: APIClient? { serverId.flatMap { coordinator.apiClient(for: $0) } }
    private var selection: DictationDictionarySelection {
        .make(workspace: workspaceDraft, global: globalDraft)
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.themeComment)
                    Button("Reload from Server") { Task { await load() } }
                }
            }
            if global != nil {
                entries(title: "All Workspaces", phrases: globalDraft, scope: .global)
                if workspaceId != nil {
                    entries(title: "This Workspace", phrases: workspaceDraft, scope: .workspace)
                }
                Section {
                    Button {
                        editing = nil
                        phrase = ""
                        addToWorkspace = workspaceId != nil
                    } label: {
                        Label("Add Phrase", systemImage: "plus")
                    }
                    if !phrase.isEmpty || editing != nil {
                        if workspaceId != nil {
                            Picker("Scope", selection: $addToWorkspace) {
                                Text("All Workspaces").tag(false)
                                Text("This Workspace").tag(true)
                            }
                        }
                        TextField("Phrase", text: $phrase)
                            .textInputAutocapitalization(.words)
                        HStack {
                            Button("Cancel") { phrase = ""; editing = nil }
                            Spacer()
                            Button("Add to List") { addPhrase() }
                                .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } footer: {
                    Text("Saved phrases are hints, not guaranteed transcriptions. Entries marked excluded will not be selected for the next take.")
                }
                if let provider = global?.provider, let serverId {
                    Section {
                        Toggle("Send Selected Phrases to Server Dictation", isOn: $sendToServer)
                            .onChange(of: sendToServer) { _, enabled in
                                DictationDictionaryConsent.setEnabled(enabled, serverId: serverId, provider: provider)
                            }
                    } footer: {
                        Text(DictationDictionaryCopy.consentFooter(
                            serverName: serverName(serverId),
                            provider: provider
                        ))
                    }
                }
                if workspaceId != nil {
                    Section {
                        Button("Forget This Workspace", role: .destructive) { confirmingForget = true }
                            .disabled(isSaving)
                    }
                }
            }
        }
        .settingsPage("Dictionary")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || global == nil ||
                        (globalDraft == global?.phrases && workspaceDraft == (workspace?.phrases ?? [])))
            }
        }
        .task(id: "\(serverId ?? ""):\(workspaceId ?? "")") { await load() }
        .confirmationDialog(
            "Forget this workspace's phrases?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget This Workspace", role: .destructive) {
                Task { await forgetWorkspace() }
            }
        } message: {
            Text("This deletes this workspace's phrases on the server. Phrases for All Workspaces stay.")
        }
    }

    private func entries(title: String, phrases: [String], scope: DictationDictionarySelection.Scope) -> some View {
        Section(title) {
            ForEach(Array(phrases.enumerated()), id: \.offset) { index, value in
                let entry = selection.entries.first { $0.scope == scope && $0.phrase == value }
                Button {
                    editing = .init(workspace: scope == .workspace, index: index, phrase: value)
                    addToWorkspace = scope == .workspace
                    phrase = value
                } label: {
                    VStack(alignment: .leading) {
                        Text(value).foregroundStyle(.themeFg)
                        if let reason = entry?.exclusion {
                            Text(exclusionText(reason)).font(.caption).foregroundStyle(.themeComment)
                        } else if global?.provider == "xai" && value.unicodeScalars.count > 50 {
                            Text("Excluded from xAI Server dictation (over 50 characters)")
                                .font(.caption).foregroundStyle(.themeComment)
                        }
                    }
                }
            }
            .onDelete { offsets in
                DictationDictionaryDraft.delete(
                    offsets: offsets, workspaceScope: scope == .workspace,
                    global: &globalDraft, workspace: &workspaceDraft, editing: &editing
                )
                phrase = ""
            }
        }
    }

    private func exclusionText(_ reason: DictationDictionarySelection.Exclusion) -> String {
        switch reason {
        case .duplicate: "Excluded: already selected in This Workspace"
        case .phraseBytes: "Excluded: over 256 UTF-8 bytes"
        case .phraseCount: "Excluded: over 100 selected phrases"
        case .totalBytes: "Excluded: over 8192 total UTF-8 bytes"
        }
    }

    private func addPhrase() {
        let value = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard DictationDictionaryDraft.add(
            value, workspaceScope: addToWorkspace,
            global: &globalDraft, workspace: &workspaceDraft, editing: &editing
        ) else {
            errorMessage = "Phrase was not added: it already exists in that scope or the edited row changed."
            return
        }
        errorMessage = nil
        phrase = ""
        editing = nil
    }

    private func load() async {
        global = nil
        workspace = nil
        errorMessage = nil
        guard let api else { errorMessage = "Connect to a paired server to edit its dictionary."; return }
        do {
            let all = try await api.dictationDictionary(workspaceId: nil)
            let local: DictationDictionaryList?
            if let workspaceId {
                local = try await api.dictationDictionary(workspaceId: workspaceId)
            } else {
                local = nil
            }
            global = all
            workspace = local
            globalDraft = all.phrases
            workspaceDraft = local?.phrases ?? []
            if let serverId, let provider = all.provider {
                sendToServer = DictationDictionaryConsent.isEnabled(serverId: serverId, provider: provider)
            }
        } catch { errorMessage = "Dictionary unavailable. Lists were not changed; retry after reconnecting." }
    }

    private func save() async {
        guard let api, let global else { return }
        // Validate both scopes before either PUT, so a rejected draft cannot
        // leave the server half-updated or silently omit visible rows.
        if let reason = DictationDictionaryDraft.saveError(
            global: globalDraft, workspace: workspaceDraft
        ) {
            errorMessage = reason
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if globalDraft != global.phrases {
                self.global = try await api.saveDictationDictionary(
                    workspaceId: nil, revision: global.revision, phrases: globalDraft
                )
            }
            if let workspaceId, let workspace, workspaceDraft != workspace.phrases {
                self.workspace = try await api.saveDictationDictionary(
                    workspaceId: workspaceId, revision: workspace.revision, phrases: workspaceDraft
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = "Save failed or list changed on server. Your edits remain here. Reload from Server will discard them."
        }
    }

    private func forgetWorkspace() async {
        guard !isSaving, let api, let workspaceId, let workspace else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            self.workspace = try await DictationDictionaryDraft.forgetWorkspace(
                global: globalDraft, workspaceDraft: $workspaceDraft
            ) {
                try await api.saveDictationDictionary(
                    workspaceId: workspaceId, revision: workspace.revision, phrases: []
                )
            }
            errorMessage = nil
        } catch let error as DictationDictionaryDraft.ForgetBlocked {
            errorMessage = error.reason
        } catch {
            errorMessage = "Forget failed or list changed on server. This Workspace edits remain here."
        }
    }

    private func serverName(_ id: String) -> String {
        coordinator.serverStore.server(for: id)?.name ?? id
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
}

/// Draft operations shared by row actions and validation; never remove the
/// source until the destination is known to accept the edit.
enum DictationDictionaryDraft {
    struct ForgetBlocked: Error {
        let reason: String
    }

    @MainActor
    static func forgetWorkspace(
        global: [String], workspaceDraft: Binding<[String]>,
        put: () async throws -> DictationDictionaryList
    ) async throws -> DictationDictionaryList {
        if let reason = saveError(global: global, workspace: []) {
            throw ForgetBlocked(reason: reason)
        }
        let saved = try await put()
        workspaceDraft.wrappedValue = saved.phrases
        return saved
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
