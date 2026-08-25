import SwiftUI

// MARK: - Navigation Target

/// Value-based navigation target for the file browser.
///
/// Pushed onto the workspace's `NavigationPath` so each directory level
/// is a real stack entry — preserving swipe-back between directories.
/// The breadcrumb bar uses `NavigationPath.removeLast(_:)` to jump
/// to any ancestor without intermediate pop animations.
struct FileBrowserNavTarget: Hashable {
    let serverId: String
    let workspaceId: String
    let worktreeId: String?
    let path: String

    init(serverId: String, workspaceId: String, worktreeId: String? = nil, path: String) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.worktreeId = worktreeId
        self.path = path
    }

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

struct FileBrowserSelection: Hashable, Identifiable, Sendable {
    let path: String
    let name: String
    let size: Int?

    var id: String { path }
}

struct FileBrowserNavigationContext: Hashable, Sendable {
    let files: [FileBrowserSelection]

    init(files: [FileBrowserSelection]) {
        var seen: Set<String> = []
        self.files = files.filter { file in
            let normalizedPath = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPath.isEmpty else { return false }
            return seen.insert(normalizedPath).inserted
        }
    }

    func selection(adjacentTo currentPath: String, direction: FileBrowserNavigationDirection) -> FileBrowserSelection? {
        guard let currentIndex = files.firstIndex(where: { $0.path == currentPath }) else { return nil }
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = currentIndex - 1
        case .next:
            targetIndex = currentIndex + 1
        }
        guard files.indices.contains(targetIndex) else { return nil }
        return files[targetIndex]
    }
}

enum FileBrowserNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

enum FileBrowserPushTransitionEdge: Equatable, Sendable {
    case leading
    case trailing

    var edge: Edge {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

struct FileBrowserPushTransitionSpec: Equatable, Sendable {
    let insertion: FileBrowserPushTransitionEdge
    let removal: FileBrowserPushTransitionEdge

    static func spec(for direction: FileBrowserNavigationDirection) -> FileBrowserPushTransitionSpec {
        switch direction {
        case .previous:
            return .init(insertion: .leading, removal: .trailing)
        case .next:
            return .init(insertion: .trailing, removal: .leading)
        }
    }
}

struct FileBrowserTreeNavigationMutation: Equatable {
    let treeDirectoryPath: String
    let selectedFile: FileBrowserSelection?
}

enum FileBrowserTreeNavigationReducer {
    static func openDirectory(path: String, selectedFile: FileBrowserSelection?) -> FileBrowserTreeNavigationMutation {
        FileBrowserTreeNavigationMutation(treeDirectoryPath: path, selectedFile: nil)
    }

    static func popToBreadcrumb(path: String, selectedFile: FileBrowserSelection?) -> FileBrowserTreeNavigationMutation {
        FileBrowserTreeNavigationMutation(treeDirectoryPath: path, selectedFile: nil)
    }

    /// Workspace-linked file destinations are registered only on the workspace stack.
    /// Compact chat/tree-pane browsers must fall back to an in-sheet NavigationLink.
    static func shouldUseWorkspaceLinkedFileDestination(
        usesInlineCompactNavigation: Bool,
        serverId: String?
    ) -> Bool {
        guard !usesInlineCompactNavigation, let serverId, !serverId.isEmpty else {
            return false
        }
        return true
    }
}

enum FileBrowserLayoutMode: Equatable {
    case adaptive
    case compactOnly
}

private enum FileBrowserAdaptiveLayout: Equatable {
    case compact
    case landscapeTree
    case portraitOverlay
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
    let serverId: String?
    let workspaceId: String
    let worktreeId: String?
    let initialPath: String
    let layoutMode: FileBrowserLayoutMode
    let contentChromeMode: FileBrowserContentChromeMode

    init(
        serverId: String? = nil,
        workspaceId: String,
        worktreeId: String? = nil,
        initialPath: String,
        layoutMode: FileBrowserLayoutMode = .adaptive,
        contentChromeMode: FileBrowserContentChromeMode = .pushed
    ) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.worktreeId = worktreeId
        self.initialPath = initialPath
        self.layoutMode = layoutMode
        self.contentChromeMode = contentChromeMode
    }

    @Environment(\.apiClient) private var apiClient
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppNavigation.self) private var navigation
    @Environment(FileIndexStore.self) private var fileIndexStore
    @State private var listing: DirectoryListingResponse?
    @State private var error: String?
    @State private var searchText = ""
    @State private var fuzzyResults: [FuzzyMatch.ScoredPath] = []
    @State private var selectedFile: FileBrowserSelection?
    @State private var markdownViewportRestore = FullScreenMarkdownViewportRestoreState()
    @State private var isTreeOverlayVisible = true
    @State private var activeLayout: FileBrowserAdaptiveLayout = .compact
    @State private var treeDirectoryPath: String?

