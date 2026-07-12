import SwiftUI

struct CommitDetailActionMenuState: Equatable {
    let menuDisabled: Bool
    let promptTemplatesDisabled: Bool

    static func make(
        workspaceId: String,
        detail: GitCommitDetail?,
        launchActionInFlightTitle: String?
    ) -> Self {
        Self(
            menuDisabled: launchActionInFlightTitle != nil || workspaceId.isEmpty,
            promptTemplatesDisabled: launchActionInFlightTitle != nil || (detail?.files.isEmpty ?? true)
        )
    }
}

/// Sheet view showing commit metadata and a tappable file list.
/// Tapping a file opens a diff view for that file in that commit.
struct CommitDetailView: View {
    let workspaceId: String
    let commit: GitCommitSummary

    @Environment(\.apiClient) private var apiClient
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @Environment(SessionStore.self) private var sessionStore
    @State private var detail: GitCommitDetail?
    @State private var error: String?
    @State private var selectedFile: GitCommitFileInfo?
    @State private var launchActionInFlightTitle: String?
    @State private var launchError: String?
    @State private var navigateToQuickAction: QuickActionSessionNavDestination?
    @State private var quickActionOptions: [WorkspaceQuickActionOption] = []
    @State private var isLoadingQuickActions = false

    private var sortedQuickActionOptions: [WorkspaceQuickActionOption] {
        quickActionOptions.sorted { left, right in
            if left.sourceScope != right.sourceScope {
                if left.sourceScope == "project" { return true }
                if right.sourceScope == "project" { return false }
            }
            return left.commandName.localizedCaseInsensitiveCompare(right.commandName) == .orderedAscending
        }
    }

    private var actionMenuState: CommitDetailActionMenuState {
        CommitDetailActionMenuState.make(
            workspaceId: workspaceId,
            detail: detail,
            launchActionInFlightTitle: launchActionInFlightTitle
        )
    }

