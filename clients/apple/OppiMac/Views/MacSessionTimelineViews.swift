import SwiftUI

struct MacSessionTimelineView: View {
    let isLoading: Bool
    let lastError: String?
    let items: [ChatItem]
    var sessionID: String? = nil
    var workspaceID: String? = nil
    var toolOutputStore: ToolOutputStore? = nil
    var loadFullToolOutput: ((String) async -> Void)? = nil
    var bottomContentInset: CGFloat = 0
    var isBusy: Bool = false
    let store: MacSessionTraceStore
    var sessionFocus: FocusState<KeybindingFocus?>.Binding

    @State private var fontPreferenceRevision = 0

    var body: some View {
        let _ = fontPreferenceRevision
        let emptyFailure = MacTimelineFailurePaint.message(
            status: store.session?.status,
            lastError: lastError
        )
        Group {
            if isLoading && items.isEmpty {
                ProgressView("Loading timeline…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = emptyFailure, items.isEmpty {
                ContentUnavailableView {
                    Label("Could not load timeline", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await store.loadSelectedFromLocalConfig() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.timeline.retry")
                }
            } else if items.isEmpty && !isBusy {
                ContentUnavailableView(
                    "No timeline events",
                    systemImage: "text.bubble",
                    description: Text("This session has no trace rows yet.")
                )
            } else {
                MacSessionTimelineScrollView(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    items: items,
                    toolOutputStore: toolOutputStore,
                    loadFullToolOutput: loadFullToolOutput,
                    bottomContentInset: bottomContentInset,
                    isBusy: isBusy,
                    store: store,
                    sessionFocus: sessionFocus
                )
            }
        }
        .foregroundStyle(.themeFg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScrollSurface()
        .onReceive(NotificationCenter.default.publisher(
            for: FontPreferenceStore.didChangeNotification
        )) { _ in
            fontPreferenceRevision &+= 1
        }
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            MacMarkdownStreamingParserStore.shared.retain(itemIDs: Set(ids))
        }
    }
}

/// Timeline loading can fail before the transport supplies a detailed error.
/// The selected session remains authoritative, so an `.error` status must not
/// fall through to the ordinary empty-history message.
enum MacTimelineFailurePaint: Sendable {
    static let fallbackMessage = "This session ended with an error before timeline details became available."

    static func message(status: SessionStatus?, lastError: String?) -> String? {
        if let lastError {
            return lastError
        }
        return status == .error ? fallbackMessage : nil
    }
}

enum MacTimelineProseRole: Equatable, Sendable {
    case user
    case assistant
}

enum MacTimelineProsePaint: Sendable {
    enum RowAlignment: Equatable, Sendable {
        case leading
        case trailing
    }

    static let readableMaximumWidth: CGFloat = 720
    static let userLeadingInset: CGFloat = 0

    static func alignment(for role: MacTimelineProseRole) -> RowAlignment {
        switch role {
        case .user: .leading
        case .assistant: .leading
        }
    }
}

private struct MacSessionTimelineScrollSnapshot: Equatable {
    var contentHeight: CGFloat
    var offsetY: CGFloat
    var viewportHeight: CGFloat
    var viewportWidth: CGFloat
}

private struct MacSessionTimelineScrollView: View {
    let sessionID: String?
    let workspaceID: String?
    let items: [ChatItem]
    var toolOutputStore: ToolOutputStore? = nil
    var loadFullToolOutput: ((String) async -> Void)? = nil
    var bottomContentInset: CGFloat = 0
    var isBusy: Bool = false
    let store: MacSessionTraceStore
    var sessionFocus: FocusState<KeybindingFocus?>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAttachedToLatestRow = true
    @State private var lastContentHeight: CGFloat = 0
    @State private var lastViewportWidth: CGFloat = 0
    @State private var scrollPhase: ScrollPhase = .idle

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        ChatItemSummaryRow(
                            item: item,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            toolOutputStore: toolOutputStore,
                            loadFullToolOutput: loadFullToolOutput,
                            store: store
                        )
                            .id(item.id)
                    }
                    if isBusy {
                        MacWorkingIndicatorRow()
                            .id(MacWorkingIndicatorRow.rowID)
                    }
                    Color.clear
                        .frame(height: bottomContentInset)
                        .id(MacSessionTimelineAutoFollow.latestAnchorID)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .defaultScrollAnchor(isAttachedToLatestRow ? .bottom : nil)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .background {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    .focusable(true)
                    .focused(sessionFocus, equals: .timeline)
                    .focusEffectDisabled(true)
                    .onKeyPress { press in
                        handleTimelineKeyPress(press)
                    }
            }
            .onScrollGeometryChange(for: MacSessionTimelineScrollSnapshot.self) { geometry in
                MacSessionTimelineScrollSnapshot(
                    contentHeight: geometry.contentSize.height,
                    offsetY: geometry.contentOffset.y,
                    viewportHeight: geometry.containerSize.height,
                    viewportWidth: geometry.containerSize.width
                )
            } action: { _, snapshot in
                let contentHeightIncreased = MacSessionTimelineAutoFollow.contentHeightIncreasedFromDocumentGrowth(
                    previousHeight: lastContentHeight,
                    nextHeight: snapshot.contentHeight,
                    previousViewportWidth: lastViewportWidth,
                    nextViewportWidth: snapshot.viewportWidth
                )
                let isNearBottom = MacSessionTimelineAutoFollow.isNearBottom(
                    contentHeight: snapshot.contentHeight,
                    offsetY: snapshot.offsetY,
                    viewportHeight: snapshot.viewportHeight
                )
                let nextAttachment = MacSessionTimelineAutoFollow.isAttachedAfterGeometryChange(
                    wasAttached: isAttachedToLatestRow,
                    isNearBottom: isNearBottom,
                    scrollPhase: scrollPhase
                )
                if !MacSessionTimelineAutoFollow.measurementsMatch(lastContentHeight, snapshot.contentHeight) {
                    lastContentHeight = snapshot.contentHeight
                }
                if !MacSessionTimelineAutoFollow.measurementsMatch(lastViewportWidth, snapshot.viewportWidth) {
                    lastViewportWidth = snapshot.viewportWidth
                }
                if isAttachedToLatestRow != nextAttachment {
                    isAttachedToLatestRow = nextAttachment
                }
                if MacSessionTimelineAutoFollow.shouldScrollAfterContentGrowth(
                    isAttached: nextAttachment,
                    isNearBottom: isNearBottom,
                    contentHeightIncreased: contentHeightIncreased
                ) {
                    scrollToLatestIfAttached(proxy: proxy, animated: false)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
            }
            .onChange(of: sessionID) { _, _ in
                isAttachedToLatestRow = true
                lastContentHeight = 0
                lastViewportWidth = 0
                scrollToLatestIfAttached(proxy: proxy, animated: false)
            }
            .onChange(of: store.scrollTargetID) { _, targetID in
                guard let targetID else { return }
                scrollToOutlineTarget(proxy: proxy, targetID: targetID, items: items)
            }
            .onAppear {
                guard let targetID = store.scrollTargetID else { return }
                scrollToOutlineTarget(proxy: proxy, targetID: targetID, items: items)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAttachedToLatestRow {
                    Button {
                        isAttachedToLatestRow = true
                        scrollToLatestIfAttached(proxy: proxy, animated: true)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.trailing, 16)
                    .padding(.bottom, bottomContentInset + 12)
                    .accessibilityIdentifier("mac.timeline.jumpToLatest")
                    .help("Jump to latest activity")
                }
            }
        }
    }

