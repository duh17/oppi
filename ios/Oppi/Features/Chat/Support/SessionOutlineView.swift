import SwiftUI

/// Condensed session timeline for navigating long conversations.
///
/// Shows two panes:
/// - Session Timeline: scannable timeline entries, filterable by type
/// - Changes: centralized file-change summary (edit/write) grouped by file
///
/// **Performance:** Pre-computes per-item summaries and lowercased search text
/// on appear. Filtering uses pre-lowercased `String.contains` instead of
/// `localizedCaseInsensitiveContains`. Search is debounced at 200ms. A render
/// window limits ForEach scope to ~200 visible items with auto-expand on scroll.
struct SessionOutlineView: View {
    let sessionId: String
    let workspaceId: String?
    let items: [ChatItem]
    let onSelect: (String) -> Void
    var onFork: ((String) -> Void)?

    @Environment(ToolArgsStore.self) private var toolArgsStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var filter: OutlineFilter = .all
    @State private var mode: OutlineMode = .outline

    // Pre-computed outline entries — built once on appear.
    @State private var allEntries: [OutlineEntry] = []
    @State private var displayedEntries: [OutlineEntry] = []

    private static let initialRenderWindow = 200
    private static let renderWindowStep = 200
    @State private var renderWindow = Self.initialRenderWindow

    @State private var searchDebounceTask: Task<Void, Never>?

    enum OutlineMode: String, CaseIterable {
        case outline = "Session Timeline"
        case changes = "Changes"
    }