    var body: some View {
        Group {
            if let detail {
                loadedContent(detail)
            } else if let error {
                ContentUnavailableView(
                    "Unable to load commit",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView("Loading commit…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle("Commit")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: commit.sha) {
            await loadDetail()
        }
        .task(id: workspaceId) {
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
            ToolbarItem(placement: .primaryAction) {
                actionMenu
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
        .sheet(item: $selectedFile) { file in
            NavigationStack {
                CommitFileDiffView(workspaceId: workspaceId, sha: commit.sha, file: file)
                    .environment(\.reviewCommentSelectionScope, reviewCommentSelectionScope)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                selectedFile = nil
                            } label: {
                                Image(systemName: FullScreenViewerNavigationChrome.DismissMode.modal.systemImageName)
                            }
                            .accessibilityLabel(FullScreenViewerNavigationChrome.DismissMode.modal.accessibilityLabel)
                        }
                    }
            }
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
                        .disabled(actionMenuState.promptTemplatesDisabled)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(actionMenuState.menuDisabled)
        .accessibilityLabel("Actions")
    }

    // MARK: - Loaded Content

    private func loadedContent(_ detail: GitCommitDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                commitHeader(detail)

                Divider().overlay(Color.themeComment.opacity(0.2))

                filesSectionHeader(detail)

                Divider().overlay(Color.themeComment.opacity(0.15))

                fileList(detail)
            }
        }
    }

    // MARK: - Commit Header

    private func commitHeader(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // SHA
            Text(detail.sha)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.themeComment)

            // Commit message
            Text(detail.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)

            // Author + date
            HStack(spacing: 8) {
                Text(detail.author)
                    .font(.caption2)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(relativeDate(from: detail.date))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }

            // Line stats
            HStack(spacing: 8) {
                if detail.addedLines > 0 {
                    Text("+\(detail.addedLines)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.themeDiffAdded)
                }
                if detail.removedLines > 0 {
                    Text("-\(detail.removedLines)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.themeDiffRemoved)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Files Section Header

    private func filesSectionHeader(_ detail: GitCommitDetail) -> some View {
        HStack(spacing: 6) {
            Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s") changed")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.themeComment)
                .tracking(0.4)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - File List

    private func fileList(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(detail.files) { file in
                commitFileRow(file)
            }
        }
        .padding(.vertical, 4)
    }

    private func commitFileRow(_ file: GitCommitFileInfo) -> some View {
        let icon = FileIcon.forPath(file.path)

        return Button {
            selectedFile = file
        } label: {
            HStack(spacing: 6) {
                icon.iconView(size: 16, font: .appChip)

                Text(file.path.shortenedPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if let added = file.addedLines, added > 0 {
                    Text("+\(added)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.themeDiffAdded)
                }
                if let removed = file.removedLines, removed > 0 {
                    Text("-\(removed)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.themeDiffRemoved)
                }

                statusBadge(file.status)

                Image(systemName: "chevron.right")
                    .font(.appBadgeLight)
                    .foregroundStyle(.themeComment.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(_ status: String) -> some View {
        let (label, color) = statusInfo(status)
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }

    private func statusInfo(_ status: String) -> (String, Color) {
        switch status {
        case "M": return ("M", .themeOrange)
        case "A": return ("A", .themeDiffAdded)
        case "D": return ("D", .themeDiffRemoved)
        case "R": return ("R", .themeCyan)
        case "C": return ("C", .themeCyan)
        default: return (status, .themeComment)
        }
    }

    // MARK: - Data Loading

    private func loadDetail() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }

        do {
            detail = try await api.getCommitDetail(workspaceId: workspaceId, sha: commit.sha)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadQuickActionsIfNeeded() async {
        guard !workspaceId.isEmpty else { return }
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

    private func startEmptySession() async {
        guard launchActionInFlightTitle == nil else { return }
        guard !workspaceId.isEmpty else {
            launchError = "Workspace is unavailable."
            return
        }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }

        launchActionInFlightTitle = "Starting new session…"
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceSession(workspaceId: workspaceId)
            sessionStore.upsert(response.session)
            launchError = nil
            navigateToQuickAction = QuickActionSessionNavDestination.empty(sessionId: response.session.id)
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func createQuickActionSession(option: WorkspaceQuickActionOption) async {
        guard launchActionInFlightTitle == nil else { return }
        guard !workspaceId.isEmpty else {
            launchError = "Workspace is unavailable."
            return
        }
        guard let detail else { return }
        let paths = detail.files.map(\.path)
        guard !paths.isEmpty else {
            launchError = "Commit has no changed files."
            return
        }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: workspaceId,
                paths: paths,
                commitSha: detail.sha,
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

    // MARK: - Date Formatting

    private func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: isoString) else {
                return isoString
            }
            return SessionFormatting.durationString(since: date) + " ago"
        }
        return SessionFormatting.durationString(since: date) + " ago"
    }
}

/// Diff view for a single file within a specific commit.
/// Loads the diff via `getCommitFileDiff` and displays using `WorkspaceReviewDiffView`.
struct CommitFileDiffView: View {
    let workspaceId: String
    let sha: String
    let file: GitCommitFileInfo

    @Environment(\.apiClient) private var apiClient
    @State private var diff: WorkspaceReviewDiffResponse?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ReviewFileSummaryBar(
                path: file.path,
                status: file.status,
                addedLines: file.addedLines,
                removedLines: file.removedLines
            )

            Divider().overlay(Color.themeComment.opacity(0.2))

            Group {
                if let diff {
                    WorkspaceReviewDiffView(diff: diff, filePath: file.path)
                } else if let error {
                    ContentUnavailableView(
                        "Diff Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    ProgressView("Loading diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle(file.path.lastPathComponentForDisplay)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sha + "|" + file.path) {
            await loadDiff()
        }
    }


    // MARK: - Data Loading

    private func loadDiff() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }

        do {
            diff = try await api.getCommitFileDiff(workspaceId: workspaceId, sha: sha, path: file.path)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
