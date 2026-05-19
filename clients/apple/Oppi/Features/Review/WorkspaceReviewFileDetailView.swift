import SwiftUI
import UIKit

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

struct WorkspaceReviewFileDetailView: View {
    let workspaceId: String
    let selectedSessionId: String?
    let file: WorkspaceReviewFile
    var selectedTextActionScopeOverride: SelectedTextActionScope? = nil

    @Environment(\.apiClient) private var apiClient
    @Environment(\.selectedTextActionScope) private var selectedTextActionScope
    @Environment(SessionStore.self) private var sessionStore

    @State private var selectedTab: DetailTab = .diff
    @State private var diff: WorkspaceReviewDiffResponse?
    @State private var error: String?
    @State private var isLoading = false
    @State private var launchActionInFlightTitle: String?
    @State private var launchError: String?
    @State private var navigateToQuickAction: QuickActionSessionNavDestination?
    @State private var quickActionOptions: [WorkspaceQuickActionOption] = []
    @State private var isLoadingQuickActions = false

    private var selectedTextScope: SelectedTextActionScope? {
        selectedTextActionScopeOverride ?? selectedTextActionScope
    }

    private var selectedTextActionContext: SelectedTextActionContext? {
        selectedTextScope?.makeActionContext(
            sessionId: selectedSessionId,
            sourceLabel: file.path.lastPathComponentForDisplay,
            filePath: file.path
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
        .navigationTitle(file.path.lastPathComponentForDisplay)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workspaceId + "|" + file.path) {
            await loadDiff()
        }
        .task(id: workspaceId) {
            await loadQuickActionsIfNeeded()
        }
        .navigationDestination(item: $navigateToQuickAction) { dest in
            ChatView(
                sessionId: dest.id,
                initialInputText: dest.inputText,
                initialPendingFiles: dest.filePaths.map { PendingFileReference(path: $0, isDirectory: false, kind: .reviewFile) }
            )
        }
        .overlay {
            if let launchActionInFlightTitle {
                ProgressView(launchActionInFlightTitle)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let diff, let shareable = shareableContentForReview(diff: diff) {
                    FileShareButton(content: shareable, style: .icon)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(launchActionInFlightTitle != nil)
            }
        }
        .alert(
            "Unable to start quick action",
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    /// Whether the file is brand-new (added or untracked) — no prior content to diff against.
    private var isNewFile: Bool {
        let s = file.status.trimmingCharacters(in: .whitespaces)
        return s == "A" || s == "??"
    }

    /// Whether the file was deleted — no current content to display.
    private var isDeletedFile: Bool {
        file.status.trimmingCharacters(in: .whitespaces) == "D"
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
            return .diff(diff.hunks, filePath: file.path)
        }

        guard !diff.currentText.isEmpty else { return nil }
        return .fromText(diff.currentText, filePath: file.path)
    }

    private func content(diff: WorkspaceReviewDiffResponse) -> some View {
        VStack(spacing: 0) {
            summaryBar(diff: diff)

            if isNewFile {
                // New file: skip tabs, show syntax-highlighted content directly
                Divider().overlay(Color.themeComment.opacity(0.2))

                FileContentView(
                    content: diff.currentText,
                    filePath: file.path,
                    presentation: .document
                )
                .environment(\.selectedTextActionScope, selectedTextScope)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isDeletedFile {
                // Deleted file: skip tabs, show diff (the only useful view)
                Divider().overlay(Color.themeComment.opacity(0.2))

                WorkspaceReviewDiffView(
                    diff: diff,
                    filePath: file.path,
                    selectedTextActionContext: selectedTextActionContext
                )
                .environment(\.selectedTextActionScope, selectedTextScope)
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
                            filePath: file.path,
                            selectedTextActionContext: selectedTextActionContext
                        )
                        .environment(\.selectedTextActionScope, selectedTextScope)
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
            filePath: file.path,
            presentation: .document
        )
        .environment(\.selectedTextActionScope, selectedTextScope)
    }

    private var fileIcon: FileIcon {
        FileIcon.forPath(file.path)
    }

    @ViewBuilder
    private func summaryBar(diff: WorkspaceReviewDiffResponse) -> some View {
        HStack(alignment: .top, spacing: 12) {
            fileIcon.iconView(size: 17, font: .subheadline.weight(.semibold))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fileIcon.color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(file.path.lastPathComponentForDisplay)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    Text(file.statusLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(GitStatusColor.color(for: file.status).opacity(0.12), in: Capsule())
                        .foregroundStyle(GitStatusColor.color(for: file.status))
                }

                if let parentPath = file.path.parentPathForDisplay {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if diff.addedLines > 0 {
                    Text("+\(diff.addedLines)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.themeDiffAdded)
                }
                if diff.removedLines > 0 {
                    Text("-\(diff.removedLines)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.themeDiffRemoved)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
                paths: [file.path],
                selectedSessionId: selectedSessionId,
                promptTemplateName: option.promptTemplateName
            )
            sessionStore.upsert(response.session)
            launchError = nil
            navigateToQuickAction = QuickActionSessionNavDestination(
                id: response.session.id,
                inputText: response.visiblePrompt,
                filePaths: response.filePaths
            )
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func loadQuickActionsIfNeeded() async {
        guard !isLoadingQuickActions else { return }
        guard let api = apiClient else { return }

        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }

        do {
            quickActionOptions = try await api.getWorkspaceQuickActions(workspaceId: workspaceId).actions
        } catch {
            quickActionOptions = []
        }
    }

    private func loadDiff() async {
        guard !isLoading else { return }
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            diff = try await api.getWorkspaceReviewDiff(workspaceId: workspaceId, path: file.path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shared diff view for review surfaces, backed by the canonical unified renderer.
struct WorkspaceReviewDiffView: View {
    let diff: WorkspaceReviewDiffResponse
    let filePath: String
    var selectedTextActionContext: SelectedTextActionContext?

    var body: some View {
        UnifiedDiffView(
            hunks: diff.hunks,
            filePath: filePath,
            emptyDescription: "This file has no textual diff to show.",
            selectedTextActionContext: selectedTextActionContext
        )
    }
}