    private var currentDirectoryPath: String {
        treeDirectoryPath ?? initialPath
    }

    private var isRoot: Bool {
        currentDirectoryPath.isEmpty || currentDirectoryPath == "/"
    }

    private var usesInlineCompactDirectoryNavigation: Bool {
        layoutMode == .compactOnly && contentChromeMode == .treePane
    }

    private var shouldShowInlineDirectoryBackButton: Bool {
        usesInlineCompactDirectoryNavigation && !isRoot && selectedFile == nil
    }

    private var fileIndex: [String]? {
        fileIndexStore.paths
    }

    private var currentFileNavigationContext: FileBrowserNavigationContext? {
        if !searchText.isEmpty {
            return searchFileNavigationContext
        }
        guard let listing else { return nil }
        return fileNavigationContext(for: listing.entries, relativeTo: currentDirectoryPath)
    }

    private var searchFileNavigationContext: FileBrowserNavigationContext {
        FileBrowserNavigationContext(files: fuzzyResults.map { result in
            FileBrowserSelection(
                path: result.path,
                name: (result.path as NSString).lastPathComponent,
                size: nil
            )
        })
    }

    /// Current depth for breadcrumb pop calculations.
    private var currentDepth: Int {
        FileBrowserNavTarget(serverId: serverId ?? "", workspaceId: workspaceId, worktreeId: worktreeId, path: currentDirectoryPath).depth
    }

