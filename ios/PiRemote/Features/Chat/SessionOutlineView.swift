import SwiftUI

/// Condensed session outline for navigating long conversations.
///
/// Shows a scannable list of all timeline entries. Tap to jump.
/// Filter by entry type and search by content.
struct SessionOutlineView: View {
    let items: [ChatItem]
    let onSelect: (String) -> Void
    var onFork: ((String) -> Void)?

    @Environment(ToolArgsStore.self) private var toolArgsStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var filter: OutlineFilter = .all

    enum OutlineFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case tools = "Tools"
    }

    private var filteredItems: [ChatItem] {
        items.filter { item in
            switch filter {
            case .all:
                // Hide system events and permission resolved badges from outline
                switch item {
                case .systemEvent, .permissionResolved: return false
                default: return true
                }
            case .messages:
                switch item {
                case .userMessage, .assistantMessage: return true
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
            .background(Color.tokyoBg)
            .searchable(text: $searchText, prompt: "Search session…")
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Only persisted user/assistant messages can be forked from.
    ///
    /// Live in-flight rows use local UUID placeholders that the server
    /// cannot resolve as fork ancestry entries.
    private func isForkable(_ item: ChatItem) -> Bool {
        guard isServerBackedEntryID(item.id) else { return false }
        switch item {
        case .userMessage, .assistantMessage: return true
        default: return false
        }
    }

    private func isServerBackedEntryID(_ id: String) -> Bool {
        UUID(uuidString: id) == nil
    }

    // MARK: - Summary Text

    private func outlineSummary(for item: ChatItem) -> String {
        switch item {
        case .userMessage(_, let text, _):
            return String(text.prefix(120))

        case .assistantMessage(_, let text, _):
            let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(clean.prefix(120))

        case .thinking(_, let preview, _, _):
            let clean = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(clean.prefix(80))

        case .toolCall(let id, let tool, let argsSummary, _, _, _, _):
            return formatToolSummary(id: id, tool: tool, argsSummary: argsSummary)

        case .permission(let req):
            return req.displaySummary

        case .permissionResolved(_, let action):
            return action == .allow ? "Allowed" : "Denied"

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

        case "read", "Read":
            let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? ""
            return "read " + path.shortenedPath

        case "write", "Write":
            let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? ""
            return "write " + path.shortenedPath

        case "edit", "Edit":
            let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? ""
            return "edit " + path.shortenedPath

        default:
            return "\(tool): \(String(argsSummary.prefix(80)))"
        }
    }
}

// MARK: - Outline Row

private struct OutlineRow: View {
    let item: ChatItem
    let summary: String
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
        switch item {
        case .userMessage: return "person.fill"
        case .assistantMessage: return "cpu"
        case .thinking: return "brain"
        case .toolCall(_, let tool, _, _, _, _, _):
            switch tool {
            case "bash", "Bash": return "terminal"
            case "read", "Read": return "doc.text"
            case "write", "Write": return "square.and.pencil"
            case "edit", "Edit": return "pencil"
            default: return "wrench"
            }
        case .permission: return "exclamationmark.shield"
        case .permissionResolved: return "checkmark.shield"
        case .systemEvent: return "info.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch item {
        case .userMessage: return .tokyoBlue
        case .assistantMessage: return .tokyoPurple
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
        switch item {
        case .userMessage: return .tokyoFg
        case .assistantMessage: return .tokyoFgDim
        case .thinking: return .tokyoComment
        case .toolCall: return .tokyoFgDim
        default: return .tokyoComment
        }
    }
}
