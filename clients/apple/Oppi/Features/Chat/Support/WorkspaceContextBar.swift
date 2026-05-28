import SwiftUI

// MARK: - Scoping logic (testable)

/// Pure-function extraction of the context bar's session-scoping rules.
/// When `sessionId` is set, all display properties scope exclusively to
/// that session's changed files — workspace-level data never leaks through.
enum ContextBarScoping {

    static func hasContent(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?,
        childSessions: [Session]
    ) -> Bool {
        // Show bar if there are child agents, even without git
        if !childSessions.isEmpty { return true }
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        if sessionId != nil { return sessionScope != nil }
        return !gitStatus.isClean
    }

    static func displayFileCount(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if sessionId != nil { return sessionScope?.sessionFileCount ?? 0 }
        return gitStatus?.uncommittedCount ?? 0
    }

    static func displayAddedLines(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if sessionId != nil { return sessionScope?.sessionAddedLines ?? 0 }
        return gitStatus?.addedLines ?? 0
    }

    static func displayRemovedLines(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> Int {
        if sessionId != nil { return sessionScope?.sessionRemovedLines ?? 0 }
        return gitStatus?.removedLines ?? 0
    }

    static func displayFiles(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?
    ) -> [GitFileStatus] {
        if sessionId != nil { return sessionScope?.sessionFiles ?? [] }
        return gitStatus?.files ?? []
    }
}

enum ContextBarCrossSessionEdits {
    static func sharedFilePaths(
        displayFiles: [GitFileStatus],
        currentSessionId: String?,
        workspaceId: String?,
        sessions: [Session]
    ) -> Set<String> {
        guard let currentSessionId, !displayFiles.isEmpty else { return [] }
        let displayedPaths = displayFiles.map(\.path)
        var sharedPaths: Set<String> = []

        for session in sessions where session.id != currentSessionId {
            if let workspaceId, let sessionWorkspaceId = session.workspaceId, sessionWorkspaceId != workspaceId {
                continue
            }
            guard let changedFiles = session.changeStats?.changedFiles, !changedFiles.isEmpty else { continue }

            for path in displayedPaths where !sharedPaths.contains(path) {
                if changedFiles.contains(where: { SessionScopedGitStatus.sessionPathMatches(sessionPath: $0, gitRelativePath: path) }) {
                    sharedPaths.insert(path)
                }
            }
        }

        return sharedPaths
    }
}

enum ContextBarSubagentStatus: Equatable {
    case waiting
    case question
    case working
    case ready
    case stopped
    case error

    struct Counts: Equatable {
        var waiting = 0
        var question = 0
        var working = 0
        var ready = 0
        var stopped = 0
        var error = 0
    }

    static func from(
        status: SessionStatus,
        pendingPermissionCount: Int,
        pendingAskCount: Int
    ) -> Self {
        if pendingPermissionCount > 0 { return .waiting }
        if pendingAskCount > 0 { return .question }

        switch status {
        case .starting, .busy, .stopping:
            return .working
        case .ready:
            return .ready
        case .stopped:
            return .stopped
        case .error:
            return .error
        }
    }

    static func counts(
        for sessions: [Session],
        pendingPermissionCount: (String) -> Int,
        pendingAskCount: (String) -> Int
    ) -> Counts {
        var counts = Counts()

        for session in sessions {
            switch from(
                status: session.status,
                pendingPermissionCount: pendingPermissionCount(session.id),
                pendingAskCount: pendingAskCount(session.id)
            ) {
            case .waiting:
                counts.waiting += 1
            case .question:
                counts.question += 1
            case .working:
                counts.working += 1
            case .ready:
                counts.ready += 1
            case .stopped:
                counts.stopped += 1
            case .error:
                counts.error += 1
            }
        }

        return counts
    }

    var label: String {
        switch self {
        case .waiting: "waiting"
        case .question: "question"
        case .working: "working"
        case .ready: "ready"
        case .stopped: "stopped"
        case .error: "error"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .waiting, .working:
            .themeOrange
        case .question:
            .themeBlue
        case .ready:
            .themeGreen
        case .stopped:
            .themeComment
        case .error:
            .themeRed
        }
    }

