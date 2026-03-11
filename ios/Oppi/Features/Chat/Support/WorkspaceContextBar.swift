import SwiftUI

/// Expandable bar showing workspace git status.
///
/// Pinned at the top of the chat view. Collapsed shows branch + dirty count + repo-wide +/-.
/// Expanded shows a tappable file list with file-type icons, per-file line stats,
/// recent commits, and select-for-review controls. Files open the diff detail view in a sheet.
///
/// Supports swipe-to-select: in select mode, dragging vertically across rows
/// selects or deselects them (Mail-style — first row touched determines direction).
struct WorkspaceContextBar: View {
    let gitStatus: GitStatus?
    let isLoading: Bool
    let appliesOuterHorizontalPadding: Bool
    let workspaceId: String?
    let sessionId: String?
    /// Incremented by the parent to request collapse (e.g. when the user taps the timeline or input).
    var collapseToken: Int = 0
    /// Called when the bar expands or collapses. Parents use this to show a dismiss overlay.
    var onExpandedChanged: ((Bool) -> Void)?

    @Environment(\.apiClient) private var apiClient
    @Environment(SessionStore.self) private var sessionStore

    @State private var isExpanded = false
    @State private var selectedFile: GitFileStatus?
    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var launchActionInFlight: WorkspaceReviewSessionAction?
    @State private var launchError: String?
    @State private var navigateToReview: ReviewSessionNavDestination?

    // Drag-select state
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragSelect = DragSelectState()

    init(
        gitStatus: GitStatus?,
        isLoading: Bool,
        appliesOuterHorizontalPadding: Bool = true,
        workspaceId: String? = nil,
        sessionId: String? = nil,
        collapseToken: Int = 0,
        onExpandedChanged: ((Bool) -> Void)? = nil
    ) {
        self.gitStatus = gitStatus
        self.isLoading = isLoading
        self.appliesOuterHorizontalPadding = appliesOuterHorizontalPadding
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.collapseToken = collapseToken
        self.onExpandedChanged = onExpandedChanged
    }

    // MARK: - Session scoping

