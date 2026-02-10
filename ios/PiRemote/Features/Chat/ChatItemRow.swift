import SwiftUI

/// Identifies a file to open in a sheet. Uses `.sheet(item:)` pattern
/// to avoid the stale-capture bug with `.sheet(isPresented:)`.
struct FileToOpen: Identifiable {
    let sessionId: String
    let path: String
    var id: String { "\(sessionId)/\(path)" }
}

/// Renders a single `ChatItem` in the chat timeline.
///
/// Designed for `LazyVStack` — lightweight, stable ID, no expensive layout.
struct ChatItemRow: View {
    let item: ChatItem
    var isStreaming: Bool = false
    var sessionId: String?
    var onFork: ((String) -> Void)?
    var onOpenFile: ((FileToOpen) -> Void)?

    /// Server-backed user/assistant messages can be forked.
    private var isForkable: Bool {
        guard UUID(uuidString: item.id) == nil else { return false }
        switch item {
        case .userMessage, .assistantMessage: return true
        default: return false
        }
    }

    private var forkAction: (() -> Void)? {
        guard isForkable, let onFork else { return nil }
        let id = item.id
        return { onFork(id) }
    }

    var body: some View {
        switch item {
        case .userMessage(_, let text, let images, _):
            UserMessageBubble(text: text, images: images, onFork: forkAction)

        case .assistantMessage(let id, let text, _):
            AssistantMessageBubble(id: id, text: text, isStreaming: isStreaming, onFork: forkAction)

        case .audioClip(let id, let title, let fileURL, _):
            AudioClipRow(id: id, title: title, fileURL: fileURL)

        case .thinking(let id, let preview, let hasMore, let isDone):
            ThinkingRow(id: id, preview: preview, hasMore: hasMore, isDone: isDone)

        case .toolCall(let id, let tool, let args, let preview, let bytes, let isError, let isDone):
            ToolCallRow(
                id: id, tool: tool, argsSummary: args,
                outputPreview: preview, outputByteCount: bytes,
                isError: isError, isDone: isDone,
                sessionId: sessionId,
                onOpenFile: onOpenFile
            )

        case .permission(let request):
            PermissionResolvedRow(
                outcome: .expired,
                tool: request.tool,
                summary: request.displaySummary
            )

        case .permissionResolved(_, let outcome, let tool, let summary):
            PermissionResolvedRow(outcome: outcome, tool: tool, summary: summary)

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
    let images: [ImageAttachment]
    var onFork: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, attachment in
                            AsyncImageThumbnail(attachment: attachment)
                        }
                    }
                    .padding(.leading, 24)
                }
            }

            if !text.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("❯")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.tokyoBlue)

                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tokyoFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !images.isEmpty {
                Text("❯")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tokyoBlue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            if !text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = text
                }
            }
            if let onFork {
                Button("Fork from here", systemImage: "arrow.triangle.branch") {
                    onFork()
                }
            }
        }
    }
}

/// Decodes a base64 image attachment off the main thread.
private struct AsyncImageThumbnail: View {
    let attachment: ImageAttachment

    @State private var decoded: UIImage?

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.tokyoBgHighlight
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tokyoComment.opacity(0.3), lineWidth: 1)
        )
        .task(id: attachment.data.prefix(32)) {
            decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: attachment.data) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
        }
    }
}

// MARK: - Assistant Message

private struct AssistantMessageBubble: View {
    let id: String
    let text: String
    var isStreaming: Bool = false
    var onFork: (() -> Void)?

    /// Debounced cursor visibility — prevents the cursor from flashing
    /// during rapid text→tool→text sequences where isStreaming toggles
    /// on/off within milliseconds.
    @State private var showCursor = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("π")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tokyoPurple)

            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(text, isStreaming: isStreaming)
                    .foregroundStyle(.tokyoFg)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showCursor {
                    StreamingCursor()
                }
            }
        }
        .task(id: isStreaming) {
            if isStreaming {
                // Wait 150ms before showing cursor — if isStreaming toggles
                // off before this fires (rapid tool call), the task is
                // cancelled and the cursor never appears. Prevents flashing.
                try? await Task.sleep(for: .milliseconds(150))
                showCursor = true
            } else {
                showCursor = false
            }
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
            if let onFork {
                Button("Fork from here", systemImage: "arrow.triangle.branch") {
                    onFork()
                }
            }
        }
    }
}

