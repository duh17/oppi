import SwiftUI

enum SessionFileOpenMode: Equatable {
    case review
    case sessionTouched
}

enum SessionFileOpenRouting {
    static func mode(path _: String, gitFile: GitFileStatus?) -> SessionFileOpenMode {
        gitFile == nil ? .sessionTouched : .review
    }
}

/// Displays the list of files touched (written/edited) by a session.
///
/// Each row shows the file icon, filename, and parent path.
/// When `searchText` is non-empty, filters using `FuzzyMatch` and highlights
/// matched characters in filename and parent path.
///
/// Tapping a row navigates to the appropriate detail view:
/// - In-workspace files with git changes → diff + current view
/// - Other touched files → session raw content view, so ignored or symlinked paths remain openable
struct SessionFilesListView: View {
    let sessionId: String
    let workspaceId: String?
    let changedFiles: [String]
    var searchText: String = ""
    var fileDetailReviewCommentScope: ReviewCommentSelectionScope? = nil

    @Environment(GitStatusStore.self) private var gitStatusStore
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var loadedChangedFiles: [String]?
    @State private var collapsedDirectories: Set<String> = []

    /// Files from git status, keyed by path for fast lookup.
    private var gitFilesByPath: [String: GitFileStatus] {
        guard let files = gitStatusStore.gitStatus?.files else { return [:] }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    }

    private var currentChangedFiles: [String] {
        loadedChangedFiles ?? changedFiles
    }

