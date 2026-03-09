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
    @State private var navigateToSessionId: String?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case diff = "Diff"
        case current = "Current"
        case history = "History"

        var id: String { rawValue }
    }

    private var availableTabs: [DetailTab] {
        selectedSessionId == nil ? [.diff, .current] : [.diff, .current, .history]
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
        .navigationDestination(item: $navigateToSessionId) { sessionId in
            ChatView(sessionId: sessionId)
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
                    ForEach(availableTabs) { tab in
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
                    case .history:
                        if let selectedSessionId {
                            WorkspaceReviewFileHistoryView(
                                workspaceId: workspaceId,
                                sessionId: selectedSessionId,
                                filePath: file.path
                            )
                        } else {
                            ContentUnavailableView(
                                "No Session History",
                                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                description: Text("Open review from a specific session to inspect file history.")
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.themeBgDark)
    }

    @ViewBuilder
    private func currentContent(diff: WorkspaceReviewDiffResponse) -> some View {
        if file.status.trimmingCharacters(in: .whitespaces) == "D" {
            ContentUnavailableView(
                "File Deleted",
                systemImage: "trash",
                description: Text("This file has been deleted in the working tree.")
            )
        } else {
            FileContentView(
                content: diff.currentText,
                filePath: file.path,
                presentation: .document
            )
        }
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
            navigateToSessionId = response.session.id
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

private struct WorkspaceReviewFileHistoryView: View {
    let workspaceId: String
    let sessionId: String
    let filePath: String

    @Environment(ServerConnection.self) private var connection

    @State private var session: Session?
    @State private var entries: [WorkspaceReviewHistoryEntry] = []
    @State private var traceError: String?
    @State private var isLoadingTrace = false
    @State private var hasLoadedTrace = false

    private var effectiveAddedLines: Int {
        entries.reduce(0) { $0 + $1.addedLines }
    }

    private var effectiveRemovedLines: Int {
        entries.reduce(0) { $0 + $1.removedLines }
    }

    var body: some View {
        contentView
            .task(id: workspaceId + "|" + sessionId + "|" + filePath) {
                await loadHistory()
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoadingTrace && !hasLoadedTrace {
            ProgressView("Loading session history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.themeBgDark)
        } else if let traceError, !hasLoadedTrace {
            ContentUnavailableView(
                "History Unavailable",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                description: Text(traceError)
            )
            .background(Color.themeBgDark)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No Session History",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                description: Text("This session did not record file mutations for this path.")
            )
            .background(Color.themeBgDark)
        } else {
            historyList
        }
    }

    private var historyList: some View {
        List {
            Section("Summary") {
                LabeledContent("Session") {
                    Text(session?.displayTitle ?? "Session \(String(sessionId.prefix(8)))")
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                }

                LabeledContent("Revisions") {
                    Text("\(entries.count)")
                        .foregroundStyle(.themeFg)
                }

                if effectiveAddedLines > 0 || effectiveRemovedLines > 0 {
                    HStack(spacing: 10) {
                        if effectiveAddedLines > 0 {
                            Text("+\(effectiveAddedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if effectiveRemovedLines > 0 {
                            Text("-\(effectiveRemovedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }
            }

            if !entries.isEmpty {
                Section("Revisions") {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let ordinal = entries.count - index
                        NavigationLink {
                            ReviewHistoryEntryDetailView(entry: entry, filePath: filePath)
                        } label: {
                            ReviewHistoryEntryRow(entry: entry, ordinal: ordinal)
                        }
                    }
                }
            }

            if let traceError, hasLoadedTrace {
                Section {
                    Text(traceError)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.themeBgDark)
    }

    private func loadHistory() async {
        await loadTraceHistoryIfNeeded()
    }

    private func loadTraceHistoryIfNeeded() async {
        guard !isLoadingTrace, !hasLoadedTrace else { return }
        guard let api = connection.apiClient else {
            traceError = "History unavailable while offline."
            return
        }

        isLoadingTrace = true
        defer { isLoadingTrace = false }

        do {
            let response = try await api.getWorkspaceSession(
                workspaceId: workspaceId,
                sessionId: sessionId,
                traceView: .full
            )
            let builtEntries = await Task.detached(priority: .userInitiated) {
                WorkspaceReviewHistoryBuilder.buildEntries(trace: response.trace, path: filePath)
            }.value
            session = response.session
            entries = builtEntries
            traceError = nil
            hasLoadedTrace = true
        } catch {
            traceError = error.localizedDescription
        }
    }


}
