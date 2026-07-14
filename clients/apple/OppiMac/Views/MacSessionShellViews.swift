import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionShellList: View {
    let targets: [MacSelectedSessionTarget]
    let runtimeSessions: [StatsActiveSession]
    let isLoadingWorkspaceSessions: Bool
    let workspaceSessionError: String?
    let sessionActionError: (String) -> String?
    let isStoppingSession: (String) -> Bool
    let isDeletingSession: (String) -> Bool
    @Binding var selectedSessionID: String?
    let refresh: () async -> Void
    let stopTarget: (MacSelectedSessionTarget) async -> Void
    let deleteTarget: (MacSelectedSessionTarget) async -> Void
    let selectTarget: (MacSelectedSessionTarget) -> Void

    @State private var targetPendingDeletion: MacSelectedSessionTarget?

    var body: some View {
        List(selection: $selectedSessionID) {
            Section("Recent sessions") {
                if targets.isEmpty {
                    if isLoadingWorkspaceSessions {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading workspace sessions...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView(
                            workspaceSessionError == nil ? "No workspace sessions" : "Could not load sessions",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(workspaceSessionError ?? "Start or attach the local server, then refresh to load recent workspace sessions.")
                        )
                    }
                } else {
                    ForEach(targets, id: \.sessionId) { target in
                        WorkspaceSessionActionRow(
                            summary: target.summary,
                            actionError: sessionActionError(target.sessionId),
                            isStopping: isStoppingSession(target.sessionId),
                            isDeleting: isDeletingSession(target.sessionId),
                            selectSession: {
                                selectedSessionID = target.sessionId
                                selectTarget(target)
                            },
                            stopSession: { await stopTarget(target) },
                            requestDelete: { targetPendingDeletion = target }
                        )
                        .tag(target.sessionId)
                    }
                }
            }

            if !runtimeSessions.isEmpty {
                Section("Runtime activity") {
                    ForEach(runtimeSessions, id: \.id) { session in
                        SessionRowView(session: session)
                            .tag(session.id)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { targetPendingDeletion != nil },
                set: { if !$0 { targetPendingDeletion = nil } }
            ),
            presenting: targetPendingDeletion
        ) { target in
            Button("Delete Session", role: .destructive) {
                Task {
                    await deleteTarget(target)
                    targetPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                targetPendingDeletion = nil
            }
        } message: { target in
            Text("Delete \"\(target.summary.session.displayTitle)\" from local session history and generated attachments.")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingWorkspaceSessions)
            }
        }
    }
}

struct SessionTraceShellDetail: View {
    let store: MacSessionTraceStore
    let isStoppingSession: Bool
    let stopSession: () async -> Void
    @State private var draft = ""
    @State private var pendingAttachments: [MacPendingAttachment] = []
    @State private var composerLocalError: String?
    @State private var isModelPickerPresented = false
    @State private var isAttachmentDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.isLoadingSessionChanges || !store.sessionChangedFiles.isEmpty || store.sessionChangedFileCount > 0 || store.sessionChangesError != nil {
                MacSessionChangedFilesCard(
                    files: store.sessionChangedFiles,
                    changedFileCount: store.sessionChangedFileCount,
                    overflow: store.sessionChangedFilesOverflow,
                    isLoading: store.isLoadingSessionChanges,
                    isLoadingDiff: store.isLoadingSessionDiff,
                    isLoadingPreview: store.isLoadingSessionFilePreview,
                    error: store.sessionChangesError,
                    diffError: store.sessionDiffError,
                    previewError: store.sessionFilePreviewError,
                    refresh: { await store.loadSessionChangesFromLocalConfig() },
                    loadDiff: { path in await store.loadSessionDiffFromLocalConfig(path: path) },
                    loadPreview: { path in await store.loadSessionFilePreviewFromLocalConfig(path: path) }
                )
            }
            if let preview = store.selectedSessionFilePreview {
                MacSessionFilePreviewCard(preview: preview, close: { store.clearSessionFilePreview() })
            }
            if let diff = store.selectedSessionDiff {
                MacSessionDiffPreview(diff: diff, close: { store.clearSessionDiff() })
            }
            Divider()
            timeline
            Divider()
            composer
        }
        .padding(24)
        .sheet(isPresented: $isModelPickerPresented) {
            MacModelPickerSheet(
                models: store.availableModels,
                currentModel: store.session?.model,
                isLoading: store.isLoadingModels,
                error: store.modelLoadError,
                refresh: { await store.loadAvailableModelsFromLocalConfig() },
                selectModel: { model in
                    Task { await store.setModelFromLocalConfig(model) }
                }
            )
        }
        .task(id: store.selectedTarget?.sessionId) {
            await store.loadSelectedFromLocalConfig()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let session = store.session {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                HStack(spacing: 8) {
                    Text(session.status.rawValue.capitalized)
                    if store.isStreaming {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    }
                    if let workspaceName = session.workspaceName {
                        Text(workspaceName)
                    }
                    modelPickerButton(model: session.model)
                    thinkingLevelMenu
                    if MacSessionActionPolicy.canStop(session.status) {
                        Button {
                            Task { await stopSession() }
                        } label: {
                            if isStoppingSession {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isStoppingSession)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            Text("Session")
                .font(.title2)
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("Loading timeline...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.lastError, store.items.isEmpty {
            ContentUnavailableView(
                "Could not load timeline",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if store.items.isEmpty {
            ContentUnavailableView(
                "No timeline events",
                systemImage: "text.bubble",
                description: Text("This session has no trace rows yet.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.items) { item in
                        ChatItemSummaryRow(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private func modelPickerButton(model: String?) -> some View {
        Button {
            isModelPickerPresented = true
        } label: {
            if store.isUpdatingModel {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(MacModelSelection.shortDisplayName(for: model) ?? "Model", systemImage: "cpu")
            }
        }
        .buttonStyle(.borderless)
        .disabled(!store.canSendMessage || store.isUpdatingModel)
    }

    private var thinkingLevelMenu: some View {
        Menu {
            Picker("Thinking", selection: Binding(
                get: { store.thinkingLevel },
                set: { level in
                    Task { await store.setThinkingLevelFromLocalConfig(level) }
                }
            )) {
                ForEach(MacComposerThinkingLevel.allCases) { level in
                    Text(level.displayTitle).tag(level)
                }
            }
        } label: {
            if store.isUpdatingThinkingLevel {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(store.thinkingLevel.displayTitle, systemImage: "brain")
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(!store.canSendMessage || store.isUpdatingThinkingLevel)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.showsMessageQueue {
                MacMessageQueueCard(
                    queue: store.messageQueue,
                    busyStreamingBehavior: Binding(
                        get: { store.busyStreamingBehavior },
                        set: { store.busyStreamingBehavior = $0 }
                    ),
                    isRefreshing: store.isRefreshingQueue,
                    isUpdating: store.isUpdatingQueue,
                    error: store.messageQueueError,
                    refresh: { await store.refreshQueueFromLocalConfig() },
                    apply: { request in try await store.applyQueueMutationFromLocalConfig(request) }
                )
            }

            if let ask = store.currentAskRequest {
                MacAskRequestCard(
                    request: ask,
                    submit: { draft in
                        await store.submitAskResponseFromLocalConfig(request: ask, draft: draft)
                    },
                    ignore: {
                        await store.ignoreAskRequestFromLocalConfig(ask)
                    }
                )
                .id(ask.id)
            }

            if !pendingAttachments.isEmpty {
                MacPendingAttachmentStrip(
                    attachments: pendingAttachments,
                    remove: { id in pendingAttachments.removeAll { $0.id == id } }
                )
            }

            if let progress = store.attachmentPreparationText {
                Label(progress, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = composerLocalError ?? store.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isAttachmentDropTarget {
                Label("Drop files to attach", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if activeFileMentionQuery != nil {
                MacFileMentionSuggestionList(
                    suggestions: fileMentionSuggestions,
                    isLoading: store.isLoadingFileIndex,
                    error: store.fileIndexError,
                    insert: insertFileSuggestion
                )
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    chooseAttachments()
                } label: {
                    Label("Attach Files", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!store.canSendMessage || store.isSending || store.isPreparingAttachments)
                .help("Attach files")

                TextField("Message this session", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(!store.canSendMessage)
                Button {
                    let message = draft
                    let attachments = pendingAttachments
                    Task {
                        composerLocalError = nil
                        let didSend = await store.sendPromptFromLocalConfig(message, attachments: attachments)
                        if didSend {
                            draft = ""
                            pendingAttachments = []
                        }
                    }
                } label: {
                    if store.isSending || store.isPreparingAttachments {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .disabled(!canSubmitComposer)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Session composer")
        }
        .onChange(of: draft) { _, _ in
            loadFileIndexIfNeeded()
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isAttachmentDropTarget, perform: handleAttachmentProviders)
        .onPasteCommand(of: [UTType.fileURL]) { providers in
            _ = handleAttachmentProviders(providers)
        }
    }

    private var activeFileMentionQuery: String? {
        MacFileMentionAutocomplete.activeToken(in: draft)
    }

    private var fileMentionSuggestions: [MacFileMentionSuggestion] {
        guard let query = activeFileMentionQuery else { return [] }
        return MacFileMentionAutocomplete.suggestions(for: query, paths: store.fileIndexPaths)
    }

    private var canSubmitComposer: Bool {
        guard store.canSendMessage, !store.isSending, !store.isPreparingAttachments else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private func insertFileSuggestion(_ suggestion: MacFileMentionSuggestion) {
        draft = MacFileMentionAutocomplete.insert(suggestion, into: draft)
        composerLocalError = nil
    }

    private func loadFileIndexIfNeeded() {
        guard activeFileMentionQuery != nil,
              store.fileIndexPaths.isEmpty,
              !store.isLoadingFileIndex else { return }
        Task { await store.loadFileIndexFromLocalConfig() }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK else { return }
            addAttachmentURLs(panel.urls)
        }
    }

    private func handleAttachmentProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    DispatchQueue.main.async {
                        composerLocalError = error.localizedDescription
                    }
                    return
                }
                guard let url = Self.fileURL(from: item) else { return }
                DispatchQueue.main.async {
                    addAttachmentURLs([url])
                }
            }
        }
        return true
    }

    private func addAttachmentURLs(_ urls: [URL]) {
        let result = MacPendingAttachmentCollector.adding(urls: urls, to: pendingAttachments)
        pendingAttachments = result.attachments
        composerLocalError = result.rejectedMessages.isEmpty
            ? nil
            : result.rejectedMessages.joined(separator: "\n")
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        return nil
    }
}

private struct MacSessionChangedFilesCard: View {
    let files: [SessionChangedFile]
    let changedFileCount: Int
    let overflow: Int
    let isLoading: Bool
    let isLoadingDiff: Bool
    let isLoadingPreview: Bool
    let error: String?
    let diffError: String?
    let previewError: String?
    let refresh: () async -> Void
    let loadDiff: (String) async -> Void
    let loadPreview: (String) async -> Void

    private var displayedCount: Int {
        changedFileCount > 0 ? changedFileCount : files.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Changed files", systemImage: "doc.on.doc")
                    .font(.headline)
                Text("\(displayedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading || isLoadingDiff || isLoadingPreview {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh changed files", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let diffError, !diffError.isEmpty {
                Text(diffError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let previewError, !previewError.isEmpty {
                Text(previewError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if files.isEmpty, error == nil {
                Text(isLoading ? "Loading changed files…" : "No changed files reported for this session yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !files.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(8)) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(file.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button("Preview") {
                                Task { await loadPreview(file.path) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingPreview)
                            Button("Diff") {
                                Task { await loadDiff(file.path) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingDiff)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy workspace path")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if files.count > 8 || overflow > 0 {
                    Text("\(max(files.count - 8, 0) + overflow) more changed files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct MacSessionFilePreviewCard: View {
    let preview: MacSessionFilePreview
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(preview.path, systemImage: preview.kind.systemImage)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(preview.displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(.borderless)
            }

            switch preview.kind {
            case .text:
                MacTextFileSourcePreview(preview: preview)
            case .image:
                if let imageData = preview.imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("Image preview is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .binary:
                Text("Binary preview is unavailable. Use Copy path and inspect the file from the workspace when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct MacTextFileSourcePreview: View {
    let preview: MacSessionFilePreview

    var body: some View {
        if case .orgMode = preview.fileType, let text = preview.text {
            MacOrgDocumentPreview(content: text)
        } else if let language = preview.sourceLanguageLabel, let text = preview.text {
            MacCodeOutputPreview(model: MacCodeOutputModel(language: language, text: text))
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(preview.text?.isEmpty == false ? preview.text ?? "" : " ")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct MacSessionDiffPreview: View {
    let diff: WorkspaceReviewDiffResponse
    let close: () -> Void

    private var plan: WorkspaceReviewDiffPreviewPlan {
        WorkspaceReviewDiffPreviewPlan(diff: diff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(diff.path, systemImage: "plus.forwardslash.minus")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("+\(diff.addedLines) −\(diff.removedLines)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let revisionCount = diff.revisionCount {
                    Text("\(revisionCount) edits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(.borderless)
            }

            if diff.hunks.isEmpty {
                Text("No textual changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let truncationMessage = plan.truncationMessage {
                    Label(truncationMessage, systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.hunks) { visibleHunk in
                            Text(visibleHunk.headerText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.purple)
                            ForEach(visibleHunk.lines) { line in
                                HStack(spacing: 8) {
                                    Text(line.kind.prefix)
                                        .frame(width: 12, alignment: .center)
                                    Text(line.text.isEmpty ? " " : line.text)
                                }
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                            }
                            if visibleHunk.hiddenLineCount > 0 {
                                Text("… \(visibleHunk.hiddenLineCount) more lines in this hunk")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func color(for kind: WorkspaceReviewDiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .context: .primary
        }
    }
}

private struct MacFileMentionSuggestionList: View {
    let suggestions: [MacFileMentionSuggestion]
    let isLoading: Bool
    let error: String?
    let insert: (MacFileMentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("File mentions", systemImage: "at")
                    .font(.caption.weight(.semibold))
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if suggestions.isEmpty, !isLoading {
                Text("No matching workspace files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions) { suggestion in
                    Button {
                        insert(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.displayName)
                                    .lineLimit(1)
                                if let parent = suggestion.parentPath {
                                    Text(parent)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct MacPendingAttachmentStrip: View {
    let attachments: [MacPendingAttachment]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .lineLimit(1)
                            Text(Self.formattedSize(attachment.sizeBytes))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            remove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct MacMessageQueueCard: View {
    let queue: MessageQueueState
    @Binding var busyStreamingBehavior: StreamingBehavior
    let isRefreshing: Bool
    let isUpdating: Bool
    let error: String?
    let refresh: () async -> Void
    let apply: (MacMessageQueueMutationRequest) async throws -> Void

    @State private var isExpanded = false
    @State private var editorState: MacMessageQueueEditorState
    @State private var localError: String?

    init(
        queue: MessageQueueState,
        busyStreamingBehavior: Binding<StreamingBehavior>,
        isRefreshing: Bool,
        isUpdating: Bool,
        error: String?,
        refresh: @escaping () async -> Void,
        apply: @escaping (MacMessageQueueMutationRequest) async throws -> Void
    ) {
        self.queue = queue
        _busyStreamingBehavior = busyStreamingBehavior
        self.isRefreshing = isRefreshing
        self.isUpdating = isUpdating
        self.error = error
        self.refresh = refresh
        self.apply = apply
        _editorState = State(initialValue: MacMessageQueueEditorState(queue: queue))
    }

    private var controlsDisabled: Bool { isRefreshing || isUpdating }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label("Message Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.headline)
                    Text("\(editorState.displayedQueue.steering.count) steering · \(editorState.displayedQueue.followUp.count) follow-up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controlsDisabled {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Picker("Send while busy", selection: $busyStreamingBehavior) {
                    Text("Steer").tag(StreamingBehavior.steer)
                    Text("Follow-up").tag(StreamingBehavior.followUp)
                }
                .pickerStyle(.segmented)
                .disabled(controlsDisabled)

                if let visibleError = localError ?? error, !visibleError.isEmpty {
                    Text(visibleError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if editorState.isEmpty {
                    Text("Queue is empty. Messages sent while the session is busy will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    queueSection(title: "Steering", kind: .steer, items: editorState.displayedQueue.steering)
                    queueSection(title: "Follow-up", kind: .followUp, items: editorState.displayedQueue.followUp)
                }

                footer
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .onChange(of: queue) { _, latest in
            editorState.receiveServerQueue(latest)
        }
    }

    private func queueSection(title: String, kind: MessageQueueKind, items: [MessageQueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items.indices, id: \.self) { index in
                queueRow(kind: kind, index: index)
            }
        }
    }

    private func queueRow(kind: MessageQueueKind, index: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            TextField("Queued message", text: messageBinding(kind: kind, index: index), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(controlsDisabled)

            Button {
                applyImmediate(editorState.moveItem(kind: kind, from: index, direction: -1))
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(controlsDisabled || !canMove(kind: kind, index: index, direction: -1))

            Button {
                applyImmediate(editorState.moveItem(kind: kind, from: index, direction: 1))
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(controlsDisabled || !canMove(kind: kind, index: index, direction: 1))

            Button {
                applyImmediate(editorState.moveBetweenQueues(kind: kind, index: index))
            } label: {
                Image(systemName: kind == .steer ? "arrow.down.right" : "arrow.up.left")
            }
            .disabled(controlsDisabled)

            Button(role: .destructive) {
                applyImmediate(editorState.deleteItem(kind: kind, index: index))
            } label: {
                Image(systemName: "trash")
            }
            .disabled(controlsDisabled)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") {
                Task { await refresh() }
            }
            .disabled(controlsDisabled)

            Spacer()

            if editorState.isDraftMode {
                Button("Discard") {
                    editorState.discardDraft()
                    localError = nil
                }
                .disabled(controlsDisabled)

                Button("Save") {
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controlsDisabled)
            }
        }
        .font(.caption)
    }

    private func messageBinding(kind: MessageQueueKind, index: Int) -> Binding<String> {
        Binding(
            get: { item(kind: kind, index: index)?.message ?? "" },
            set: { value in
                if editorState.updateMessage(kind: kind, index: index, message: value) {
                    localError = nil
                }
            }
        )
    }

    private func item(kind: MessageQueueKind, index: Int) -> MessageQueueItem? {
        let items = kind == .steer ? editorState.displayedQueue.steering : editorState.displayedQueue.followUp
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    private func canMove(kind: MessageQueueKind, index: Int, direction: Int) -> Bool {
        let items = kind == .steer ? editorState.displayedQueue.steering : editorState.displayedQueue.followUp
        return items.indices.contains(index) && items.indices.contains(index + direction)
    }

    private func applyImmediate(_ request: MacMessageQueueMutationRequest?) {
        guard let request else { return }
        Task { await applyRequest(request) }
    }

    private func saveDraft() {
        guard let request = editorState.draftRequest() else { return }
        Task { await applyRequest(request) }
    }

    private func applyRequest(_ request: MacMessageQueueMutationRequest) async {
        localError = nil
        do {
            try await apply(request)
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct MacAskRequestCard: View {
    let request: AskRequest
    let submit: (MacAskResponseDraft) async -> Void
    let ignore: () async -> Void

    @State private var draft = MacAskResponseDraft()
    @State private var customAnswers: [String: String] = [:]
    @State private var isSending = false

    private var isSingleQuestionSingleSelect: Bool {
        request.questions.count == 1 && !(request.questions.first?.multiSelect ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Agent question", systemImage: "questionmark.bubble")
                    .font(.headline)
                Spacer()
                if request.questions.count > 1 {
                    Text("\(request.questions.count) questions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(request.questions) { question in
                questionView(question)
            }

            HStack {
                Button("Ignore") {
                    Task { await sendIgnore() }
                }
                .disabled(isSending)

                Spacer()

                Button {
                    Task { await sendSubmit() }
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send answer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || draft.isEmpty)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question")
    }

    private func questionView(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if question.multiSelect {
                Label("Select multiple", systemImage: "checkmark.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(question.options, id: \.value) { option in
                optionButton(option, question: question)
            }

            if request.allowCustom {
                customAnswerField(question)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionButton(_ option: AskOption, question: AskQuestion) -> some View {
        let isSelected = draft.isSelected(option, question: question)
        return Button {
            draft.toggle(option, question: question)
            if isSingleQuestionSingleSelect {
                Task { await sendSubmit() }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.multiSelect
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func customAnswerField(_ question: AskQuestion) -> some View {
        TextField(
            request.customPlaceholder ?? "Custom answer",
            text: Binding(
                get: { customAnswers[question.id] ?? "" },
                set: { value in
                    customAnswers[question.id] = value
                    draft.setCustom(value, question: question)
                }
            ),
            axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...4)
    }

    private func sendSubmit() async {
        guard !isSending, !draft.isEmpty else { return }
        isSending = true
        await submit(draft)
        isSending = false
    }

    private func sendIgnore() async {
        guard !isSending else { return }
        isSending = true
        await ignore()
        isSending = false
    }
}

private struct ChatItemSummaryRow: View {
    let item: ChatItem

    var body: some View {
        switch item {
        case .userMessage(_, let text, _, let timestamp):
            TimelineBubble(title: "You", subtitle: timestamp.relativeString(), text: text, tint: .blue)
        case .assistantMessage(_, let text, let timestamp):
            TimelineBubble(title: "Assistant", subtitle: timestamp.relativeString(), text: text, tint: .secondary)
        case .audioClip(_, let title, _, let timestamp):
            TimelineBubble(title: "Audio", subtitle: timestamp.relativeString(), text: title, tint: .purple)
        case .thinking(_, let preview, let hasMore, let isDone):
            TimelineBubble(
                title: isDone ? "Thinking" : "Thinking...",
                subtitle: hasMore ? "Preview" : nil,
                text: preview,
                tint: .orange
            )
        case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone):
            ToolTimelineBubble(
                title: tool,
                subtitle: Self.toolSubtitle(isDone: isDone, isError: isError, outputPreview: outputPreview),
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                isError: isError,
                tint: isError ? .red : .green
            )
        case .systemEvent(_, let message):
            TimelineBubble(title: "System", subtitle: nil, text: message, tint: .secondary)
        case .cacheMiss(_, let message):
            TimelineBubble(title: "Cache miss", subtitle: nil, text: message, tint: .orange)
        case .customEvent(_, let message, let presentation):
            TimelineBubble(title: presentation.title, subtitle: presentation.subtitle, text: message, tint: .secondary)
        case .error(_, let message):
            TimelineBubble(title: "Error", subtitle: nil, text: message, tint: .red)
        }
    }

    private static func toolSubtitle(isDone: Bool, isError: Bool, outputPreview: String) -> String {
        let base = isDone ? (isError ? "Failed" : "Done") : "Running"
        guard !outputPreview.isEmpty else { return base }
        if MacDiffOutputModel.shouldRender(text: outputPreview) {
            return "\(base) · \(MacDiffOutputModel(text: outputPreview).changeSummary)"
        }
        let media = MacMediaOutputModel(text: outputPreview)
        if !media.items.isEmpty {
            return "\(base) · \(media.summary)"
        }
        let terminal = MacTerminalOutputModel(text: outputPreview, isError: isError)
        if let commandText = terminal.commandText {
            return "\(base) · \(commandText)"
        }
        return base
    }

    private static func toolText(argsSummary: String, outputPreview: String) -> String {
        let strippedOutput = MacTerminalOutputModel.strippingANSI(from: outputPreview)
        return [argsSummary, strippedOutput].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

private struct ToolTimelineBubble: View {
    let title: String
    let subtitle: String?
    let argsSummary: String
    let outputPreview: String
    let isError: Bool
    let tint: Color

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if canExpand {
                    Button(isExpanded ? "Collapse" : "Expand") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if !argsSummary.isEmpty {
                Text(argsSummary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(isExpanded ? nil : 6)
            }

            toolOutput
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var toolOutput: some View {
        let stripped = MacTerminalOutputModel.strippingANSI(from: outputPreview)
        if stripped.isEmpty {
            EmptyView()
        } else if isExpanded, MacDiffOutputModel.shouldRender(text: stripped) {
            MacDiffOutputPreview(model: MacDiffOutputModel(text: stripped))
        } else if isExpanded, MacMediaOutputModel.shouldRender(text: stripped) {
            MacMediaOutputPreview(model: MacMediaOutputModel(text: stripped))
        } else if isExpanded, MacCodeOutputModel.shouldRenderStandalone(text: stripped) {
            MacCodeOutputPreview(model: MacCodeOutputModel(language: nil, text: stripped))
        } else if isExpanded || MacInlineOutputFormatter.shouldUseTerminalBlock(for: stripped) {
            MacTerminalOutputPreview(model: MacTerminalOutputModel(text: stripped, isError: isError), isExpanded: isExpanded)
        } else {
            Text(stripped)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(12)
        }
    }

    private var canExpand: Bool {
        outputPreview.components(separatedBy: .newlines).count > 8
            || outputPreview.count > 800
            || MacDiffOutputModel.shouldRender(text: outputPreview)
            || MacMediaOutputModel.shouldRender(text: outputPreview)
            || MacCodeOutputModel.shouldRenderStandalone(text: outputPreview)
            || MacInlineOutputFormatter.shouldUseTerminalBlock(for: outputPreview)
    }
}

private struct MacTerminalOutputPreview: View {
    let model: MacTerminalOutputModel
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(model.statusTitle, systemImage: model.isError ? "exclamationmark.triangle" : "terminal")
                if let commandText = model.commandText {
                    Text(commandText)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fontWeight(.semibold)

            Text(model.outputText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MacDiffOutputPreview: View {
    let model: MacDiffOutputModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.changeSummary, systemImage: "plus.forwardslash.minus")
                .font(.caption)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(for: line.kind))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func color(for kind: MacDiffLineKind) -> Color {
        switch kind {
        case .addition: .green
        case .removal: .red
        case .hunk: .purple
        case .fileHeader: .secondary
        case .context: .primary
        }
    }
}

private struct MacCodeOutputPreview: View {
    let model: MacCodeOutputModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.language ?? "Code", systemImage: "curlybraces")
                .font(.caption)
                .fontWeight(.semibold)
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(AttributedString(MacSyntaxHighlighter.attributedCode(
                    model.text,
                    language: model.syntaxLanguage,
                    includeLineNumbers: true
                )))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 360)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MacMediaOutputPreview: View {
    let model: MacMediaOutputModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.summary, systemImage: "photo.on.rectangle")
                .font(.caption)
                .fontWeight(.semibold)
            ForEach(model.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(.secondary)
                    Text(item.displayLabel)
                    Text(item.mimeType)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.formattedSize)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(8)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct TimelineBubble: View {
    let title: String
    let subtitle: String?
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SessionShellDetail: View {
    let session: StatsActiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(session.workspaceName ?? "Local workspace")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    Text(session.status.capitalized)
                }
                if let model = session.model {
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(model)
                    }
                }
                GridRow {
                    Text("Cost").foregroundStyle(.secondary)
                    Text(SessionFormatting.costString(session.cost))
                }
                if let contextTokens = session.contextTokens, let contextWindow = session.contextWindow {
                    GridRow {
                        Text("Context").foregroundStyle(.secondary)
                        Text("\(contextTokens) / \(contextWindow)")
                    }
                }
            }
            .font(.callout)

            MacShellEmptyDetail(
                title: "Open from a workspace for chat",
                message: "This runtime row came from local server stats. Choose the same session under Workspaces or Recent sessions to load trace history and enable the composer.",
                systemImage: "arrow.turn.down.right"
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
