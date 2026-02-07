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

        case .thinking(let id, let preview, let hasMore, let isDone):
            ThinkingRow(id: id, preview: preview, hasMore: hasMore, isDone: isDone)

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
        HStack(alignment: .top, spacing: 8) {
            Text("❯")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tokyoBlue)

            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tokyoFg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
        }
    }
}

// MARK: - Assistant Message

private struct AssistantMessageBubble: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("π")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tokyoPurple)

            MarkdownText(text, isStreaming: isStreaming)
                .foregroundStyle(.tokyoFg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
            Button("Copy as Markdown", systemImage: "text.document") {
                UIPasteboard.general.string = text
            }
        }
    }
}

// MARK: - Thinking

private struct ThinkingRow: View {
    let id: String
    let preview: String
    let hasMore: Bool
    var isDone: Bool = false

    @Environment(TimelineReducer.self) private var reducer
    @Environment(ToolOutputStore.self) private var toolOutputStore

    private var isExpanded: Bool {
        reducer.expandedItemIDs.contains(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard isDone else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        reducer.expandedItemIDs.remove(id)
                    } else {
                        reducer.expandedItemIDs.insert(id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isDone {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundStyle(.tokyoPurple)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.tokyoPurple)
                    }
                    Text(isDone ? "Thought" : "Thinking…")
                        .font(.subheadline)
                        .foregroundStyle(.tokyoComment)
                    Spacer()
                    if isDone {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tokyoComment)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                let fullText = toolOutputStore.fullOutput(for: id)
                let displayText = fullText.isEmpty ? preview : fullText
                ScrollView {
                    Text(displayText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoComment)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(8)
                .background(Color.tokyoBgDark)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button("Copy Thinking", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = displayText
                    }
                }
            }
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
    @Environment(ToolArgsStore.self) private var toolArgsStore

    private var isExpanded: Bool {
        reducer.expandedItemIDs.contains(id)
    }

    /// Structured args (if available) for smart rendering.
    private var args: [String: JSONValue]? {
        toolArgsStore.args(for: id)
    }

    var body: some View {
        // Special-case pseudo tools
        if tool == "__compaction" {
            SystemEventRow(message: "Context compacted")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Header: tool-specific smart formatting
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            reducer.expandedItemIDs.remove(id)
                        } else {
                            reducer.expandedItemIDs.insert(id)
                        }
                    }
                } label: {
                    toolHeader
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
            .background(Color.tokyoBgHighlight.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.tokyoComment.opacity(0.35), lineWidth: 1)
            )
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

    // MARK: - Smart Tool Header

    @ViewBuilder
    private var toolHeader: some View {
        switch tool {
        case "Bash", "bash":
            bashHeader
        case "Read", "read":
            fileToolHeader(verb: "read", icon: "doc.text")
        case "Write", "write":
            fileToolHeader(verb: "write", icon: "square.and.pencil")
        case "Edit", "edit":
            fileToolHeader(verb: "edit", icon: "pencil")
        default:
            genericHeader
        }
    }

    private var bashHeader: some View {
        HStack(spacing: 6) {
            statusIcon
            Text("$")
                .font(.caption.monospaced().bold())
                .foregroundStyle(.tokyoGreen)
            Text(bashCommand)
                .font(.caption.monospaced())
                .foregroundStyle(.tokyoFg)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer()
            trailingInfo
        }
    }

    private func fileToolHeader(verb: String, icon: String) -> some View {
        HStack(spacing: 6) {
            statusIcon
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tokyoCyan)
            Text(verb)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.tokyoCyan)
            Text(filePath)
                .font(.caption.monospaced())
                .foregroundStyle(.tokyoFgDim)
                .lineLimit(1)
            Spacer()
            trailingInfo
        }
    }

    private var genericHeader: some View {
        HStack(spacing: 6) {
            statusIcon
            Text(tool)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.tokyoCyan)
            if !argsSummary.isEmpty {
                Text(argsSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tokyoFgDim)
                    .lineLimit(1)
            }
            Spacer()
            trailingInfo
        }
    }

    private var statusIcon: some View {
        Image(systemName: isDone ? (isError ? "xmark.circle.fill" : "checkmark.circle.fill") : "play.circle.fill")
            .foregroundStyle(isError ? .tokyoRed : isDone ? .tokyoGreen : .tokyoBlue)
            .font(.caption)
    }

    private var trailingInfo: some View {
        HStack(spacing: 4) {
            if outputByteCount > 0 {
                Text(formatBytes(outputByteCount))
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tokyoComment)
        }
    }

    // MARK: - Arg Extraction

    private var bashCommand: String {
        if let cmd = args?["command"]?.stringValue {
            return String(cmd.prefix(120))
        }
        // Fall back to parsing argsSummary
        if argsSummary.hasPrefix("command: ") {
            return String(argsSummary.dropFirst(9).prefix(120))
        }
        return argsSummary
    }

    private var filePath: String {
        let raw = args?["path"]?.stringValue
            ?? args?["file_path"]?.stringValue
            ?? parseArgValue("path")
        guard let p = raw else { return argsSummary }

        var display = p.shortenedPath

        // Add line range for read
        if tool == "Read" || tool == "read" {
            let offset = args?["offset"]?.numberValue.map(Int.init)
            let limit = args?["limit"]?.numberValue.map(Int.init)
            if let offset {
                let end = limit.map { offset + $0 - 1 }
                display += ":\(offset)\(end.map { "-\($0)" } ?? "")"
            }
        }

        return display
    }

    /// Parse a value from the flat argsSummary string (fallback when structured args unavailable).
    private func parseArgValue(_ key: String) -> String? {
        let prefix = "\(key): "
        guard let range = argsSummary.range(of: prefix) else { return nil }
        let after = argsSummary[range.upperBound...]
        if let commaRange = after.range(of: ", ") {
            return String(after[..<commaRange.lowerBound])
        }
        return String(after)
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
                .foregroundStyle(isError ? .tokyoRed : .tokyoFg)
                .textSelection(.enabled)

            // Inline images
            ForEach(images) { image in
                ImageBlobView(base64: image.base64, mimeType: image.mimeType)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokyoBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Copy Output", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = output
            }
        }
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
        .foregroundStyle(action == .allow ? .tokyoGreen : .tokyoRed)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            (action == .allow ? Color.tokyoGreen : Color.tokyoRed).opacity(0.18)
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
                .foregroundStyle(.tokyoComment)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tokyoComment)
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
                .foregroundStyle(.tokyoRed)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tokyoFg)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokyoRed.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Copy Error", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message
            }
        }
    }
}
