import SwiftUI

/// Condensed session timeline for navigating long conversations.
///
/// Shows a scannable timeline of session entries, filterable by type.
///
/// **Performance:** Pre-computes per-item summaries and lowercased search text
/// on appear. Filtering uses pre-lowercased `String.contains` instead of
/// `localizedCaseInsensitiveContains`. Search is debounced at 200ms. A render
/// window limits ForEach scope to ~200 visible items with auto-expand on scroll.
struct SessionOutlineView: View {
    let items: [ChatItem]
    let sessionId: String
    let workspaceId: String?
    struct TreeNavigationRequest: Sendable, Equatable {
        let targetId: String
        let summarize: Bool
        let customInstructions: String?
        let replaceInstructions: Bool?
        let label: String?
    }

    let onSelect: (String) -> Void
    var onFork: ((String) -> Void)?
    var onNavigateTreeNode: ((TreeNavigationRequest) async throws -> Void)? = nil
    var initialTreeSnapshot: SessionTreeSnapshot? = nil
    var loadTree: ((SessionTreeFilterMode) async throws -> SessionTreeSnapshot)? = nil
    var initialOutlineSnapshot: SessionOutlineSnapshot? = nil
    var loadOutline: (() async throws -> SessionOutlineSnapshot)? = nil

    @Environment(ToolArgsStore.self) private var toolArgsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var outlineLayout: OutlineLayout = .timeline
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var filter: OutlineFilter = .all

    // Pre-computed outline entries — built once on appear, then replaced by
    // the server's lightweight full-session outline when available.
    @State private var allEntries: [OutlineEntry] = []
    @State private var displayedEntries: [OutlineEntry] = []
    @State private var outlineSnapshot: SessionOutlineSnapshot?
    @State private var isLoadingOutline = false
    @State private var outlineLoadErrorMessage: String?

    // Session tree (for /tree-style navigation surface)
    @State private var treeFilter: SessionTreeFilterMode = .standard
    @State private var treeSnapshot: SessionTreeSnapshot?
    @State private var treeSnapshotFilter: SessionTreeFilterMode?
    @State private var treeFilteredNodes: [SessionTreeNodeSnapshot] = []
    @State private var displayedTreeNodes: [SessionTreeNodeSnapshot] = []
    @State private var collapsedTreeNodeIds: Set<String> = []
    @State private var isLoadingTree = false
    @State private var treeLoadErrorMessage: String?
    @State private var treeNavigateErrorMessage: String?
    @State private var navigatingTreeNodeId: String?
    @State private var pendingTreeNavigationTargetId: String?
    @State private var showTreeNavigationOptions = false
    @State private var showCustomSummaryInstructionsSheet = false
    @State private var customSummaryInstructions = ""

    private static let initialRenderWindow = 200
    private static let renderWindowStep = 200
    @State private var renderWindow = Self.initialRenderWindow

    @State private var searchDebounceTask: Task<Void, Never>?

    enum OutlineLayout: String, CaseIterable {
        case timeline = "Timeline"
        case tree = "Tree"
    }