    private var sessionChangesLoadKey: String {
        "\(workspaceId ?? "")|\(sessionId)"
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchActive: Bool {
        !normalizedSearchText.isEmpty
    }

    /// Filtered + sorted files. When searching, uses FuzzyMatch for scoring.
    private var displayFiles: [SessionFileDisplayItem] {
        let files = currentChangedFiles
        let query = normalizedSearchText
        if query.isEmpty {
            return files.map { SessionFileDisplayItem(path: $0, matchPositions: []) }
        }
        return FuzzyMatch.search(query: query, candidates: files, limit: 100)
            .map { SessionFileDisplayItem(path: $0.path, matchPositions: $0.positions) }
    }

    /// Directory groups for the files tab. Default ordering follows the path tree;
    /// search ordering keeps the highest-scored match's group first.
    private var displayDirectoryGroups: [SessionFileDirectoryGroup] {
        let files = displayFiles
        guard !files.isEmpty else { return [] }

        var filesByDirectory: [String: [SessionFileDisplayItem]] = [:]
        var firstVisibleIndexByDirectory: [String: Int] = [:]

        for (index, file) in files.enumerated() {
            let directory = Self.directoryKey(for: file.path)
            filesByDirectory[directory, default: []].append(file)
            firstVisibleIndexByDirectory[directory] = min(
                firstVisibleIndexByDirectory[directory] ?? index,
                index
            )
        }

        let directories = filesByDirectory.keys.sorted { lhs, rhs in
            if isSearchActive {
                let lhsIndex = firstVisibleIndexByDirectory[lhs] ?? Int.max
                let rhsIndex = firstVisibleIndexByDirectory[rhs] ?? Int.max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            }

            let pathOrder = lhs.localizedTreePathCompare(to: rhs)
            if pathOrder != .orderedSame {
                return pathOrder == .orderedAscending
            }
            return lhs < rhs
        }

        return directories.map { directory in
            SessionFileDirectoryGroup(
                directory: directory,
                title: Self.directoryTitle(for: directory),
                files: filesByDirectory[directory] ?? []
            )
        }
    }

    var body: some View {
        let groups = displayDirectoryGroups
        let orderedPaths = groups.flatMap { $0.files.map(\.path) }
        let reviewNavigationFiles = reviewNavigationFiles(for: orderedPaths)
        let sessionTouchedNavigationContext = navigationContext(for: orderedPaths.filter { path in
            SessionFileOpenRouting.mode(path: path, gitFile: gitFilesByPath[path]) == .sessionTouched
        })

        Group {
            if currentChangedFiles.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc.text",
                    description: Text("This session hasn't created or edited any files yet.")
                )
                .background(Color.themeBgDark)
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .background(Color.themeBgDark)
            } else {
                List {
                    ForEach(groups) { group in
                        let isCollapsed = isDirectoryCollapsed(group.directory)
                        Section {
                            if !isCollapsed {
                                ForEach(group.files) { file in
                                    fileRow(
                                        path: file.path,
                                        matchPositions: file.matchPositions,
                                        reviewNavigationFiles: reviewNavigationFiles,
                                        sessionTouchedNavigationContext: sessionTouchedNavigationContext
                                    )
                                    .listRowBackground(Color.themeBgDark)
                                    .listRowSeparatorTint(Color.themeComment.opacity(0.15))
                                }
                            }
                        } header: {
                            SessionFileDirectoryHeader(
                                title: group.title,
                                fileCount: group.files.count,
                                isCollapsed: isCollapsed,
                                isSearchActive: isSearchActive,
                                onToggle: isSearchActive ? nil : {
                                    withAnimation(ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion)) {
                                        toggleDirectoryCollapse(group.directory)
                                    }
                                }
                            )
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .tint(.themeComment)
                .background(Color.themeBgDark)
            }
        }
        .task(id: sessionChangesLoadKey) {
            await loadSessionChanges()
        }
    }

    // MARK: - Directory Groups

    private static func directoryKey(for path: String) -> String {
        path.parentPathForDisplay?.shortenedPath ?? ""
    }

    private static func directoryTitle(for directory: String) -> String {
        directory.isEmpty ? "Workspace root" : directory
    }

    private func isDirectoryCollapsed(_ directory: String) -> Bool {
        !isSearchActive && collapsedDirectories.contains(directory)
    }

    private func toggleDirectoryCollapse(_ directory: String) {
        if collapsedDirectories.contains(directory) {
            collapsedDirectories.remove(directory)
        } else {
            collapsedDirectories.insert(directory)
        }
    }

    private func reviewNavigationFiles(for paths: [String]) -> [WorkspaceReviewFile] {
        paths.compactMap { gitFilesByPath[$0]?.toReviewFile() }
    }

    private func navigationContext(for paths: [String]) -> FileBrowserNavigationContext {
        FileBrowserNavigationContext(files: paths.map { path in
            FileBrowserSelection(path: path, name: path.lastPathComponentForDisplay, size: nil)
        })
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(
        path: String,
        matchPositions: [Int] = [],
        reviewNavigationFiles: [WorkspaceReviewFile],
        sessionTouchedNavigationContext: FileBrowserNavigationContext
    ) -> some View {
        let icon = FileIcon.forPath(path)
        let fileName = path.lastPathComponentForDisplay
        let parentPath = path.parentPathForDisplay
        let gitFile = gitFilesByPath[path]
        let (filePositions, parentPositions) = Self.splitPositions(matchPositions, in: path)

        Group {
            if let workspaceId, let gitFile,
               SessionFileOpenRouting.mode(path: path, gitFile: gitFile) == .review
            {
                // Git-changed file → push to diff/review detail (needs tabs + actions)
                NavigationLink {
                    WorkspaceReviewFileDetailView(
                        workspaceId: workspaceId,
                        selectedSessionId: sessionId,
                        file: gitFile.toReviewFile(),
                        reviewCommentSelectionScopeOverride: makeFileDetailReviewCommentScope(),
                        navigationFiles: reviewNavigationFiles
                    )
                } label: {
                    fileRowContent(
                        icon: icon, fileName: fileName, parentPath: parentPath,
                        gitFile: gitFile,
                        filePositions: filePositions, parentPositions: parentPositions
                    )
                }
            } else if let workspaceId {
                NavigationLink {
                    SessionTouchedFileContentView(
                        workspaceId: workspaceId,
                        sessionId: sessionId,
                        filePath: path,
                        fileName: path.lastPathComponentForDisplay,
                        navigationContext: sessionTouchedNavigationContext
                    )
                    .environment(\.reviewCommentSelectionScope, makeFileDetailReviewCommentScope())
                } label: {
                    fileRowContent(
                        icon: icon, fileName: fileName, parentPath: parentPath,
                        gitFile: gitFile,
                        filePositions: filePositions, parentPositions: parentPositions
                    )
                }
            } else {
                // No workspace context — best effort plain display
                fileRowContent(
                    icon: icon, fileName: fileName, parentPath: parentPath,
                    gitFile: gitFile,
                    filePositions: filePositions, parentPositions: parentPositions
                )
            }
        }
    }

    @MainActor
    private func makeFileDetailReviewCommentScope() -> ReviewCommentSelectionScope? {
        guard case .activeSession(let router) = fileDetailReviewCommentScope else {
            return fileDetailReviewCommentScope
        }
        return .activeSession(router.retargetingDispatch { request in
            dismiss()
            router.dispatch(request)
        })
    }

    @MainActor
    private func loadSessionChanges() async {
        guard let workspaceId, let apiClient else {
            loadedChangedFiles = nil
            return
        }

        do {
            let response = try await apiClient.listSessionChanges(
                workspaceId: workspaceId,
                sessionId: sessionId
            )
            guard !Task.isCancelled else { return }
            loadedChangedFiles = response.files.map(\.path)
        } catch {
            // Keep the live session snapshot as the fallback list.
            guard !Task.isCancelled else { return }
            loadedChangedFiles = nil
        }
    }

    @ViewBuilder
    private func fileRowContent(
        icon: FileIcon,
        fileName: String,
        parentPath: String?,
        gitFile: GitFileStatus?,
        filePositions: [Int],
        parentPositions: [Int]
    ) -> some View {
            HStack(spacing: 10) {
                // File icon
                icon.iconView(size: 18, font: .subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(icon.color.opacity(0.1))
                    )

                // File name + parent path
                VStack(alignment: .leading, spacing: 2) {
                    if filePositions.isEmpty {
                        Text(fileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                    } else {
                        Text(Self.highlighted(
                            fileName,
                            positions: filePositions,
                            baseColor: .themeFg,
                            baseFont: .subheadline.weight(.medium)
                        ))
                        .lineLimit(1)
                    }

                    if let parentPath {
                        let display = parentPath.shortenedPath
                        if parentPositions.isEmpty {
                            Text(display)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(Self.highlighted(
                                display,
                                positions: parentPositions,
                                baseColor: .themeComment,
                                baseFont: .caption2
                            ))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Git status indicator (if tracked and changed)
                if let gitFile {
                    HStack(spacing: 4) {
                        if let added = gitFile.addedLines, added > 0 {
                            Text("+\(added)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if let removed = gitFile.removedLines, removed > 0 {
                            Text("-\(removed)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
    }

    // MARK: - Fuzzy Match Helpers

    /// Split full-path match positions into filename and parent portions.
    /// Positions are unicode scalar indices into the original path.
    private static func splitPositions(
        _ positions: [Int], in path: String
    ) -> (filename: [Int], parent: [Int]) {
        guard !positions.isEmpty else { return ([], []) }
        let scalars = Array(path.unicodeScalars)
        // Find the last '/' to determine the boundary
        var lastSlash = -1
        for (i, s) in scalars.enumerated() where s == "/" {
            lastSlash = i
        }
        guard lastSlash >= 0 else {
            // No directory separator — all positions belong to filename
            return (positions, [])
        }
        let filenameStart = lastSlash + 1
        var filenamePositions: [Int] = []
        var parentPositions: [Int] = []
        for pos in positions {
            if pos >= filenameStart {
                filenamePositions.append(pos - filenameStart)
            } else if pos < lastSlash {
                parentPositions.append(pos)
            }
            // pos == lastSlash (the '/' itself) is dropped — not shown in either part
        }
        return (filenamePositions, parentPositions)
    }

    /// Build an AttributedString with matched positions highlighted in yellow.
    private static func highlighted(
        _ text: String,
        positions: [Int],
        baseColor: Color,
        baseFont: Font
    ) -> AttributedString {
        let scalars = Array(text.unicodeScalars)
        let matchSet = Set(positions)
        var result = AttributedString()

        var i = 0
        while i < scalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < scalars.count, matchSet.contains(end + 1) { end += 1 }
                var seg = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                seg.foregroundColor = .themeYellow
                seg.font = baseFont.bold()
                result.append(seg)
                i = end + 1
            } else {
                var end = i
                while end + 1 < scalars.count, !matchSet.contains(end + 1) { end += 1 }
                var seg = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                seg.foregroundColor = baseColor
                seg.font = baseFont
                result.append(seg)
                i = end + 1
            }
        }
        return result
    }
}

private struct SessionFileDisplayItem: Identifiable, Equatable {
    let path: String
    let matchPositions: [Int]

    var id: String { path }
}

private struct SessionFileDirectoryGroup: Identifiable, Equatable {
    let directory: String
    let title: String
    let files: [SessionFileDisplayItem]

    var id: String { directory }
}

private struct SessionFileDirectoryHeader: View {
    let title: String
    let fileCount: Int
    let isCollapsed: Bool
    let isSearchActive: Bool
    let onToggle: (() -> Void)?

    var body: some View {
        if let onToggle {
            Button(action: onToggle) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(title) files" : "Collapse \(title) files")
            .accessibilityValue(accessibilityValue)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(fileCountText)")
        }
    }

    private var content: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeBlue)
                .accessibilityHidden(true)

            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("\(fileCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
                .accessibilityHidden(true)

            if !isSearchActive {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .textCase(nil)
    }

    private var fileCountText: String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }

    private var accessibilityValue: String {
        "\(isCollapsed ? "Collapsed" : "Expanded"), \(fileCountText)"
    }
}
