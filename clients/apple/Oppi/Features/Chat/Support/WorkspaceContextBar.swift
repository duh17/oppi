import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Scoping logic (testable)

/// Pure-function extraction of the context bar's session-scoping rules.
/// When `sessionId` is set, all display properties scope exclusively to
/// that session's changed files — workspace-level data never leaks through.
enum ContextBarScoping {

    static func hasContent(
        gitStatus: GitStatus?,
        sessionId: String?,
        sessionScope: SessionScopedGitStatus?,
        showCleanWorkspace: Bool = false
    ) -> Bool {
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        if sessionId != nil { return sessionScope != nil }
        if showCleanWorkspace { return true }
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

enum ContextBarQuickActionRoute: Equatable {
    case currentSession
    case newSession
}

enum ContextBarQuickActionRouting {
    static func defaultTapRoute(sessionId: String?, canReviewInCurrentSession: Bool) -> ContextBarQuickActionRoute {
        if sessionId != nil && canReviewInCurrentSession {
            return .currentSession
        }
        return .newSession
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
        var originalPathByNormalizedPath: [String: String] = [:]
        originalPathByNormalizedPath.reserveCapacity(displayFiles.count)
        for file in displayFiles {
            originalPathByNormalizedPath[normalizedPath(file.path)] = file.path
        }

        let displayedPathSet = Set(originalPathByNormalizedPath.keys)
        guard !displayedPathSet.isEmpty else { return [] }

        var remainingPaths = displayedPathSet
        var sharedPaths: Set<String> = []

        for session in sessions where session.id != currentSessionId {
            if let workspaceId, let sessionWorkspaceId = session.workspaceId, sessionWorkspaceId != workspaceId {
                continue
            }
            guard let changedFiles = session.changeStats?.changedFiles, !changedFiles.isEmpty else { continue }

            for changedFile in changedFiles {
                let matches = matchingDisplayedPaths(for: changedFile, remainingDisplayedPaths: remainingPaths)
                guard !matches.isEmpty else { continue }

                for path in matches {
                    sharedPaths.insert(originalPathByNormalizedPath[path] ?? path)
                    remainingPaths.remove(path)
                }

                if remainingPaths.isEmpty {
                    return sharedPaths
                }
            }
        }

        return sharedPaths
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacing("\\", with: "/")
    }

    private static func matchingDisplayedPaths(
        for sessionPath: String,
        remainingDisplayedPaths: Set<String>
    ) -> [String] {
        guard !remainingDisplayedPaths.isEmpty else { return [] }

        let normalizedSessionPath = normalizedPath(sessionPath)
        let components = normalizedSessionPath.split(separator: "/", omittingEmptySubsequences: true)
        var matches: [String] = []

        func appendIfDisplayed(_ candidate: String) {
            guard remainingDisplayedPaths.contains(candidate), !matches.contains(candidate) else { return }
            matches.append(candidate)
        }

        appendIfDisplayed(normalizedSessionPath)

        guard components.count > 1 else { return matches }
        for index in components.indices {
            appendIfDisplayed(components[index...].joined(separator: "/"))
        }

        return matches
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
    let worktreeId: String?
    let showCleanWorkspace: Bool
    var onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)?
    var fileDetailReviewCommentScope: ReviewCommentSelectionScope?
    /// Incremented by the parent to request collapse (e.g. when the user taps the timeline or input).
    var collapseToken: Int = 0
    /// Called when the bar expands or collapses. Parents use this to show a dismiss overlay.
    var onExpandedChanged: ((Bool) -> Void)?

    @Environment(\.apiClient) private var apiClient
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isExpanded = false
    @State private var selectedFile: GitFileStatus?
    @State private var selectedCommit: GitCommitSummary?
    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var launchActionInFlightTitle: String?
    @State private var launchError: String?
    @State private var navigateToQuickAction: QuickActionSessionNavDestination?
    @State private var quickActionOptions: [WorkspaceQuickActionOption] = []
    @State private var quickActionOptionsContextKey: String?
    @State private var isLoadingQuickActions = false

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
        worktreeId: String? = nil,
        showCleanWorkspace: Bool = false,
        initialExpanded: Bool = false,
        onReviewInCurrentSession: ((String, [PendingFileReference]) -> Void)? = nil,
        fileDetailReviewCommentScope: ReviewCommentSelectionScope? = nil,
        collapseToken: Int = 0,
        onExpandedChanged: ((Bool) -> Void)? = nil
    ) {
        self.gitStatus = gitStatus
        self.isLoading = isLoading
        self.appliesOuterHorizontalPadding = appliesOuterHorizontalPadding
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.worktreeId = worktreeId
        self.showCleanWorkspace = showCleanWorkspace
        _isExpanded = State(initialValue: initialExpanded)
        self.onReviewInCurrentSession = onReviewInCurrentSession
        self.fileDetailReviewCommentScope = fileDetailReviewCommentScope
        self.collapseToken = collapseToken
        self.onExpandedChanged = onExpandedChanged
    }

    // MARK: - Session scoping

    @MainActor
    static func makeFileDetailReviewCommentScope(
        parentScope: ReviewCommentSelectionScope?,
        fallbackScope: ReviewCommentSelectionScope?,
        dismissFileDetail: @escaping () -> Void
    ) -> ReviewCommentSelectionScope? {
        if let parentScope {
            switch parentScope {
            case .activeSession(let router):
                return .activeSession(router.retargetingDispatch { request in
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

    // MARK: - Computed (scoped)

    private var hasContent: Bool {
        ContextBarScoping.hasContent(
            gitStatus: gitStatus,
            sessionId: sessionId,
            sessionScope: sessionScope,
            showCleanWorkspace: showCleanWorkspace
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

    private var canLaunch: Bool {
        !selectedPaths.isEmpty && launchActionInFlightTitle == nil
    }

    /// All commits: recent from git status + any additionally loaded ones.
    private var allCommits: [GitCommitSummary] {
        (gitStatus?.recentCommits ?? []) + additionalCommits
    }

    private var usesIPadTypography: Bool {
        guard horizontalSizeClass == .regular else { return false }
#if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
#else
        return false
#endif
    }

    private func gitBarFont(compact: Font, iPad: Font) -> Font {
        usesIPadTypography ? iPad : compact
    }

    /// Dynamic max height for the scrollable content area.
    /// Estimates row heights to hug content; capped at 480.
    /// Note: selectionActionBar is outside the ScrollView — not counted here.
    private func expandedMaxHeight(displayFiles: [GitFileStatus], sharedEditPaths: Set<String>) -> CGFloat {
        let fileRows = CGFloat(displayFiles.count) * (usesIPadTypography ? 28 : 26)
        let commitRows = CGFloat(allCommits.count) * (usesIPadTypography ? 20 : 17)
        let loadMoreRow: CGFloat = hasMoreCommits ? (usesIPadTypography ? 28 : 24) : 0
        let sectionHeaders: CGFloat = usesIPadTypography ? 28 : 24
        let overlapHint: CGFloat = sharedEditPaths.isEmpty ? 0 : (usesIPadTypography ? 24 : 22)
        let chrome: CGFloat = 20
        return min(fileRows + commitRows + loadMoreRow + sectionHeaders + overlapHint + chrome, 480)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading && gitStatus == nil {
                EmptyView()
            } else if hasContent {
                VStack(spacing: 0) {
                    collapsedBar
                    FeatureEducationTipBannerHost(
                        tip: FeatureEducationTips.ChangedFilesBarTip(),
                        descriptor: FeatureEducationTips.changedFilesBar,
                        contentInsets: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
                    )
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
                            .environment(\.reviewCommentSelectionScope, Self.makeFileDetailReviewCommentScope(
                                parentScope: fileDetailReviewCommentScope,
                                fallbackScope: nil,
                                dismissFileDetail: { selectedCommit = nil }
                            ))
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button {
                                        selectedCommit = nil
                                    } label: {
                                        Image(systemName: FullScreenViewerNavigationChrome.DismissMode.modal.systemImageName)
                                    }
                                    .accessibilityLabel(FullScreenViewerNavigationChrome.DismissMode.modal.accessibilityLabel)
                                }
                            }
                    }
                }
                .alert(
                    "Unable to start action",
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
                .onChange(of: sessionId) { _, _ in
                    resetQuickActionCache()
                    guard isSelecting else { return }
                    Task { await loadQuickActionsIfNeeded() }
                }
                .onChange(of: worktreeId) { _, _ in
                    resetQuickActionCache()
                    guard isSelecting else { return }
                    Task { await loadQuickActionsIfNeeded() }
                }
            }
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
    }

    // MARK: - Collapsed

    private var collapsedBar: some View {
        HStack(spacing: 0) {
            Button {
                let wasExpanded = isExpanded
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    if !isExpanded {
                        isSelecting = false
                        selectedPaths.removeAll()
                    }
                }
                if !wasExpanded, isExpanded {
                    FeatureEducationTips.markChangedFilesBarExpanded()
                }
            } label: {
                HStack(spacing: 8) {
                    if let branch = gitStatus?.branch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.branch")
                                .font(gitBarFont(compact: .caption2.weight(.semibold), iPad: .caption.weight(.semibold)))
                            Text(branch)
                                .font(gitBarFont(
                                    compact: .caption.monospaced().weight(.medium),
                                    iPad: .footnote.monospaced().weight(.medium)
                                ))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.themeCyan)
                    }

                    if displayFileCount > 0 {
                        Text("\(SessionFormatting.compactCount(displayFileCount)) changed")
                            .font(gitBarFont(
                                compact: .caption.monospaced().weight(.semibold),
                                iPad: .footnote.monospaced().weight(.semibold)
                            ))
                            .foregroundStyle(dirtyColor)
                            .lineLimit(1)
                    }

                    if displayAddedLines > 0 || displayRemovedLines > 0 {
                        HStack(spacing: 4) {
                            if displayAddedLines > 0 {
                                Text("+\(SessionFormatting.compactCount(displayAddedLines))")
                                    .font(gitBarFont(compact: .caption2.monospaced().bold(), iPad: .caption.monospaced().bold()))
                                    .foregroundStyle(.themeDiffAdded)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if displayRemovedLines > 0 {
                                Text("-\(SessionFormatting.compactCount(displayRemovedLines))")
                                    .font(gitBarFont(compact: .caption2.monospaced().bold(), iPad: .caption.monospaced().bold()))
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
                                        .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                                        .foregroundStyle(.themeDiffAdded)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                if behind > 0 {
                                    Text("\u{2193}\(SessionFormatting.compactCount(behind))")
                                        .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                                        .foregroundStyle(.themeOrange)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }


                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(gitBarFont(compact: .appTagBold, iPad: .caption2.weight(.bold)))
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
                        .font(gitBarFont(compact: .caption2.weight(.semibold), iPad: .caption.weight(.semibold)))
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
        let files = displayFiles
        let sharedPaths = ContextBarCrossSessionEdits.sharedFilePaths(
            displayFiles: files,
            currentSessionId: sessionId,
            workspaceId: workspaceId,
            sessions: sessionStore.sessions
        )

        return VStack(spacing: 0) {
            ScrollView {
                expandedPanel(displayFiles: files, sharedEditPaths: sharedPaths)
            }
            .frame(maxHeight: expandedMaxHeight(displayFiles: files, sharedEditPaths: sharedPaths))

            if isSelecting {
                selectionActionBar
            }
        }
    }

    // MARK: - Expanded Panel

    private func expandedPanel(displayFiles: [GitFileStatus], sharedEditPaths: Set<String>) -> some View {
        let allFilesSelected = !displayFiles.isEmpty && displayFiles.allSatisfy { selectedPaths.contains($0.path) }

        return VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.themeComment.opacity(0.2))

            // Selection header when selecting
            if isSelecting {
                HStack(spacing: 8) {
                    Button {
                        if allFilesSelected {
                            selectedPaths.removeAll()
                        } else {
                            selectedPaths = Set(displayFiles.map(\.path))
                        }
                    } label: {
                        Text(allFilesSelected ? "Deselect All" : "Select All")
                            .font(gitBarFont(compact: .caption2.weight(.semibold), iPad: .caption.weight(.semibold)))
                            .foregroundStyle(.themePurple)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !selectedPaths.isEmpty {
                        Text("\(selectedPaths.count) selected")
                            .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
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
                    if !sharedEditPaths.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(gitBarFont(compact: .caption2.weight(.semibold), iPad: .caption.weight(.semibold)))
                            Text("\(sharedEditPaths.count) file\(sharedEditPaths.count == 1 ? "" : "s") touched in another session")
                                .font(gitBarFont(compact: .caption2.weight(.medium), iPad: .caption.weight(.medium)))
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
                        contextBarFileRow(file: file, isSharedEdit: sharedEditPaths.contains(file.path))
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RowFramePreferenceKey.self,
                                        value: [file.path: geo.frame(in: .named("contextBarFileList"))]
                                    )
                                }
                            )
                    }

                    if sessionId == nil, let gitStatus, gitStatus.totalFiles > gitStatus.files.count {
                        Text("... and \(gitStatus.totalFiles - gitStatus.files.count) more")
                            .font(gitBarFont(compact: .caption2, iPad: .caption))
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
                                    .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                                    .foregroundStyle(.themeComment)
                                Text(commit.message)
                                    .font(gitBarFont(compact: .caption2, iPad: .caption))
                                    .foregroundStyle(.themeFgDim)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(gitBarFont(compact: .appBadgeLight, iPad: .caption2.weight(.semibold)))
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
                                    .font(gitBarFont(compact: .caption2.weight(.semibold), iPad: .caption.weight(.semibold)))
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
                                .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
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
                            .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                            .foregroundStyle(.themeComment)
                    }
                    if let msg = gitStatus.lastCommitMessage {
                        Text(msg)
                            .font(gitBarFont(compact: .caption2, iPad: .caption))
                            .foregroundStyle(.themeFgDim)
                            .lineLimit(1)
                    }
                    if gitStatus.stashCount > 0 {
                        Spacer(minLength: 0)
                        Text("\(gitStatus.stashCount) stash")
                            .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
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
    private func contextBarFileRow(file: GitFileStatus, isSharedEdit: Bool) -> some View {
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
                        .font(gitBarFont(compact: .appLabel, iPad: .caption))
                        .foregroundStyle(selectedPaths.contains(file.path) ? .themePurple : .themeComment)
                        .frame(width: 16)
                }

                icon.iconView(size: 16, font: .appChip)

                Text(file.path.shortenedPath)
                    .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if isSharedEdit {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(gitBarFont(compact: .appBadgeLight, iPad: .caption2.weight(.semibold)))
                        .foregroundStyle(.themeOrange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.themeOrange.opacity(0.12), in: Capsule())
                        .accessibilityLabel("Touched in another session")
                }

                if let added = file.addedLines, added > 0 {
                    Text("+\(added)")
                        .font(gitBarFont(compact: .caption2.monospaced().bold(), iPad: .caption.monospaced().bold()))
                        .foregroundStyle(.themeDiffAdded)
                }
                if let removed = file.removedLines, removed > 0 {
                    Text("-\(removed)")
                        .font(gitBarFont(compact: .caption2.monospaced().bold(), iPad: .caption.monospaced().bold()))
                        .foregroundStyle(.themeDiffRemoved)
                }

                if !isSelecting, canTap {
                    Image(systemName: "chevron.right")
                        .font(gitBarFont(compact: .appBadgeLight, iPad: .caption2.weight(.semibold)))
                        .foregroundStyle(.themeComment.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, usesIPadTypography ? 5 : 4)
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
                        .font(gitBarFont(compact: .caption2, iPad: .caption))
                        .foregroundStyle(.themeComment)
                    Spacer()
                } else {
                    Text("\(selectedPaths.count) file\(selectedPaths.count == 1 ? "" : "s")")
                        .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                        .foregroundStyle(selectedPaths.isEmpty ? .themeComment : .themeFg)

                    Spacer()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            newSessionButton

                            if selectedFileQuickActions.isEmpty {
                                Text(isLoadingQuickActions ? "Loading templates…" : "No prompt templates")
                                    .font(gitBarFont(compact: .caption2, iPad: .caption))
                                    .foregroundStyle(.themeComment)
                            } else {
                                HStack(spacing: 8) {
                                    ForEach(selectedFileQuickActions) { option in
                                        quickActionButton(option: option)
                                    }
                                }
                                .disabled(!canLaunch)
                                .opacity(canLaunch ? 1 : 0.4)
                            }
                        }
                    }
                    .frame(maxWidth: 280, alignment: .trailing)
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
                    worktreeId: worktreeId,
                    reviewCommentSelectionScopeOverride: Self.makeFileDetailReviewCommentScope(
                        parentScope: fileDetailReviewCommentScope,
                        fallbackScope: nil,
                        dismissFileDetail: { selectedFile = nil }
                    ),
                    navigationFiles: displayFiles.map { $0.toReviewFile() },
                    allowsHorizontalBackSwipe: false
                )
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

    // MARK: - Selection Logic

    private func toggleSelection(for file: GitFileStatus) {
        if selectedPaths.contains(file.path) {
            selectedPaths.remove(file.path)
        } else {
            selectedPaths.insert(file.path)
        }
    }

    private var newSessionButton: some View {
        Button {
            Task { await launchEmptySession() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(gitBarFont(compact: .caption2, iPad: .caption))
                    .foregroundStyle(.themePurple)
                    .frame(width: 13)

                Text("New Session")
                    .font(gitBarFont(compact: .caption2.monospaced().weight(.medium), iPad: .caption.monospaced().weight(.medium)))
                    .foregroundStyle(.themeFg)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .themedSurface(.opaqueCard, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(launchActionInFlightTitle != nil)
        .accessibilityLabel("Start new session with selected files")
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
        let route = ContextBarQuickActionRouting.defaultTapRoute(
            sessionId: sessionId,
            canReviewInCurrentSession: onReviewInCurrentSession != nil
        )

        return Button {
            switch route {
            case .currentSession:
                Task { await useSelectionInCurrentSession(option: option) }
            case .newSession:
                Task { await launchSelection(option: option) }
            }
        } label: {
            quickActionButtonLabel(option: option)
        }
        .buttonStyle(.plain)
        .contextMenu {
            switch route {
            case .currentSession:
                Button("Use in new session") {
                    Task { await launchSelection(option: option) }
                }
            case .newSession:
                if onReviewInCurrentSession != nil {
                    Button("Use in this session") {
                        Task { await useSelectionInCurrentSession(option: option) }
                    }
                }
            }
        }
    }

    private func quickActionButtonLabel(option: WorkspaceQuickActionOption) -> some View {
        return HStack(spacing: 6) {
            Image(systemName: SlashCommand.Source.prompt.iconName)
                .font(gitBarFont(compact: .caption2, iPad: .caption))
                .foregroundStyle(quickActionSourceColor(option.sourceScope))
                .frame(width: 13)

            Text("/\(option.commandName)")
                .font(gitBarFont(compact: .caption2.monospaced().weight(.medium), iPad: .caption.monospaced().weight(.medium)))
                .foregroundStyle(.themeBlue)

            Text(quickActionSourceLabel(option.sourceScope))
                .font(gitBarFont(compact: .caption2.monospaced(), iPad: .caption.monospaced()))
                .foregroundStyle(.themeComment)
        }
        .accessibilityLabel(option.title)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .themedSurface(.opaqueCard, in: Capsule())
    }

    private func resetQuickActionCache() {
        quickActionOptions = []
        quickActionOptionsContextKey = nil
        isLoadingQuickActions = false
    }

    private func loadQuickActionsIfNeeded() async {
        guard isSelecting else { return }
        guard let workspaceId, let api = apiClient else { return }
        let selectedSessionId = sessionId
        let selectedWorktreeId = worktreeId
        let cacheKey = "\(workspaceId)|\(selectedSessionId ?? "")|\(selectedWorktreeId ?? "")"
        guard quickActionOptionsContextKey != cacheKey else { return }
        guard !isLoadingQuickActions else { return }

        isLoadingQuickActions = true
        defer { isLoadingQuickActions = false }

        do {
            let actions = try await api.getWorkspaceQuickActions(
                workspaceId: workspaceId,
                selectedSessionId: selectedSessionId,
                worktreeId: selectedWorktreeId
            ).actions
            guard self.workspaceId == workspaceId,
                  self.sessionId == selectedSessionId,
                  self.worktreeId == selectedWorktreeId else { return }
            quickActionOptions = actions
            quickActionOptionsContextKey = cacheKey
        } catch {
            guard self.workspaceId == workspaceId,
                  self.sessionId == selectedSessionId,
                  self.worktreeId == selectedWorktreeId else { return }
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
                worktreeId: worktreeId,
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

    private func launchEmptySession() async {
        guard let workspaceId else { return }
        guard let api = apiClient else {
            launchError = "Server is offline."
            return
        }
        guard launchActionInFlightTitle == nil else { return }

        launchActionInFlightTitle = "Starting new session…"
        defer { launchActionInFlightTitle = nil }

        do {
            let paths = displayFiles.filter { selectedPaths.contains($0.path) }.map(\.path)
            let response = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                worktreeId: worktreeId
            )
            sessionStore.upsert(response.session)
            selectedPaths.removeAll()
            isSelecting = false
            navigateToQuickAction = QuickActionSessionNavDestination.attaching(
                sessionId: response.session.id,
                filePaths: paths
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
                worktreeId: worktreeId,
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