    enum OutlineFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case tools = "Tools"
    }

    private var hasTree: Bool {
        initialTreeSnapshot != nil || loadTree != nil || treeSnapshot != nil
    }

    private var searchPrompt: String {
        switch outlineLayout {
        case .timeline:
            return "Search session timeline…"
        case .tree:
            return "Search session tree…"
        }
    }

    var body: some View {
        NavigationStack {
            outlinePane
            .background(Color.themeBg)
            .searchable(text: $searchText, prompt: searchPrompt)
            .navigationTitle("Session Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if outlineSnapshot == nil, let initialOutlineSnapshot {
                    outlineSnapshot = initialOutlineSnapshot
                }
                buildIndex()
                applyFilter()

                await loadOutlineIfNeeded()

                if treeSnapshot == nil, let initialTreeSnapshot {
                    treeSnapshot = initialTreeSnapshot
                    treeSnapshotFilter = .standard
                    applyTreeFilter()
                }
            }
            .onChange(of: searchText) { _, newValue in
                searchDebounceTask?.cancel()
                if newValue.isEmpty {
                    // Clear search immediately for responsiveness.
                    debouncedSearchText = ""
                    collapsedTreeNodeIds.removeAll()
                    applyFilter()
                    applyTreeFilter()
                } else {
                    searchDebounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        debouncedSearchText = newValue
                    }
                }
            }
            .onChange(of: debouncedSearchText) { _, _ in
                collapsedTreeNodeIds.removeAll()
                applyFilter()
                applyTreeFilter()
            }
            .onChange(of: filter) { _, _ in
                applyFilter()
            }
            .onChange(of: outlineLayout) { _, newLayout in
                if newLayout != .tree {
                    treeNavigateErrorMessage = nil
                    return
                }

                Task { @MainActor in
                    await loadTreeIfNeeded()
                    applyTreeFilter()
                }
            }
            .onChange(of: showTreeNavigationOptions) { _, isShown in
                if !isShown,
                   !showCustomSummaryInstructionsSheet,
                   navigatingTreeNodeId == nil {
                    pendingTreeNavigationTargetId = nil
                }
            }
            .onChange(of: showCustomSummaryInstructionsSheet) { _, isShown in
                if !isShown,
                   !showTreeNavigationOptions,
                   navigatingTreeNodeId == nil {
                    pendingTreeNavigationTargetId = nil
                }
            }
            .onChange(of: treeSnapshot?.nodes.count) { _, _ in
                collapsedTreeNodeIds.removeAll()
                applyTreeFilter()
            }
            .onDisappear {
                searchDebounceTask?.cancel()
            }
            .confirmationDialog(
                "Navigate Session Tree",
                isPresented: $showTreeNavigationOptions,
                titleVisibility: .visible
            ) {
                Button("Switch without summary") {
                    guard let targetId = pendingTreeNavigationTargetId else { return }
                    beginTreeNavigationWithoutSummary(targetId: targetId)
                }

                Button("Summarize abandoned branch") {
                    guard let targetId = pendingTreeNavigationTargetId else { return }
                    beginTreeNavigationWithDefaultSummary(targetId: targetId)
                }

                Button("Summarize with custom instructions") {
                    customSummaryInstructions = ""
                    showCustomSummaryInstructionsSheet = true
                }

                Button("Cancel", role: .cancel) {
                    clearPendingTreeNavigationSelection()
                }
            } message: {
                Text("Choose how to handle the branch you leave behind.")
            }
            .sheet(isPresented: $showCustomSummaryInstructionsSheet) {
                customSummaryInstructionsSheet
            }
        }
    }

    // MARK: - Index Building

    /// Build pre-computed entries for the local timeline or full-session outline.
    private func buildIndex() {
        guard allEntries.isEmpty else { return }

        if let outlineSnapshot {
            allEntries = outlineSnapshot.entries.map(Self.outlineEntry(from:))
            return
        }

        allEntries = items.map { item in
            let isCompaction = Self.isCompactionEvent(item)
            let summary = outlineSummary(for: item)
            let diffStats = outlineDiffStats(for: item)

            let passesAllFilter: Bool
            switch item {
            case .systemEvent, .cacheMiss:
                passesAllFilter = isCompaction
            default:
                passesAllFilter = true
            }

            let isMessage: Bool
            switch item {
            case .userMessage, .assistantMessage, .audioClip:
                isMessage = true
            default:
                isMessage = false
            }

            let isTool: Bool
            if case .toolCall = item {
                isTool = true
            } else {
                isTool = false
            }

            let isForkable: Bool
            if case .userMessage = item, UUID(uuidString: item.id) == nil {
                isForkable = true
            } else {
                isForkable = false
            }

            return OutlineEntry(
                id: item.id,
                item: item,
                kind: Self.outlineKind(for: item, isCompaction: isCompaction),
                tool: Self.outlineTool(for: item),
                timestamp: item.timestamp,
                summary: summary,
                diffStats: diffStats,
                isCompaction: isCompaction,
                isForkable: isForkable,
                passesAllFilter: passesAllFilter,
                isMessage: isMessage,
                isTool: isTool,
                isError: Self.outlineIsError(for: item)
            )
        }
    }

    /// Filter pre-computed entries by current filter and search text.
    private func applyFilter() {
        let query = debouncedSearchText

        var filtered = allEntries.filter { entry in
            switch filter {
            case .all:
                guard entry.passesAllFilter else { return false }
            case .messages:
                guard entry.isMessage else { return false }
            case .tools:
                guard entry.isTool else { return false }
            }
            return true
        }

        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summaries = filtered.map(\.summary)
            let matches = TextSearchMatch.search(
                query: query,
                candidates: summaries,
                limit: filtered.count
            )
            filtered = matches.map { match in
                var entry = filtered[match.index]
                entry.matchPositions = match.positions
                return entry
            }
        } else {
            // Clear positions when search is cleared
            for i in filtered.indices {
                filtered[i].matchPositions = []
            }
        }

        displayedEntries = filtered
        renderWindow = Self.initialRenderWindow
    }

    private func loadOutlineIfNeeded() async {
        guard let loadOutline else { return }
        guard !isLoadingOutline else { return }
        guard outlineSnapshot == nil else { return }

        isLoadingOutline = true
        defer { isLoadingOutline = false }

        do {
            let snapshot = try await loadOutline()
            let projectedEntries = snapshot.entries.map(Self.outlineEntry(from:))
            if projectedEntries.isEmpty, !items.isEmpty {
                outlineLoadErrorMessage = nil
                return
            }
            outlineSnapshot = snapshot
            allEntries = projectedEntries
            outlineLoadErrorMessage = nil
            applyFilter()
        } catch {
            outlineLoadErrorMessage = error.localizedDescription
        }
    }

    private static func outlineEntry(from snapshot: SessionOutlineEntrySnapshot) -> OutlineEntry {
        OutlineEntry(
            id: snapshot.id,
            item: nil,
            kind: OutlineEntryKind(rawValue: snapshot.kind) ?? .system,
            tool: snapshot.tool,
            timestamp: outlineTimestamp(snapshot.timestamp),
            summary: snapshot.summary,
            diffStats: nil,
            isCompaction: snapshot.kind == OutlineEntryKind.compaction.rawValue,
            isForkable: snapshot.isForkable == true,
            passesAllFilter: snapshot.passesAllFilter,
            isMessage: snapshot.isMessage,
            isTool: snapshot.isTool,
            isError: snapshot.isError == true
        )
    }

    private static func outlineTimestamp(_ timestamp: String) -> Date? {
        guard !timestamp.isEmpty else { return nil }
        return FastISO8601Parser.parse(timestamp, fallback: outlineDateFormatter)
    }

    nonisolated(unsafe) private static let outlineDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func outlineKind(for item: ChatItem, isCompaction: Bool) -> OutlineEntryKind {
        if isCompaction { return .compaction }
        switch item {
        case .userMessage: return .user
        case .assistantMessage: return .assistant
        case .audioClip: return .assistant
        case .thinking: return .thinking
        case .toolCall: return .tool
        case .systemEvent, .cacheMiss: return .system
        case .customEvent: return .custom
        case .error: return .error
        }
    }

    private static func outlineTool(for item: ChatItem) -> String? {
        if case .toolCall(_, let tool, _, _, _, _, _) = item {
            return tool
        }
        return nil
    }

    private static func outlineIsError(for item: ChatItem) -> Bool {
        if case .toolCall(_, _, _, _, _, let isError, _) = item {
            return isError
        }
        if case .error = item {
            return true
        }
        return false
    }

    private func loadTreeIfNeeded() async {
        guard let loadTree else { return }
        guard !isLoadingTree else { return }
        guard treeSnapshot == nil || treeSnapshotFilter != treeFilter else { return }

        isLoadingTree = true
        defer { isLoadingTree = false }

        let maxAttempts = 3
        var attempt = 0

        while attempt < maxAttempts {
            attempt += 1

            do {
                let snapshot = try await loadTree(treeFilter)
                treeSnapshot = snapshot
                treeSnapshotFilter = treeFilter
                treeLoadErrorMessage = nil
                return
            } catch {
                let shouldRetry = attempt < maxAttempts && Self.shouldRetryTreeLoad(error)
                if shouldRetry {
                    let delayMs = 250 * attempt
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    if Task.isCancelled { return }
                    continue
                }

                if treeSnapshotFilter != treeFilter {
                    treeSnapshot = nil
                    treeSnapshotFilter = nil
                }
                treeLoadErrorMessage = error.localizedDescription
                return
            }
        }
    }

    private static func shouldRetryTreeLoad(_ error: Error) -> Bool {
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .notConnected, .sendTimeout:
                return true
            default:
                return false
            }
        }

        if let commandError = error as? CommandRequestError {
            switch commandError {
            case .timeout:
                return true
            case .rejected(_, let reason):
                guard let reason else { return false }
                return reason.contains("Session not active")
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("session not active")
            || description.contains("timed out")
    }

    private func applyTreeFilter() {
        guard let treeSnapshot else {
            treeFilteredNodes = []
            displayedTreeNodes = []
            return
        }

        let query = debouncedSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let baseNodes = treeSnapshot.nodes.filter(\.matchesFilter)

        if query.isEmpty {
            treeFilteredNodes = baseNodes
        } else {
            treeFilteredNodes = baseNodes.filter { node in
                let candidate = [
                    node.textPreview,
                    node.label,
                    node.id,
                    node.type,
                    node.role,
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")

                return TextSearchMatch.match(query: query, candidate: candidate) != nil
            }
        }

        displayedTreeNodes = applyCollapsedTreeNodes(treeFilteredNodes)
    }

    private func applyCollapsedTreeNodes(
        _ nodes: [SessionTreeNodeSnapshot]
    ) -> [SessionTreeNodeSnapshot] {
        guard !collapsedTreeNodeIds.isEmpty else { return nodes }

        var visible: [SessionTreeNodeSnapshot] = []
        var collapsedDepthStack: [Int] = []

        for node in nodes {
            while let last = collapsedDepthStack.last, node.depth <= last {
                _ = collapsedDepthStack.popLast()
            }

            if !collapsedDepthStack.isEmpty {
                continue
            }

            visible.append(node)

            if collapsedTreeNodeIds.contains(node.id) {
                collapsedDepthStack.append(node.depth)
            }
        }

        return visible
    }

    private func hasCollapsibleChildren(
        nodeId: String,
        within nodes: [SessionTreeNodeSnapshot]
    ) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else {
            return false
        }

        guard index < nodes.count - 1 else {
            return false
        }

        return nodes[index + 1].depth > nodes[index].depth
    }

    private func toggleTreeNodeCollapsed(_ nodeId: String) {
        if collapsedTreeNodeIds.contains(nodeId) {
            collapsedTreeNodeIds.remove(nodeId)
        } else {
            collapsedTreeNodeIds.insert(nodeId)
        }

        displayedTreeNodes = applyCollapsedTreeNodes(treeFilteredNodes)
    }

    private func selectTreeFilter(_ nextFilter: SessionTreeFilterMode) {
        guard treeFilter != nextFilter else { return }

        treeFilter = nextFilter
        collapsedTreeNodeIds.removeAll()

        Task { @MainActor in
            await loadTreeIfNeeded()
            applyTreeFilter()
        }
    }

    private func makeTreeDisplayNodes(
        from nodes: [SessionTreeNodeSnapshot]
    ) -> [SessionTreeDisplayNode] {
        SessionTreeDisplayLayout.displayNodes(
            visibleNodes: nodes,
            allNodes: treeSnapshot?.nodes ?? nodes
        )
    }

    private func handleTreeNodeSelection(_ nodeId: String) {
        treeNavigateErrorMessage = nil

        guard onNavigateTreeNode != nil else {
            onSelect(nodeId)
            dismiss()
            return
        }

        guard navigatingTreeNodeId == nil else { return }
        pendingTreeNavigationTargetId = nodeId
        showTreeNavigationOptions = true
    }

    private func beginTreeNavigationWithoutSummary(targetId: String) {
        startTreeNavigation(.init(
            targetId: targetId,
            summarize: false,
            customInstructions: nil,
            replaceInstructions: nil,
            label: nil
        ))
    }

    private func beginTreeNavigationWithDefaultSummary(targetId: String) {
        startTreeNavigation(.init(
            targetId: targetId,
            summarize: true,
            customInstructions: nil,
            replaceInstructions: nil,
            label: nil
        ))
    }

    private func beginTreeNavigationWithCustomSummary() {
        guard let targetId = pendingTreeNavigationTargetId else { return }

        let instructions = customSummaryInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !instructions.isEmpty else { return }

        startTreeNavigation(.init(
            targetId: targetId,
            summarize: true,
            customInstructions: instructions,
            replaceInstructions: false,
            label: nil
        ))
    }

    private func startTreeNavigation(_ request: TreeNavigationRequest) {
        treeNavigateErrorMessage = nil
        showTreeNavigationOptions = false
        showCustomSummaryInstructionsSheet = false
        pendingTreeNavigationTargetId = nil

        guard let onNavigateTreeNode else {
            onSelect(request.targetId)
            dismiss()
            return
        }

        guard navigatingTreeNodeId == nil else { return }
        navigatingTreeNodeId = request.targetId

        Task {
            defer { navigatingTreeNodeId = nil }

            do {
                try await onNavigateTreeNode(request)
                guard !Task.isCancelled else { return }
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                treeNavigateErrorMessage = error.localizedDescription
            }
        }
    }

    private func clearPendingTreeNavigationSelection() {
        pendingTreeNavigationTargetId = nil
        showTreeNavigationOptions = false
        showCustomSummaryInstructionsSheet = false
        customSummaryInstructions = ""
    }

    private var hasCustomSummaryInstructions: Bool {
        !customSummaryInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customSummaryInstructionsSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add extra guidance for what to preserve in the branch summary.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                TextEditor(text: $customSummaryInstructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("tree-summary-instructions")
                    .frame(minHeight: 160)
                    .themedTextInputCard(cornerRadius: 12, contentPadding: 8)

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color.themeBg)
            .navigationTitle("Summary Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        clearPendingTreeNavigationSelection()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Navigate") {
                        beginTreeNavigationWithCustomSummary()
                    }
                    .disabled(!hasCustomSummaryInstructions || navigatingTreeNodeId != nil)
                    .accessibilityIdentifier("tree-summary-navigate")
                }
            }
        }
    }

    // MARK: - Outline Pane

    private var outlineLayoutPicker: some View {
        Picker("Layout", selection: $outlineLayout) {
            Text("Timeline").tag(OutlineLayout.timeline)
            if hasTree {
                Text("Tree").tag(OutlineLayout.tree)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var outlinePane: some View {
        VStack(spacing: 0) {
            if hasTree {
                outlineLayoutPicker
                Divider().overlay(Color.themeComment.opacity(0.3))
            }

            switch outlineLayout {
            case .timeline:
                timelinePane
            case .tree:
                treePane
            }
        }
    }

    private func filterChipLabel(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.caption.bold())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.themeBlue : Color.themeBgHighlight,
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .themeOnBlue : .themeFgDim)
    }

    @ViewBuilder
    private var timelinePane: some View {
        let visibleCount = min(displayedEntries.count, renderWindow)

        VStack(spacing: 0) {
            // Filter chips
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(OutlineFilter.allCases, id: \.self) { f in
                            Button {
                                withAnimation(ThemeMotion.easeInOut(duration: 0.15, reduceMotion: reduceMotion)) {
                                    filter = f
                                }
                            } label: {
                                filterChipLabel(f.rawValue, isSelected: filter == f)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isLoadingOutline {
                    ProgressView()
                        .controlSize(.small)
                }

                Text("\(displayedEntries.count) items")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider().overlay(Color.themeComment.opacity(0.3))

            // Outline list with render window
            ScrollView {
                if let outlineLoadErrorMessage,
                   outlineSnapshot == nil,
                   !outlineLoadErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.themeOrange)
                            .font(.caption)

                        Text("Full outline unavailable: \(outlineLoadErrorMessage)")
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.themeOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.themeOrange.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                LazyVStack(spacing: 0) {
                    ForEach(0..<visibleCount, id: \.self) { index in
                        let entry = displayedEntries[index]
                        Button {
                            onSelect(entry.id)
                            dismiss()
                        } label: {
                            OutlineRow(
                                item: entry.item,
                                kind: entry.kind,
                                tool: entry.tool,
                                timestamp: entry.timestamp,
                                summary: entry.summary,
                                matchPositions: entry.matchPositions,
                                diffStats: entry.diffStats,
                                isCompaction: entry.isCompaction,
                                isError: entry.isError,
                                showDivider: index < visibleCount - 1
                            )
                        }
                        .buttonStyle(.plain)
                        .id(entry.id)
                        .contextMenu {
                            if let onFork, entry.isForkable {
                                Button("Fork from here", systemImage: "arrow.triangle.branch") {
                                    onFork(entry.id)
                                    dismiss()
                                }
                            }
                        }
                        .onAppear {
                            // Auto-expand render window when approaching the end.
                            if index >= visibleCount - 20,
                               renderWindow < displayedEntries.count {
                                renderWindow = min(
                                    displayedEntries.count,
                                    renderWindow + Self.renderWindowStep
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tree Pane

    private var treeFilterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SessionTreeFilterMode.allCases, id: \.self) { mode in
                        Button {
                            selectTreeFilter(mode)
                        } label: {
                            filterChipLabel(mode.title, isSelected: treeFilter == mode)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLoadingTree, treeSnapshot != nil {
                ProgressView()
                    .controlSize(.small)
            }

            Text("\(treeFilteredNodes.count) items")
                .font(.caption2)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var treePane: some View {
        VStack(spacing: 0) {
            treeFilterBar

            Divider().overlay(Color.themeComment.opacity(0.3))

            if isLoadingTree, treeSnapshot == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading session tree…")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.themeBgDark)
            } else if displayedTreeNodes.isEmpty {
                if let treeLoadErrorMessage, treeSnapshot == nil {
                    ContentUnavailableView(
                        "Tree unavailable",
                        systemImage: "arrow.triangle.branch",
                        description: Text(treeLoadErrorMessage)
                    )
                    .background(Color.themeBgDark)
                } else if !debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: debouncedSearchText)
                        .background(Color.themeBgDark)
                } else {
                    ContentUnavailableView(
                        "No tree data",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This session has no tree entries yet.")
                    )
                    .background(Color.themeBgDark)
                }
            } else {
                ScrollView {
                    if let treeNavigateErrorMessage,
                       !treeNavigateErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.themeOrange)
                                .font(.caption)

                            Text(treeNavigateErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.themeFg)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.themeOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.themeOrange.opacity(0.35), lineWidth: 1)
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    let treeDisplayNodes = makeTreeDisplayNodes(from: displayedTreeNodes)

                    LazyVStack(spacing: 0) {
                        ForEach(treeDisplayNodes) { displayNode in
                            let node = displayNode.node
                            let isCollapsible = hasCollapsibleChildren(
                                nodeId: node.id,
                                within: treeFilteredNodes
                            )

                            OutlineTreeRow(
                                displayNode: displayNode,
                                isCollapsible: isCollapsible,
                                isCollapsed: collapsedTreeNodeIds.contains(node.id),
                                isDisabled: navigatingTreeNodeId != nil,
                                isLoading: navigatingTreeNodeId == node.id,
                                onSelect: {
                                    handleTreeNodeSelection(node.id)
                                },
                                onToggleCollapse: isCollapsible
                                    ? {
                                        toggleTreeNodeCollapsed(node.id)
                                    }
                                    : nil
                            )
                            .contextMenu {
                                if let onFork,
                                   node.role == "user",
                                   UUID(uuidString: node.id) == nil {
                                    Button("Fork from here", systemImage: "arrow.triangle.branch") {
                                        onFork(node.id)
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Summary Text

    private func outlineSummary(for item: ChatItem) -> String {
        switch item {
        case .userMessage(_, let text, _, _):
            return String(text.prefix(120))

        case .assistantMessage(_, let text, _):
            let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(clean.prefix(120))

        case .audioClip(_, let title, let fileURL, _):
            return "\(title): \(fileURL.lastPathComponent)"

        case .thinking(_, let preview, _, _):
            let clean = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(clean.prefix(80))

        case .toolCall(let id, let tool, let argsSummary, _, _, _, _):
            return formatToolSummary(id: id, tool: tool, argsSummary: argsSummary)

        case .systemEvent(_, let msg), .cacheMiss(_, let msg):
            return msg

        case .customEvent(_, let msg, let presentation):
            return msg.isEmpty ? presentation.title : msg

        case .error(_, let msg):
            return msg
        }
    }

    private func formatToolSummary(id: String, tool: String, argsSummary: String) -> String {
        let args = toolArgsStore.args(for: id)

        switch tool {
        case "bash", "Bash":
            let cmd = args?["command"]?.stringValue ?? argsSummary
            return "$ " + String(cmd.replacingOccurrences(of: "\n", with: " ").prefix(100))

        case "__compaction":
            return "Context compacted"

        case "read", "Read":
            let path = args?["path"]?.stringValue ?? ""
            return "read " + path.shortenedPath

        case "write", "Write":
            let path = args?["path"]?.stringValue ?? ""
            return "write " + path.shortenedPath

        case "edit", "Edit":
            let path = args?["path"]?.stringValue ?? ""
            return "edit " + path.shortenedPath

        default:
            return "\(tool): \(String(argsSummary.prefix(80)))"
        }
    }

    private func outlineDiffStats(for item: ChatItem) -> ToolCallFormatting.DiffStats? {
        guard case .toolCall(let id, let tool, _, _, _, _, _) = item,
              ToolCallFormatting.isEditTool(tool) else { return nil }
        return ToolCallFormatting.editDiffStats(from: toolArgsStore.args(for: id))
    }

    // MARK: - Classification Helpers

    private static func isCompactionEvent(_ item: ChatItem) -> Bool {
        switch item {
        case .toolCall(_, let tool, _, _, _, _, _):
            return ToolCallFormatting.normalized(tool) == "__compaction"
        case .systemEvent(_, let message):
            return isCompactionMessage(message)
        default:
            return false
        }
    }

    private static func isCompactionMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }
        return normalized.contains("compact")
    }
}

// MARK: - Pre-computed Outline Entry

private enum OutlineEntryKind: String {
    case user
    case assistant
    case thinking
    case tool
    case system
    case compaction
    case custom
    case error
}

/// Holds pre-computed summary, search text, and classification for each item.
/// Built once on view appear so filtering is cheap.
private struct OutlineEntry: Identifiable {
    let id: String
    let item: ChatItem?
    let kind: OutlineEntryKind
    let tool: String?
    let timestamp: Date?
    let summary: String
    let diffStats: ToolCallFormatting.DiffStats?
    let isCompaction: Bool
    let isForkable: Bool

    // Filter category flags
    let passesAllFilter: Bool
    let isMessage: Bool
    let isTool: Bool
    let isError: Bool

    /// Unicode scalar positions of literal search matches (populated during search).
    var matchPositions: [Int] = []
}

// MARK: - Outline Row

private struct OutlineRow: View {
    let item: ChatItem?
    let kind: OutlineEntryKind
    let tool: String?
    let timestamp: Date?
    let summary: String
    var matchPositions: [Int] = []
    var diffStats: ToolCallFormatting.DiffStats?
    let isCompaction: Bool
    let isError: Bool
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Type icon
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                // Summary text — highlighted when searching
                if matchPositions.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(highlightedSummary)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isCompaction {
                    Text("Compaction")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.themeOrange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.themeOrange)
                }

                // Diff stats for edit tools
                if let stats = diffStats {
                    HStack(spacing: 3) {
                        if stats.added > 0 {
                            Text("+\(stats.added)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if stats.removed > 0 {
                            Text("-\(stats.removed)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }

                // Timestamp (if available)
                if let timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showDivider {
                Divider()
                    .overlay(Color.themeComment.opacity(0.15))
                    .padding(.leading, 42)
            }
        }
    }

    private var highlightedSummary: AttributedString {
        let scalars = Array(summary.unicodeScalars)
        let matchSet = Set(matchPositions)
        var result = AttributedString()

        var i = 0
        while i < scalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < scalars.count, matchSet.contains(end + 1) { end += 1 }
                var seg = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                seg.foregroundColor = .themeYellow
                seg.font = .caption.bold()
                result.append(seg)
                i = end + 1
            } else {
                var end = i
                while end + 1 < scalars.count, !matchSet.contains(end + 1) { end += 1 }
                var seg = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                seg.foregroundColor = textColor
                seg.font = .caption
                result.append(seg)
                i = end + 1
            }
        }
        return result
    }

    private var iconName: String {
        if isCompaction {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }

        switch kind {
        case .user: return "person.fill"
        case .assistant: return itemAudioIcon ?? "cpu"
        case .thinking: return "sparkle"
        case .tool:
            return ToolCallFormatting.sfSymbolName(for: tool ?? "") ?? "wrench"
        case .system: return "info.circle"
        case .compaction: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .custom: return "info.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        if isCompaction {
            return .themeOrange
        }

        switch kind {
        case .user: return .themeBlue
        case .assistant, .thinking: return .themePurple
        case .tool: return isError ? .themeRed : .themeCyan
        case .system: return .themeComment
        case .compaction: return .themeOrange
        case .custom: return .themeBlue
        case .error: return .themeRed
        }
    }

    private var textColor: Color {
        if isCompaction {
            return .themeFg
        }

        switch kind {
        case .user: return .themeFg
        case .assistant: return .themeFgDim
        case .thinking: return .themeComment
        case .tool: return .themeFgDim
        case .compaction: return .themeFg
        default: return .themeComment
        }
    }

    private var itemAudioIcon: String? {
        if let item, case .audioClip = item { return "waveform" }
        return nil
    }
}

private enum OutlineTreeLayout {
    static let levelIndent: CGFloat = 18
}

struct SessionTreeDisplayGutter: Equatable {
    let position: Int
    let show: Bool
}

private struct SessionTreeLayoutFrame {
    let id: String
    let indent: Int
    let justBranched: Bool
    let showConnector: Bool
    let isLast: Bool
    let gutters: [SessionTreeDisplayGutter]
    let isVirtualRootChild: Bool
}

enum SessionTreeDisplayLayout {
    static func displayNodes(
        visibleNodes: [SessionTreeNodeSnapshot],
        allNodes: [SessionTreeNodeSnapshot]
    ) -> [SessionTreeDisplayNode] {
        guard !visibleNodes.isEmpty else { return [] }

        let visibleIds = Set(visibleNodes.map(\.id))

        var allNodesById: [String: SessionTreeNodeSnapshot] = [:]
        allNodesById.reserveCapacity(max(allNodes.count, visibleNodes.count))

        for node in allNodes {
            allNodesById[node.id] = node
        }

        for node in visibleNodes where allNodesById[node.id] == nil {
            allNodesById[node.id] = node
        }

        func nearestVisibleAncestorId(for node: SessionTreeNodeSnapshot) -> String? {
            var currentParentId = node.parentId

            while let parentId = currentParentId {
                if visibleIds.contains(parentId) {
                    return parentId
                }
                currentParentId = allNodesById[parentId]?.parentId
            }

            return nil
        }

        var visibleChildren: [String?: [String]] = [nil: []]
        visibleChildren.reserveCapacity(visibleNodes.count)

        for node in visibleNodes {
            let parentId = nearestVisibleAncestorId(for: node)
            visibleChildren[parentId, default: []].append(node.id)
        }

        let rootIds = visibleChildren[nil] ?? []
        let multipleRoots = rootIds.count > 1

        var displayNodes: [SessionTreeDisplayNode] = []
        displayNodes.reserveCapacity(visibleNodes.count)

        var stack: [SessionTreeLayoutFrame] = []

        for (index, rootId) in rootIds.enumerated().reversed() {
            stack.append(SessionTreeLayoutFrame(
                id: rootId,
                indent: multipleRoots ? 1 : 0,
                justBranched: multipleRoots,
                showConnector: multipleRoots,
                isLast: index == rootIds.count - 1,
                gutters: [],
                isVirtualRootChild: multipleRoots
            ))
        }

        while let current = stack.popLast() {
            guard let node = allNodesById[current.id] else { continue }

            let displayDepth = multipleRoots
                ? max(0, current.indent - 1)
                : max(0, current.indent)

            displayNodes.append(SessionTreeDisplayNode(
                node: node,
                displayDepth: displayDepth,
                showConnector: current.showConnector,
                isLast: current.isLast,
                gutters: current.gutters,
                isVirtualRootChild: current.isVirtualRootChild
            ))

            let children = visibleChildren[current.id] ?? []
            let multipleChildren = children.count > 1

            let childIndent: Int
            if multipleChildren {
                childIndent = current.indent + 1
            } else if current.justBranched, current.indent > 0 {
                childIndent = current.indent + 1
            } else {
                childIndent = current.indent
            }

            let connectorDisplayed = current.showConnector && !current.isVirtualRootChild
            let connectorPosition = max(0, displayDepth - 1)
            let childGutters = connectorDisplayed
                ? current.gutters + [SessionTreeDisplayGutter(
                    position: connectorPosition,
                    show: !current.isLast
                )]
                : current.gutters

            for (index, childId) in children.enumerated().reversed() {
                stack.append(SessionTreeLayoutFrame(
                    id: childId,
                    indent: childIndent,
                    justBranched: multipleChildren,
                    showConnector: multipleChildren,
                    isLast: index == children.count - 1,
                    gutters: childGutters,
                    isVirtualRootChild: false
                ))
            }
        }

        return displayNodes
    }
}

struct SessionTreeDisplayNode: Identifiable, Equatable {
    let node: SessionTreeNodeSnapshot
    let displayDepth: Int
    let showConnector: Bool
    let isLast: Bool
    let gutters: [SessionTreeDisplayGutter]
    let isVirtualRootChild: Bool

    var id: String { node.id }
}

private struct OutlineTreeRow: View {
    let displayNode: SessionTreeDisplayNode
    let isCollapsible: Bool
    let isCollapsed: Bool
    let isDisabled: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onToggleCollapse: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            OutlineTreeConnectorLines(displayNode: displayNode)

            if isCollapsible {
                Button {
                    onToggleCollapse?()
                } label: {
                    Image(systemName: isCollapsed ? "plus.square" : "minus.square")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel(isCollapsed ? "Expand branch" : "Collapse branch")
                .accessibilityIdentifier("tree-toggle-\(node.id)")
            }

            Button(action: onSelect) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if node.isLeafPath {
                        Text("•")
                            .font(.caption.bold())
                            .foregroundStyle(.themeOrange)
                    }

                    if let displayLabel {
                        Text("[\(displayLabel)]")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeOrange)
                            .lineLimit(1)
                    }

                    if !rolePrefix.isEmpty {
                        Text(rolePrefix)
                            .font(.caption.bold())
                            .foregroundStyle(roleColor)
                    }

                    if !primaryText.isEmpty {
                        Text(primaryText)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.themeBlue)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var node: SessionTreeNodeSnapshot { displayNode.node }

    private var displayLabel: String? {
        guard let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return label
    }

    private var primaryText: String {
        let preview = node.textPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preview.isEmpty {
            return preview
        }

        if node.type == "message" {
            return "(no content)"
        }

        return ""
    }

    private var rolePrefix: String {
        if node.type == "message" {
            switch node.role {
            case "user": return "user:"
            case "assistant": return "assistant:"
            case "toolResult": return ""
            case "bashExecution": return "bash:"
            case let role? where !role.isEmpty:
                return "\(role):"
            default:
                return "message:"
            }
        }

        switch node.type {
        case "compaction":
            return "[compaction]"
        case "branch_summary":
            return "[branch summary]"
        case "model_change":
            return "[model]"
        case "thinking_level_change":
            return "[thinking]"
        default:
            let normalized = node.type.replacingOccurrences(of: "_", with: " ")
            return "[\(normalized)]"
        }
    }

    private var roleColor: Color {
        if node.type == "message" {
            switch node.role {
            case "user": return .themeBlue
            case "assistant": return .themePurple
            default: return .themeComment
            }
        }

        switch node.type {
        case "branch_summary": return .themeBlue
        case "compaction": return .themeOrange
        default: return .themeComment
        }
    }
}

private struct OutlineTreeConnectorLines: View {
    let displayNode: SessionTreeDisplayNode

    private let levelWidth: CGFloat = OutlineTreeLayout.levelIndent

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let stroke = StrokeStyle(lineWidth: 1, lineCap: .round)
                let lineColor = Color.themeComment.opacity(0.38)
                let centerY = size.height * 0.5

                for gutter in displayNode.gutters where gutter.show {
                    let x = xPosition(for: gutter.position)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(lineColor), style: stroke)
                }

                guard connectorDisplayed else { return }

                let branchLevel = max(0, displayNode.displayDepth - 1)
                let branchX = xPosition(for: branchLevel)

                var vertical = Path()
                vertical.move(to: CGPoint(x: branchX, y: 0))
                vertical.addLine(to: CGPoint(x: branchX, y: displayNode.isLast ? centerY : size.height))
                context.stroke(vertical, with: .color(lineColor), style: stroke)

                var elbow = Path()
                elbow.move(to: CGPoint(x: branchX, y: centerY))
                elbow.addLine(to: CGPoint(x: branchX + (levelWidth * 0.55), y: centerY))
                context.stroke(elbow, with: .color(lineColor), style: stroke)
            }
        }
        .frame(width: connectorWidth)
    }

    private var connectorDisplayed: Bool {
        displayNode.showConnector && !displayNode.isVirtualRootChild
    }

    private var connectorWidth: CGFloat {
        guard displayNode.displayDepth > 0 else { return connectorDisplayed ? levelWidth : 6 }
        return CGFloat(displayNode.displayDepth) * levelWidth + 2
    }

    private func xPosition(for depthLevel: Int) -> CGFloat {
        CGFloat(depthLevel) * levelWidth + (levelWidth * 0.22)
    }
}