    var backgroundColor: Color {
        switch self {
        case .waiting, .working:
            Color.themeOrange.opacity(0.12)
        case .question:
            Color.themeBlue.opacity(0.12)
        case .ready:
            Color.themeGreen.opacity(0.12)
        case .stopped:
            Color.themeComment.opacity(0.1)
        case .error:
            Color.themeRed.opacity(0.12)
        }
    }
}

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
    let childSessions: [Session]
    var onSelectChild: ((String) -> Void)?
    var onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)?
    var fileDetailActionScope: SelectedTextActionScope?
    /// Incremented by the parent to request collapse (e.g. when the user taps the timeline or input).
    var collapseToken: Int = 0
    /// Called when the bar expands or collapses. Parents use this to show a dismiss overlay.
    var onExpandedChanged: ((Bool) -> Void)?

    @Environment(\.apiClient) private var apiClient
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore
    @Environment(AskRequestStore.self) private var askRequestStore

    @State private var isExpanded = false
    @State private var selectedFile: GitFileStatus?
    @State private var selectedCommit: GitCommitSummary?
    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var launchActionInFlightTitle: String?
    @State private var launchError: String?
    @State private var navigateToQuickAction: QuickActionSessionNavDestination?
    @State private var quickActionOptions: [WorkspaceQuickActionOption] = []
    @State private var quickActionOptionsWorkspaceId: String?
    @State private var isLoadingQuickActions = false
    @State private var stoppingAgentIds: Set<String> = []

    // Commit pagination state
    @State private var additionalCommits: [GitCommitSummary] = []
    @State private var hasMoreCommits = true
    @State private var isLoadingMore = false

    // Drag-select state
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragSelect = DragSelectState()

    init(
        gitStatus: GitStatus?,
        isLoading: Bool,
        appliesOuterHorizontalPadding: Bool = true,
        workspaceId: String? = nil,
        sessionId: String? = nil,
        initialExpanded: Bool = false,
        childSessions: [Session] = [],
        onSelectChild: ((String) -> Void)? = nil,
        onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)? = nil,
        fileDetailActionScope: SelectedTextActionScope? = nil,
        collapseToken: Int = 0,
        onExpandedChanged: ((Bool) -> Void)? = nil
    ) {
        self.gitStatus = gitStatus
        self.isLoading = isLoading
        self.appliesOuterHorizontalPadding = appliesOuterHorizontalPadding
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        _isExpanded = State(initialValue: initialExpanded)
        self.childSessions = childSessions
        self.onSelectChild = onSelectChild
        self.onReviewInCurrentSession = onReviewInCurrentSession
        self.fileDetailActionScope = fileDetailActionScope
        self.collapseToken = collapseToken
        self.onExpandedChanged = onExpandedChanged
    }

    // MARK: - Session scoping

    static func makeFileDetailActionScope(
        parentScope: SelectedTextActionScope?,
        fallbackScope: SelectedTextActionScope?,
        dismissFileDetail: @escaping () -> Void
    ) -> SelectedTextActionScope? {
        if let parentScope {
            switch parentScope {
            case .activeSession(let router):
                return .activeSession(SelectedTextPiActionRouter { request in
                    dismissFileDetail()
                    router.dispatch(request)
                })
            case .quickSession(let router):
                return .quickSession(SelectedTextPiActionRouter { request in
                    dismissFileDetail()
                    router.dispatch(request)
                })
            }
        }

        return fallbackScope
    }

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
        ContextBarScoping.hasContent(
            gitStatus: gitStatus,
            sessionId: sessionId,
            sessionScope: sessionScope,
            childSessions: childSessions
        )
    }

    private var displayFileCount: Int {
        ContextBarScoping.displayFileCount(gitStatus: gitStatus, sessionId: sessionId, sessionScope: sessionScope)
    }

    private var displayAddedLines: Int {
        ContextBarScoping.displayAddedLines(gitStatus: gitStatus, sessionId: sessionId, sessionScope: sessionScope)
    }

    private var displayRemovedLines: Int {
        ContextBarScoping.displayRemovedLines(gitStatus: gitStatus, sessionId: sessionId, sessionScope: sessionScope)
    }

    private var dirtyColor: Color {
        let count = displayFileCount
        if count == 0 { return .themeDiffAdded }
        if count <= 5 { return .themeFg }
        if count <= 15 { return .themeOrange }
        return .themeDiffRemoved
    }

    private var selectedFileQuickActions: [WorkspaceQuickActionOption] {
        quickActionOptions.sorted { left, right in
            if left.sourceScope != right.sourceScope {
                if left.sourceScope == "project" { return true }
                if right.sourceScope == "project" { return false }
            }
            return left.commandName.localizedCaseInsensitiveCompare(right.commandName) == .orderedAscending
        }
    }

    private var displayFiles: [GitFileStatus] {
        ContextBarScoping.displayFiles(gitStatus: gitStatus, sessionId: sessionId, sessionScope: sessionScope)
    }

    private var allSelected: Bool {
        !displayFiles.isEmpty && displayFiles.allSatisfy { selectedPaths.contains($0.path) }
    }

    private var sharedEditPaths: Set<String> {
        ContextBarCrossSessionEdits.sharedFilePaths(
            displayFiles: displayFiles,
            currentSessionId: sessionId,
            workspaceId: workspaceId,
            sessions: sessionStore.sessions
        )
    }

    private var canLaunch: Bool {
        !selectedPaths.isEmpty && launchActionInFlightTitle == nil
    }

    // MARK: - Agent counts

    private var agentStatusCounts: ContextBarSubagentStatus.Counts {
        ContextBarSubagentStatus.counts(
            for: childSessions,
            pendingPermissionCount: pendingPermissionCount(for:),
            pendingAskCount: pendingAskCount(for:)
        )
    }

    /// All commits: recent from git status + any additionally loaded ones.
    private var allCommits: [GitCommitSummary] {
        (gitStatus?.recentCommits ?? []) + additionalCommits
    }

    /// Dynamic max height for the scrollable content area.
    /// Estimates row heights to hug content; capped at 480.
    /// Note: selectionActionBar is outside the ScrollView — not counted here.
    private var expandedMaxHeight: CGFloat {
        let agentRows = CGFloat(childSessions.count) * 44
        let fileRows = CGFloat(displayFiles.count) * 26
        let commitRows = CGFloat(allCommits.count) * 17
        let loadMoreRow: CGFloat = hasMoreCommits ? 24 : 0
        let sectionHeaders: CGFloat = (!childSessions.isEmpty && !displayFiles.isEmpty) ? 48 : 24
        let overlapHint: CGFloat = sharedEditPaths.isEmpty ? 0 : 22
        let chrome: CGFloat = 20
        return min(agentRows + fileRows + commitRows + loadMoreRow + sectionHeaders + overlapHint + chrome, 480)
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
                .sheet(item: $selectedCommit) { commit in
                    NavigationStack {
                        CommitDetailView(workspaceId: workspaceId ?? "", commit: commit)
                            .environment(\.selectedTextActionScope, Self.makeFileDetailActionScope(
                                parentScope: fileDetailActionScope,
                                fallbackScope: nil,
                                dismissFileDetail: { selectedCommit = nil }
                            ))
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { selectedCommit = nil }
                                }
                            }
                    }
                }
                .alert(
                    "Quick Action Error",
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
                .onChange(of: isSelecting) { _, selecting in
                    guard selecting else { return }
                    Task { await loadQuickActionsIfNeeded() }
                }
                .onChange(of: workspaceId) { _, _ in
                    resetQuickActionCache()
                    guard isSelecting else { return }
                    Task { await loadQuickActionsIfNeeded() }
                }
            }
        }
        .navigationDestination(item: $navigateToQuickAction) { dest in
            ChatView(
                sessionId: dest.id,
                initialInputText: dest.inputText,
                initialPendingFiles: dest.filePaths.map {
                    PendingFileReference(path: $0, isDirectory: false, kind: .reviewFile, displayPrefix: dest.fileDisplayPrefix)
                }
            )
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
                        Text("\(SessionFormatting.compactCount(displayFileCount)) changed")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(dirtyColor)
                            .lineLimit(1)
                    }

                    if displayAddedLines > 0 || displayRemovedLines > 0 {
                        HStack(spacing: 4) {
                            if displayAddedLines > 0 {
                                Text("+\(SessionFormatting.compactCount(displayAddedLines))")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.themeDiffAdded)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if displayRemovedLines > 0 {
                                Text("-\(SessionFormatting.compactCount(displayRemovedLines))")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.themeDiffRemoved)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 0)

                    if let ahead = gitStatus?.ahead, let behind = gitStatus?.behind {
                        if ahead > 0 || behind > 0 {
                            HStack(spacing: 4) {
                                if ahead > 0 {
                                    Text("\u{2191}\(SessionFormatting.compactCount(ahead))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.themeDiffAdded)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                if behind > 0 {
                                    Text("\u{2193}\(SessionFormatting.compactCount(behind))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.themeOrange)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }

                    // Agent status pills (right-aligned)
                    if !childSessions.isEmpty {
                        agentStatusPills
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.appTagBold)
                        .foregroundStyle(.themeComment)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-context-bar.toggle")

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

            // Agents section
            if !childSessions.isEmpty {
                agentsSection
                if !displayFiles.isEmpty {
                    Divider().overlay(Color.themeComment.opacity(0.15))
                }
            }

            // File list
            if !displayFiles.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !sharedEditPaths.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.caption2.weight(.semibold))
                            Text("\(sharedEditPaths.count) file\(sharedEditPaths.count == 1 ? "" : "s") touched in another session")
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.themeOrange)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 3)
                        .accessibilityIdentifier("context-bar-overlap-hint")
                    }

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
            if !allCommits.isEmpty {
                Divider().overlay(Color.themeComment.opacity(0.15))

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allCommits) { commit in
                        Button {
                            selectedCommit = commit
                        } label: {
                            HStack(spacing: 8) {
                                Text(commit.sha)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.themeComment)
                                Text(commit.message)
                                    .font(.caption2)
                                    .foregroundStyle(.themeFgDim)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.appBadgeLight)
                                    .foregroundStyle(.themeComment.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if hasMoreCommits {
                        Button {
                            Task { await loadMoreCommits() }
                        } label: {
                            if isLoadingMore {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Text("Load more")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.themePurple)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }

                    if let gitStatus, gitStatus.stashCount > 0 {
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
                        .font(.appLabel)
                        .foregroundStyle(selectedPaths.contains(file.path) ? .themePurple : .themeComment)
                        .frame(width: 16)
                }

                icon.iconView(size: 16, font: .appChip)

                Text(file.path.shortenedPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if sharedEditPaths.contains(file.path) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.appBadgeLight)
                        .foregroundStyle(.themeOrange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.themeOrange.opacity(0.12), in: Capsule())
                        .accessibilityLabel("Touched in another session")
                }

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
                        .font(.appBadgeLight)
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
                if let launchActionInFlightTitle {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(launchActionInFlightTitle)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                    Spacer()
                } else {
                    Text("\(selectedPaths.count) file\(selectedPaths.count == 1 ? "" : "s")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(selectedPaths.isEmpty ? .themeComment : .themeFg)

                    Spacer()

                    if selectedFileQuickActions.isEmpty {
                        Text(isLoadingQuickActions ? "Loading templates…" : "No prompt templates")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedFileQuickActions) { option in
                                    quickActionButton(option: option)
                                }
                            }
                        }
                        .frame(maxWidth: 240, alignment: .trailing)
                        .disabled(!canLaunch)
                        .opacity(canLaunch ? 1 : 0.4)
                    }
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
                    file: file.toReviewFile(),
                    selectedTextActionScopeOverride: Self.makeFileDetailActionScope(
                        parentScope: fileDetailActionScope,
                        fallbackScope: nil,
                        dismissFileDetail: { selectedFile = nil }
                    )
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

    private func quickActionSourceLabel(_ sourceScope: String?) -> String {
        switch sourceScope {
        case "project": return "Project"
        case "user": return "User"
        case "temporary": return "Custom"
        default: return "Prompt"
        }
    }

    private func quickActionSourceColor(_ sourceScope: String?) -> Color {
        switch sourceScope {
        case "project": return .themeOrange
        case "temporary": return SlashCommand.Source.prompt.iconColor
        default: return SlashCommand.Source.prompt.iconColor
        }
    }

    private func quickActionButton(option: WorkspaceQuickActionOption) -> some View {
        Menu {
            if onReviewInCurrentSession != nil {
                Button("Use in this session") {
                    Task { await useSelectionInCurrentSession(option: option) }
                }
            }
            Button("Use in new session") {
                Task { await launchSelection(option: option) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: SlashCommand.Source.prompt.iconName)
                    .font(.caption2)
                    .foregroundStyle(quickActionSourceColor(option.sourceScope))
                    .frame(width: 13)

                Text("/\(option.commandName)")
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.themeBlue)

                Text(quickActionSourceLabel(option.sourceScope))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }
            .accessibilityLabel(option.title)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.themeBgDark.opacity(0.92), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.themeComment.opacity(0.22), lineWidth: 1)
            )
        }
    }

    private func resetQuickActionCache() {
        quickActionOptions = []
        quickActionOptionsWorkspaceId = nil
        isLoadingQuickActions = false
    }

    private func loadQuickActionsIfNeeded() async {
        guard isSelecting else { return }
        guard let workspaceId, let api = apiClient else { return }
        guard quickActionOptionsWorkspaceId != workspaceId else { return }
        guard !isLoadingQuickActions else { return }

        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }

        do {
            let actions = try await api.getWorkspaceQuickActions(workspaceId: workspaceId).actions
            guard self.workspaceId == workspaceId else { return }
            quickActionOptions = actions
            quickActionOptionsWorkspaceId = workspaceId
        } catch {
            guard self.workspaceId == workspaceId else { return }
            quickActionOptions = []
        }
    }

    private func useSelectionInCurrentSession(option: WorkspaceQuickActionOption) async {
        guard let workspaceId, !selectedPaths.isEmpty else { return }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }
        guard let onReviewInCurrentSession else { return }
        guard launchActionInFlightTitle == nil else { return }

        let paths = displayFiles.filter { selectedPaths.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else { return }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.prepareWorkspaceQuickActionSelection(
                workspaceId: workspaceId,
                paths: paths,
                selectedSessionId: sessionId,
                promptTemplateName: option.promptTemplateName
            )
            selectedPaths.removeAll()
            isSelecting = false
            collapseBar()
            onReviewInCurrentSession(
                response.visiblePrompt,
                response.filePaths.map {
                    PendingFileReference(path: $0, isDirectory: false, kind: .reviewFile, displayPrefix: option.title)
                }
            )
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func launchSelection(option: WorkspaceQuickActionOption) async {
        guard let workspaceId, !selectedPaths.isEmpty else { return }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }
        guard launchActionInFlightTitle == nil else { return }

        // Preserve file order from the list
        let paths = displayFiles.filter { selectedPaths.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else { return }

        launchActionInFlightTitle = option.progressTitle
        defer { launchActionInFlightTitle = nil }

        do {
            let response = try await api.createWorkspaceQuickActionSession(
                workspaceId: workspaceId,
                paths: paths,
                selectedSessionId: sessionId,
                promptTemplateName: option.promptTemplateName
            )
            sessionStore.upsert(response.session)
            selectedPaths.removeAll()
            isSelecting = false
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

    // MARK: - Load More Commits

    private func loadMoreCommits() async {
        guard let workspaceId, let api = apiClient, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let currentCount = allCommits.count
        do {
            let response = try await api.getCommitLog(workspaceId: workspaceId, offset: currentCount)
            additionalCommits.append(contentsOf: response.commits)
            hasMoreCommits = response.hasMore
        } catch {
            // Silently fail — not critical
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

    // MARK: - Agent Status Pills (collapsed header)

    private var agentStatusPills: some View {
        let counts = agentStatusCounts

        return HStack(spacing: 4) {
            if counts.waiting > 0 {
                compactAgentStatusPill(count: counts.waiting, status: .waiting)
            }
            if counts.question > 0 {
                compactAgentStatusPill(count: counts.question, status: .question)
            }
            if counts.working > 0 {
                compactAgentStatusPill(count: counts.working, status: .working)
            }
            if counts.ready > 0 {
                compactAgentStatusPill(count: counts.ready, status: .ready)
            }
            if counts.stopped > 0 {
                compactAgentStatusPill(count: counts.stopped, status: .stopped)
            }
            if counts.error > 0 {
                compactAgentStatusPill(count: counts.error, status: .error)
            }
        }
    }

    private func compactAgentStatusPill(
        count: Int,
        status: ContextBarSubagentStatus
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.foregroundColor)
                .frame(width: 5, height: 5)

            Text("\(count)")
                .font(.appTagBold)
                .foregroundStyle(status.foregroundColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(status.backgroundColor, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(status.label)")
    }

    // MARK: - Agents Section (expanded)

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SUB-AGENTS")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.themeComment)
                .tracking(0.8)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(childSessions) { child in
                agentRow(child)
            }
        }
        .padding(.bottom, 4)
    }

    private var agentIsStoppable: (Session) -> Bool {
        { child in
            !stoppingAgentIds.contains(child.id)
                && (child.status == .busy || child.status == .starting)
        }
    }

    private func agentRow(_ child: Session) -> some View {
        let status = agentStatus(for: child)

        return HStack(spacing: 0) {
            Button {
                onSelectChild?(child.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // Top line: status pill + name + chevron
                    HStack(spacing: 8) {
                        agentStatusLabel(for: status)
                            .fixedSize()

                        Text(child.displayTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(status == .error ? .themeRed : .themeFg)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        if !agentIsStoppable(child) {
                            Image(systemName: "chevron.right")
                                .font(.appBadgeLight)
                                .foregroundStyle(.themeComment.opacity(0.5))
                        }
                    }

                    // Bottom line: model, cost, duration
                    HStack(spacing: 6) {
                        if let model = SessionFormatting.shortModelName(child.model) {
                            Text(model)
                        }
                        if child.cost > 0 {
                            Text(SessionFormatting.costString(child.cost))
                        }
                        if let currentTurnStartedAt = child.currentTurnStartedAt,
                           child.status == .busy || child.status == .starting || child.status == .stopping {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(SessionFormatting.durationString(since: currentTurnStartedAt))
                            }
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
                    .padding(.leading, 2)
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if agentIsStoppable(child) {
                Button {
                    Task { await stopAgent(child) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.body)
                        .foregroundStyle(.themeRed)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if stoppingAgentIds.contains(child.id) {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func stopAgent(_ child: Session) async {
        guard let api = apiClient,
              let workspaceId = child.workspaceId ?? workspaceId else { return }
        stoppingAgentIds.insert(child.id)
        defer { stoppingAgentIds.remove(child.id) }
        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspaceId, sessionId: child.id)
            sessionStore.upsert(updated)
        } catch {
            launchError = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func pendingPermissionCount(for sessionId: String) -> Int {
        permissionStore.pending(for: sessionId).count
    }

    private func pendingAskCount(for sessionId: String) -> Int {
        askRequestStore.hasPending(for: sessionId) ? 1 : 0
    }

    private func agentStatus(for child: Session) -> ContextBarSubagentStatus {
        ContextBarSubagentStatus.from(
            status: child.status,
            pendingPermissionCount: pendingPermissionCount(for: child.id),
            pendingAskCount: pendingAskCount(for: child.id)
        )
    }

    private func agentStatusLabel(for status: ContextBarSubagentStatus) -> some View {
        Text(status.label)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(status.foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(status.backgroundColor, in: RoundedRectangle(cornerRadius: 4))
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


