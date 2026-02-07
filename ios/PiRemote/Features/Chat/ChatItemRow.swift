import SwiftUI

/// Renders a single `ChatItem` in the chat timeline.
///
/// Designed for `LazyVStack` — lightweight, stable ID, no expensive layout.
struct ChatItemRow: View {
    let item: ChatItem
    var isStreaming: Bool = false

    var body: some View {
        switch item {
        case .userMessage(_, let text, _):
            UserMessageBubble(text: text)

        case .assistantMessage(_, let text, _):
            AssistantMessageBubble(text: text, isStreaming: isStreaming)

        case .thinking(_, let preview, _):
            ThinkingRow(preview: preview)

        case .toolCall(let id, let tool, let args, let preview, let bytes, let isError, let isDone):
            ToolCallRow(
                id: id, tool: tool, argsSummary: args,
                outputPreview: preview, outputByteCount: bytes,
                isError: isError, isDone: isDone
            )

        case .permission(let request):
            PermissionCardView(request: request)

        case .permissionResolved(_, let action):
            PermissionResolvedBadge(action: action)

        case .systemEvent(_, let message):
            SystemEventRow(message: message)

        case .error(_, let message):
            ErrorRow(message: message)
        }
    }
}

// MARK: - User Message

private struct UserMessageBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .padding(12)
                .background(.tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - Assistant Message

private struct AssistantMessageBubble: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        HStack {
            MarkdownText(text, isStreaming: isStreaming)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Thinking

private struct ThinkingRow: View {
    let preview: String

    var body: some View {
        HStack {
            DisclosureGroup {
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Tool Call

private struct ToolCallRow: View {
    let id: String
    let tool: String
    let argsSummary: String
    let outputPreview: String
    let outputByteCount: Int
    let isError: Bool
    let isDone: Bool

    @Environment(TimelineReducer.self) private var reducer
    @Environment(ToolOutputStore.self) private var toolOutputStore

    private var isExpanded: Bool {
        reducer.expandedItemIDs.contains(id)
    }

    var body: some View {
        // Special-case pseudo tools
        if tool == "__compaction" {
            SystemEventRow(message: "Context compacted")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Header: tool name + status
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            reducer.expandedItemIDs.remove(id)
                        } else {
                            reducer.expandedItemIDs.insert(id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isDone ? (isError ? "xmark.circle.fill" : "checkmark.circle.fill") : "play.circle.fill")
                            .foregroundStyle(isError ? .red : isDone ? .green : .blue)
                            .font(.caption)

                        Text(tool)
                            .font(.caption.monospaced().bold())

                        if !argsSummary.isEmpty {
                            Text(argsSummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if outputByteCount > 0 {
                            Text(formatBytes(outputByteCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                // Expanded output
                if isExpanded {
                    let fullOutput = toolOutputStore.fullOutput(for: id)
                    if !fullOutput.isEmpty {
                        ToolOutputContent(
                            output: fullOutput,
                            isError: isError
                        )
                    }
                }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                if !outputPreview.isEmpty {
                    Button("Copy Output", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = toolOutputStore.fullOutput(for: id)
                    }
                }
                Button("Copy Command", systemImage: "terminal") {
                    UIPasteboard.general.string = "\(tool): \(argsSummary)"
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Tool Output Content

/// Renders tool output with inline image detection.
private struct ToolOutputContent: View {
    let output: String
    let isError: Bool

    var body: some View {
        let images = ImageExtractor.extract(from: output)

        VStack(alignment: .leading, spacing: 8) {
            // Text output (truncated for display)
            Text(output.prefix(2000))
                .font(.caption.monospaced())
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)

            // Inline images
            ForEach(images) { image in
                ImageBlobView(base64: image.base64, mimeType: image.mimeType)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Permission Resolved

private struct PermissionResolvedBadge: View {
    let action: PermissionAction

    var body: some View {
        HStack {
            Image(systemName: action == .allow ? "checkmark.shield.fill" : "xmark.shield.fill")
            Text(action == .allow ? "Allowed" : "Denied")
                .font(.caption.bold())
        }
        .foregroundStyle(action == .allow ? .green : .red)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            (action == .allow ? Color.green : Color.red).opacity(0.1)
        )
        .clipShape(Capsule())
    }
}

// MARK: - System Event

struct SystemEventRow: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }
}

// MARK: - Error

private struct ErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
