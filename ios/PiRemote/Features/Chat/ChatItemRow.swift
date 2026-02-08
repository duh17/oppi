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
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore

    /// File path to open in RemoteFileView when tapped.
    @State private var filePathToOpen: String?
    @State private var showFileSheet = false
    /// Whether lazy output loading is in progress (evicted tool calls).
    @State private var isLoadingOutput = false

    private var isExpanded: Bool {
        reducer.expandedItemIDs.contains(id)
    }

    /// Structured args (if available) for smart rendering.
    private var args: [String: JSONValue]? {
        toolArgsStore.args(for: id)
    }

    private var isReadTool: Bool { ToolCallFormatting.isReadTool(tool) }
    private var isWriteTool: Bool { ToolCallFormatting.isWriteTool(tool) }
    private var isEditTool: Bool { ToolCallFormatting.isEditTool(tool) }
    private var toolFilePath: String? { ToolCallFormatting.filePath(from: args) }
    private var readStartLine: Int { ToolCallFormatting.readStartLine(from: args) }

    /// Session ID for file/output API calls.
    private var sessionId: String? { sessionStore.activeSessionId }

    var body: some View {
        // Special-case pseudo tools
        if tool == "__compaction" {
            SystemEventRow(message: "Context compacted")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Header: tool-specific smart formatting
                HStack(spacing: 0) {
                    // Main header area — tap to expand/collapse
                    Button {
                        expandOrLazyLoad()
                    } label: {
                        toolHeader
                    }
                    .buttonStyle(.plain)
                }

                // Expanded output — tool-specific rendering
                if isExpanded {
                    if isLoadingOutput {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading output…")
                                .font(.caption)
                                .foregroundStyle(.tokyoComment)
                        }
                        .padding(8)
                    } else {
                        expandedContent
                    }
                }
            }
            .padding(8)
            .background(Color.tokyoBgHighlight.opacity(0.75))
            .sheet(isPresented: $showFileSheet) {
                if let sessionId, let filePathToOpen {
                    RemoteFileView(sessionId: sessionId, path: filePathToOpen)
                }
            }
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
                if toolFilePath != nil, sessionId != nil {
                    Button("Open File", systemImage: "doc.text.magnifyingglass") {
                        openFile()
                    }
                }
            }
        }
    }

    // MARK: - Expand & Lazy Load

    /// Expand the tool call row. If output was evicted, lazy-load it from the
    /// server's JSONL trace before expanding.
    private func expandOrLazyLoad() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isExpanded {
                reducer.expandedItemIDs.remove(id)
                return
            }
            reducer.expandedItemIDs.insert(id)
        }

        // If output was evicted (store is empty but we know there was output),
        // lazy-load from the server trace.
        let hasOutput = toolOutputStore.fullOutput(for: id).isEmpty == false
        let hadOutput = outputByteCount > 0
        if !hasOutput && hadOutput && !isLoadingOutput {
            lazyLoadOutput()
        }
    }

    /// Fetch full tool output from the server's JSONL trace for evicted items.
    private func lazyLoadOutput() {
        guard let sessionId, let api = connection.apiClient else { return }

        isLoadingOutput = true
        Task { @MainActor in
            defer { isLoadingOutput = false }
            do {
                let (output, _) = try await api.getToolOutput(sessionId: sessionId, toolCallId: id)
                if !output.isEmpty {
                    toolOutputStore.append(output, to: id)
                }
            } catch {
                // Non-fatal — user just sees empty expanded output
            }
        }
    }

    /// Open the tool's file path in RemoteFileView.
    private func openFile() {
        guard let path = toolFilePath else { return }
        filePathToOpen = path
        showFileSheet = true
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        let fullOutput = toolOutputStore.fullOutput(for: id)

        if isEditTool, !isError,
           let oldText = args?["oldText"]?.stringValue,
           let newText = args?["newText"]?.stringValue {
            // Edit tool: show diff
            DiffContentView(oldText: oldText, newText: newText, filePath: toolFilePath)
        } else if isWriteTool, !isError, let content = args?["content"]?.stringValue {
            // Write tool: show written content
            FileContentView(content: content, filePath: toolFilePath)
        } else if isReadTool, !isError, !fullOutput.isEmpty {
            // Read tool: show file content or image
            if !ImageExtractor.extract(from: fullOutput).isEmpty {
                // Image file — render via ToolOutputContent (handles data URIs)
                ToolOutputContent(output: fullOutput, isError: false)
            } else {
                FileContentView(
                    content: fullOutput,
                    filePath: toolFilePath,
                    startLine: readStartLine
                )
            }
        } else if !fullOutput.isEmpty {
            // Everything else: plain output
            ToolOutputContent(output: fullOutput, isError: isError)
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

            // File path — tappable to open in RemoteFileView
            if isDone, toolFilePath != nil, sessionId != nil {
                Button {
                    openFile()
                } label: {
                    Text(filePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoBlue)
                        .underline(color: .tokyoBlue.opacity(0.5))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else {
                Text(filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tokyoFgDim)
                    .lineLimit(1)
            }
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
                Text(ToolCallFormatting.formatBytes(outputByteCount))
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tokyoComment)
        }
    }

    // MARK: - Arg Extraction (delegates to ToolCallFormatting)

    private var bashCommand: String {
        ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
    }

    private var filePath: String {
        ToolCallFormatting.displayFilePath(tool: tool, args: args, argsSummary: argsSummary)
    }
}

// MARK: - Tool Output Content

/// Renders tool output with inline image detection and ANSI color support.
///
/// When image data URIs are detected, they are stripped from the text display
/// and rendered as inline images below the text. If the output is purely
/// image data (no remaining text), the text portion is suppressed entirely.
private struct ToolOutputContent: View {
    let output: String
    let isError: Bool

    var body: some View {
        let images = ImageExtractor.extract(from: output)

        // Strip data URIs from text display to avoid showing raw base64
        let strippedText: String = {
            guard !images.isEmpty else { return output }
            var text = output
            // Remove in reverse order to preserve range validity
            for image in images.reversed() {
                text.removeSubrange(image.range)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        VStack(alignment: .leading, spacing: 8) {
            // Text output (only if there's non-image content)
            if !strippedText.isEmpty {
                let displayText = String(strippedText.prefix(2000))
                if isError {
                    Text(ANSIParser.strip(displayText))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoRed)
                        .textSelection(.enabled)
                } else {
                    Text(ANSIParser.attributedString(from: displayText))
                        .textSelection(.enabled)
                }
            }

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
            if !strippedText.isEmpty {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = strippedText
                }
            }
            if !images.isEmpty {
                Button("Copy Image", systemImage: "photo") {
                    if let first = images.first,
                       let data = Data(base64Encoded: first.base64, options: .ignoreUnknownCharacters),
                       let uiImage = UIImage(data: data) {
                        UIPasteboard.general.image = uiImage
                    }
                }
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