    enum OutlineFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case tools = "Tools"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) {
                    ForEach(OutlineMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider().overlay(Color.themeComment.opacity(0.3))

                switch mode {
                case .outline:
                    outlinePane
                case .changes:
                    SessionChangesView(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        items: items,
                        searchText: debouncedSearchText
                    )
                }
            }
            .background(Color.themeBg)
            .searchable(
                text: $searchText,
                prompt: mode == .outline ? "Search session timeline…" : "Search changed files…"
            )
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                buildIndex()
                applyFilter()
            }
            .onChange(of: searchText) { _, newValue in
                searchDebounceTask?.cancel()
                if newValue.isEmpty {
                    // Clear search immediately for responsiveness.
                    debouncedSearchText = ""
                    applyFilter()
                } else {
                    searchDebounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        debouncedSearchText = newValue
                    }
                }
            }
            .onChange(of: debouncedSearchText) { _, _ in
                applyFilter()
            }
            .onChange(of: filter) { _, _ in
                applyFilter()
            }
            .onDisappear {
                searchDebounceTask?.cancel()
            }
        }
    }

    // MARK: - Index Building

    /// Build pre-computed entries for all items. O(n) once on appear.
    private func buildIndex() {
        guard allEntries.isEmpty else { return }

        var entries: [OutlineEntry] = []
        entries.reserveCapacity(items.count)

        for item in items {
            let isCompaction = Self.isCompactionEvent(item)
            let summary = outlineSummary(for: item)
            let diffStats = outlineDiffStats(for: item)

            let passesAllFilter: Bool
            switch item {
            case .permissionResolved:
                passesAllFilter = false
            case .systemEvent:
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

            entries.append(OutlineEntry(
                id: item.id,
                item: item,
                summary: summary,
                lowercasedSummary: summary.lowercased(),
                diffStats: diffStats,
                isCompaction: isCompaction,
                isForkable: isForkable,
                passesAllFilter: passesAllFilter,
                isMessage: isMessage,
                isTool: isTool
            ))
        }

        allEntries = entries
    }

    /// Filter pre-computed entries by current filter and search text.
    private func applyFilter() {
        let query = debouncedSearchText.lowercased()

        displayedEntries = allEntries.filter { entry in
            // Type filter
            switch filter {
            case .all:
                guard entry.passesAllFilter else { return false }
            case .messages:
                guard entry.isMessage else { return false }
            case .tools:
                guard entry.isTool else { return false }
            }

            // Search filter (pre-lowercased, no ICU overhead)
            if !query.isEmpty {
                return entry.lowercasedSummary.contains(query)
            }
            return true
        }

        // Reset render window when filter/search changes so the user
        // starts at the top of the new result set.
        renderWindow = Self.initialRenderWindow
    }

    // MARK: - Outline Pane

    @ViewBuilder
    private var outlinePane: some View {
        let visibleCount = min(displayedEntries.count, renderWindow)

        VStack(spacing: 0) {
            // Filter chips
            HStack(spacing: 8) {
                ForEach(OutlineFilter.allCases, id: \.self) { f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            filter = f
                        }
                    } label: {
                        Text(f.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                filter == f ? Color.themeBlue : Color.themeBgHighlight,
                                in: Capsule()
                            )
                            .foregroundStyle(filter == f ? .white : .themeFgDim)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(displayedEntries.count) items")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider().overlay(Color.themeComment.opacity(0.3))

            // Outline list with render window
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<visibleCount, id: \.self) { index in
                        let entry = displayedEntries[index]
                        Button {
                            onSelect(entry.id)
                            dismiss()
                        } label: {
                            OutlineRow(
                                item: entry.item,
                                summary: entry.summary,
                                diffStats: entry.diffStats,
                                isCompaction: entry.isCompaction,
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

        case .permission(let req):
            return req.displaySummary

        case .permissionResolved(_, let outcome, let tool, _):
            let label = switch outcome {
            case .allowed: "Allowed"
            case .denied: "Denied"
            case .expired: "Expired"
            case .cancelled: "Cancelled"
            }
            return "\(label): \(tool)"

        case .systemEvent(_, let msg):
            return msg

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
            let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? ""
            return "read " + path.shortenedPath

        case "write", "Write":
            let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? ""
            return "write " + path.shortenedPath

        case "edit", "Edit":
            let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? ""
            return "edit " + path.shortenedPath

        case "todo", "Todo":
            let summary = ToolCallFormatting.todoSummary(args: args, argsSummary: argsSummary)
            return summary.isEmpty ? "todo" : "todo \(summary)"

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

/// Holds pre-computed summary, search text, and classification for each item.
/// Built once on view appear so filtering is cheap boolean + string.contains.
private struct OutlineEntry: Identifiable {
    let id: String
    let item: ChatItem
    let summary: String
    /// Pre-lowercased summary for fast search (avoids ICU locale overhead).
    let lowercasedSummary: String
    let diffStats: ToolCallFormatting.DiffStats?
    let isCompaction: Bool
    let isForkable: Bool

    // Filter category flags
    let passesAllFilter: Bool
    let isMessage: Bool
    let isTool: Bool
}

// MARK: - Outline Row

private struct OutlineRow: View {
    let item: ChatItem
    let summary: String
    var diffStats: ToolCallFormatting.DiffStats?
    let isCompaction: Bool
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Type icon
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                // Summary text
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                if let ts = item.timestamp {
                    Text(ts, style: .time)
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

    private var iconName: String {
        if isCompaction {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }

        switch item {
        case .userMessage: return "person.fill"
        case .assistantMessage: return "cpu"
        case .audioClip: return "waveform"
        case .thinking: return "sparkle"
        case .toolCall(_, let tool, _, _, _, _, _):
            switch tool {
            case "bash", "Bash": return "terminal"
            case "read", "Read": return "doc.text"
            case "write", "Write": return "square.and.pencil"
            case "edit", "Edit": return "pencil"
            case "todo", "Todo": return "checklist"
            default: return "wrench"
            }
        case .permission: return "exclamationmark.shield"
        case .permissionResolved: return "checkmark.shield"
        case .systemEvent: return "info.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        if isCompaction {
            return .themeOrange
        }

        switch item {
        case .userMessage: return .themeBlue
        case .assistantMessage: return .themePurple
        case .audioClip: return .themePurple
        case .thinking: return .themePurple
        case .toolCall(_, _, _, _, _, let isError, _):
            return isError ? .themeRed : .themeCyan
        case .permission: return .themeOrange
        case .permissionResolved: return .themeGreen
        case .systemEvent: return .themeComment
        case .error: return .themeRed
        }
    }

    private var textColor: Color {
        if isCompaction {
            return .themeFg
        }

        switch item {
        case .userMessage: return .themeFg
        case .assistantMessage: return .themeFgDim
        case .audioClip: return .themeFgDim
        case .thinking: return .themeComment
        case .toolCall: return .themeFgDim
        default: return .themeComment
        }
    }
}
