import SwiftUI

struct WorkspaceReviewView: View {
    let workspaceId: String
    let selectedSessionId: String?

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var review: WorkspaceReviewFilesResponse?
    @State private var error: String?
    @State private var isLoading = false
    @State private var filter: ReviewFilter
    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var launchActionInFlight: WorkspaceReviewSessionAction?
    @State private var launchError: String?
    @State private var navigateToSessionId: String?

    init(workspaceId: String, selectedSessionId: String? = nil) {
        self.workspaceId = workspaceId
        self.selectedSessionId = selectedSessionId
        _filter = State(initialValue: selectedSessionId == nil ? .all : .selectedSession)
    }

    private enum ReviewFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case selectedSession = "Touched"
        case staged = "Staged"
        case unstaged = "Unstaged"
        case untracked = "Untracked"

        var id: String { rawValue }
    }

    private var workspaceName: String {
        connection.workspaceStore.workspaces.first(where: { $0.id == workspaceId })?.name ?? "Workspace"
    }

    private var visibleFilters: [ReviewFilter] {
        if selectedSessionId == nil {
            return [.all, .staged, .unstaged, .untracked]
        }
        return [.all, .selectedSession, .staged, .unstaged, .untracked]
    }

    private var filteredFiles: [WorkspaceReviewFile] {
        guard let review else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return review.files
            .filter { file in
                switch filter {
                case .all:
                    break
                case .selectedSession:
                    guard file.selectedSessionTouched else { return false }
                case .staged:
                    guard file.isStaged else { return false }
                case .unstaged:
                    guard file.isUnstaged else { return false }
                case .untracked:
                    guard file.isUntracked else { return false }
                }

                guard !query.isEmpty else { return true }
                return file.path.lowercased().contains(query) || file.statusLabel.lowercased().contains(query)
            }
            .sorted { lhs, rhs in
                lhs.path.localizedTreePathCompare(to: rhs.path) == .orderedAscending
            }
    }

    private var filteredFilePaths: [String] {
        filteredFiles.map(\.path)
    }

    private var selectedFilesInVisibleOrder: [WorkspaceReviewFile] {
        filteredFiles.filter { selectedPaths.contains($0.path) }
    }

    private var allVisibleSelected: Bool {
        !filteredFiles.isEmpty && filteredFiles.allSatisfy { selectedPaths.contains($0.path) }
    }

    private var canLaunchSelection: Bool {
        !selectedPaths.isEmpty && launchActionInFlight == nil
    }

    private var canSelectFiles: Bool {
        review?.isGitRepo == true && !(review?.files.isEmpty ?? true)
    }

    var body: some View {
        contentView
            .background(Color.themeBgDark)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search changed files…")
            .task(id: workspaceId + (selectedSessionId ?? "")) {
                await loadReview()
            }
            .onChange(of: filteredFilePaths) { _, newValue in
                guard isSelecting else { return }
                selectedPaths.formIntersection(Set(newValue))
            }
            .navigationDestination(item: $navigateToSessionId) { sessionId in
                ChatView(sessionId: sessionId)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting, review?.isGitRepo == true {
                    selectionActionBar
                }
            }
            .overlay {
                launchOverlay
            }
            .toolbar {
                toolbarContent
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

    @ViewBuilder
    private var contentView: some View {
        if isLoading && review == nil {
            ProgressView("Loading review…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.themeBgDark)
        } else if let error, review == nil {
            ContentUnavailableView(
                "Review Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let review, !review.isGitRepo {
            ContentUnavailableView(
                "Not a Git Workspace",
                systemImage: "arrow.triangle.branch",
                description: Text("Current review is only available for git-backed workspaces.")
            )
        } else if let review, review.files.isEmpty {
            ContentUnavailableView(
                "No Dirty Files",
                systemImage: "checkmark.circle",
                description: Text("This workspace has no changes to review.")
            )
        } else {
            reviewList
        }
    }

    @ViewBuilder
    private var launchOverlay: some View {
        if let launchActionInFlight {
            ProgressView(launchActionInFlight.progressTitle)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }

        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "None" : "All") {
                    toggleSelectAllVisible()
                }
                .disabled(filteredFiles.isEmpty || launchActionInFlight != nil)
            }
        }

        if canSelectFiles {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? "Cancel" : "Select") {
                    toggleSelectionMode()
                }
                .disabled(launchActionInFlight != nil)
            }
        }
    }

    private var reviewList: some View {
        List {
            Section {
                filterChips
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if let review {
                if selectedSessionId != nil {
                    Section("Scope") {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                .font(.subheadline)
                                .foregroundStyle(.themePurple)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Selected session provenance")
                                    .foregroundStyle(.themeFg)
                                Text("Diffs show current git state. Touched badges and History come from the selected session.")
                                    .font(.caption)
                                    .foregroundStyle(.themeComment)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Summary") {
                    LabeledContent("Workspace") {
                        Text(workspaceName)
                            .foregroundStyle(.themeFg)
                    }

                    if let branch = review.branch, !branch.isEmpty {
                        LabeledContent("Branch") {
                            Text(branch)
                                .font(.caption.monospaced())
                                .foregroundStyle(.themeCyan)
                        }
                    }

                    LabeledContent("Changed Files") {
                        Text("\(review.changedFileCount)")
                            .foregroundStyle(.themeFg)
                    }

                    HStack(spacing: 10) {
                        if review.stagedFileCount > 0 {
                            badge(text: "staged \(review.stagedFileCount)", color: .themeGreen)
                        }
                        if review.unstagedFileCount > 0 {
                            badge(text: "unstaged \(review.unstagedFileCount)", color: .themeOrange)
                        }
                        if review.untrackedFileCount > 0 {
                            badge(text: "untracked \(review.untrackedFileCount)", color: .themeComment)
                        }
                    }

                    if review.addedLines > 0 || review.removedLines > 0 {
                        HStack(spacing: 10) {
                            if review.addedLines > 0 {
                                Text("+\(review.addedLines)")
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(.themeDiffAdded)
                            }
                            if review.removedLines > 0 {
                                Text("-\(review.removedLines)")
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(.themeDiffRemoved)
                            }
                        }
                    }

                    if review.selectedSessionTouchedCount > 0 {
                        LabeledContent("Touched by Session") {
                            Text("\(review.selectedSessionTouchedCount)")
                                .foregroundStyle(.themePurple)
                        }
                    }

                    if isSelecting {
                        LabeledContent("Selection") {
                            Text(selectionSummary)
                                .foregroundStyle(selectedPaths.isEmpty ? .themeComment : .themePurple)
                        }
                    }
                }

                if filteredFiles.isEmpty {
                    Section {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView(
                                "No Matching Files",
                                systemImage: "line.3.horizontal.decrease.circle",
                                description: Text(emptyFilterMessage)
                            )
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                } else {
                    Section("Files") {
                        ForEach(filteredFiles) { file in
                            if isSelecting {
                                Button {
                                    toggleSelection(for: file)
                                } label: {
                                    WorkspaceReviewFileRow(
                                        file: file,
                                        showsSelectionMarker: true,
                                        isSelected: selectedPaths.contains(file.path)
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    WorkspaceReviewFileDetailView(
                                        workspaceId: workspaceId,
                                        selectedSessionId: selectedSessionId,
                                        file: file
                                    )
                                } label: {
                                    WorkspaceReviewFileRow(file: file)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.themeBgDark)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleFilters) { candidate in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            filter = candidate
                        }
                    } label: {
                        Text(candidate.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                filter == candidate ? Color.themeBlue : Color.themeBgHighlight,
                                in: Capsule()
                            )
                            .foregroundStyle(filter == candidate ? .white : .themeFgDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.themeComment.opacity(0.2))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionSummary)
                        .font(.caption.bold())
                        .foregroundStyle(.themeFg)
                    Text("Start a focused follow-up session from these files")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }

                Spacer(minLength: 12)

                Button(WorkspaceReviewSessionAction.review.primaryButtonTitle) {
                    Task {
                        await launchSelection(.review)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.themePurple)
                .disabled(!canLaunchSelection)

                Menu {
                    Button(WorkspaceReviewSessionAction.reflect.menuTitle) {
                        Task {
                            await launchSelection(.reflect)
                        }
                    }

                    Button(WorkspaceReviewSessionAction.prepareCommit.menuTitle) {
                        Task {
                            await launchSelection(.prepareCommit)
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!canLaunchSelection)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.themeBgDark)
        }
    }

    private var selectionSummary: String {
        if selectedPaths.isEmpty {
            return "No files selected"
        }

        return selectedPaths.count == 1 ? "1 file selected" : "\(selectedPaths.count) files selected"
    }

    private var emptyFilterMessage: String {
        switch filter {
        case .all:
            return "No files match the current review scope."
        case .selectedSession:
            return "The selected session has not touched any currently dirty files."
        case .staged:
            return "No staged files to review."
        case .unstaged:
            return "No unstaged files to review."
        case .untracked:
            return "No untracked files to review."
        }
    }

    @ViewBuilder
    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func toggleSelectionMode() {
        if isSelecting {
            isSelecting = false
            selectedPaths.removeAll()
        } else {
            isSelecting = true
            selectedPaths.formIntersection(Set(filteredFilePaths))
        }
    }

    private func toggleSelectAllVisible() {
        if allVisibleSelected {
            selectedPaths.removeAll()
        } else {
            selectedPaths = Set(filteredFilePaths)
        }
    }

    private func toggleSelection(for file: WorkspaceReviewFile) {
        if selectedPaths.contains(file.path) {
            selectedPaths.remove(file.path)
        } else {
            selectedPaths.insert(file.path)
        }
    }

    private func launchSelection(_ action: WorkspaceReviewSessionAction) async {
        let paths = selectedFilesInVisibleOrder.map(\.path)
        guard !paths.isEmpty else {
            launchError = "Select at least one file to start a focused review session."
            return
        }

        await createReviewSession(action: action, paths: paths)
    }

    private func createReviewSession(
        action: WorkspaceReviewSessionAction,
        paths: [String]
    ) async {
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
                paths: paths,
                selectedSessionId: selectedSessionId
            )
            sessionStore.upsert(response.session)
            selectedPaths.removeAll()
            isSelecting = false
            launchError = nil
            navigateToSessionId = response.session.id
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func loadReview() async {
        guard !isLoading else { return }
        guard let api = connection.apiClient else {
            error = "Server is offline."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.getWorkspaceReviewFiles(
                workspaceId: workspaceId,
                sessionId: selectedSessionId
            )
            review = response
            error = nil
            if selectedSessionId == nil && filter == .selectedSession {
                filter = .all
            }
            selectedPaths.formIntersection(Set(response.files.map(\.path)))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct WorkspaceReviewFileRow: View {
    let file: WorkspaceReviewFile
    var showsSelectionMarker = false
    var isSelected = false

    private var fileIcon: FileIcon {
        FileIcon.forPath(file.path)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsSelectionMarker {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .themePurple : .themeComment)
                    .frame(width: 18)
            }

            Image(systemName: fileIcon.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fileIcon.color)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fileIcon.color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path.lastPathComponentForDisplay)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)

                        if let parentPath = file.path.parentPathForDisplay {
                            Text(parentPath)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        if let addedLines = file.addedLines, addedLines > 0 {
                            Text("+\(addedLines)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if let removedLines = file.removedLines, removedLines > 0 {
                            Text("-\(removedLines)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }

                HStack(spacing: 6) {
                    chip(text: file.statusLabel, color: statusColor)

                    if file.isStaged && !file.isUntracked {
                        chip(text: "Staged", color: .themeGreen)
                    }
                    if file.isUnstaged && !file.isUntracked {
                        chip(text: "Unstaged", color: .themeOrange)
                    }
                    if file.selectedSessionTouched {
                        chip(text: "Touched", color: .themePurple)
                    }
                }
            }
        }
        .padding(.vertical, 2)
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

    @ViewBuilder
    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}
