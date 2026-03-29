import SwiftUI

// MARK: - Navigation Target

/// Value-based navigation target for the file browser.
///
/// Pushed onto the workspace's `NavigationPath` so each directory level
/// is a real stack entry — preserving swipe-back between directories.
/// The breadcrumb bar uses `NavigationPath.removeLast(_:)` to jump
/// to any ancestor without intermediate pop animations.
struct FileBrowserNavTarget: Hashable {
    let workspaceId: String
    let path: String

    /// Number of directory levels deep from the file browser root.
    /// Root ("" or "/") is depth 0, "src/" is 1, "src/components/" is 2, etc.
    var depth: Int {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed.isEmpty { return 0 }
        return trimmed.split(separator: "/").count
    }

    /// Path segments for breadcrumb display.
    /// Returns [(label, depth)] pairs where depth 0 = root.
    var breadcrumbSegments: [(label: String, depth: Int)] {
        var segments: [(String, Int)] = [("Files", 0)]
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/")
        for (i, part) in parts.enumerated() {
            segments.append((String(part), i + 1))
        }
        return segments
    }
}

/// Workspace file browser — entry point view.
///
/// Shows directory contents with navigation into subdirectories,
/// search, and tap-to-view for text/code files.
///
/// Each directory level is a value-based push on the workspace
/// NavigationPath, preserving swipe-back. A breadcrumb bar shows
/// the full path and supports jumping to any ancestor directory.
///
/// Search uses a shared file index cached in `FileIndexStore`.
/// All filtering happens locally on-device for instant feedback.
struct FileBrowserView: View {
    let workspaceId: String
    let initialPath: String

    @Environment(\.apiClient) private var apiClient
    @Environment(AppNavigation.self) private var navigation
    @Environment(FileIndexStore.self) private var fileIndexStore
    @State private var listing: DirectoryListingResponse?
    @State private var error: String?
    @State private var searchText = ""
    @State private var fuzzyResults: [FuzzyMatch.ScoredPath] = []

    private var isRoot: Bool {
        initialPath.isEmpty || initialPath == "/"
    }

    private var fileIndex: [String]? {
        fileIndexStore.paths
    }

    /// Current depth for breadcrumb pop calculations.
    private var currentDepth: Int {
        FileBrowserNavTarget(workspaceId: workspaceId, path: initialPath).depth
    }

    /// Breadcrumb segments for the current path.
    private var breadcrumbSegments: [(label: String, depth: Int)] {
        FileBrowserNavTarget(workspaceId: workspaceId, path: initialPath).breadcrumbSegments
    }

