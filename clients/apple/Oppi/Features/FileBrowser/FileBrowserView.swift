import SwiftUI

/// Workspace file browser — entry point view.
///
/// Shows directory contents with navigation into subdirectories,
/// search, and tap-to-view for text/code files.
///
/// Search uses a shared file index cached in `FileIndexStore`.
/// All filtering happens locally on-device for instant feedback.
struct FileBrowserView: View {
    let workspaceId: String
    let initialPath: String

    @Environment(\.apiClient) private var apiClient
    @Environment(FileIndexStore.self) private var fileIndexStore
    @State private var listing: DirectoryListingResponse?
    @State private var isLoadingMore = false
    @State private var error: String?
    @State private var searchText = ""
    @State private var fuzzyResults: [FuzzyMatch.ScoredPath] = []

    private static let pageSize = 100

    private var isRoot: Bool {
        initialPath.isEmpty || initialPath == "/"
    }

    private var fileIndex: [String]? {
        fileIndexStore.paths
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
        .searchable(text: $searchText, prompt: "Search")
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
        .task { await loadDirectory() }
        .task { ensureFileIndex() }
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
                ForEach(response.entries) { entry in
                    fileEntryRow(entry, relativeTo: initialPath)
                }
                if response.hasMore {
                    HStack {
                        if isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        } else {
                            Text("\(response.entries.count) of \(response.total) items")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .task { await loadMore() }
                }
                if response.truncated {
                    Text("Directory listing capped at \(response.total) entries")
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
                ForEach(fuzzyResults, id: \.path) { result in
                    NavigationLink {
                        let fileName = result.path.split(separator: "/").last.map(String.init) ?? result.path
                        FileBrowserContentView(
                            workspaceId: workspaceId,
                            filePath: result.path,
                            fileName: fileName
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                HighlightedPathText(
                                    path: result.path,
                                    matchPositions: result.positions
                                )
                                .lineLimit(1)
                            }
                        } icon: {
                            let icon = FileIcon.forPath(result.path)
                            Image(systemName: icon.symbolName)
                                .foregroundStyle(icon.color)
                        }
                    }
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
            NavigationLink {
                let dirPath = if let path = entry.path {
                    path.hasSuffix("/") ? path : "\(path)/"
                } else {
                    parentPath.isEmpty ? "\(entry.name)/" : "\(parentPath)\(entry.name)/"
                }
                Self(workspaceId: workspaceId, initialPath: dirPath)
            } label: {
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
                FileBrowserContentView(workspaceId: workspaceId, filePath: filePath, fileName: entry.name)
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
            listing = try await api.listWorkspaceDirectory(
                workspaceId: workspaceId,
                path: initialPath,
                offset: 0,
                limit: Self.pageSize
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let api = apiClient, let current = listing, current.hasMore else { return }
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.listWorkspaceDirectory(
                workspaceId: workspaceId,
                path: initialPath,
                offset: current.entries.count,
                limit: Self.pageSize
            )
            listing = DirectoryListingResponse(
                path: current.path,
                entries: current.entries + next.entries,
                total: next.total,
                truncated: next.truncated
            )
        } catch {
            // Silently fail — the user can scroll again to retry
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

// MARK: - Highlighted Path Text

/// Renders a file path with matched characters highlighted using AttributedString.
private struct HighlightedPathText: View {
    let path: String
    let matchPositions: [Int]

    var body: some View {
        Text(attributedPath)
    }

    private var attributedPath: AttributedString {
        let scalars = Array(path.unicodeScalars)
        let matchSet = Set(matchPositions)
        var result = AttributedString()

        var i = 0
        while i < scalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < scalars.count, matchSet.contains(end + 1) {
                    end += 1
                }
                var segment = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                segment.foregroundColor = .themeYellow
                segment.font = .body.monospaced().bold()
                result.append(segment)
                i = end + 1
            } else {
                var end = i
                while end + 1 < scalars.count, !matchSet.contains(end + 1) {
                    end += 1
                }
                var segment = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                segment.foregroundColor = .themeFgDim
                segment.font = .body.monospaced()
                result.append(segment)
                i = end + 1
            }
        }

        return result
    }
}