    private func scrollToOutlineTarget(
        proxy: ScrollViewProxy,
        targetID: String,
        items: [ChatItem]
    ) {
        isAttachedToLatestRow = MacSessionTimelineAutoFollow.shouldAttachToLatestAfterJump(
            targetID: targetID,
            latestItemID: items.last?.id
        )
        if let animation = MacSessionTimelineAutoFollow.scrollAnimation(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        } else {
            proxy.scrollTo(targetID, anchor: .center)
        }
        store.clearScrollTarget()
    }

    private func handleTimelineKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard sessionFocus.wrappedValue == .timeline else { return .ignored }
        guard let chord = KeybindingEventMap.chord(
            characters: press.characters,
            isUpArrow: press.key == .upArrow,
            isDownArrow: press.key == .downArrow,
            isLeftArrow: press.key == .leftArrow,
            isRightArrow: press.key == .rightArrow,
            isReturn: press.key == .return,
            isEscape: press.key == .escape,
            isTab: press.key == .tab,
            command: press.modifiers.contains(.command),
            shift: press.modifiers.contains(.shift),
            option: press.modifiers.contains(.option),
            control: press.modifiers.contains(.control)
        ) else {
            return .ignored
        }
        let action = store.applyKeybinding(chord)
        return MacTimelineKeybinding.consumes(action) ? .handled : .ignored
    }

    private func scrollToLatestIfAttached(proxy: ScrollViewProxy, animated: Bool) {
        guard MacSessionTimelineAutoFollow.shouldScrollToLatestRow(isAttached: isAttachedToLatestRow) else { return }
        if animated,
           let animation = MacSessionTimelineAutoFollow.scrollAnimation(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                proxy.scrollTo(MacSessionTimelineAutoFollow.latestAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(MacSessionTimelineAutoFollow.latestAnchorID, anchor: .bottom)
        }
    }
}

private struct ChatItemSummaryRow: View {
    let item: ChatItem
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var toolOutputStore: ToolOutputStore? = nil
    var loadFullToolOutput: ((String) async -> Void)? = nil
    let store: MacSessionTraceStore
    @Environment(\.theme) private var theme

    private var worktreeId: String? { store.session?.worktreeId }

