import SwiftUI
import UIKit

enum WorkspaceReviewFileRenderer: Equatable {
    case review
    case workspaceFile
}

enum WorkspaceReviewFileRenderingPolicy {
    static func renderer(for path: String, status: String? = nil) -> WorkspaceReviewFileRenderer {
        if status?.trimmingCharacters(in: .whitespacesAndNewlines) == "D" {
            return .review
        }
        return FileType.detect(from: path).previewCategory == .text ? .review : .workspaceFile
    }
}

enum WorkspaceReviewFileDetailPhase: Equatable {
    case loading
    case unavailable(String)
    case loaded(WorkspaceReviewDiffResponse)

    static func resolve(
        diff: WorkspaceReviewDiffResponse?,
        error: String?
    ) -> Self {
        if let diff {
            return .loaded(diff)
        }
        if let error {
            return .unavailable(error)
        }
        return .loading
    }
}

struct WorkspaceReviewFileDetailToolbarState: Equatable {
    let showsShare: Bool
    let showsActionMenu: Bool
    let actionMenuDisabled: Bool
    let actionMenuAccessibilityLabel: String

    static func make(
        hasShareableContent: Bool,
        launchActionInFlightTitle: String?
    ) -> Self {
        Self(
            showsShare: hasShareableContent,
            showsActionMenu: true,
            actionMenuDisabled: launchActionInFlightTitle != nil,
            actionMenuAccessibilityLabel: String(localized: "Actions")
        )
    }
}

struct WorkspaceReviewFileDetailView: View {
    let workspaceId: String
    let selectedSessionId: String?
    let file: WorkspaceReviewFile
    var worktreeId: String? = nil
    var reviewCommentSelectionScopeOverride: ReviewCommentSelectionScope? = nil
    var navigationFiles: [WorkspaceReviewFile] = []
    var allowsHorizontalBackSwipe = true

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @Environment(SessionStore.self) private var sessionStore

    @State private var activeFile: WorkspaceReviewFile?
    @State private var fileTransitionDirection: FileBrowserNavigationDirection = .next
    @State private var selectedTab: DetailTab = .diff
    @State private var diff: WorkspaceReviewDiffResponse?
    @State private var error: String?
    @State private var isLoading = false
    @State private var launchActionInFlightTitle: String?
    @State private var launchError: String?
    @State private var navigateToQuickAction: QuickActionSessionNavDestination?
    @State private var quickActionOptions: [WorkspaceQuickActionOption] = []
    @State private var isLoadingQuickActions = false

    private var currentFile: WorkspaceReviewFile {
        activeFile ?? file
    }

    private var effectiveReviewCommentSelectionScope: ReviewCommentSelectionScope? {
        reviewCommentSelectionScopeOverride ?? reviewCommentSelectionScope
    }

    private var reviewCommentSelectionContext: ReviewCommentSelectionContext? {
        effectiveReviewCommentSelectionScope?.makeContext(
            sessionId: selectedSessionId,
            sourceLabel: currentFile.path.lastPathComponentForDisplay,
            filePath: currentFile.path
        )
    }

    private var sortedQuickActionOptions: [WorkspaceQuickActionOption] {
        quickActionOptions.sorted { left, right in
            if left.sourceScope != right.sourceScope {
                if left.sourceScope == "project" { return true }
                if right.sourceScope == "project" { return false }
            }
            return left.commandName.localizedCaseInsensitiveCompare(right.commandName) == .orderedAscending
        }
    }

    private var diffTaskID: String {
        [workspaceId, selectedSessionId ?? "", worktreeId ?? "", currentFile.path].joined(separator: "|")
    }

    private var quickActionTaskID: String {
        [workspaceId, selectedSessionId ?? "", worktreeId ?? ""].joined(separator: "|")
    }

    private enum DetailTab: CaseIterable, Identifiable {
        case diff
        case current

        var id: Self { self }

        var title: String {
            switch self {
            case .diff: return "Changes"
            case .current: return "File"
            }
        }
    }