    var body: some View {
        Group {
            if !searchText.isEmpty {
                searchResultsView
            } else if let listing {
                directoryListView(listing)
            } else if let error {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle(isRoot ? "Files" : lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search files")
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                fuzzyResults = []
                return
            }
            performLocalSearch(query: trimmed)
        }
        .onChange(of: fileIndex) { _, _ in
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            performLocalSearch(query: trimmed)
        }
        .refreshable {
            await loadDirectory()
            if let api = apiClient {
                fileIndexStore.invalidate()
                fileIndexStore.ensureLoaded(workspaceId: workspaceId, apiClient: api)
            }
        }
        .task { await loadDirectory() }
        .task { ensureFileIndex() }
    }

    private var searchResultCountText: String {
        let count = fuzzyResults.count
        if count >= 100 {
            return "100+ files"
        }
        return "\(count) file\(count == 1 ? "" : "s")"
    }

    // MARK: - Directory List

    @ViewBuilder
    private func directoryListView(_ response: DirectoryListingResponse) -> some View {
        if response.entries.isEmpty {
            ContentUnavailableView(
                "Empty Directory",
                systemImage: "folder",
                description: Text("No files in this directory.")
            )
        } else {
            List {
                // Breadcrumb bar (only when not at root)
                if !isRoot {
                    Section {
                        FileBrowserBreadcrumb(
                            segments: breadcrumbSegments,
                            currentDepth: currentDepth,
                            onNavigate: { targetDepth in
                                let popCount = currentDepth - targetDepth
                                guard popCount > 0, navigation.workspacePath.count >= popCount else { return }
                                navigation.workspacePath.removeLast(popCount)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }

                ForEach(response.entries) { entry in
                    fileEntryRow(entry, relativeTo: initialPath)
                }
                if response.truncated {
                    Text("Showing first \(response.entries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsView: some View {
        if fileIndexStore.isLoading, fileIndex == nil {
            ProgressView("Loading file index...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if fuzzyResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                Section {
                    ForEach(fuzzyResults, id: \.path) { result in
                        let fileName = (result.path as NSString).lastPathComponent
                        let dirPath = {
                            let dir = (result.path as NSString).deletingLastPathComponent
                            return dir.isEmpty ? "" : dir + "/"
                        }()
                        NavigationLink {
                            FileBrowserContentView(
                                workspaceId: workspaceId,
                                filePath: result.path,
                                fileName: fileName
                            )
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    SearchResultFileName(
                                        fileName: fileName,
                                        fullPath: result.path,
                                        matchPositions: result.positions
                                    )
                                    if !dirPath.isEmpty {
                                        Text(dirPath)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.themeComment)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            } icon: {
                                let icon = FileIcon.forPath(result.path)
                                Image(systemName: icon.symbolName)
                                    .foregroundStyle(icon.color)
                            }
                        }
                    }
                } header: {
                    Text(searchResultCountText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.themeComment)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func fileEntryRow(
        _ entry: FileEntry,
        showFullPath: Bool = false,
        relativeTo parentPath: String
    ) -> some View {
        if entry.isDirectory {
            NavigationLink(value: {
                let dirPath = if let path = entry.path {
                    path.hasSuffix("/") ? path : "\(path)/"
                } else {
                    parentPath.isEmpty ? "\(entry.name)/" : "\(parentPath)\(entry.name)/"
                }
                return FileBrowserNavTarget(workspaceId: workspaceId, path: dirPath)
            }()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showFullPath ? (entry.path ?? entry.name) : entry.name)
                            .font(.body)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.themeBlue)
                }
            }
        } else {
            NavigationLink {
                let filePath = entry.path ?? (parentPath.isEmpty ? entry.name : "\(parentPath)\(entry.name)")
                FileBrowserContentView(
                    workspaceId: workspaceId,
                    filePath: filePath,
                    fileName: entry.name,
                    fileSize: entry.size
                )
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showFullPath ? (entry.path ?? entry.name) : entry.name)
                            .font(.body)
                            .lineLimit(1)
                        Text(entry.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                } icon: {
                    let icon = FileIcon.forPath(entry.name)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(icon.color)
                }
            }
        }
    }

    // MARK: - Helpers

    private var lastPathComponent: String {
        let trimmed = initialPath.hasSuffix("/") ? String(initialPath.dropLast()) : initialPath
        return trimmed.split(separator: "/").last.map(String.init) ?? "Files"
    }

    private func loadDirectory() async {
        guard let api = apiClient else {
            self.error = "Not connected"
            return
        }
        do {
            listing = try await api.listWorkspaceDirectory(workspaceId: workspaceId, path: initialPath)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ensureFileIndex() {
        guard let api = apiClient else { return }
        fileIndexStore.ensureLoaded(workspaceId: workspaceId, apiClient: api)
    }

    private func performLocalSearch(query: String) {
        guard let index = fileIndex else { return }

        let candidates = index
        Task.detached {
            let results = FuzzyMatch.search(query: query, candidates: candidates, limit: 100)
            await MainActor.run {
                let currentTrimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if currentTrimmed == query {
                    fuzzyResults = results
                }
            }
        }
    }
}

// MARK: - Breadcrumb Bar

/// Horizontal scrollable breadcrumb showing the directory path.
///
/// Each segment is tappable to navigate to that directory level.
/// Auto-scrolls to keep the current (rightmost) segment visible.
private struct FileBrowserBreadcrumb: View {
    let segments: [(label: String, depth: Int)]
    let currentDepth: Int
    let onNavigate: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.themeComment.opacity(0.5))
                        }
                        Button {
                            if segment.depth < currentDepth {
                                onNavigate(segment.depth)
                            }
                        } label: {
                            Text(segment.label)
                                .font(.caption.weight(segment.depth == currentDepth ? .semibold : .medium))
                                .foregroundStyle(segment.depth == currentDepth ? Color.accentColor : .themeComment)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                proxy.scrollTo(segments.count - 1, anchor: .trailing)
            }
        }
    }
}

// MARK: - Search Result File Name

/// Renders the filename with matched characters highlighted.
///
/// Match positions from FuzzyMatch refer to the full path. This view
/// translates them into filename-relative offsets so only the filename
/// portion is displayed, with highlights applied to characters that
/// were part of the fuzzy match.
private struct SearchResultFileName: View {
    let fileName: String
    let fullPath: String
    let matchPositions: [Int]

    var body: some View {
        Text(attributedFileName)
            .lineLimit(1)
    }

    private var attributedFileName: AttributedString {
        let fileNameScalars = Array(fileName.unicodeScalars)
        let pathScalars = Array(fullPath.unicodeScalars)
        let fileNameStart = pathScalars.count - fileNameScalars.count

        // Translate full-path match positions to filename-relative positions
        let matchSet = Set(
            matchPositions
                .filter { $0 >= fileNameStart }
                .map { $0 - fileNameStart }
        )

        var result = AttributedString()
        var i = 0
        while i < fileNameScalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < fileNameScalars.count, matchSet.contains(end + 1) {
                    end += 1
                }
                var segment = AttributedString(String(String.UnicodeScalarView(fileNameScalars[i...end])))
                segment.foregroundColor = .themeYellow
                segment.font = .body.bold()
                result.append(segment)
                i = end + 1
            } else {
                var end = i
                while end + 1 < fileNameScalars.count, !matchSet.contains(end + 1) {
                    end += 1
                }
                var segment = AttributedString(String(String.UnicodeScalarView(fileNameScalars[i...end])))
                segment.foregroundColor = .themeFg
                segment.font = .body
                result.append(segment)
                i = end + 1
            }
        }

        return result
    }
}
