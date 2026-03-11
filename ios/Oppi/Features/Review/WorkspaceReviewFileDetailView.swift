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

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore

    @State private var selectedTab: DetailTab = .diff
    @State private var diff: WorkspaceReviewDiffResponse?
    @State private var error: String?
    @State private var isLoading = false
    @State private var launchActionInFlight: WorkspaceReviewSessionAction?
    @State private var launchError: String?
    @State private var navigateToReview: ReviewSessionNavDestination?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case diff = "Diff"
        case current = "Current"

        var id: String { rawValue }
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
        .navigationDestination(item: $navigateToReview) { dest in
            ChatView(sessionId: dest.id, initialInputText: dest.inputText, initialContextPills: dest.pills)
        }
        .overlay {
            if let launchActionInFlight {
                ProgressView(launchActionInFlight.progressTitle)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(WorkspaceReviewSessionAction.review.fileMenuTitle) {
                        Task {
                            await createReviewSession(action: .review)
                        }
                    }

                    Button(WorkspaceReviewSessionAction.reflect.fileMenuTitle) {
                        Task {
                            await createReviewSession(action: .reflect)
                        }
                    }

                    Button(WorkspaceReviewSessionAction.prepareCommit.fileMenuTitle) {
                        Task {
                            await createReviewSession(action: .prepareCommit)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(launchActionInFlight != nil)
            }
        }
        .alert(
            "Unable to start review session",
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isDeletedFile {
                // Deleted file: skip tabs, show diff (the only useful view)
                Divider().overlay(Color.themeComment.opacity(0.2))

                WorkspaceReviewDiffView(diff: diff, filePath: file.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("View", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().overlay(Color.themeComment.opacity(0.2))

                Group {
                    switch selectedTab {
                    case .diff:
                        WorkspaceReviewDiffView(diff: diff, filePath: file.path)
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
    }

    private var fileIcon: FileIcon {
        FileIcon.forPath(file.path)
    }

    @ViewBuilder
    private func summaryBar(diff: WorkspaceReviewDiffResponse) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fileIcon.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fileIcon.color)
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
                        .background(statusColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(statusColor)
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

    private var statusColor: Color {
        switch file.status.trimmingCharacters(in: .whitespaces) {
        case "M": return .themeOrange
        case "A": return .themeDiffAdded
        case "D": return .themeDiffRemoved
        case "R", "C": return .themeCyan
        case "??": return .themeComment
        case "UU", "AA", "DD": return .themeDiffRemoved
        default: return .themeFg
        }
    }

    private func createReviewSession(action: WorkspaceReviewSessionAction) async {
        guard launchActionInFlight == nil else { return }
        guard let api = connection.apiClient else {
            launchError = "Server is offline."
            return
        }

        launchActionInFlight = action
        defer { launchActionInFlight = nil }

        do {
            let response = try await api.createWorkspaceReviewSession(
                workspaceId: workspaceId,
                action: action,
                paths: [file.path],
                selectedSessionId: selectedSessionId
            )
            sessionStore.upsert(response.session)
            launchError = nil
            let pills = response.contextSummary.map { ContextPill(from: $0) }
            navigateToReview = ReviewSessionNavDestination(
                id: response.session.id,
                pills: pills,
                inputText: response.visiblePrompt
            )
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func loadDiff() async {
        guard !isLoading else { return }
        guard let api = connection.apiClient else {
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

    var body: some View {
        UnifiedDiffView(
            hunks: diff.hunks,
            filePath: filePath,
            emptyDescription: "This file has no textual diff to show."
        )
    }
}