    var body: some View {
        switch item {
        case .userMessage(let id, let text, let images, let timestamp):
            MarkdownTimelineBubble(
                role: .user,
                title: "You",
                subtitle: timestamp.relativeString(),
                text: text,
                images: images,
                itemID: id,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        case .assistantMessage(let id, let text, let timestamp):
            MarkdownTimelineBubble(
                role: .assistant,
                title: "Assistant",
                subtitle: timestamp.relativeString(),
                text: text,
                itemID: id,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        case .audioClip(_, let title, _, let timestamp):
            TimelineBubble(
                title: "Audio",
                subtitle: timestamp.relativeString(),
                text: title,
                fill: theme.accent.purple.opacity(0.12)
            )
        case .thinking(let id, let preview, let hasMore, let isDone):
            ThinkingTimelineBubble(
                itemID: id,
                preview: preview,
                hasMore: hasMore,
                isDone: isDone,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        case .toolCall(let id, let tool, let argsSummary, let outputPreview, let outputByteCount, let isError, let isDone):
            ToolTimelineBubble(
                itemID: id,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                outputByteCount: outputByteCount,
                isError: isError,
                isDone: isDone,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                toolOutputStore: toolOutputStore,
                loadFullToolOutput: loadFullToolOutput,
                store: store
            )
        case .systemEvent(_, let message):
            MacSystemTimelineStrip(message: message, style: .informational)
        case .cacheMiss(_, let message):
            MacSystemTimelineStrip(message: message, style: .warning)
        case .customEvent(_, let message, let presentation):
            TimelineBubble(
                title: presentation.title,
                subtitle: presentation.subtitle,
                text: message,
                fill: theme.bg.secondary
            )
        case .error(_, let message):
            TimelineBubble(
                title: "Error",
                subtitle: nil,
                text: message,
                fill: theme.accent.red.opacity(0.12)
            )
        }
    }

}

/// Match the iOS information hierarchy for low-priority lifecycle events:
/// these are centered captions on the timeline surface, not message cards.
private struct MacSystemTimelineStrip: View {
    enum Style {
        case informational
        case warning
    }

    let message: String
    let style: Style

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .frame(width: 13, height: 13)
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(ThemeShapeStyle(role: foregroundRole))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }

    private var symbolName: String {
        switch style {
        case .informational: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var foregroundRole: ThemeShapeStyle.Role {
        switch style {
        case .informational: .comment
        case .warning: .orange
        }
    }
}

enum MacToolTimelineChrome {
    static let compactActionTargetSize: CGFloat = 24

    struct FileTitleCandidates: Equatable, Sendable {
        let full: String
        let breadcrumb: String
        let fileName: String
    }

    struct TrailingPresentation: Equatable, Sendable {
        let added: Int?
        let removed: Int?
        let segments: [StyledSegment]?
        let text: String?

        var accessibilityText: String? {
            if let added, let removed {
                if added == 0, removed == 0 { return "modified" }
                return [
                    added > 0 ? "+\(added)" : nil,
                    removed > 0 ? "-\(removed)" : nil,
                ]
                .compactMap { $0 }
                .joined(separator: " ")
            }
            if let segments {
                return segments.map(\.text).joined()
            }
            return text
        }
    }

    static func displayTitle(tool: String) -> String {
        let normalized = ToolCallFormatting.normalized(tool)
        return normalized.isEmpty ? tool : normalized
    }

    /// Compact single-line header detail for accessibility and help. Visible
    /// file rows choose among full, breadcrumb, and filename at paint time.
    static func collapsedHeaderDetail(
        tool: String,
        args: [String: JSONValue]? = nil,
        argsSummary: String
    ) -> String? {
        if ToolCallFormatting.isBashTool(tool) {
            return nil
        }
        if let compact = ToolCallFormatting.compactReadDisplayTitle(
            tool: tool,
            args: args,
            argsSummary: argsSummary
        ) {
            return compact.isEmpty ? nil : compact
        }
        if ToolCallFormatting.isReadTool(tool)
            || ToolCallFormatting.isWriteTool(tool)
            || ToolCallFormatting.isEditTool(tool) {
            let full = ToolCallFormatting.displayFilePath(
                tool: tool,
                args: args,
                argsSummary: argsSummary
            )
            return full.isEmpty ? nil : full
        }
        let line = singleLine(argsSummary)
        return line.isEmpty ? nil : line
    }

    /// iOS uses the built-in tool glyph as the tool name and gives the title
    /// line to the command/path. Keep that same information hierarchy on Mac.
    static func headerTitle(
        tool: String,
        args: [String: JSONValue]? = nil,
        argsSummary: String,
        details: JSONValue? = nil,
        isExpanded: Bool,
        isVoicePresentationResult: Bool = false
    ) -> String {
        let normalized = ToolCallFormatting.normalized(tool)
        if isVoicePresentationResult {
            return "Voice message"
        }
        if ToolCallFormatting.isBashTool(normalized) {
            if isExpanded { return " " }
            let command = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
            let compact = singleLine(command)
            return compact.isEmpty ? "bash" : compact
        }

        if let titles = fileTitleCandidates(
            tool: normalized,
            args: args,
            argsSummary: argsSummary,
            isExpanded: isExpanded
        ) {
            return titles.full
        }

        if normalized == "ask" {
            return ToolCallFormatting.askCollapsedTitle(
                args: args,
                details: details,
                argsSummary: argsSummary
            )
        }

        let detail = singleLine(argsSummary)
        let name = displayTitle(tool: tool)
        let title = detail.isEmpty ? name : "\(name) \(detail)"
        return title.count > 240 ? String(title.prefix(239)) + "…" : title
    }

    static func fileTitleCandidates(
        tool: String,
        args: [String: JSONValue]? = nil,
        argsSummary: String,
        isExpanded: Bool
    ) -> FileTitleCandidates? {
        let normalized = ToolCallFormatting.normalized(tool)
        guard normalized == "read" || normalized == "write" || normalized == "edit" else {
            return nil
        }

        let full: String
        if normalized == "read",
           !isExpanded,
           let compact = ToolCallFormatting.compactReadDisplayTitle(
               tool: normalized,
               args: args,
               argsSummary: argsSummary
           ) {
            full = compact
        } else {
            full = ToolCallFormatting.displayFilePath(
                tool: normalized,
                args: args,
                argsSummary: argsSummary
            )
        }
        guard !full.isEmpty else { return nil }

        let breadcrumb = ToolCallFormatting.breadcrumbDisplayPath(full)
        let fileName = ToolCallFormatting.fileNameDisplayPath(full)
        return FileTitleCandidates(
            full: full,
            breadcrumb: breadcrumb.isEmpty ? full : breadcrumb,
            fileName: fileName.isEmpty ? full : fileName
        )
    }

    static func toolSymbolName(tool: String) -> String? {
        ToolCallFormatting.sfSymbolName(for: ToolCallFormatting.normalized(tool))
    }

    static func toolAccentRole(tool: String) -> ThemeShapeStyle.Role {
        switch ToolCallFormatting.normalized(tool) {
        case "bash": .green
        case "voice_speak", "voice_create": .purple
        default: .cyan
        }
    }

    /// Matches iOS `ToolPresentationBuilder`: built-in file/ask/voice rows use
    /// their native fallback title, expanded bash owns its command panel, and
    /// only icon-replaced prefixes are stripped from reducer-owned segments.
    static func styledCallSegments(
        tool: String,
        isExpanded: Bool,
        isVoicePresentationResult: Bool,
        segments: [StyledSegment]?
    ) -> [StyledSegment]? {
        guard let segments, !segments.isEmpty else { return nil }
        let normalized = ToolCallFormatting.normalized(tool)
        let isBuiltInFileTool = normalized == "read" || normalized == "write" || normalized == "edit"
        guard !isVoicePresentationResult,
              !isBuiltInFileTool,
              normalized != "ask",
              !(isExpanded && normalized == "bash") else {
            return nil
        }

        let prefix = segments.first.flatMap { segment -> String? in
            guard segment.style == .bold else { return nil }
            return segment.text.trimmingCharacters(in: .whitespaces)
        }
        guard toolPrefixIconReplacesName(prefix) else { return segments }

        return segments.dropFirst().enumerated().compactMap { index, segment in
            let text = index == 0
                ? String(segment.text.drop(while: { $0 == " " }))
                : segment.text
            return text.isEmpty ? nil : StyledSegment(text: text, style: segment.style)
        }
    }

    static func trailingPresentation(
        tool: String,
        args: [String: JSONValue]?,
        details: JSONValue?,
        resultSegments: [StyledSegment]?,
        isDone: Bool,
        isInterrupted: Bool
    ) -> TrailingPresentation {
        if isInterrupted {
            return TrailingPresentation(
                added: nil,
                removed: nil,
                segments: nil,
                text: "Interrupted"
            )
        }

        var editStats: ToolCallFormatting.DiffStats?
        var fallback: String?
        if ToolCallFormatting.isEditTool(tool) {
            if !isDone {
                fallback = "editing"
            } else if let stats = ToolCallFormatting.editDiffStats(from: args) {
                editStats = stats
            } else if let lines = ToolCallFormatting.editResultDiffLines(from: details) {
                let stats = DiffEngine.stats(lines)
                editStats = ToolCallFormatting.DiffStats(
                    added: stats.added,
                    removed: stats.removed
                )
            } else {
                fallback = "modified"
            }
        }

        if let editStats {
            return TrailingPresentation(
                added: editStats.added,
                removed: editStats.removed,
                segments: nil,
                text: nil
            )
        }
        if let resultSegments, !resultSegments.isEmpty {
            return TrailingPresentation(
                added: nil,
                removed: nil,
                segments: resultSegments,
                text: nil
            )
        }
        return TrailingPresentation(
            added: nil,
            removed: nil,
            segments: nil,
            text: fallback
        )
    }

    static func segmentRole(for style: StyledSegment.Style?) -> ThemeShapeStyle.Role {
        switch style {
        case .bold, nil: .foreground
        case .muted: .foregroundDim
        case .dim: .comment
        case .accent: .cyan
        case .success: .green
        case .warning: .yellow
        case .error: .red
        }
    }

    static func elapsedText(
        startedAt: Date?,
        elapsedSeconds: Int?,
        isDone: Bool,
        now: Date
    ) -> String? {
        let elapsed: Int
        if let elapsedSeconds {
            elapsed = elapsedSeconds
        } else if let startedAt {
            elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        } else {
            return nil
        }
        guard !isDone || elapsed >= 1 else { return nil }
        return ToolCallFormatting.formatElapsed(elapsed)
    }

    private static func toolPrefixIconReplacesName(_ prefix: String?) -> Bool {
        switch prefix {
        case "$", "read", "write", "edit", "ask", "voice_speak", "voice_create": true
        default: false
        }
    }

    static func languageSymbolName(_ language: String) -> String {
        switch language.lowercased() {
        case "swift": "swift"
        case "markdown": "doc.richtext"
        case "diff": "plusminus"
        case "sql": "cylinder"
        case "image": "photo.fill"
        case "audio": "waveform"
        case "video": "video.fill"
        case "⚠︎media", "⚠media": "exclamationmark.triangle.fill"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The document column can paint any substantive semantic descriptor. The
    /// action is descriptor-driven so extension tools get the same affordance.
    static func offersDocumentView(for content: ToolContentDescriptor?) -> Bool {
        switch content {
        case .terminal, .diff, .code, .markdown, .file, .media:
            return true
        case .status, .none:
            return false
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func statusLabel(
        isDone: Bool,
        isError: Bool,
        isInterrupted: Bool = false
    ) -> String {
        if !isDone { return "Running" }
        if isInterrupted { return "Interrupted" }
        return isError ? "Failed" : "Done"
    }

    static func statusSymbolName(
        isDone: Bool,
        isError: Bool,
        isInterrupted: Bool = false
    ) -> String {
        if !isDone { return "play.circle.fill" }
        if isInterrupted { return "exclamationmark.circle.fill" }
        return isError ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    static func languageLabel(
        tool: String,
        args: [String: JSONValue]? = nil,
        argsSummary: String,
        content: ToolContentDescriptor?
    ) -> String? {
        if let path = ToolCallFormatting.filePath(from: args)
            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary) {
            switch FileType.detect(from: path) {
            case .plain, .binary:
                break
            case let fileType:
                return fileType.displayLabel
            }
        }
        if ToolCallFormatting.isBashTool(tool) {
            let command = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
            let segments = BashEmbeddedLanguageDetector.detect(command)
            if let embedded = segments.first(where: {
                if case .embeddedCode = $0.kind { return true }
                return false
            }), case .embeddedCode(let language) = embedded.kind {
                return language.displayName
            }
        }
        switch content {
        case .diff:
            return SyntaxLanguage.diff.displayName
        case .code(let code):
            return code.language?.displayName
        case .file(let file):
            return file.language?.displayName
        case .terminal(let terminal):
            return terminal.language?.displayName
        case .markdown, .media, .status, .none:
            return nil
        }
    }
}

enum MacToolTimelineState: Equatable, Sendable {
    case running
    case succeeded
    case failed
    case interrupted

    static func make(
        isDone: Bool,
        isError: Bool,
        isInterrupted: Bool = false
    ) -> Self {
        if !isDone { return .running }
        if isInterrupted { return .interrupted }
        return isError ? .failed : .succeeded
    }

    var surfaceRole: ThemeShapeStyle.Role {
        switch self {
        case .running: .toolPendingBackground
        case .succeeded: .toolSuccessBackground
        case .failed: .toolErrorBackground
        case .interrupted: .orange
        }
    }

    var surfaceOpacity: Double {
        switch self {
        case .running, .succeeded, .failed: 1
        case .interrupted: 0.08
        }
    }

    var borderRole: ThemeShapeStyle.Role {
        switch self {
        case .running: .blue
        case .succeeded: .comment
        case .failed: .red
        case .interrupted: .orange
        }
    }

    var statusRole: ThemeShapeStyle.Role {
        switch self {
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .interrupted: .orange
        }
    }

    var borderOpacity: Double {
        switch self {
        case .running, .failed, .interrupted: 0.25
        case .succeeded: 0.20
        }
    }
}

/// Expanded rows prefer any non-empty ToolOutputStore text, including
/// preview-only snapshots (loadSession 8k), matching iOS fullOutput fallback.
enum MacToolRowOutput {
    static func displayed(
        isExpanded: Bool,
        storeOutput: String,
        outputPreview: String
    ) -> String {
        if isExpanded, !storeOutput.isEmpty {
            return storeOutput
        }
        return outputPreview
    }
}

/// Same parse as `MacToolDocumentColumnModel.make`. Timeline paints this value;
/// it must not re-infer kind with MacDiffOutputModel or MacInlineOutputFormatter.
enum MacToolRowPresentation {
    @MainActor
    static func make(
        toolRowID: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        toolOutputStore: ToolOutputStore,
        toolArgsStore: ToolArgsStore,
        toolDetailsStore: ToolDetailsStore,
        isExpanded: Bool = true
    ) -> ToolContentPresentation {
        let stored = toolOutputStore.fullOutput(for: toolRowID)
        return ToolContentDescriptorBuilder.build(
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: ToolContentDescriptorBuilder.Context(
                args: toolArgsStore.args(for: toolRowID),
                details: toolDetailsStore.details(for: toolRowID),
                fullOutput: MacToolRowOutput.displayed(
                    isExpanded: isExpanded,
                    storeOutput: stored,
                    outputPreview: outputPreview
                ),
                isLoadingOutput: toolOutputStore.hasPreviewOnlyOutput(for: toolRowID)
            )
        )
    }
}

enum MacBashCommandChrome {
    static func commandText(
        tool: String,
        args: [String: JSONValue]? = nil,
        argsSummary: String,
        outputText: String
    ) -> String? {
        guard ToolCallFormatting.isBashTool(tool) else { return nil }
        if let command = MacTerminalOutputModel(text: outputText).commandText, !command.isEmpty {
            return command
        }
        let fromArgs = ToolCallFormatting.bashCommandFull(args: args, argsSummary: argsSummary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fromArgs.isEmpty ? nil : fromArgs
    }
}

private struct ToolTimelineBubble: View {
    let itemID: String
    let tool: String
    let argsSummary: String
    let outputPreview: String
    let outputByteCount: Int
    let isError: Bool
    let isDone: Bool
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var toolOutputStore: ToolOutputStore? = nil
    var loadFullToolOutput: ((String) async -> Void)? = nil
    let store: MacSessionTraceStore

    private var isExpanded: Bool { store.isToolRowExpanded(itemID) }
    private var isSelected: Bool { store.selectedToolRowID == itemID }
    private var isInterrupted: Bool { store.isToolInterrupted(itemID) }
    private var state: MacToolTimelineState {
        MacToolTimelineState.make(
            isDone: isDone,
            isError: isError,
            isInterrupted: isInterrupted
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if isExpanded {
                expandedBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ThemeShapeStyle(role: state.surfaceRole).opacity(state.surfaceOpacity),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    ThemeShapeStyle(role: state.borderRole).opacity(state.borderOpacity),
                    lineWidth: 1
                )
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.themeBlue.opacity(0.72), lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .simultaneousGesture(TapGesture().onEnded {
            store.selectToolRow(itemID)
        })
        .accessibilityIdentifier("mac.timeline.toolRow")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .task(id: isExpanded ? itemID : "") {
            guard isExpanded else { return }
            await loadFullToolOutput?(itemID)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            headerSummary

            HStack(spacing: 5) {
                if let audioSource {
                    MacToolAudioPlaybackButton(itemID: itemID, source: audioSource)
                }
                MacToolElapsedLabel(
                    startedAt: isVoicePresentationResult ? nil : store.toolStartTime(for: itemID),
                    elapsedSeconds: isVoicePresentationResult ? nil : store.toolElapsed(for: itemID),
                    isDone: isDone
                )
                .accessibilityHidden(true)
                trailingMetadata
                    .accessibilityHidden(true)
                languageMetadata

                if canOpenDocument {
                    Button {
                        store.selectToolRow(itemID)
                        _ = store.applyKeybinding(.commandReturn, toolRowIDs: [itemID])
                    } label: {
                        Image(systemName: "sidebar.trailing")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.themeComment)
                            .frame(width: 16, height: 16)
                            .frame(
                                width: MacToolTimelineChrome.compactActionTargetSize,
                                height: MacToolTimelineChrome.compactActionTargetSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open in Document View")
                    .accessibilityIdentifier("mac.timeline.openDocument")
                    .help("Open in Document View")
                }

                if canExpand {
                    Button {
                        store.selectToolRow(itemID)
                        store.setToolRowExpanded(itemID, expanded: !isExpanded)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.themeComment)
                            .frame(width: 16, height: 16)
                            .frame(
                                width: MacToolTimelineChrome.compactActionTargetSize,
                                height: MacToolTimelineChrome.compactActionTargetSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Keep the descriptive metadata as one concise accessibility element,
    /// while the adjacent audio and disclosure buttons remain real actions.
    private var headerSummary: some View {
        HStack(spacing: 5) {
            Image(systemName: MacToolTimelineChrome.statusSymbolName(
                isDone: isDone,
                isError: isError,
                isInterrupted: isInterrupted
            ))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ThemeShapeStyle(role: state.statusRole))
                .frame(width: 14, height: 14)
            if let symbolName = MacToolTimelineChrome.toolSymbolName(tool: tool) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ThemeShapeStyle(role: MacToolTimelineChrome.toolAccentRole(tool: tool)))
                    .frame(width: 12, height: 12)
                    .help(MacToolTimelineChrome.displayTitle(tool: tool))
            }
            headerTitle
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    @ViewBuilder
    private var headerTitle: some View {
        if let titles = fileTitleCandidates {
            if isExpanded {
                plainHeaderTitle(titles.full)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    plainHeaderTitle(titles.full)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 18)
                    plainHeaderTitle(titles.breadcrumb)
                        .fixedSize(horizontal: true, vertical: false)
                    plainHeaderTitle(titles.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else if let styledCallSegments {
            MacStyledSegmentText(segments: styledCallSegments, scale: .title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(argsSummary)
        } else {
            plainHeaderTitle(MacToolTimelineChrome.headerTitle(
                tool: tool,
                args: toolArgs,
                argsSummary: argsSummary,
                details: toolDetails,
                isExpanded: isExpanded,
                isVoicePresentationResult: isVoicePresentationResult
            ))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func plainHeaderTitle(_ title: String) -> some View {
        Text(title)
            .font(Font(FontPreferenceStore.macCodeFont(weight: .semibold)))
            .foregroundStyle(.themeToolTitle)
            .help(fileTitleCandidates?.full ?? argsSummary)
    }

    @ViewBuilder
    private var languageMetadata: some View {
        if let language = MacToolTimelineChrome.languageLabel(
            tool: tool,
            args: toolArgs,
            argsSummary: argsSummary,
            content: presentation.content
        ) {
            Image(systemName: MacToolTimelineChrome.languageSymbolName(language))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.themeBlue)
                .frame(width: 14, height: 14)
                .help(language)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingMetadata: some View {
        if let added = trailingPresentation.added,
           let removed = trailingPresentation.removed {
            HStack(spacing: 4) {
                if added == 0, removed == 0 {
                    Text("modified")
                        .foregroundStyle(.themeComment)
                } else {
                    if added > 0 {
                        Text("+\(added)")
                            .foregroundStyle(.themeDiffAdded)
                    }
                    if removed > 0 {
                        Text("-\(removed)")
                            .foregroundStyle(.themeDiffRemoved)
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .fixedSize()
        } else if let segments = trailingPresentation.segments {
            MacStyledSegmentText(segments: segments, scale: .trailing)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96, alignment: .trailing)
                .help(segments.map(\.text).joined())
        } else if let text = trailingPresentation.text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(isInterrupted ? .themeOrange : .themeComment)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let command = bashCommand {
            MacBashCommandBar(command: command)
        }

        toolOutput
    }

    @ViewBuilder
    private var toolOutput: some View {
        switch presentation.content {
        case .diff(let diff):
            MacToolTimelineDiffPreview(diff: diff)
                .frame(maxHeight: isExpanded ? nil : 220, alignment: .top)
                .clipped()
        case .code(let code):
            MacCodeOutputPreview(
                model: MacCodeOutputModel(language: code.language?.displayName, text: code.text),
                source: MacReviewCommentSource(
                    kind: code.filePath == nil ? .toolOutput : .file,
                    path: code.filePath,
                    timelineItemId: itemID,
                    startLine: code.startLine ?? 1
                )
            )
            .frame(maxHeight: isExpanded ? 360 : 180)
        case .markdown(let markdown):
            MacMarkdownDocumentView(
                markdown: markdown.text,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
            .textSelection(.enabled)
            .lineLimit(isExpanded ? nil : 12)
        case .file(let file):
            fileOutput(file)
        case .media(let media):
            MacToolDocumentMediaView(
                media: media,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                routeScope: store.selectedTarget?.routeScope
            )
            .frame(maxHeight: isExpanded ? nil : 220, alignment: .top)
            .clipped()
        case .terminal(let terminal):
            terminalOutput(terminal)
        case .status(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.themeFgDim)
        case nil:
            EmptyView()
        }
    }

    private var presentation: ToolContentPresentation {
        MacToolRowPresentation.make(
            toolRowID: itemID,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            toolOutputStore: toolOutputStore ?? store.toolOutputStore,
            toolArgsStore: store.toolArgsStore,
            toolDetailsStore: store.toolDetailsStore,
            isExpanded: isExpanded
        )
    }

    private var displayedOutput: String {
        MacToolRowOutput.displayed(
            isExpanded: isExpanded,
            storeOutput: (toolOutputStore ?? store.toolOutputStore).fullOutput(for: itemID),
            outputPreview: outputPreview
        )
    }

    private var bashCommand: String? {
        MacBashCommandChrome.commandText(
            tool: tool,
            args: toolArgs,
            argsSummary: argsSummary,
            outputText: displayedOutput
        )
    }

    private var toolArgs: [String: JSONValue]? {
        store.toolArgsStore.args(for: itemID)
    }

    private var toolDetails: JSONValue? {
        store.toolDetailsStore.details(for: itemID)
    }

    private var isVoicePresentationResult: Bool {
        ToolContentDescriptorBuilder.audioPresentation(from: toolDetails) != nil
    }

    private var audioSource: MacToolAudioSource? {
        guard case .media(let media) = presentation.content else { return nil }
        return MacToolAudioSourceResolver.source(
            media: media,
            sessionID: sessionID,
            routeScope: store.selectedTarget?.routeScope
        )
    }

    private var styledCallSegments: [StyledSegment]? {
        MacToolTimelineChrome.styledCallSegments(
            tool: tool,
            isExpanded: isExpanded,
            isVoicePresentationResult: isVoicePresentationResult,
            segments: store.toolCallSegments(for: itemID)
        )
    }

    private var fileTitleCandidates: MacToolTimelineChrome.FileTitleCandidates? {
        MacToolTimelineChrome.fileTitleCandidates(
            tool: tool,
            args: toolArgs,
            argsSummary: argsSummary,
            isExpanded: isExpanded
        )
    }

    private var trailingPresentation: MacToolTimelineChrome.TrailingPresentation {
        MacToolTimelineChrome.trailingPresentation(
            tool: tool,
            args: toolArgs,
            details: toolDetails,
            resultSegments: store.toolResultSegments(for: itemID),
            isDone: isDone,
            isInterrupted: isInterrupted
        )
    }

    private var canExpand: Bool {
        argsSummary.components(separatedBy: .newlines).count > 4
            || argsSummary.count > 240
            || outputPreview.components(separatedBy: .newlines).count > 8
            || outputPreview.count > 800
            || outputByteCount > outputPreview.utf8.count
            || outputPreview.count >= ChatItem.maxPreviewLength
            || toolOutputStore?.hasPreviewOnlyOutput(for: itemID) == true
            || (toolOutputStore?.hasCompleteOutput(for: itemID) == true
                && (toolOutputStore?.fullOutput(for: itemID).count ?? 0) > outputPreview.count)
            || descriptorSupportsExpansion
    }

    private var canOpenDocument: Bool {
        MacToolTimelineChrome.offersDocumentView(for: presentation.content)
    }

    private var descriptorSupportsExpansion: Bool {
        switch presentation.content {
        case .diff, .code, .file, .media, .markdown, .terminal, .status:
            return true
        case .none:
            return false
        }
    }

    @ViewBuilder
    private func terminalOutput(_ terminal: ToolContentDescriptor.Terminal) -> some View {
        let output = terminal.output ?? ""
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            MacTerminalOutputPreview(
                model: MacTerminalOutputModel(text: output, isError: isError),
                isExpanded: isExpanded,
                itemID: itemID
            )
        }
    }

    @ViewBuilder
    private func fileOutput(_ file: ToolContentDescriptor.File) -> some View {
        if MacToolDocumentColumnPaint.fileUsesPDFPreview(file) {
            Label(file.filePath ?? "PDF", systemImage: "doc.richtext")
                .font(.caption)
                .foregroundStyle(.themeFg)
        } else if let kind = MacMarkupPreviewKind.from(file: file) {
            MacMarkupSourcePreviewView(source: file.text, kind: kind, fillsColumn: false)
                .frame(maxHeight: isExpanded ? 360 : 180)
                .clipped()
        } else if MacToolDocumentColumnPaint.fileUsesSyntaxHighlighter(file) {
            MacCodeOutputPreview(
                model: MacCodeOutputModel(language: file.language?.displayName, text: file.text),
                source: MacReviewCommentSource(
                    kind: .file,
                    path: file.filePath,
                    timelineItemId: itemID,
                    startLine: file.startLine ?? 1
                )
            )
            .frame(maxHeight: isExpanded ? 360 : 180)
        } else if file.fileType == .markdown {
            MacMarkdownDocumentView(
                markdown: file.text,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                filePath: file.filePath
            )
            .textSelection(.enabled)
            .lineLimit(isExpanded ? nil : 12)
        } else if file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            MacTerminalOutputPreview(
                model: MacTerminalOutputModel(text: file.text, isError: isError),
                isExpanded: isExpanded,
                itemID: itemID,
                sourceKind: file.filePath == nil ? .terminalOutput : .file,
                path: file.filePath
            )
        }
    }

    private var headerAccessibilityLabel: String {
        var parts = [
            styledCallSegments?.map(\.text).joined()
                ?? MacToolTimelineChrome.headerTitle(
                    tool: tool,
                    args: toolArgs,
                    argsSummary: argsSummary,
                    details: toolDetails,
                    isExpanded: isExpanded,
                    isVoicePresentationResult: isVoicePresentationResult
                ),
            MacToolTimelineChrome.statusLabel(
                isDone: isDone,
                isError: isError,
                isInterrupted: isInterrupted
            ),
        ]
        if let language = MacToolTimelineChrome.languageLabel(
            tool: tool,
            args: toolArgs,
            argsSummary: argsSummary,
            content: presentation.content
        ) {
            parts.insert(language, at: parts.count - 1)
        }
        if let trailing = trailingPresentation.accessibilityText, !trailing.isEmpty {
            parts.insert(trailing, at: parts.count - 1)
        }
        if let elapsed = MacToolTimelineChrome.elapsedText(
            startedAt: isVoicePresentationResult ? nil : store.toolStartTime(for: itemID),
            elapsedSeconds: isVoicePresentationResult ? nil : store.toolElapsed(for: itemID),
            isDone: isDone,
            now: Date()
        ) {
            parts.insert(elapsed, at: parts.count - 1)
        }
        return parts.joined(separator: ", ")
    }
}

private struct MacStyledSegmentText: View {
    enum Scale {
        case title
        case trailing
    }

    let segments: [StyledSegment]
    let scale: Scale
    @Environment(\.theme) private var theme

    var body: some View {
        // Attributed text requires concrete colors. Reading `theme` here keeps
        // mounted timeline rows tied to the live environment on every repaint.
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            part.font = font(for: segment.style)
            part.foregroundColor = color(for: segment.style)
            result.append(part)
        }
        return result
    }

    private func font(for style: StyledSegment.Style?) -> Font {
        let weight: Font.Weight = style == .bold ? .semibold : .regular
        switch scale {
        case .title:
            return Font.system(size: 11, weight: weight, design: .monospaced)
        case .trailing:
            return Font.system(size: 10, weight: weight, design: .monospaced)
        }
    }

    private func color(for style: StyledSegment.Style?) -> Color {
        switch MacToolTimelineChrome.segmentRole(for: style) {
        case .foreground: theme.text.primary
        case .foregroundDim: theme.text.secondary
        case .comment: theme.text.tertiary
        case .cyan: theme.accent.cyan
        case .green: theme.accent.green
        case .yellow: theme.accent.yellow
        case .red: theme.accent.red
        default: theme.text.primary
        }
    }
}

private struct MacToolElapsedLabel: View {
    let startedAt: Date?
    let elapsedSeconds: Int?
    let isDone: Bool

    @ViewBuilder
    var body: some View {
        if !isDone, elapsedSeconds == nil, startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                label(at: context.date)
            }
        } else {
            label(at: Date())
        }
    }

    @ViewBuilder
    private func label(at date: Date) -> some View {
        if let text = MacToolTimelineChrome.elapsedText(
            startedAt: startedAt,
            elapsedSeconds: elapsedSeconds,
            isDone: isDone,
            now: date
        ) {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
                .fixedSize()
        }
    }
}

private struct MacBashCommandBar: View {
    let command: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$")
                .font(Font(FontPreferenceStore.macCodeFont(weight: .semibold)))
                .foregroundStyle(.themeGreen)
            Text(command)
                .font(Font(FontPreferenceStore.macCodeFont()))
                .foregroundStyle(.themeToolTitle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.themeBgHighlight, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.themeBlue.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct MacTerminalOutputPreview: View {
    let model: MacTerminalOutputModel
    let isExpanded: Bool
    var itemID: String? = nil
    var sourceKind: ReviewCommentReferenceSource = .terminalOutput
    var path: String? = nil

    var body: some View {
        MacReviewCommentTextView(
            text: model.outputText,
            source: MacReviewCommentSource(
                kind: sourceKind,
                path: path,
                label: model.commandText,
                timelineItemId: itemID
            ),
            fillsColumn: true
        )
        .frame(maxHeight: isExpanded ? 360 : 180)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(outputBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(outputBorder, lineWidth: 1)
        )
    }

    private var outputBackground: AnyShapeStyle {
        if model.isError {
            return AnyShapeStyle(ThemeShapeStyle(role: .red).opacity(0.10))
        }
        return AnyShapeStyle(ThemeShapeStyle(role: .backgroundDark))
    }

    private var outputBorder: AnyShapeStyle {
        if model.isError {
            return AnyShapeStyle(ThemeShapeStyle(role: .red).opacity(0.35))
        }
        return AnyShapeStyle(ThemeShapeStyle(role: .comment).opacity(0.20))
    }
}

private struct MacToolTimelineDiffPreview: View {
    let diff: ToolContentDescriptor.Diff
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MacToolDocumentDiffLayout.rows(from: diff).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(gutter(row.oldLineNumber))
                        .foregroundStyle(theme.text.tertiary)
                        .monospacedDigit()
                    Text(gutter(row.newLineNumber))
                        .foregroundStyle(theme.text.tertiary)
                        .monospacedDigit()
                    Text(row.kind.prefix)
                        .frame(width: 12, alignment: .center)
                    Text(row.text.isEmpty ? " " : row.text)
                }
                .font(Font(FontPreferenceStore.macCodeFont()))
                .foregroundStyle(color(for: row.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
                .background(background(for: row.kind))
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.themeComment.opacity(0.20), lineWidth: 1)
        )
    }

    private func gutter(_ number: Int?) -> String {
        number.map { String(format: "%4d", $0) } ?? "    "
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diff.addedAccent
        case .removed: theme.diff.removedAccent
        case .context: theme.diff.contextFg
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diff.addedBg
        case .removed: theme.diff.removedBg
        case .context: Color.clear
        }
    }
}

struct MacCodeOutputPreview: View {
    let model: MacCodeOutputModel
    var source: MacReviewCommentSource = MacReviewCommentSource(kind: .timelineText)
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.language ?? "Code", systemImage: "curlybraces")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(theme.markdown.codeBlock)
            MacReviewCommentTextView(
                text: model.text,
                attributedText: MacSyntaxHighlighter.attributedCode(
                    model.text,
                    language: model.syntaxLanguage,
                    includeLineNumbers: false
                ),
                source: source,
                fillsColumn: false,
                heightBehavior: .fitContent(maxHeight: 360)
            )
            .frame(maxHeight: 360)
            .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.markdown.codeBlockBorder, lineWidth: 1)
            )
        }
    }
}

/// Caps collapsed thinking to the painted ideal height versus the 200pt cap.
/// Timeline rows are proposed unbounded height, so ViewThatFits cannot fold.
/// Overflow is published from the view with a PreferenceKey; layout stays pure.
enum ThinkingFoldPolicy {
    /// Same number as iOS `ThinkingRowHeightPolicy.defaultMaxBubbleHeight`.
    /// iOS is not wired to this type.
    static let collapsedMaxHeight: CGFloat = 200

    static func overflowsCollapsedCap(paintedHeight: CGFloat) -> Bool {
        paintedHeight > collapsedMaxHeight
    }
}

/// iOS fades done thinking at the bottom 30% when the 200pt cap clips.
enum ThinkingFadePolicy {
    static let startFraction: CGFloat = 0.7

    static func shouldFade(isDone: Bool, overflowsPaintedCap: Bool, isExpanded: Bool = false) -> Bool {
        isDone && overflowsPaintedCap && !isExpanded
    }
}

private struct ThinkingPaintedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ThinkingFoldLayout: Layout {
    var cap: CGFloat
    var isExpanded: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = isExpanded ? ideal.height : min(ideal.height, cap)
        return CGSize(width: ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

struct ThinkingTimelineBubble: View {
    let itemID: String
    let preview: String
    let hasMore: Bool
    let isDone: Bool
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil

    @Environment(\.theme) private var theme
    @State private var overflowsPaintedCap = false
    @State private var isExpanded = false

    private var collapsedCap: CGFloat {
        ThinkingFoldPolicy.collapsedMaxHeight
    }

    var body: some View {
        // Match iOS: no "Thinking" title. Done gets a sparkle; streaming is
        // plain muted callout. WorkingIndicator already shows activity.
        HStack(alignment: .top, spacing: 6) {
            if isDone, !preview.isEmpty {
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.accent.purple.opacity(0.7))
                    .frame(width: 14, height: 14)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            thinkingBody
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.text.tertiary.opacity(isDone ? 0.08 : 0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .contextMenu {
            if overflowsPaintedCap {
                Button(isExpanded ? "Show Less" : "Show All") {
                    isExpanded.toggle()
                }
            }
        }
        .accessibilityIdentifier("mac.timeline.thinkingRow")
        .accessibilityLabel("Thinking")
        .accessibilityValue(foldAccessibilityValue)
        .accessibilityAction(named: isExpanded ? "Show Less" : "Show All") {
            guard overflowsPaintedCap else { return }
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private var thinkingBody: some View {
        if preview.isEmpty {
            EmptyView()
        } else {
            ThinkingFoldLayout(
                cap: collapsedCap,
                isExpanded: isExpanded
            ) {
                Group {
                    if isDone {
                        MacMarkdownDocumentView(
                            markdown: preview,
                            itemID: itemID,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            worktreeId: worktreeId,
                            typography: .thinking
                        )
                    } else {
                        Text(preview)
                            .font(Font(FontPreferenceStore.macMessageFont(forTextStyle: .callout)))
                            .foregroundStyle(theme.text.tertiary.opacity(0.88))
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ThinkingPaintedHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            .clipped()
            .mask {
                if ThinkingFadePolicy.shouldFade(
                    isDone: isDone,
                    overflowsPaintedCap: overflowsPaintedCap,
                    isExpanded: isExpanded
                ) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: ThinkingFadePolicy.startFraction),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Rectangle()
                }
            }
            .onPreferenceChange(ThinkingPaintedHeightKey.self) { height in
                let overflows = ThinkingFoldPolicy.overflowsCollapsedCap(paintedHeight: height)
                if overflowsPaintedCap != overflows {
                    overflowsPaintedCap = overflows
                }
            }
            .accessibilityIdentifier("mac.timeline.thinking.body")
        }
    }

    private var foldAccessibilityValue: String {
        guard overflowsPaintedCap else { return "Short" }
        return isExpanded ? "Expanded" : "Truncated"
    }
}

private struct MarkdownTimelineBubble: View {
    let role: MacTimelineProseRole
    let title: String
    let subtitle: String?
    let text: String
    var images: [ImageAttachment] = []
    var itemID: String? = nil
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil

    private var rowAlignment: Alignment {
        switch MacTimelineProsePaint.alignment(for: role) {
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TimelineBubbleHeader(
                title: title,
                subtitle: subtitle,
                sessionID: sessionID,
                showsAssistantAvatar: role == .assistant
            )
            if !images.isEmpty {
                MacUserMessageImageStrip(images: images)
            }
            if !text.isEmpty {
                MacMarkdownDocumentView(
                    markdown: text,
                    itemID: itemID,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId,
                    typography: .message,
                    proseMaximumWidth: MacTimelineProsePaint.readableMaximumWidth
                )
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: rowAlignment)
        .padding(.leading, role == .user ? MacTimelineProsePaint.userLeadingInset : 0)
    }
}

private struct TimelineBubbleHeader: View {
    let title: String
    let subtitle: String?
    var sessionID: String? = nil
    var showsAssistantAvatar: Bool = false
    var titleColor: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if showsAssistantAvatar {
                MacCurrentAssistantAvatarView(
                    sessionId: sessionID ?? "timeline",
                    size: 18
                )
                .accessibilityIdentifier("mac.timeline.assistantAvatar")
            }
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(titleColor ?? theme.text.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.text.secondary)
            }
        }
    }
}

private struct TimelineBubble: View {
    let title: String
    let subtitle: String?
    let text: String
    let fill: Color
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.text.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(theme.text.secondary)
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(theme.text.primary)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
    }
}
