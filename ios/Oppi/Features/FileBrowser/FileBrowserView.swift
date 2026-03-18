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
    @Environment(ServerConnection.self) private var connection
    @State private var listing: DirectoryListingResponse?
    @State private var error: String?
    @State private var searchText = ""
    @State private var fuzzyResults: [FuzzyMatch.ScoredPath] = []

    private var isRoot: Bool {
        initialPath.isEmpty || initialPath == "/"
    }

    private var fileIndex: [String]? {
        connection.fileIndexStore.paths
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
        if connection.fileIndexStore.isLoading, fileIndex == nil {
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
                            let fileName = result.path.split(separator: "/").last.map(String.init) ?? result.path
                            Image(systemName: fileIconName(for: fileName))
                                .foregroundStyle(.themeFgDim)
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
                    Image(systemName: fileIconName(for: entry.name))
                        .foregroundStyle(.themeFgDim)
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
        connection.fileIndexStore.ensureLoaded(workspaceId: workspaceId, apiClient: api)
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

// MARK: - File icon mapping

private func fileIconName(for filename: String) -> String {
    let ext = filename.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
    switch ext {
    case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt", "c", "cpp", "h", "rb", "php", "lua":
        return "chevron.left.forwardslash.chevron.right"
    case "json", "yml", "yaml", "toml", "xml", "plist":
        return "doc.text"
    case "md", "markdown", "txt", "rst":
        return "doc.plaintext"
    case "html", "htm", "css", "scss":
        return "globe"
    case "png", "jpg", "jpeg", "gif", "webp", "svg":
        return "photo"
    case "pdf":
        return "doc.richtext"
    case "sh", "bash", "zsh":
        return "terminal"
    case "lock":
        return "lock"
    case "gitignore", "gitattributes":
        return "arrow.triangle.branch"
    default:
        return "doc"
    }
}
