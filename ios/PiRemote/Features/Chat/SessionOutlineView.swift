import SwiftUI

/// Condensed session timeline for navigating long conversations.
///
/// Shows two panes:
/// - Session Timeline: scannable timeline entries, filterable by type
/// - Changes: centralized file-change summary (edit/write) grouped by file
struct SessionOutlineView: View {
    let sessionId: String
    let workspaceId: String?
    let items: [ChatItem]
    let onSelect: (String) -> Void
    var onFork: ((String) -> Void)?

    @Environment(ToolArgsStore.self) private var toolArgsStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var filter: OutlineFilter = .all
    @State private var mode: OutlineMode = .outline

    enum OutlineMode: String, CaseIterable {
        case outline = "Session Timeline"
        case changes = "Changes"
    }

    enum OutlineFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case tools = "Tools"
    }

    private var filteredItems: [ChatItem] {
        items.filter { item in
            switch filter {
            case .all:
                // Keep the list focused: hide most system-only noise,
                // but preserve compaction markers so users can locate the boundary.
                switch item {
                case .permissionResolved:
                    return false
                case .systemEvent:
                    return isCompactionEvent(item)
                default:
                    return true
                }
            case .messages:
                switch item {
                case .userMessage, .assistantMessage, .audioClip: return true
                default: return false
                }
            case .tools:
                if case .toolCall = item { return true }
                return false
            }
        }.filter { item in
            guard !searchText.isEmpty else { return true }
            return outlineSummary(for: item).localizedCaseInsensitiveContains(searchText)
        }
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

                Divider().overlay(Color.tokyoComment.opacity(0.3))

                switch mode {
                case .outline:
                    outlinePane
                case .changes:
                    SessionChangesView(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        items: items,
                        searchText: searchText
                    )
                }
            }
            .background(Color.tokyoBg)
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
        }
    }

    @ViewBuilder
    private var outlinePane: some View {
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
                                filter == f ? Color.tokyoBlue : Color.tokyoBgHighlight,
                                in: Capsule()
                            )
                            .foregroundStyle(filter == f ? .white : .tokyoFgDim)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(filteredItems.count) items")
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider().overlay(Color.tokyoComment.opacity(0.3))

            // Outline list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            onSelect(item.id)
                            dismiss()
                        } label: {
                            OutlineRow(
                                item: item,
                                summary: outlineSummary(for: item),
                                diffStats: outlineDiffStats(for: item),
                                isCompaction: isCompactionEvent(item),
                                showDivider: index < filteredItems.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let onFork, isForkable(item) {
                                Button("Fork from here", systemImage: "arrow.triangle.branch") {
                                    onFork(item.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Only persisted user messages can be forked from.
    ///
    /// Mirrors pi CLI behavior (`get_fork_messages` returns user entry IDs).
    /// Live in-flight rows use local UUID placeholders that the server
    /// cannot resolve as fork ancestry entries.
    private func isForkable(_ item: ChatItem) -> Bool {
        guard isServerBackedEntryID(item.id) else { return false }
        switch item {
        case .userMessage: return true
        default: return false
        }
    }

    private func isServerBackedEntryID(_ id: String) -> Bool {
        UUID(uuidString: id) == nil
    }

    private func isCompactionEvent(_ item: ChatItem) -> Bool {
        switch item {
        case .toolCall(_, let tool, _, _, _, _, _):
            return ToolCallFormatting.normalized(tool) == "__compaction"
        case .systemEvent(_, let message):
            return isCompactionMessage(message)
        default:
            return false
        }
    }

    private func isCompactionMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }
        return normalized.contains("compact")
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
                        .background(Color.tokyoOrange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tokyoOrange)
                }

                // Diff stats for edit tools
                if let stats = diffStats {
                    HStack(spacing: 3) {
                        if stats.added > 0 {
                            Text("+\(stats.added)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.tokyoGreen)
                        }
                        if stats.removed > 0 {
                            Text("-\(stats.removed)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.tokyoRed)
                        }
                    }
                }

                // Timestamp (if available)
                if let ts = item.timestamp {
                    Text(ts, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tokyoComment)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showDivider {
                Divider()
                    .overlay(Color.tokyoComment.opacity(0.15))
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
        case .thinking: return "brain"
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
            return .tokyoOrange
        }

        switch item {
        case .userMessage: return .tokyoBlue
        case .assistantMessage: return .tokyoPurple
        case .audioClip: return .tokyoPurple
        case .thinking: return .tokyoPurple
        case .toolCall(_, _, _, _, _, let isError, _):
            return isError ? .tokyoRed : .tokyoCyan
        case .permission: return .tokyoOrange
        case .permissionResolved: return .tokyoGreen
        case .systemEvent: return .tokyoComment
        case .error: return .tokyoRed
        }
    }

    private var textColor: Color {
        if isCompaction {
            return .tokyoFg
        }

        switch item {
        case .userMessage: return .tokyoFg
        case .assistantMessage: return .tokyoFgDim
        case .audioClip: return .tokyoFgDim
        case .thinking: return .tokyoComment
        case .toolCall: return .tokyoFgDim
        default: return .tokyoComment
        }
    }
}