    /// Breadcrumb segments for the current path.
    private var breadcrumbSegments: [(label: String, depth: Int)] {
        FileBrowserNavTarget(serverId: serverId ?? "", workspaceId: workspaceId, worktreeId: worktreeId, path: currentDirectoryPath).breadcrumbSegments
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = adaptiveLayout(for: proxy.size)
            adaptiveContent(layout: layout, size: proxy.size)
                .onAppear {
                    activeLayout = layout
                    if layout == .portraitOverlay, selectedFile == nil {
                        isTreeOverlayVisible = true
                    }
                }
                .onChange(of: layout) { _, newValue in
                    activeLayout = newValue
                    if newValue == .compact {
                        treeDirectoryPath = nil
                    }
                    if newValue == .portraitOverlay, selectedFile == nil {
                        isTreeOverlayVisible = true
                    }
                }
        }
        .fileBrowserSearchable(isEnabled: activeLayout == .compact, text: $searchText)
        .navigationTitle(isRoot ? "Files" : lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if shouldShowInlineDirectoryBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: navigateToInlineParentDirectory) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("fileBrowser.inlineBack")
                }
            }
        }
        .onChange(of: initialPath) { _, _ in
            treeDirectoryPath = nil
            selectedFile = nil
        }
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
            await loadDirectory(path: currentDirectoryPath)
            if let api = apiClient {
                fileIndexStore.invalidate()
                fileIndexStore.ensureLoaded(workspaceId: workspaceId, worktreeId: worktreeId, apiClient: api)
            }
        }
        .task(id: "\(worktreeId ?? ""):\(currentDirectoryPath)") { await loadDirectory(path: currentDirectoryPath) }
        .task { ensureFileIndex() }
    }

    @ViewBuilder
    private func adaptiveContent(layout: FileBrowserAdaptiveLayout, size: CGSize) -> some View {
        switch layout {
        case .compact:
            compactBrowserContent
        case .landscapeTree:
            landscapeTreeContent(size: size)
        case .portraitOverlay:
            portraitOverlayContent(size: size)
        }
    }

    private func adaptiveLayout(for size: CGSize) -> FileBrowserAdaptiveLayout {
        guard layoutMode == .adaptive else { return .compact }
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .compact }
        guard horizontalSizeClass == .regular else { return .compact }
        return size.width >= size.height ? .landscapeTree : .portraitOverlay
    }

    @ViewBuilder
    private var compactBrowserContent: some View {
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
    }

    private func landscapeTreeContent(size: CGSize) -> some View {
        HStack(spacing: 0) {
            fileTreeRail(showCloseButton: false)
                .frame(width: min(max(size.width * 0.30, 320), 430))
                .padding(.leading, 16)
                .padding(.vertical, 16)

            Divider()
                .overlay(.themeComment.opacity(0.18))
                .padding(.vertical, 20)

            selectedFileContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.themeBg)
    }

    private func portraitOverlayContent(size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            selectedFileContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isTreeOverlayVisible, selectedFile != nil {
                fileTreeRevealButton
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if isTreeOverlayVisible || selectedFile == nil {
                fileTreeRail(showCloseButton: selectedFile != nil)
                    .frame(width: min(size.width * 0.82, 390))
                    .padding(.leading, 12)
                    .padding(.vertical, 14)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .background(.themeBg)
        .animation(.easeInOut(duration: 0.18), value: isTreeOverlayVisible)
    }

    @ViewBuilder
    private var selectedFileContent: some View {
        if let activeSelection = selectedFile {
            treePaneSelectedFileContent(
                for: activeSelection,
                store: $markdownViewportRestore
            )
        } else {
            ContentUnavailableView {
                Label("Select a File", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Choose a file from the tree.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.themeBg)
        }
    }

    private var searchResultCountText: String {
        let count = fuzzyResults.count
        if count >= 100 {
            return "100+ files"
        }
        return "\(count) file\(count == 1 ? "" : "s")"
    }

    private func fileTreeRail(showCloseButton: Bool) -> some View {
        VStack(spacing: 12) {
            fileTreeHeader(showCloseButton: showCloseButton)
            fileTreeSearchField
            fileTreeBody
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .fileTreeGlassPanel(cornerRadius: 28)
        .accessibilityIdentifier("fileBrowser.tree")
    }

    private func fileTreeHeader(showCloseButton: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.themeBlue)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Files")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text(isRoot ? "Workspace root" : currentDirectoryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if showCloseButton {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isTreeOverlayVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFg)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Hide file tree")
            }
        }
    }

    private var fileTreeRevealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTreeOverlayVisible = true
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.themeFg)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .fileTreeGlassPanel(cornerRadius: 21)
        .accessibilityLabel("Show file tree")
        .accessibilityIdentifier("fileBrowser.tree.reveal")
    }

    private var fileTreeSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.themeComment)

            TextField("Search files", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .foregroundStyle(.themeFg)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.themeComment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear file search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .fileTreeGlassPanel(cornerRadius: 16)
    }

    @ViewBuilder
    private var fileTreeBody: some View {
        if !searchText.isEmpty {
            fileTreeSearchResults
        } else if let listing {
            fileTreeDirectory(listing)
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

    @ViewBuilder
    private var fileTreeSearchResults: some View {
        if fileIndexStore.isLoading, fileIndex == nil {
            ProgressView("Loading file index...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if fuzzyResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(searchResultCountText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.themeComment)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)

                    ForEach(fuzzyResults, id: \.path) { result in
                        let fileName = (result.path as NSString).lastPathComponent
                        let dirPath = {
                            let dir = (result.path as NSString).deletingLastPathComponent
                            return dir.isEmpty ? "" : dir + "/"
                        }()
                        fileTreeFileButton(
                            name: fileName,
                            path: result.path,
                            subtitle: dirPath.isEmpty ? nil : dirPath,
                            size: nil,
                            modifiedText: nil,
                            navigationContext: searchFileNavigationContext
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func fileTreeDirectory(_ response: DirectoryListingResponse) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !isRoot {
                    FileBrowserBreadcrumb(
                        segments: breadcrumbSegments,
                        currentDepth: currentDepth,
                        onNavigate: { targetDepth in
                            popToBreadcrumbDepth(targetDepth)
                        }
                    )
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }

                if response.entries.isEmpty {
                    ContentUnavailableView(
                        "Empty Directory",
                        systemImage: "folder",
                        description: Text("No files in this directory.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    let navigationContext = fileNavigationContext(for: response.entries, relativeTo: currentDirectoryPath)
                    ForEach(response.entries) { entry in
                        fileTreeEntryButton(entry, relativeTo: currentDirectoryPath, navigationContext: navigationContext)
                    }
                }

                if response.truncated {
                    Text("Showing first \(response.entries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func fileTreeEntryButton(
        _ entry: FileEntry,
        relativeTo parentPath: String,
        navigationContext: FileBrowserNavigationContext
    ) -> some View {
        if entry.isDirectory {
            let dirPath = directoryPath(for: entry, relativeTo: parentPath)
            Button {
                openDirectory(path: dirPath)
            } label: {
                fileTreeRow(
                    icon: "folder.fill",
                    iconColor: .themeBlue,
                    title: entry.name,
                    subtitle: nil,
                    trailing: "chevron.right",
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
        } else {
            let path = filePath(for: entry, relativeTo: parentPath)
            fileTreeFileButton(
                name: entry.name,
                path: path,
                subtitle: entry.formattedSize.isEmpty ? nil : entry.formattedSize,
                size: entry.size,
                modifiedText: entry.relativeModifiedTime,
                isRecentlyModified: entry.isRecentlyModified,
                navigationContext: navigationContext
            )
        }
    }

    private func fileTreeFileButton(
        name: String,
        path: String,
        subtitle: String?,
        size: Int?,
        modifiedText: String?,
        isRecentlyModified: Bool = false,
        navigationContext: FileBrowserNavigationContext
    ) -> some View {
        Button {
            selectFile(path: path, name: name, size: size)
        } label: {
            fileTreeRow(
                icon: FileIcon.forPath(name).symbolName,
                iconColor: .themeComment,
                title: name,
                subtitle: subtitle,
                trailingText: modifiedText,
                isSelected: selectedFile?.path == path,
                trailingColor: isRecentlyModified ? .themeGreen : .themeComment
            )
        }
        .buttonStyle(.plain)
    }

    private func fileTreeRow(
        icon: String,
        iconColor: ThemeShapeStyle,
        title: String,
        subtitle: String?,
        trailing: String? = nil,
        trailingText: String? = nil,
        isSelected: Bool,
        trailingColor: ThemeShapeStyle = .themeComment
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(isSelected ? .themeBlue : iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let trailingText {
                Text(trailingText)
                    .font(.caption2)
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
            }

            if let trailing {
                Image(systemName: trailing)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.themeComment.opacity(0.7))
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isSelected ? .themeBlue.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.themeBlue.opacity(0.36), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                                popToBreadcrumbDepth(targetDepth)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }

                ForEach(response.entries) { entry in
                    fileEntryRow(entry, relativeTo: currentDirectoryPath)
                }
                if response.truncated {
                    Text("Showing first \(response.entries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }
            .listStyle(.plain)
            .themedListSurface()
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
                        compactFileNavigationLink(
                            path: result.path,
                            name: fileName,
                            size: nil,
                            navigationContext: searchFileNavigationContext
                        ) {
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
                                FileIcon.forPath(result.path)
                                    .iconView(size: 20)
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
            .themedListSurface()
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
            let dirPath = directoryPath(for: entry, relativeTo: parentPath)
            let label = Label {
                Text(showFullPath ? (entry.path ?? entry.name) : entry.name)
                    .font(.body)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.themeBlue)
            }

            if usesInlineCompactDirectoryNavigation {
                Button {
                    openDirectory(path: dirPath)
                } label: {
                    compactListRowContent { label }
                }
                .buttonStyle(.plain)
            } else if let serverId {
                NavigationLink(value: FileBrowserNavTarget(serverId: serverId, workspaceId: workspaceId, worktreeId: worktreeId, path: dirPath)) {
                    compactListRowContent { label }
                }
            } else {
                NavigationLink {
                    FileBrowserView(
                        workspaceId: workspaceId,
                        worktreeId: worktreeId,
                        initialPath: dirPath,
                        layoutMode: layoutMode,
                        contentChromeMode: contentChromeMode
                    )
                } label: {
                    compactListRowContent { label }
                }
            }
        } else {
            let filePath = filePath(for: entry, relativeTo: parentPath)
            compactFileNavigationLink(
                path: filePath,
                name: entry.name,
                size: entry.size,
                navigationContext: currentFileNavigationContext
            ) {
                Label {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(showFullPath ? (entry.path ?? entry.name) : entry.name)
                                .font(.body)
                                .lineLimit(1)
                            Text(entry.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                        }
                        Spacer()
                        Text(entry.relativeModifiedTime)
                            .font(.caption2)
                            .foregroundStyle(entry.isRecentlyModified ? .themeGreen : .themeComment)
                    }
                } icon: {
                    FileIcon.forPath(entry.name)
                        .iconView(size: 20)
                }
            }
        }
    }

    @ViewBuilder
    private func compactFileNavigationLink<Label: View>(
        path: String,
        name: String,
        size: Int?,
        navigationContext: FileBrowserNavigationContext? = nil,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let target = linkedFileTarget(path: path, name: name, navigationContext: navigationContext) {
            NavigationLink(value: target) {
                compactListRowContent { label() }
            }
        } else {
            NavigationLink {
                compactNavigationFileContent(
                    path: path,
                    name: name,
                    size: size,
                    navigationContext: navigationContext,
                    store: $markdownViewportRestore
                )
            } label: {
                compactListRowContent { label() }
            }
        }
    }

    private func compactListRowContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func linkedFileTarget(
        path: String,
        name: String,
        navigationContext: FileBrowserNavigationContext?
    ) -> WorkspaceLinkedFileNavTarget? {
        guard FileBrowserTreeNavigationReducer.shouldUseWorkspaceLinkedFileDestination(
            usesInlineCompactNavigation: usesInlineCompactDirectoryNavigation,
            serverId: serverId
        ), let serverId else { return nil }
        return .workspaceFile(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            path: path,
            fileName: name,
            navigationContext: navigationContext
        )
    }

    // MARK: - Helpers

    private func treePaneSelectedFileContent(
        for selection: FileBrowserSelection,
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        FileBrowserContentView(
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            serverId: serverId,
            filePath: selection.path,
            fileName: selection.name,
            fileSize: selection.size,
            chromeMode: .treePane,
            navigationContext: currentFileNavigationContext,
            onNavigationSelectionChange: { selectedFile = $0 },
            onBackNavigation: clearSelectedFileForBackNavigation,
            markdownViewportRestore: FileBrowserContentView.restoreStore(
                for: .treePaneSelectedFile,
                store: store
            )
        )
    }

    private func compactNavigationFileContent(
        path: String,
        name: String,
        size: Int?,
        navigationContext: FileBrowserNavigationContext?,
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        FileBrowserContentView(
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            serverId: serverId,
            filePath: path,
            fileName: name,
            fileSize: size,
            chromeMode: contentChromeMode,
            navigationContext: navigationContext,
            markdownViewportRestore: FileBrowserContentView.restoreStore(
                for: .compactNavigationLink,
                store: store
            )
        )
    }

    private func selectFile(path: String, name: String, size: Int?) {
        selectedFile = FileBrowserSelection(path: path, name: name, size: size)
        if activeLayout == .portraitOverlay {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTreeOverlayVisible = false
            }
        }
    }

    private func clearSelectedFileForBackNavigation() {
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedFile = nil
            if activeLayout == .portraitOverlay {
                isTreeOverlayVisible = true
            }
        }
    }

    private func navigateToInlineParentDirectory() {
        guard shouldShowInlineDirectoryBackButton else { return }
        popToBreadcrumbDepth(max(0, currentDepth - 1))
    }

    private func openDirectory(path: String) {
        guard activeLayout == .compact && !usesInlineCompactDirectoryNavigation else {
            let mutation = FileBrowserTreeNavigationReducer.openDirectory(
                path: path,
                selectedFile: selectedFile
            )
            treeDirectoryPath = mutation.treeDirectoryPath
            selectedFile = mutation.selectedFile
            error = nil
            listing = nil
            return
        }

        selectedFile = nil
        guard let serverId else {
            let mutation = FileBrowserTreeNavigationReducer.openDirectory(
                path: path,
                selectedFile: selectedFile
            )
            treeDirectoryPath = mutation.treeDirectoryPath
            selectedFile = mutation.selectedFile
            error = nil
            listing = nil
            return
        }
        let target = FileBrowserNavTarget(serverId: serverId, workspaceId: workspaceId, worktreeId: worktreeId, path: path)
        switch navigation.workspaceNavigationPresentation {
        case .stack:
            navigation.pushWorkspaceFileBrowser(target)
        case .split:
            navigation.pushSplitDetailFileBrowser(target)
        }
    }

    private func directoryPath(for entry: FileEntry, relativeTo parentPath: String) -> String {
        if let path = entry.path {
            return path.hasSuffix("/") ? path : "\(path)/"
        }
        return parentPath.isEmpty ? "\(entry.name)/" : "\(parentPath)\(entry.name)/"
    }

    private func filePath(for entry: FileEntry, relativeTo parentPath: String) -> String {
        entry.path ?? (parentPath.isEmpty ? entry.name : "\(parentPath)\(entry.name)")
    }

    private func fileNavigationContext(for entries: [FileEntry], relativeTo parentPath: String) -> FileBrowserNavigationContext {
        FileBrowserNavigationContext(files: entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            return FileBrowserSelection(
                path: filePath(for: entry, relativeTo: parentPath),
                name: entry.name,
                size: entry.size
            )
        })
    }

    private func popToBreadcrumbDepth(_ targetDepth: Int) {
        let popCount = currentDepth - targetDepth
        guard popCount > 0 else { return }

        guard activeLayout == .compact && !usesInlineCompactDirectoryNavigation else {
            let mutation = FileBrowserTreeNavigationReducer.popToBreadcrumb(
                path: breadcrumbPath(for: targetDepth),
                selectedFile: selectedFile
            )
            treeDirectoryPath = mutation.treeDirectoryPath
            selectedFile = mutation.selectedFile
            error = nil
            listing = nil
            return
        }

        switch navigation.workspaceNavigationPresentation {
        case .stack:
            guard navigation.workspacePath.count >= popCount else { return }
            navigation.workspacePath.removeLast(popCount)
        case .split:
            guard navigation.splitDetailPath.count >= popCount else { return }
            navigation.removeLastSplitDetailPath(popCount)
        }
    }

    private func breadcrumbPath(for depth: Int) -> String {
        guard depth > 0 else { return "" }
        let trimmed = currentDirectoryPath.hasSuffix("/") ? String(currentDirectoryPath.dropLast()) : currentDirectoryPath
        let parts = trimmed.split(separator: "/").prefix(depth).map(String.init)
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "/") + "/"
    }

    private var lastPathComponent: String {
        let trimmed = currentDirectoryPath.hasSuffix("/") ? String(currentDirectoryPath.dropLast()) : currentDirectoryPath
        return trimmed.split(separator: "/").last.map(String.init) ?? "Files"
    }

    private func loadDirectory(path: String) async {
        guard let api = apiClient else {
            self.error = "Not connected"
            ClientLog.error("FileBrowser", "Directory load failed", metadata: [
                "workspaceId": workspaceId,
                "path": safeDebugPath(path),
                "reason": "missing_api_client",
                "layoutMode": String(describing: layoutMode),
                "contentChromeMode": String(describing: contentChromeMode),
            ])
            return
        }
        do {
            let response = try await api.listWorkspaceDirectory(workspaceId: workspaceId, path: path, worktreeId: worktreeId)
            guard path == currentDirectoryPath else { return }
            listing = response
            error = nil
        } catch {
            guard path == currentDirectoryPath else { return }
            self.error = error.localizedDescription
            var metadata = ClientLog.networkErrorMetadata(error)
            metadata.merge([
                "workspaceId": workspaceId,
                "path": safeDebugPath(path),
                "layoutMode": String(describing: layoutMode),
                "contentChromeMode": String(describing: contentChromeMode),
            ]) { current, _ in current }
            ClientLog.error("FileBrowser", "Directory load failed", metadata: metadata)
        }
    }

    private func safeDebugPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<root>" }
        if trimmed.count <= 96 { return trimmed }
        return String(trimmed.prefix(93)) + "..."
    }

    private func ensureFileIndex() {
        guard let api = apiClient else { return }
        fileIndexStore.ensureLoaded(workspaceId: workspaceId, worktreeId: worktreeId, apiClient: api)
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

private struct FileBrowserSearchableModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search files"
            )
        } else {
            content
        }
    }
}

private extension View {
    func fileBrowserSearchable(isEnabled: Bool, text: Binding<String>) -> some View {
        modifier(FileBrowserSearchableModifier(isEnabled: isEnabled, text: text))
    }

    func fileTreeGlassPanel(cornerRadius: CGFloat) -> some View {
        themedSurface(
            .floatingControl,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
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
                                .foregroundStyle(segment.depth == currentDepth ? .themeBlue : .themeComment)
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

#if DEBUG
extension FileBrowserView {
    func debugTreePaneSelectedFileContentForTesting(
        selection: FileBrowserSelection,
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        treePaneSelectedFileContent(for: selection, store: store)
    }

    func debugCompactNavigationFileContentForTesting(
        path: String,
        name: String,
        size: Int?,
        store: Binding<FullScreenMarkdownViewportRestoreState>
    ) -> FileBrowserContentView {
        compactNavigationFileContent(
            path: path,
            name: name,
            size: size,
            navigationContext: nil,
            store: store
        )
    }
}
#endif
