import SwiftUI

/// Workspace file browser — entry point view.
///
/// Shows directory contents with navigation into subdirectories,
/// search, and tap-to-view for text/code files.
struct FileBrowserView: View {
    let workspaceId: String
    let initialPath: String

    @Environment(\.apiClient) private var apiClient
    @State private var listing: DirectoryListingResponse?
    @State private var error: String?
    @State private var searchText = ""
    @State private var searchResults: FileSearchResponse?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private var displayPath: String {
        let path = listing?.path ?? initialPath
        if path.isEmpty || path == "/" { return "/" }
        return "/\(path)"
    }

    private var isRoot: Bool {
        initialPath.isEmpty || initialPath == "/"
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
        .searchable(text: $searchText, prompt: "Search files")
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults = nil
                isSearching = false
                return
            }
            isSearching = true
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await performSearch(query: newValue)
            }
        }
        .task { await loadDirectory() }
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
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsView: some View {
        if isSearching, searchResults == nil {
            ProgressView("Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let results = searchResults {
            if results.entries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(results.entries) { entry in
                        fileEntryRow(entry, showFullPath: true, relativeTo: "")
                    }
                    if results.truncated {
                        Text("Showing first \(results.entries.count) results")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
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
                FileBrowserView(workspaceId: workspaceId, initialPath: dirPath)
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
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: fileIconName(for: entry.name))
                        .foregroundStyle(.secondary)
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

    private func performSearch(query: String) async {
        guard let api = apiClient else { return }
        do {
            let results = try await api.searchWorkspaceFiles(workspaceId: workspaceId, query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = FileSearchResponse(query: query, entries: [], truncated: false)
            isSearching = false
        }
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