// MARK: - Audio Play Button

private enum AudioButtonState {
    case idle, loading, playing
}

private struct AudioPlayButton: View {
    let state: AudioButtonState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch state {
                case .idle:
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.tokyoComment)
                case .loading:
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.tokyoPurple)
                case .playing:
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundStyle(.tokyoPurple)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

// MARK: - Audio Clip Row

private struct AudioClipRow: View {
    let id: String
    let title: String
    let fileURL: URL

    @Environment(AudioPlayerService.self) private var audioPlayer

    private var state: AudioButtonState {
        if audioPlayer.loadingItemID == id { return .loading }
        if audioPlayer.playingItemID == id { return .playing }
        return .idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.tokyoPurple)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.tokyoFg)
                Text(fileURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
                    .lineLimit(1)
            }

            Spacer()

            AudioPlayButton(state: state) {
                audioPlayer.toggleFilePlayback(fileURL: fileURL, itemID: id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.tokyoBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Streaming Cursor

/// Pulsing block cursor indicating the assistant is still generating.
///
/// Uses explicit `withAnimation` in `onAppear` instead of an `.animation`
/// modifier. The modifier form adds a trait key that `ForEachState.forEachItem`
/// must walk for ALL items in the LazyVStack, not just visible ones.
private struct StreamingCursor: View {
    @State private var isVisible = true

    var body: some View {
        Rectangle()
            .fill(Color.tokyoPurple)
            .frame(width: 8, height: 14)
            .opacity(isVisible ? 0.8 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isVisible = false
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
                guard isDone else { return }
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
    var sessionId: String?
    var onOpenFile: ((FileToOpen) -> Void)?

    @Environment(TimelineReducer.self) private var reducer
    @Environment(ToolOutputStore.self) private var toolOutputStore
    @Environment(ToolArgsStore.self) private var toolArgsStore
    @Environment(ServerConnection.self) private var connection
    @Environment(\.theme) private var theme

    @State private var isLoadingOutput = false

    private var isExpanded: Bool { reducer.expandedItemIDs.contains(id) }
    private var args: [String: JSONValue]? { toolArgsStore.args(for: id) }
    private var toolFilePath: String? { ToolCallFormatting.filePath(from: args) }
    private var readStartLine: Int { ToolCallFormatting.readStartLine(from: args) }
    private var normalizedTool: String { ToolCallFormatting.normalized(tool) }
    private var bashRawCommand: String? {
        args?["command"]?.stringValue ?? ToolCallFormatting.parseArgValue("command", from: argsSummary)
    }
    private var expandedBashCommandText: String? {
        guard normalizedTool == "bash" else { return nil }
        if let bashRawCommand, !bashRawCommand.isEmpty {
            return bashRawCommand
        }
        let fallback = bashCommand
        return fallback.isEmpty ? nil : fallback
    }
    private var commandClipboardText: String {
        if normalizedTool == "bash", let bashRawCommand {
            return bashRawCommand
        }
        if let args, !args.isEmpty {
            return args
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.summary())" }
                .joined(separator: ", ")
        }
        if !argsSummary.isEmpty {
            return argsSummary
        }
        return tool
    }

    private func copyCommandToClipboard() {
        UIPasteboard.general.string = commandClipboardText
    }

    private func copyOutputToClipboard(_ output: String) {
        UIPasteboard.general.string = output
    }

    /// Background + border colors based on tool execution state.
    private var stateBackground: Color {
        if !isDone { return Color.tokyoBgHighlight.opacity(0.75) }
        return isError ? Color.tokyoRed.opacity(0.08) : Color.tokyoGreen.opacity(0.06)
    }

    private var stateBorder: Color {
        if !isDone { return Color.tokyoBlue.opacity(0.25) }
        return isError ? Color.tokyoRed.opacity(0.25) : Color.tokyoComment.opacity(0.2)
    }

    var body: some View {
        if tool == "__compaction" {
            SystemEventRow(message: "Context compacted")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { expandOrLazyLoad() } label: { toolHeader }
                    .buttonStyle(.plain)

                if !isExpanded && isDone { collapsedPreview }

                if isExpanded {
                    if isLoadingOutput {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading output…").font(.caption).foregroundStyle(.tokyoComment)
                        }
                        .padding(8)
                    } else {
                        expandedContent
                    }
                }
            }
            .padding(8)
            .background(stateBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(stateBorder, lineWidth: 1)
            )
            .contextMenu {
                if !outputPreview.isEmpty {
                    Button("Copy Output", systemImage: "doc.on.doc") {
                        copyOutputToClipboard(toolOutputStore.fullOutput(for: id))
                    }
                }
                Button("Copy Command", systemImage: "terminal") {
                    copyCommandToClipboard()
                }
                if toolFilePath != nil, sessionId != nil {
                    Button("Open File", systemImage: "doc.text.magnifyingglass") { openFile() }
                }
            }
        }
    }

    // MARK: - Expand & Lazy Load

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        let mutation = {
            if expanded {
                reducer.expandedItemIDs.insert(id)
            } else {
                reducer.expandedItemIDs.remove(id)
            }
        }

        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                mutation()
            }
        } else {
            withTransaction(Transaction(animation: nil)) {
                mutation()
            }
        }
    }

    private func expandOrLazyLoad() {
        if isExpanded {
            // Collapsing large tool output can trigger a visible bounce if the
            // height change is animated through UIKit-hosted layout.
            setExpanded(false, animated: false)
            return
        }

        setExpanded(true, animated: true)

        let hasOutput = !toolOutputStore.fullOutput(for: id).isEmpty
        if !hasOutput && outputByteCount > 0 && !isLoadingOutput {
            lazyLoadOutput()
        }
    }

    private func lazyLoadOutput() {
        guard let sessionId, let api = connection.apiClient else { return }
        isLoadingOutput = true
        Task { @MainActor in
            defer { isLoadingOutput = false }
            if let (output, _) = try? await api.getToolOutput(sessionId: sessionId, toolCallId: id),
               !output.isEmpty {
                toolOutputStore.append(output, to: id)
            }
        }
    }

    private func openFile() {
        guard let path = toolFilePath, let sid = sessionId else { return }
        onOpenFile?(FileToOpen(sessionId: sid, path: path))
    }

    // MARK: - Tool Header

    /// Composable tool header — all headers follow the same shell:
    /// `statusIcon | [tool-specific content] | Spacer | trailingInfo`
    @ViewBuilder
    private var toolHeader: some View {
        HStack(spacing: 6) {
            statusIcon
            toolHeaderContent
            Spacer()
            trailingInfo
        }
    }

    /// Tool-specific middle content for the header.
    @ViewBuilder
    private var toolHeaderContent: some View {
        switch normalizedTool {
        case "bash":
            Text("$").font(.caption.monospaced().bold()).foregroundStyle(.tokyoGreen)
            if isExpanded {
                Text("bash")
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.text.tertiary)
                    .lineLimit(1)
            } else {
                Text(bashCommand)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tokyoFg)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

        case "read", "write", "edit":
            let (icon, verb) = fileToolInfo
            Image(systemName: icon).font(.caption).foregroundStyle(.tokyoCyan)
            Text(verb).font(.caption.monospaced().bold()).foregroundStyle(.tokyoCyan)
            filePathLabel

        case "grep":
            Text("grep").font(.caption.monospaced().bold()).foregroundStyle(.tokyoCyan)
            if let p = args?["pattern"]?.stringValue {
                Text("/\(p)/").font(.caption.monospaced()).foregroundStyle(.tokyoPurple).lineLimit(1)
            }
            if let p = args?["path"]?.stringValue {
                Text(p.shortenedPath).font(.caption.monospaced()).foregroundStyle(.tokyoFgDim).lineLimit(1)
            }
            if let g = args?["glob"]?.stringValue {
                Text("(\(g))").font(.caption2.monospaced()).foregroundStyle(.tokyoComment).lineLimit(1)
            }

        case "find":
            Text("find").font(.caption.monospaced().bold()).foregroundStyle(.tokyoCyan)
            if let p = args?["pattern"]?.stringValue {
                Text(p).font(.caption.monospaced()).foregroundStyle(.tokyoPurple).lineLimit(1)
            }
            if let p = args?["path"]?.stringValue {
                Text("in \(p.shortenedPath)").font(.caption2.monospaced()).foregroundStyle(.tokyoFgDim).lineLimit(1)
            }

        case "ls":
            Text("ls").font(.caption.monospaced().bold()).foregroundStyle(.tokyoCyan)
            Text((args?["path"]?.stringValue ?? ".").shortenedPath)
                .font(.caption.monospaced()).foregroundStyle(.tokyoFgDim).lineLimit(1)

        case "todo":
            Image(systemName: "checklist")
                .font(.caption)
                .foregroundStyle(.tokyoPurple)
            Text("todo")
                .font(.caption.monospaced().bold())
                .foregroundStyle(.tokyoPurple)
            if !todoSummary.isEmpty {
                Text(todoSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tokyoFgDim)
                    .lineLimit(1)
            }

        default:
            Text(tool).font(.caption.monospaced().bold()).foregroundStyle(.tokyoCyan)
            if !argsSummary.isEmpty {
                Text(argsSummary).font(.caption.monospaced()).foregroundStyle(.tokyoFgDim).lineLimit(1)
            }
        }
    }

    /// File tool icon + verb for read/write/edit.
    private var fileToolInfo: (icon: String, verb: String) {
        switch normalizedTool {
        case "read": return ("doc.text", "read")
        case "write": return ("square.and.pencil", "write")
        case "edit": return ("pencil", "edit")
        default: return ("doc", tool)
        }
    }

    /// Tappable file path (when done + available) or plain text.
    @ViewBuilder
    private var filePathLabel: some View {
        let display = ToolCallFormatting.displayFilePath(tool: tool, args: args, argsSummary: argsSummary)
        if isDone, toolFilePath != nil, sessionId != nil {
            Button { openFile() } label: {
                Text(display)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tokyoBlue)
                    .underline(color: .tokyoBlue.opacity(0.5))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(display).font(.caption.monospaced()).foregroundStyle(.tokyoFgDim).lineLimit(1)
        }
    }

    private var statusIcon: some View {
        Image(systemName: isDone ? (isError ? "xmark.circle.fill" : "checkmark.circle.fill") : "play.circle.fill")
            .foregroundStyle(isError ? .tokyoRed : isDone ? .tokyoGreen : .tokyoBlue)
            .font(.caption)
    }

    private var trailingInfo: some View {
        HStack(spacing: 4) {
            if normalizedTool == "edit",
               let stats = ToolCallFormatting.editDiffStats(from: args) {
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
                if stats.added == 0 && stats.removed == 0 {
                    Text("modified")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tokyoComment)
                }
            }

            if outputByteCount > 0 {
                Text(ToolCallFormatting.formatBytes(outputByteCount))
                    .font(.caption2).foregroundStyle(.tokyoComment)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.tokyoComment)
        }
    }

    private var bashCommand: String {
        ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
    }

    private var todoSummary: String {
        ToolCallFormatting.todoSummary(args: args, argsSummary: argsSummary)
    }

    // MARK: - Collapsed Preview

    @ViewBuilder
    private var collapsedPreview: some View {
        switch normalizedTool {
        case "bash":
            previewLines(ToolCallFormatting.tailLines(outputPreview))

        case "read":
            if !isError { previewLines(ToolCallFormatting.headLines(outputPreview)) }

        case "edit":
            EmptyView()

        default:
            if isError, !outputPreview.isEmpty {
                Text(String(outputPreview.prefix(120)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tokyoRed)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Shared preview text for bash (tail) and read (head) collapsed previews.
    @ViewBuilder
    private func previewLines(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(.tokyoFgDim)
                .lineLimit(3)
                .padding(.horizontal, 4)
        }
    }

    /// +N/-N change stats for edit tool.
    @ViewBuilder
    private var editStats: some View {
        if let stats = ToolCallFormatting.editDiffStats(from: args) {
            HStack(spacing: 8) {
                if stats.added > 0 {
                    Text("+\(stats.added)").font(.caption2.monospaced().bold()).foregroundStyle(.tokyoGreen)
                }
                if stats.removed > 0 {
                    Text("-\(stats.removed)").font(.caption2.monospaced().bold()).foregroundStyle(.tokyoRed)
                }
                if stats.added == 0 && stats.removed == 0 {
                    Text("modified").font(.caption2.monospaced()).foregroundStyle(.tokyoComment)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Expanded Content

    /// Full bash command shown when tool call is expanded.
    @ViewBuilder
    private var expandedBashCommand: some View {
        if let cmd = expandedBashCommandText {
            BashCommandBlockView(command: cmd) {
                copyCommandToClipboard()
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        let fullOutput = toolOutputStore.fullOutput(for: id)

        expandedBashCommand

        if ToolCallFormatting.isEditTool(tool), !isError,
           let oldText = args?["oldText"]?.stringValue,
           let newText = args?["newText"]?.stringValue {
            AsyncDiffView(oldText: oldText, newText: newText, filePath: toolFilePath, showHeader: false)
        } else if ToolCallFormatting.isWriteTool(tool), !isError, let content = args?["content"]?.stringValue {
            FileContentView(content: content, filePath: toolFilePath)
        } else if ToolCallFormatting.isReadTool(tool), !isError, !fullOutput.isEmpty {
            AsyncToolOutput(output: fullOutput, isError: false, filePath: toolFilePath, startLine: readStartLine)
                .onTapGesture(count: 2) {
                    copyOutputToClipboard(fullOutput)
                }
        } else if ToolCallFormatting.isTodoTool(tool), !isError, !fullOutput.isEmpty {
            TodoToolOutputView(output: fullOutput)
                .onTapGesture(count: 2) {
                    copyOutputToClipboard(fullOutput)
                }
        } else if !fullOutput.isEmpty {
            AsyncToolOutput(output: fullOutput, isError: isError)
                .onTapGesture(count: 2) {
                    copyOutputToClipboard(fullOutput)
                }
        }
    }
}

private struct BashCommandBlockView: View {
    let command: String
    let onCopy: () -> Void

    @Environment(\.theme) private var theme
    @State private var highlighted: AttributedString?

    private var renderCommand: String {
        String(command.prefix(6_000))
    }

    private var highlightKey: String {
        let prefix = String(renderCommand.prefix(64))
        let suffix = String(renderCommand.suffix(64))
        return "\(renderCommand.utf8.count):\(prefix):\(suffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let highlighted {
                Text(highlighted)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(renderCommand)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(theme.bg.highlight.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.accent.blue.opacity(0.35), lineWidth: 1)
        )
        .task(id: highlightKey) {
            let source = renderCommand
            highlighted = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(source, language: .shell)
            }.value
        }
        .onTapGesture(count: 2) {
            onCopy()
        }
        .contextMenu {
            Button("Copy Command", systemImage: "terminal") {
                onCopy()
            }
        }
    }
}

// MARK: - Permission Resolved

struct PermissionResolvedRow: View {
    let outcome: PermissionOutcome
    let tool: String
    let summary: String

    private var icon: String {
        switch outcome {
        case .allowed: return "checkmark.shield.fill"
        case .denied: return "xmark.shield.fill"
        case .expired: return "clock.badge.xmark"
        case .cancelled: return "xmark.circle"
        }
    }

    private var color: Color {
        switch outcome {
        case .allowed: return .tokyoGreen
        case .denied, .cancelled: return .tokyoRed
        case .expired: return .tokyoComment
        }
    }

    private var label: String {
        switch outcome {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .expired: return "Expired"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text("\(label): \(tool)")
                .font(.caption.monospaced().bold())
                .foregroundStyle(color)
            Text(truncatedSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.tokyoFgDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Copy Command", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = "\(tool): \(summary)"
            }
        }
    }

    private var truncatedSummary: String {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 60 { return cleaned }
        return String(cleaned.prefix(59)) + "…"
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