    var body: some View {
        Group {
            if currentRenderer == .workspaceFile {
                workspaceFileContent
            } else {
                switch WorkspaceReviewFileDetailPhase.resolve(diff: diff, error: error) {
                case .loading:
                    ProgressView("Loading file review…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.themeBgDark)
                case .unavailable(let error):
                    ContentUnavailableView(
                        "Review Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .background(Color.themeBgDark)
                case .loaded(let diff):
                    content(diff: diff)
                }
            }
        }
        .environment(\.horizontalBackSwipeAction, horizontalBackSwipeAction)
        .filePushTransition(id: currentFile.path, direction: fileTransitionDirection)
        .horizontalBackSwipeGesture(isEnabled: allowsHorizontalBackSwipe && parentOwnsBackSwipe) { dismiss() }
        .overlay(alignment: .bottom) {
            reviewNavigatorControls
                .padding(.bottom, FullScreenFloatingControlChrome.bottomPadding)
        }
        .navigationTitle(currentFile.path.lastPathComponentForDisplay)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: diffTaskID) {
            await loadDiff(for: currentFile)
        }
        .onChange(of: file.path) { _, _ in
            activeFile = nil
            diff = nil
            error = nil
        }
        .task(id: quickActionTaskID) {
            await loadQuickActionsIfNeeded()
        }
        .navigationDestination(item: $navigateToQuickAction) { dest in
            ChatView(
                sessionId: dest.id,
                workspaceIdHint: workspaceId,
                initialInputText: dest.inputText,
                initialPendingFiles: dest.filePaths.map {
                    PendingFileReference(path: $0, isDirectory: false, kind: .reviewFile, displayPrefix: dest.fileDisplayPrefix)
                }
            )
        }
        .overlay {
            if let launchActionInFlightTitle {
                ProgressView(launchActionInFlightTitle)
                    .tint(.themeCyan)
                    .foregroundStyle(.themeFg)
                    .padding()
                    .themedFloatingPanel()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if toolbarState.showsShare, let shareable = toolbarShareableContent {
                    FileShareButton(content: shareable, style: .icon)
                }

                if toolbarState.showsActionMenu {
                    actionMenu
                }
            }
        }
        .alert(
            "Unable to start action",
            isPresented: launchErrorPresented
        ) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private var launchErrorPresented: Binding<Bool> {
        Binding(
            get: { launchError != nil },
            set: { isPresented in
                if !isPresented { launchError = nil }
            }
        )
    }

    private var toolbarShareableContent: FileShareService.ShareableContent? {
        guard currentRenderer == .review, let diff else { return nil }
        return shareableContentForReview(diff: diff)
    }

    private var toolbarState: WorkspaceReviewFileDetailToolbarState {
        WorkspaceReviewFileDetailToolbarState.make(
            hasShareableContent: toolbarShareableContent != nil,
            launchActionInFlightTitle: launchActionInFlightTitle
        )
    }

    private var actionMenu: some View {
        Menu {
            Button {
                Task {
                    await startEmptySession()
                }
            } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }

            Section("Prompt Templates") {
                if isLoadingQuickActions && quickActionOptions.isEmpty {
                    Button("Loading templates…") {}
                        .disabled(true)
                } else if sortedQuickActionOptions.isEmpty {
                    Button("No prompt templates") {}
                        .disabled(true)
                } else {
                    ForEach(sortedQuickActionOptions) { option in
                        Button {
                            Task {
                                await createQuickActionSession(option: option)
                            }
                        } label: {
                            Label("/\(option.commandName)", systemImage: SlashCommand.Source.prompt.iconName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(toolbarState.actionMenuDisabled)
        .accessibilityLabel(toolbarState.actionMenuAccessibilityLabel)
        .accessibilityIdentifier("review-file.prompt-templates")
    }

    private var horizontalBackSwipeAction: (@MainActor @Sendable () -> Void)? {
        guard allowsHorizontalBackSwipe else { return nil }
        return { dismiss() }
    }

    private var currentRenderer: WorkspaceReviewFileRenderer {
        WorkspaceReviewFileRenderingPolicy.renderer(for: currentFile.path, status: currentFile.status)
    }

    private var parentOwnsBackSwipe: Bool {
        guard currentRenderer == .review else { return false }
        guard let diff else { return true }
        if isDeletedFile { return diff.hunks.isEmpty }
        if isNewFile { return !currentContentInstallsUIKitBackSwipe(diff.currentText) }

        switch selectedTab {
        case .diff:
            return diff.hunks.isEmpty
        case .current:
            return !currentContentInstallsUIKitBackSwipe(diff.currentText)
        }
    }

    private func currentContentInstallsUIKitBackSwipe(_ text: String) -> Bool {
        switch FileType.detect(from: currentFile.path, content: text) {
        case .code, .json, .plain, .graphviz:
            return true
        case .markdown, .html, .image, .audio, .video, .pdf, .binary,
             .latex, .orgMode, .mermaid:
            return false
        }
    }

    /// Whether the file is brand-new (added or untracked) — no prior content to diff against.
    private var isNewFile: Bool {
        let s = currentFile.status.trimmingCharacters(in: .whitespaces)
        return s == "A" || s == "??"
    }

    /// Whether the file was deleted — no current content to display.
    private var isDeletedFile: Bool {
        currentFile.status.trimmingCharacters(in: .whitespaces) == "D"
    }

    /// Build shareable content from the review, switching on the active tab.
    ///
    /// Diff tab: shares the rendered diff with colored backgrounds and gutter bars.
    /// Current tab (or new/deleted files): shares the full file content.
    private func shareableContentForReview(
        diff: WorkspaceReviewDiffResponse
    ) -> FileShareService.ShareableContent? {
        let showingDiff = selectedTab == .diff && !isNewFile && !isDeletedFile
            || isDeletedFile  // deleted files always show diff

        if showingDiff, !diff.hunks.isEmpty {
            return .diff(diff.hunks, filePath: currentFile.path)
        }

        guard !diff.currentText.isEmpty else { return nil }
        return .fromText(diff.currentText, filePath: currentFile.path)
    }

    private var workspaceFileContent: some View {
        VStack(spacing: 0) {
            ReviewFileSummaryBar(
                path: currentFile.path,
                status: currentFile.status,
                statusLabel: currentFile.statusLabel,
                addedLines: currentFile.addedLines,
                removedLines: currentFile.removedLines
            )

            Divider().overlay(Color.themeComment.opacity(0.2))

            FileBrowserContentView(
                workspaceId: workspaceId,
                worktreeId: worktreeId,
                filePath: currentFile.path,
                fileName: currentFile.path.lastPathComponentForDisplay,
                chromeMode: .treePane,
                allowsHorizontalBackSwipe: allowsHorizontalBackSwipe
            )
        }
        .background(Color.themeBgDark)
    }

    private func content(diff: WorkspaceReviewDiffResponse) -> some View {
        VStack(spacing: 0) {
            ReviewFileSummaryBar(
                path: currentFile.path,
                status: currentFile.status,
                statusLabel: currentFile.statusLabel,
                addedLines: diff.addedLines,
                removedLines: diff.removedLines
            )

            if isNewFile {
                // New file: skip tabs, show syntax-highlighted content directly
                Divider().overlay(Color.themeComment.opacity(0.2))

                FileContentView(
                    content: diff.currentText,
                    filePath: currentFile.path,
                    presentation: .document
                )
                .environment(\.reviewCommentSelectionScope, effectiveReviewCommentSelectionScope)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isDeletedFile {
                // Deleted file: skip tabs, show diff (the only useful view)
                Divider().overlay(Color.themeComment.opacity(0.2))

                WorkspaceReviewDiffView(
                    diff: diff,
                    filePath: currentFile.path,
                    reviewCommentSelectionContext: reviewCommentSelectionContext
                )
                .environment(\.reviewCommentSelectionScope, effectiveReviewCommentSelectionScope)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("View", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().overlay(Color.themeComment.opacity(0.2))

                Group {
                    switch selectedTab {
                    case .diff:
                        WorkspaceReviewDiffView(
                            diff: diff,
                            filePath: currentFile.path,
                            reviewCommentSelectionContext: reviewCommentSelectionContext
                        )
                        .environment(\.reviewCommentSelectionScope, effectiveReviewCommentSelectionScope)
                    case .current:
                        currentContent(diff: diff)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.themeBgDark)
    }

    private func currentContent(diff: WorkspaceReviewDiffResponse) -> some View {
        FileContentView(
            content: diff.currentText,
            filePath: currentFile.path,
            presentation: .document
        )
        .environment(\.reviewCommentSelectionScope, effectiveReviewCommentSelectionScope)
    }

    private func startEmptySession() async {
        guard launchActionInFlightTitle == nil else { return }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }

        launchActionInFlightTitle = "Starting new session…"
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                worktreeId: worktreeId
            )
            sessionStore.upsert(response.session)
            launchError = nil
            navigateToQuickAction = QuickActionSessionNavDestination.attaching(
                sessionId: response.session.id,
                filePath: currentFile.path
            )
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func createQuickActionSession(option: WorkspaceQuickActionOption) async {
        guard launchActionInFlightTitle == nil else { return }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: workspaceId,
                paths: [currentFile.path],
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId,
                promptTemplateName: option.promptTemplateName
            )
            sessionStore.upsert(response.session)
            launchError = nil
            navigateToQuickAction = QuickActionSessionNavDestination(
                id: response.session.id,
                inputText: response.visiblePrompt,
                filePaths: response.filePaths,
                fileDisplayPrefix: option.title
            )
        } catch {
            launchError = error.localizedDescription
        }
    }

    // MARK: - File Navigation

    private var reviewNavigationFiles: [WorkspaceReviewFile] {
        var seen: Set<String> = []
        return navigationFiles.filter { file in
            seen.insert(file.path).inserted
        }
    }

    private var reviewNavigatorControls: some View {
        AdjacentFileNavigatorControls(
            canGoPrevious: adjacentReviewFile(.previous) != nil,
            canGoNext: adjacentReviewFile(.next) != nil,
            onPrevious: { navigateToAdjacentReviewFile(.previous) },
            onNext: { navigateToAdjacentReviewFile(.next) }
        )
    }

    private func adjacentReviewFile(_ direction: FileBrowserNavigationDirection) -> WorkspaceReviewFile? {
        let files = reviewNavigationFiles
        guard let currentIndex = files.firstIndex(where: { $0.path == currentFile.path }) else { return nil }
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = currentIndex - 1
        case .next:
            targetIndex = currentIndex + 1
        }
        guard files.indices.contains(targetIndex) else { return nil }
        return files[targetIndex]
    }

    private func navigateToAdjacentReviewFile(_ direction: FileBrowserNavigationDirection) {
        guard let nextFile = adjacentReviewFile(direction) else { return }
        fileTransitionDirection = direction
        withAnimation(.easeInOut(duration: 0.22)) {
            activeFile = nextFile
            diff = nil
            error = nil
        }
    }

    private func isCurrentReviewFile(_ requestedFile: WorkspaceReviewFile) -> Bool {
        !Task.isCancelled && currentFile.path == requestedFile.path
    }

    private func loadQuickActionsIfNeeded() async {
        guard !isLoadingQuickActions else { return }
        guard let api = apiClient else { return }

        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }

        do {
            quickActionOptions = try await api.getWorkspaceQuickActions(
                workspaceId: workspaceId,
                selectedSessionId: selectedSessionId,
                worktreeId: worktreeId
            ).actions
        } catch {
            quickActionOptions = []
        }
    }

    private func loadDiff(for requestedFile: WorkspaceReviewFile) async {
        diff = nil
        error = nil
        guard WorkspaceReviewFileRenderingPolicy.renderer(
            for: requestedFile.path,
            status: requestedFile.status
        ) == .review else { return }
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }

        isLoading = true
        defer {
            if currentFile.path == requestedFile.path {
                isLoading = false
            }
        }

        do {
            let loadedDiff = try await loadBestAvailableDiff(api: api, file: requestedFile)
            guard isCurrentReviewFile(requestedFile) else { return }
            diff = loadedDiff
            error = nil
        } catch {
            guard isCurrentReviewFile(requestedFile) else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadBestAvailableDiff(api: APIClient, file: WorkspaceReviewFile) async throws -> WorkspaceReviewDiffResponse {
        if let selectedSessionId {
            do {
                let sessionDiff = try await api.getSessionDiff(
                    workspaceId: workspaceId,
                    sessionId: selectedSessionId,
                    path: file.path
                )
                if !Self.shouldFallbackToWorkspaceDiff(sessionDiff: sessionDiff, file: file) {
                    return sessionDiff
                }
            } catch {
                // Older sessions may lack trace mutations for this path; fall back to the
                // Git work-tree diff so the review surface still opens.
            }
        }

        return try await api.getWorkspaceReviewDiff(
            workspaceId: workspaceId,
            path: file.path,
            selectedSessionId: selectedSessionId,
            worktreeId: worktreeId
        )
    }

    static func shouldFallbackToWorkspaceDiff(
        sessionDiff: WorkspaceReviewDiffResponse,
        file: WorkspaceReviewFile
    ) -> Bool {
        let visibleGitLineChanges = (file.addedLines ?? 0) + (file.removedLines ?? 0)
        guard visibleGitLineChanges > 0 else { return false }
        return sessionDiff.hunks.isEmpty
            && sessionDiff.addedLines == 0
            && sessionDiff.removedLines == 0
    }
}

/// Shared diff view for review surfaces, backed by the canonical unified renderer.
struct WorkspaceReviewDiffView: View {
    let diff: WorkspaceReviewDiffResponse
    let filePath: String
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?

    var body: some View {
        UnifiedDiffView(
            hunks: diff.hunks,
            filePath: filePath,
            emptyDescription: "This file has no textual diff to show.",
            reviewCommentSelectionContext: reviewCommentSelectionContext
        )
    }
}