    /// When viewing a session that has touched files, scope the bar to show only those files.
    /// Returns nil if no session, no changeStats, or the session hasn't modified any files yet.
    private var sessionScope: SessionScopedGitStatus? {
        guard let gitStatus, let sessionId else { return nil }
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return nil }
        guard let changedFiles = session.changeStats?.changedFiles, !changedFiles.isEmpty else { return nil }
        return SessionScopedGitStatus.filter(gitStatus: gitStatus, sessionChangedFiles: changedFiles)
    }

    /// True when the bar is showing session-scoped files instead of the full git status.
    private var isScoped: Bool { sessionScope != nil }

    // MARK: - Computed (scoped)

    private var hasContent: Bool {
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        return !gitStatus.isClean
    }

    /// File count shown in the collapsed bar — session count when scoped, total otherwise.
    private var displayFileCount: Int {
        sessionScope?.sessionFileCount ?? gitStatus?.uncommittedCount ?? 0
    }

    /// Added lines shown in the collapsed bar.
    private var displayAddedLines: Int {
        sessionScope?.sessionAddedLines ?? gitStatus?.addedLines ?? 0
    }

    /// Removed lines shown in the collapsed bar.
    private var displayRemovedLines: Int {
        sessionScope?.sessionRemovedLines ?? gitStatus?.removedLines ?? 0
    }

    private var dirtyColor: Color {
        let count = displayFileCount
        if count == 0 { return .themeDiffAdded }
        if count <= 5 { return .themeFg }
        if count <= 15 { return .themeOrange }
        return .themeDiffRemoved
    }

    /// Files displayed in the expanded panel — session-touched only when scoped.
    private var displayFiles: [GitFileStatus] {
        sessionScope?.sessionFiles ?? gitStatus?.files ?? []
    }

    private var allSelected: Bool {
        !displayFiles.isEmpty && displayFiles.allSatisfy { selectedPaths.contains($0.path) }
    }

    private var canLaunch: Bool {
        !selectedPaths.isEmpty && launchActionInFlight == nil
    }

    /// Dynamic max height: grows with content, caps at 480.
    private var expandedMaxHeight: CGFloat {
        guard gitStatus != nil else { return 300 }
        let fileRows = CGFloat(displayFiles.count) * 32
        let commitRows = CGFloat(gitStatus?.recentCommits.count ?? 0) * 24
        let selectionBar: CGFloat = isSelecting ? 52 : 0
        let chrome: CGFloat = 60
        return min(fileRows + commitRows + selectionBar + chrome, 480)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading && gitStatus == nil {
                EmptyView()
            } else if hasContent {
                VStack(spacing: 0) {
                    collapsedBar
                    if isExpanded {
                        expandedContent
                    }
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, appliesOuterHorizontalPadding ? 16 : 0)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .sheet(item: $selectedFile) { file in
                    fileDetailSheet(file: file)
                }
                .alert(
                    "Review Error",
                    isPresented: Binding(
                        get: { launchError != nil },
                        set: { if !$0 { launchError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { launchError = nil }
                } message: {
                    Text(launchError ?? "")
                }
                .onChange(of: collapseToken) {
                    guard isExpanded else { return }
                    collapseBar()
                }
                .onChange(of: isExpanded) { _, expanded in
                    onExpandedChanged?(expanded)
                }
            }
        }
        .navigationDestination(item: $navigateToReview) { dest in
            ChatView(sessionId: dest.id, initialInputText: dest.inputText, initialContextPills: dest.pills)
        }
    }

    // MARK: - Collapsed

    private var collapsedBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    if !isExpanded {
                        isSelecting = false
                        selectedPaths.removeAll()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let branch = gitStatus?.branch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.branch")
                                .font(.caption2.weight(.semibold))
                            Text(branch)
                                .font(.caption.monospaced().weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.themeCyan)
                    }

                    if displayFileCount > 0 {
                        Text("\(displayFileCount) changed")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(dirtyColor)
                    }

                    if displayAddedLines > 0 || displayRemovedLines > 0 {
                        HStack(spacing: 4) {
                            if displayAddedLines > 0 {
                                Text("+\(displayAddedLines)")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.themeDiffAdded)
                            }
                            if displayRemovedLines > 0 {
                                Text("-\(displayRemovedLines)")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.themeDiffRemoved)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    if let ahead = gitStatus?.ahead, let behind = gitStatus?.behind {
                        if ahead > 0 || behind > 0 {
                            HStack(spacing: 4) {
                                if ahead > 0 {
                                    Text("\u{2191}\(ahead)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.themeDiffAdded)
                                }
                                if behind > 0 {
                                    Text("\u{2193}\(behind)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.themeOrange)
                                }
                            }
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.themeComment)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, workspaceId != nil {
                // Select/cancel toggle
                Divider()
                    .frame(height: 18)
                    .padding(.trailing, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSelecting.toggle()
                        if !isSelecting { selectedPaths.removeAll() }
                    }
                } label: {
                    Text(isSelecting ? "Cancel" : "Select")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelecting ? .themeOrange : .themePurple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                expandedPanel
            }
            .frame(maxHeight: expandedMaxHeight)

            if isSelecting {
                selectionActionBar
            }
        }
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.themeComment.opacity(0.2))

            // Selection header when selecting
            if isSelecting {
                HStack(spacing: 8) {
                    Button {
                        if allSelected {
                            selectedPaths.removeAll()
                        } else {
                            selectedPaths = Set(displayFiles.map(\.path))
                        }
                    } label: {
                        Text(allSelected ? "Deselect All" : "Select All")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themePurple)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !selectedPaths.isEmpty {
                        Text("\(selectedPaths.count) selected")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeFg)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider().overlay(Color.themeComment.opacity(0.15))
            }

            // File list
            if !displayFiles.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(displayFiles) { file in
                        contextBarFileRow(file: file)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RowFramePreferenceKey.self,
                                        value: [file.path: geo.frame(in: .named("contextBarFileList"))]
                                    )
                                }
                            )
                    }

                    if !isScoped, let gitStatus, gitStatus.totalFiles > gitStatus.files.count {
                        Text("... and \(gitStatus.totalFiles - gitStatus.files.count) more")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 6)
                .coordinateSpace(name: "contextBarFileList")
                .onPreferenceChange(RowFramePreferenceKey.self) { rowFrames = $0 }
                .gesture(
                    isSelecting
                        ? DragGesture(minimumDistance: 8, coordinateSpace: .named("contextBarFileList"))
                            .onChanged { value in
                                handleDragSelect(at: value.location)
                            }
                            .onEnded { _ in
                                dragSelect.reset()
                            }
                        : nil
                )
            }

            // Recent commits
            if let gitStatus, !gitStatus.recentCommits.isEmpty {
                Divider().overlay(Color.themeComment.opacity(0.15))

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(gitStatus.recentCommits) { commit in
                        HStack(spacing: 8) {
                            Text(commit.sha)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themeComment)

                            Text(commit.message)
                                .font(.caption2)
                                .foregroundStyle(.themeFgDim)
                                .lineLimit(1)
                        }
                    }

                    if gitStatus.stashCount > 0 {
                        HStack(spacing: 8) {
                            Text("\(gitStatus.stashCount) stash")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themePurple)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if let gitStatus, gitStatus.isGitRepo {
                Divider().overlay(Color.themeComment.opacity(0.15))

                HStack(spacing: 8) {
                    if let sha = gitStatus.headSha {
                        Text(sha)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeComment)
                    }
                    if let msg = gitStatus.lastCommitMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.themeFgDim)
                            .lineLimit(1)
                    }
                    if gitStatus.stashCount > 0 {
                        Spacer(minLength: 0)
                        Text("\(gitStatus.stashCount) stash")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themePurple)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - File Row

    @ViewBuilder
    private func contextBarFileRow(file: GitFileStatus) -> some View {
        let icon = FileIcon.forPath(file.path)
        let canTap = workspaceId != nil

        Button {
            if isSelecting {
                toggleSelection(for: file)
            } else if canTap {
                selectedFile = file
            }
        } label: {
            HStack(spacing: 6) {
                if isSelecting {
                    Image(systemName: selectedPaths.contains(file.path) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selectedPaths.contains(file.path) ? .themePurple : .themeComment)
                        .frame(width: 16)
                }

                Image(systemName: icon.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(icon.color)
                    .frame(width: 16, height: 16)

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

                if !isSelecting, canTap {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.themeComment.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection Action Bar

    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.themeComment.opacity(0.2))

            HStack(spacing: 8) {
                if let launchActionInFlight {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(launchActionInFlight.progressTitle)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                    Spacer()
                } else {
                    Text("\(selectedPaths.count) file\(selectedPaths.count == 1 ? "" : "s")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(selectedPaths.isEmpty ? .themeComment : .themeFg)

                    Spacer()

                    Button("Review") {
                        Task { await launchSelection(.review) }
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.themePurple, in: Capsule())
                    .disabled(!canLaunch)
                    .opacity(canLaunch ? 1 : 0.4)

                    Menu {
                        Button(WorkspaceReviewSessionAction.reflect.menuTitle) {
                            Task { await launchSelection(.reflect) }
                        }
                        Button(WorkspaceReviewSessionAction.prepareCommit.menuTitle) {
                            Task { await launchSelection(.prepareCommit) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themePurple)
                    }
                    .disabled(!canLaunch)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - File Detail Sheet

    @ViewBuilder
    private func fileDetailSheet(file: GitFileStatus) -> some View {
        if let workspaceId {
            NavigationStack {
                WorkspaceReviewFileDetailView(
                    workspaceId: workspaceId,
                    selectedSessionId: sessionId,
                    file: file.toReviewFile()
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { selectedFile = nil }
                    }
                }
            }
        }
    }

    // MARK: - Selection Logic

    private func toggleSelection(for file: GitFileStatus) {
        if selectedPaths.contains(file.path) {
            selectedPaths.remove(file.path)
        } else {
            selectedPaths.insert(file.path)
        }
    }

    private func launchSelection(_ action: WorkspaceReviewSessionAction) async {
        guard let workspaceId, !selectedPaths.isEmpty else { return }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }
        guard launchActionInFlight == nil else { return }

        // Preserve file order from the list
        let paths = displayFiles.filter { selectedPaths.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else { return }

        launchActionInFlight = action
        defer { launchActionInFlight = nil }

        do {
            let response = try await api.createWorkspaceReviewSession(
                workspaceId: workspaceId,
                action: action,
                paths: paths,
                selectedSessionId: sessionId
            )
            sessionStore.upsert(response.session)
            selectedPaths.removeAll()
            isSelecting = false
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

    // MARK: - Collapse

    private func collapseBar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded = false
            isSelecting = false
            selectedPaths.removeAll()
            dragSelect.reset()
        }
    }

    // MARK: - Drag-select

    /// Process a drag position: select or deselect the row under the finger.
    /// Only called when `isSelecting` is already true (gesture is conditionally attached).
    private func handleDragSelect(at location: CGPoint) {
        guard isSelecting,
              let path = DragSelectState.pathAtLocation(location, in: rowFrames) else { return }
        dragSelect.handleRow(path, selectedPaths: &selectedPaths)
    }

    // MARK: - Helpers

    // periphery:ignore
    private func statusColor(for status: String) -> Color {
        let trimmed = status.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "M": return .themeOrange
        case "A": return .themeDiffAdded
        case "D": return .themeDiffRemoved
        case "R", "C": return .themeCyan
        case "??": return .themeComment
        case "UU", "AA", "DD": return .themeDiffRemoved
        default: return .themeFg
        }
    }
}

// MARK: - Preference key for row frame collection

private struct RowFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
