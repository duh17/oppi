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
    /// Pane-owned live-tail intent. Retiling must not reset this from view state.
    var presentation: MacSessionPanePresentationState? = nil

    var body: some View {
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
                    sessionFocus: sessionFocus,
                    presentation: presentation
                )
            }
        }
        .foregroundStyle(.themeFg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScrollSurface()
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

/// One centered reading column for every timeline row and the composer.
/// The measure is in ems of the live message size, so ⌘+ widens the
/// column with the text instead of reflowing it into fewer words per line.
enum MacTimelineProsePaint: Sendable {
    static let readableMeasureEms: CGFloat = 50
    static let minimumColumnWidth: CGFloat = 560
    /// Space between the column and the pane edge on narrow panes.
    static let columnGutter: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    /// Extra air above a message so turns read as turns, not log lines.
    static let messageTopInset: CGFloat = 6
    static let cardCornerRadius: CGFloat = 12

    static func readableColumnWidth(bodyPointSize: CGFloat) -> CGFloat {
        max(minimumColumnWidth, (bodyPointSize * readableMeasureEms).rounded())
    }

    @MainActor
    static var currentColumnWidth: CGFloat {
        readableColumnWidth(
            bodyPointSize: FontPreferenceStore.macMessagePointSize(forTextStyle: .body)
        )
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
    var presentation: MacSessionPanePresentationState? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macTypographyRevision) private var typographyRevision
    @State private var fallbackLiveTailAttached = true
    @State private var lastContentHeight: CGFloat = 0
    @State private var lastViewportWidth: CGFloat = 0
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var pendingRemountTarget: MacSessionTimelineRemountTarget?
    @State private var usdzInspectLocksScroll = false

    private var isAttachedToLatestRow: Bool {
        presentation?.isLiveTailAttached ?? fallbackLiveTailAttached
    }

    private func setAttachedToLatestRow(_ attached: Bool) {
        if let presentation {
            if presentation.isLiveTailAttached != attached {
                presentation.isLiveTailAttached = attached
            }
        } else if fallbackLiveTailAttached != attached {
            fallbackLiveTailAttached = attached
        }
    }

    var body: some View {
        let _ = typographyRevision
        // Session-level values are read once here and passed down as plain
        // values. A row that reads `store.session` itself re-renders every
        // mounted row on each token/cost update.
        let rowContext = ChatItemRowContext(
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: store.session?.worktreeId,
            model: store.session?.model,
            hiddenThinkingLabel: store.extensionSurface.hiddenThinkingLabel
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MacTimelineProsePaint.rowSpacing) {
                    ForEach(items) { item in
                        ChatItemSummaryRow(
                            item: item,
                            context: rowContext,
                            toolOutputStore: toolOutputStore,
                            loadFullToolOutput: loadFullToolOutput,
                            store: store
                        )
                            .equatable()
                            .id(item.id)
                    }
                    if isBusy, MacWorkingRowPresentation(state: store.extensionSurface.working).isVisible {
                        MacWorkingIndicatorRow(state: store.extensionSurface.working)
                            .id(MacWorkingIndicatorRow.rowID)
                    }
                    Color.clear
                        .frame(height: bottomContentInset)
                        .id(MacSessionTimelineAutoFollow.latestAnchorID)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: MacTimelineProsePaint.currentColumnWidth, alignment: .leading)
                .padding(.horizontal, MacTimelineProsePaint.columnGutter)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(isAttachedToLatestRow ? .bottom : nil)
            .scrollPosition($scrollPosition)
            // macOS 26 treats this scroll view as the titlebar scroll pocket
            // and paints a toolbar-height band over the first rows, even with
            // pane chrome between them. Nothing overlaps the timeline top.
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .accessibilityIdentifier("mac.timeline")
            .scrollDisabled(usdzInspectLocksScroll)
            .onPreferenceChange(MacUSDZInspectScrollLockKey.self) { usdzInspectLocksScroll = $0 }
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
                let remountRestore = MacSessionTimelineAutoFollow.remountRestoreDecision(
                    pending: pendingRemountTarget,
                    contentHeight: snapshot.contentHeight,
                    offsetY: snapshot.offsetY,
                    viewportHeight: snapshot.viewportHeight
                )
                if remountRestore.applyRestore, let pending = pendingRemountTarget {
                    applyRemountTarget(pending, proxy: proxy)
                }
                pendingRemountTarget = remountRestore.pending
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
                let nextAttachment: Bool
                if remountRestore.holdRestore {
                    nextAttachment = isAttachedToLatestRow
                } else {
                    nextAttachment = MacSessionTimelineAutoFollow.isAttachedAfterGeometryChange(
                        wasAttached: isAttachedToLatestRow,
                        isNearBottom: isNearBottom,
                        scrollPhase: scrollPhase
                    )
                }
                if !MacSessionTimelineAutoFollow.measurementsMatch(lastContentHeight, snapshot.contentHeight) {
                    lastContentHeight = snapshot.contentHeight
                }
                if !MacSessionTimelineAutoFollow.measurementsMatch(lastViewportWidth, snapshot.viewportWidth) {
                    lastViewportWidth = snapshot.viewportWidth
                }
                if isAttachedToLatestRow != nextAttachment {
                    setAttachedToLatestRow(nextAttachment)
                }
                if !remountRestore.holdRestore {
                    recordViewport(
                        offsetY: snapshot.offsetY,
                        isAttached: nextAttachment
                    )
                }
                if !remountRestore.holdRestore,
                   MacSessionTimelineAutoFollow.shouldScrollAfterContentGrowth(
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
                setAttachedToLatestRow(true)
                presentation?.timelineViewport = MacSessionTimelineViewport()
                lastContentHeight = 0
                lastViewportWidth = 0
                pendingRemountTarget = nil
                scrollToLatestIfAttached(proxy: proxy, animated: false)
            }
            .onChange(of: store.revealToolRowID) { _, rowID in
                guard let rowID else { return }
                revealKeyboardSelection(proxy: proxy, rowID: rowID)
            }
            .onChange(of: store.scrollTargetID) { _, targetID in
                guard let targetID else { return }
                scrollToOutlineTarget(proxy: proxy, targetID: targetID, items: items)
            }
            .onAppear {
                restoreViewportIfNeeded(proxy: proxy)
                guard let targetID = store.scrollTargetID else { return }
                scrollToOutlineTarget(proxy: proxy, targetID: targetID, items: items)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAttachedToLatestRow {
                    Button {
                        pendingRemountTarget = MacSessionTimelineAutoFollow.pendingRemountTargetAfterExplicitNavigation(
                            pendingRemountTarget
                        )
                        setAttachedToLatestRow(true)
                        scrollToLatestIfAttached(proxy: proxy, animated: true)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
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
        pendingRemountTarget = MacSessionTimelineAutoFollow.pendingRemountTargetAfterExplicitNavigation(
            pendingRemountTarget
        )
        setAttachedToLatestRow(MacSessionTimelineAutoFollow.shouldAttachToLatestAfterJump(
            targetID: targetID,
            latestItemID: items.last?.id
        ))
        if let animation = MacSessionTimelineAutoFollow.scrollAnimation(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        } else {
            proxy.scrollTo(targetID, anchor: .center)
        }
        store.clearScrollTarget()
    }

    /// Keyboard navigation keeps the selected row visible without centering
    /// it on every step. Leaving the live tail is explicit navigation.
    private func revealKeyboardSelection(proxy: ScrollViewProxy, rowID: String) {
        pendingRemountTarget = MacSessionTimelineAutoFollow.pendingRemountTargetAfterExplicitNavigation(
            pendingRemountTarget
        )
        setAttachedToLatestRow(MacSessionTimelineAutoFollow.shouldAttachToLatestAfterJump(
            targetID: rowID,
            latestItemID: items.last?.id
        ))
        proxy.scrollTo(rowID)
        store.clearRevealToolRow()
    }

    private func handleTimelineKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard sessionFocus.wrappedValue == .timeline else { return .ignored }
        guard let chord = press.keybindingChord else { return .ignored }
        let action = store.applyKeybinding(chord)
        return MacTimelineKeybinding.consumes(action) ? .handled : .ignored
    }

    private func recordViewport(offsetY: CGFloat, isAttached: Bool) {
        guard let presentation else { return }
        let recorded = MacSessionTimelineAutoFollow.recordedViewport(
            offsetY: Double(offsetY),
            anchorID: scrollPosition.viewID(type: String.self),
            isAttached: isAttached
        )
        if presentation.timelineViewport != recorded {
            presentation.timelineViewport = recorded
        }
    }

    private func restoreViewportIfNeeded(proxy: ScrollViewProxy) {
        let target = MacSessionTimelineAutoFollow.remountScrollTarget(
            isAttached: isAttachedToLatestRow,
            viewport: presentation?.timelineViewport ?? MacSessionTimelineViewport(),
            availableAnchorIDs: Set(items.map(\.id))
        )
        applyRemountTarget(target, proxy: proxy)
        switch target {
        case .anchor(_, let offsetY) where offsetY > 0.5:
            pendingRemountTarget = target
        case .offset(let offsetY) where offsetY > 0.5:
            pendingRemountTarget = target
        default:
            pendingRemountTarget = nil
        }
    }

    private func applyRemountTarget(
        _ target: MacSessionTimelineRemountTarget,
        proxy: ScrollViewProxy
    ) {
        switch MacSessionTimelineAutoFollow.restoreCommand(for: target) {
        case .latest:
            scrollToLatestIfAttached(proxy: proxy, animated: false)
        case .rowStart(let id):
            proxy.scrollTo(id, anchor: .top)
            scrollPosition.scrollTo(id: id, anchor: .top)
        case .contentOffset(let offsetY):
            if case .anchor(let id, _) = target {
                proxy.scrollTo(id, anchor: .top)
            }
            scrollPosition.scrollTo(y: CGFloat(offsetY))
        case .none:
            break
        }
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

/// Session-level values every row needs, captured once per timeline render.
private struct ChatItemRowContext: Equatable, Sendable {
    var workspaceID: String?
    var sessionID: String?
    var worktreeId: String?
    var model: String?
    var hiddenThinkingLabel: String?
}

/// Equatable so a live token in one row does not re-run every mounted row's
/// body: the parent re-renders on each `items` change, and the load closure
/// alone would otherwise make SwiftUI treat every row as changed.
private struct ChatItemSummaryRow: View, Equatable {
    let item: ChatItem
    let context: ChatItemRowContext
    let toolOutputStore: ToolOutputStore?
    let loadFullToolOutput: ((String) async -> Void)?
    let store: MacSessionTraceStore
    /// Owner identity for `==`; the stores themselves are main-actor state.
    private let owners: [ObjectIdentifier?]
    @Environment(\.theme) private var theme

    init(
        item: ChatItem,
        context: ChatItemRowContext,
        toolOutputStore: ToolOutputStore?,
        loadFullToolOutput: ((String) async -> Void)?,
        store: MacSessionTraceStore
    ) {
        self.item = item
        self.context = context
        self.toolOutputStore = toolOutputStore
        self.loadFullToolOutput = loadFullToolOutput
        self.store = store
        owners = [ObjectIdentifier(store), toolOutputStore.map(ObjectIdentifier.init)]
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.context == rhs.context
            && lhs.owners == rhs.owners
    }

    var body: some View {
        switch item {
        case .userMessage(let id, let text, let images, let timestamp):
            MarkdownTimelineBubble(
                role: .user,
                timestamp: timestamp,
                text: text,
                images: images,
                itemID: id,
                context: context
            )
            .padding(.top, MacTimelineProsePaint.messageTopInset)
        case .assistantMessage(let id, let text, let timestamp):
            MarkdownTimelineBubble(
                role: .assistant,
                timestamp: timestamp,
                text: text,
                itemID: id,
                context: context
            )
            .padding(.top, MacTimelineProsePaint.messageTopInset)
        case .audioClip(_, let title, _, let timestamp):
            TimelineBubble(
                title: "Audio",
                subtitle: timestamp.relativeString(),
                text: title,
                fill: theme.accent.purple.opacity(0.10)
            )
        case .thinking(let id, let preview, let hasMore, let isDone):
            ThinkingTimelineBubble(
                itemID: id,
                preview: preview,
                hasMore: hasMore,
                isDone: isDone,
                hiddenThinkingLabel: context.hiddenThinkingLabel,
                workspaceID: context.workspaceID,
                sessionID: context.sessionID,
                worktreeId: context.worktreeId
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
                workspaceID: context.workspaceID,
                sessionID: context.sessionID,
                worktreeId: context.worktreeId,
                toolOutputStore: toolOutputStore,
                loadFullToolOutput: loadFullToolOutput,
                store: store
            )
        case .systemEvent(_, let message):
            MacSystemTimelineStrip(message: message, style: .informational)
        case .cacheMiss(_, let message), .notice(_, let message):
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

    @Environment(\.macTypographyRevision) private var typographyRevision
    let message: String
    let style: Style

    var body: some View {
        let _ = typographyRevision
        let size = MacTimelineChromeType.captionSize
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .frame(width: size, height: size)
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .font(.system(size: size))
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

/// Chrome text around timeline content (row headers, captions, metadata).
/// System face even when messages use mono, scaled with message zoom so
/// labels stay in proportion to the prose they label.
enum MacTimelineChromeType {
    @MainActor static var labelSize: CGFloat {
        (FontPreferenceStore.macMessagePointSize(forTextStyle: .body) * 0.8).rounded()
    }

    @MainActor static var captionSize: CGFloat {
        (FontPreferenceStore.macMessagePointSize(forTextStyle: .body) * 0.74).rounded()
    }
}

/// Timeline cards: a translucent theme tint with a light hairline edge, the
/// iOS row read. No per-row gradients or backdrop blur: the growing live
/// card repaints every token, and gradient fills/strokes made each token
/// cost ~3x the layout-only work (polish harness A/B, stream p50 20 ms vs 6 ms).
private struct MacTimelineCardSurface<Fill: ShapeStyle>: ViewModifier {
    let fill: Fill
    /// Nil paints the default light hairline.
    var stroke: AnyShapeStyle? = nil
    var cornerRadius: CGFloat = MacTimelineProsePaint.cardCornerRadius
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay(
                shape.strokeBorder(
                    stroke ?? AnyShapeStyle(theme.text.primary.opacity(0.08)),
                    lineWidth: 1
                )
            )
    }
}

private extension View {
    func macTimelineCard<Fill: ShapeStyle>(
        _ fill: Fill,
        stroke: AnyShapeStyle? = nil,
        cornerRadius: CGFloat = MacTimelineProsePaint.cardCornerRadius
    ) -> some View {
        modifier(MacTimelineCardSurface(fill: fill, stroke: stroke, cornerRadius: cornerRadius))
    }
}

enum MacToolTimelineChrome {
    static let compactActionTargetSize: CGFloat = 24
    static let cornerRadius: CGFloat = 10

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
        ToolCallFormatting.macLegacySFSymbolName(for: ToolCallFormatting.normalized(tool))
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
    @Environment(\.macTypographyRevision) private var typographyRevision
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

    /// Everything the row paints, derived once per body. Building the tool
    /// descriptor parses output (diffs, JSON, media), so it must not run once
    /// per property that needs it.
    private struct Derived {
        let isExpanded: Bool
        let presentation: ToolContentPresentation
        let args: [String: JSONValue]?
        let details: JSONValue?
        let isVoicePresentationResult: Bool
        let fileTitles: MacToolTimelineChrome.FileTitleCandidates?
        let styledCallSegments: [StyledSegment]?
        let trailing: MacToolTimelineChrome.TrailingPresentation
        let language: String?
        let canExpand: Bool
        let canOpenDocument: Bool
        let audioSource: MacToolAudioSource?
        let codeSize: CGFloat
    }

    private func derive() -> Derived {
        let isExpanded = self.isExpanded
        let args = store.toolArgsStore.args(for: itemID)
        let details = store.toolDetailsStore.details(for: itemID)
        let presentation = MacToolRowPresentation.make(
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
        let isVoice = ToolContentDescriptorBuilder.audioPresentation(from: details) != nil
        let audioSource: MacToolAudioSource?
        if case .media(let media) = presentation.content {
            audioSource = MacToolAudioSourceResolver.source(
                media: media,
                sessionID: sessionID,
                routeScope: store.selectedTarget?.routeScope
            )
        } else {
            audioSource = nil
        }
        return Derived(
            isExpanded: isExpanded,
            presentation: presentation,
            args: args,
            details: details,
            isVoicePresentationResult: isVoice,
            fileTitles: MacToolTimelineChrome.fileTitleCandidates(
                tool: tool,
                args: args,
                argsSummary: argsSummary,
                isExpanded: isExpanded
            ),
            styledCallSegments: MacToolTimelineChrome.styledCallSegments(
                tool: tool,
                isExpanded: isExpanded,
                isVoicePresentationResult: isVoice,
                segments: store.toolCallSegments(for: itemID)
            ),
            trailing: MacToolTimelineChrome.trailingPresentation(
                tool: tool,
                args: args,
                details: details,
                resultSegments: store.toolResultSegments(for: itemID),
                isDone: isDone,
                isInterrupted: isInterrupted
            ),
            language: MacToolTimelineChrome.languageLabel(
                tool: tool,
                args: args,
                argsSummary: argsSummary,
                content: presentation.content
            ),
            canExpand: canExpand(content: presentation.content),
            canOpenDocument: MacToolTimelineChrome.offersDocumentView(for: presentation.content),
            audioSource: audioSource,
            codeSize: FontPreferenceStore.macCodeFont().pointSize
        )
    }

    var body: some View {
        let _ = typographyRevision
        let row = derive()
        let shape = RoundedRectangle(cornerRadius: MacToolTimelineChrome.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            header(row)

            if row.isExpanded {
                expandedBody(row)
            }
        }
        // Same 14 pt inner edge as message and thinking cards, so every row's
        // first glyph lines up down the column.
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macTimelineCard(
            ThemeShapeStyle(role: state.surfaceRole).opacity(state.surfaceOpacity),
            stroke: AnyShapeStyle(ThemeShapeStyle(role: state.borderRole).opacity(state.borderOpacity)),
            cornerRadius: MacToolTimelineChrome.cornerRadius
        )
        .overlay {
            if isSelected {
                shape.strokeBorder(.themeBlue.opacity(0.72), lineWidth: 2)
            }
        }
        .contentShape(shape)
        .simultaneousGesture(TapGesture().onEnded {
            store.selectToolRow(itemID)
        })
        .accessibilityIdentifier("mac.timeline.toolRow")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(row.isExpanded ? "Expanded" : "Collapsed")
        .task(id: row.isExpanded ? itemID : "") {
            guard row.isExpanded else { return }
            await loadFullToolOutput?(itemID)
        }
    }

    private func header(_ row: Derived) -> some View {
        HStack(spacing: 6) {
            headerSummary(row)

            HStack(spacing: 6) {
                if let audioSource = row.audioSource {
                    MacToolAudioPlaybackButton(itemID: itemID, source: audioSource)
                }
                MacToolElapsedLabel(
                    startedAt: row.isVoicePresentationResult ? nil : store.toolStartTime(for: itemID),
                    elapsedSeconds: row.isVoicePresentationResult ? nil : store.toolElapsed(for: itemID),
                    isDone: isDone,
                    size: row.codeSize * 0.8
                )
                .accessibilityHidden(true)
                trailingMetadata(row)
                    .accessibilityHidden(true)
                languageMetadata(row)

                if row.canExpand {
                    Button {
                        store.selectToolRow(itemID)
                        store.setToolRowExpanded(itemID, expanded: !row.isExpanded)
                    } label: {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: row.codeSize * 0.72, weight: .semibold))
                            .foregroundStyle(.themeComment)
                            .frame(
                                width: MacToolTimelineChrome.compactActionTargetSize,
                                height: MacToolTimelineChrome.compactActionTargetSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Keep the descriptive metadata as one concise accessibility element,
    /// while the adjacent audio and disclosure buttons remain real actions.
    /// Mouse: click toggles expansion, double-click opens the document column
    /// (`handleToolRowClick`); the named action keeps that reachable without
    /// a pointer.
    private func headerSummary(_ row: Derived) -> some View {
        HStack(spacing: 7) {
            Image(systemName: MacToolTimelineChrome.statusSymbolName(
                isDone: isDone,
                isError: isError,
                isInterrupted: isInterrupted
            ))
                .font(.system(size: row.codeSize * 0.95, weight: .semibold))
                .foregroundStyle(ThemeShapeStyle(role: state.statusRole))
            if let symbolName = MacToolTimelineChrome.toolSymbolName(tool: tool) {
                Image(systemName: symbolName)
                    .font(.system(size: row.codeSize * 0.85, weight: .semibold))
                    .foregroundStyle(ThemeShapeStyle(role: MacToolTimelineChrome.toolAccentRole(tool: tool)))
                    .help(MacToolTimelineChrome.displayTitle(tool: tool))
            }
            headerTitle(row)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            store.handleToolRowClick(
                itemID,
                clickCount: NSApp.currentEvent?.clickCount ?? 1,
                canExpand: row.canExpand,
                canOpenDocument: row.canOpenDocument
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerAccessibilityLabel(row))
        .accessibilityActions {
            if row.canOpenDocument {
                Button("Open in Document View") {
                    store.openToolDocument(itemID)
                }
            }
        }
    }

    @ViewBuilder
    private func headerTitle(_ row: Derived) -> some View {
        if let titles = row.fileTitles {
            if row.isExpanded {
                plainHeaderTitle(titles.full, row: row)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    plainHeaderTitle(titles.full, row: row)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, 18)
                    plainHeaderTitle(titles.breadcrumb, row: row)
                        .fixedSize(horizontal: true, vertical: false)
                    plainHeaderTitle(titles.fileName, row: row)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else if let styledCallSegments = row.styledCallSegments {
            MacStyledSegmentText(segments: styledCallSegments, scale: .title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(argsSummary)
        } else {
            plainHeaderTitle(MacToolTimelineChrome.headerTitle(
                tool: tool,
                args: row.args,
                argsSummary: argsSummary,
                details: row.details,
                isExpanded: row.isExpanded,
                isVoicePresentationResult: row.isVoicePresentationResult
            ), row: row)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func plainHeaderTitle(_ title: String, row: Derived) -> some View {
        Text(title)
            .font(Font(FontPreferenceStore.macCodeFont(weight: .semibold)))
            .foregroundStyle(.themeToolTitle)
            .help(row.fileTitles?.full ?? argsSummary)
    }

    @ViewBuilder
    private func languageMetadata(_ row: Derived) -> some View {
        if let language = row.language {
            Image(systemName: MacToolTimelineChrome.languageSymbolName(language))
                .font(.system(size: row.codeSize * 0.85, weight: .semibold))
                .foregroundStyle(.themeBlue)
                .help(language)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func trailingMetadata(_ row: Derived) -> some View {
        let trailing = row.trailing
        let metaFont = Font.system(size: row.codeSize * 0.8).monospacedDigit()
        if let added = trailing.added,
           let removed = trailing.removed {
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
            .font(metaFont)
            .fixedSize()
        } else if let segments = trailing.segments {
            MacStyledSegmentText(segments: segments, scale: .trailing)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: row.codeSize * 9, alignment: .trailing)
                .help(segments.map(\.text).joined())
        } else if let text = trailing.text {
            Text(text)
                .font(metaFont)
                .foregroundStyle(isInterrupted ? .themeOrange : .themeComment)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func expandedBody(_ row: Derived) -> some View {
        if let command = MacBashCommandChrome.commandText(
            tool: tool,
            args: row.args,
            argsSummary: argsSummary,
            outputText: MacToolRowOutput.displayed(
                isExpanded: row.isExpanded,
                storeOutput: (toolOutputStore ?? store.toolOutputStore).fullOutput(for: itemID),
                outputPreview: outputPreview
            )
        ) {
            MacBashCommandBar(command: command)
        }

        toolOutput(row)
    }

    @ViewBuilder
    private func toolOutput(_ row: Derived) -> some View {
        switch row.presentation.content {
        case .diff(let diff):
            MacToolTimelineDiffPreview(diff: diff)
                .frame(maxHeight: row.isExpanded ? nil : 220, alignment: .top)
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
            .frame(maxHeight: row.isExpanded ? 360 : 180)
        case .markdown(let markdown):
            MacMarkdownDocumentView(
                markdown: markdown.text,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                filePath: markdown.filePath
            )
            .textSelection(.enabled)
            .lineLimit(row.isExpanded ? nil : 12)
        case .file(let file):
            fileOutput(file, row: row)
        case .media(let media):
            MacToolDocumentMediaView(
                media: media,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                routeScope: store.selectedTarget?.routeScope
            )
            .frame(maxHeight: row.isExpanded ? nil : 220, alignment: .top)
            .clipped()
        case .terminal(let terminal):
            terminalOutput(terminal, row: row)
        case .status(let message):
            Text(message)
                .font(.system(size: row.codeSize * 0.85))
                .foregroundStyle(.themeFgDim)
        case nil:
            EmptyView()
        }
    }

    private func canExpand(content: ToolContentDescriptor?) -> Bool {
        argsSummary.components(separatedBy: .newlines).count > 4
            || argsSummary.count > 240
            || outputPreview.components(separatedBy: .newlines).count > 8
            || outputPreview.count > 800
            || outputByteCount > outputPreview.utf8.count
            || outputPreview.count >= ChatItem.maxPreviewLength
            || toolOutputStore?.hasPreviewOnlyOutput(for: itemID) == true
            || (toolOutputStore?.hasCompleteOutput(for: itemID) == true
                && (toolOutputStore?.fullOutput(for: itemID).count ?? 0) > outputPreview.count)
            || descriptorSupportsExpansion(content)
    }

    private func descriptorSupportsExpansion(_ content: ToolContentDescriptor?) -> Bool {
        switch content {
        case .diff, .code, .file, .media, .markdown, .terminal, .status:
            return true
        case .none:
            return false
        }
    }

    @ViewBuilder
    private func terminalOutput(_ terminal: ToolContentDescriptor.Terminal, row: Derived) -> some View {
        let output = terminal.output ?? ""
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            MacTerminalOutputPreview(
                model: MacTerminalOutputModel(text: output, isError: isError),
                isExpanded: row.isExpanded,
                itemID: itemID
            )
        }
    }

    @ViewBuilder
    private func fileOutput(_ file: ToolContentDescriptor.File, row: Derived) -> some View {
        if MacToolDocumentColumnPaint.fileUsesPDFPreview(file) {
            Label(file.filePath ?? "PDF", systemImage: "doc.richtext")
                .font(.system(size: row.codeSize * 0.85))
                .foregroundStyle(.themeFg)
        } else if let plan = DelimitedTableViewerPlan.opening(
            fileType: file.fileType ?? .plain,
            path: file.filePath,
            text: file.text
        ) {
            MacDelimitedTablePreviewView(
                plan: plan,
                fillsColumn: false,
                filePath: file.filePath
            )
            .frame(maxHeight: row.isExpanded ? 360 : 180)
            .clipped()
        } else if let plan = GeoJSONViewerPlan.opening(
            fileType: file.fileType ?? .plain,
            path: file.filePath,
            text: file.text
        ) {
            MacGeoJSONPreviewView(
                plan: plan,
                fillsColumn: false,
                filePath: file.filePath
            )
            .frame(maxHeight: row.isExpanded ? 360 : 180)
            .clipped()
        } else if let kind = MacMarkupPreviewKind.from(file: file) {
            MacMarkupSourcePreviewView(source: file.text, kind: kind, fillsColumn: false)
                .frame(maxHeight: row.isExpanded ? 360 : 180)
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
            .frame(maxHeight: row.isExpanded ? 360 : 180)
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
            .lineLimit(row.isExpanded ? nil : 12)
        } else if file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            MacTerminalOutputPreview(
                model: MacTerminalOutputModel(text: file.text, isError: isError),
                isExpanded: row.isExpanded,
                itemID: itemID,
                sourceKind: file.filePath == nil ? .terminalOutput : .file,
                path: file.filePath
            )
        }
    }

    private func headerAccessibilityLabel(_ row: Derived) -> String {
        var parts = [
            row.styledCallSegments?.map(\.text).joined()
                ?? MacToolTimelineChrome.headerTitle(
                    tool: tool,
                    args: row.args,
                    argsSummary: argsSummary,
                    details: row.details,
                    isExpanded: row.isExpanded,
                    isVoicePresentationResult: row.isVoicePresentationResult
                ),
            MacToolTimelineChrome.statusLabel(
                isDone: isDone,
                isError: isError,
                isInterrupted: isInterrupted
            ),
        ]
        if let language = row.language {
            parts.insert(language, at: parts.count - 1)
        }
        if let trailing = row.trailing.accessibilityText, !trailing.isEmpty {
            parts.insert(trailing, at: parts.count - 1)
        }
        if let elapsed = MacToolTimelineChrome.elapsedText(
            startedAt: row.isVoicePresentationResult ? nil : store.toolStartTime(for: itemID),
            elapsedSeconds: row.isVoicePresentationResult ? nil : store.toolElapsed(for: itemID),
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
    @Environment(\.macTypographyRevision) private var typographyRevision

    var body: some View {
        // Attributed text requires concrete colors. Reading `theme` here keeps
        // mounted timeline rows tied to the live environment on every repaint.
        let _ = typographyRevision
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

    /// Same code family and zoom as plain tool titles, so styled and plain
    /// headers line up row to row.
    private func font(for style: StyledSegment.Style?) -> Font {
        let weight: NSFont.Weight = style == .bold ? .semibold : .regular
        switch scale {
        case .title:
            return Font(FontPreferenceStore.macCodeFont(weight: weight))
        case .trailing:
            let size = FontPreferenceStore.macCodeFont().pointSize * 0.8
            return Font(FontPreferenceStore.macCodeFont(size: size, weight: weight))
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
    let size: CGFloat

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
                .font(.system(size: size).monospacedDigit())
                .foregroundStyle(.themeComment)
                .fixedSize()
        }
    }
}

private struct MacBashCommandBar: View {
    @Environment(\.macTypographyRevision) private var typographyRevision
    let command: String

    var body: some View {
        let _ = typographyRevision
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$")
                .font(Font(FontPreferenceStore.macCodeFont(weight: .semibold)))
                .foregroundStyle(.themeGreen)
            Text(MacSyntaxHighlighter.tokenColoredText(command, language: .shell))
                .font(Font(FontPreferenceStore.macCodeFont()))
                .foregroundStyle(.themeToolTitle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.themeBgHighlight, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.themeBlue.opacity(0.30), lineWidth: 1)
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
    @Environment(\.macTypographyRevision) private var typographyRevision
    let diff: ToolContentDescriptor.Diff
    @Environment(\.theme) private var theme

    private var language: SyntaxLanguage? {
        MacToolDocumentDiffLayout.syntaxLanguage(for: diff)
    }

    var body: some View {
        let _ = typographyRevision
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
                    Text(row.text.isEmpty
                        ? AttributedString(" ")
                        : MacSyntaxHighlighter.tokenColoredText(row.text, language: language))
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
    @Environment(\.macTypographyRevision) private var typographyRevision
    let model: MacCodeOutputModel
    var source: MacReviewCommentSource = MacReviewCommentSource(kind: .timelineText)
    @Environment(\.theme) private var theme

    @State private var wrapsLines = false
    @State private var didCopy = false

    var body: some View {
        let _ = typographyRevision
        // Same card as iOS `NativeCodeBlockView`: highlight header, dark body,
        // one border. A floating language label over a second box reads as a
        // different control.
        VStack(alignment: .leading, spacing: 0) {
            header
            MacReviewCommentTextView(
                text: model.text,
                attributedText: MacSyntaxHighlighter.attributedCode(
                    model.text,
                    language: model.syntaxLanguage
                ),
                source: source,
                fillsColumn: wrapsLines,
                heightBehavior: .fitContent(maxHeight: 360),
                textContainerInset: NSSize(width: 8, height: 4)
            )
            .accessibilityIdentifier("markdown.codeBlock.text")
            .frame(maxHeight: 360)
        }
        .background(.themeBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.markdown.codeBlockBorder.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown.codeBlock")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.language ?? "code")
                // iOS language label is `AppFont.mono` (11 pt). HIG macOS
                // minimum is 10 pt; this chrome stays at 11 so it does not
                // grow with message zoom.
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.text.tertiary)
                .lineLimit(1)
                .accessibilityIdentifier("markdown.codeBlock.language")
            Spacer(minLength: 8)
            headerButton(
                // Same wrap glyph as iOS `CodeWrapControl`.
                systemImage: "text.alignleft",
                label: wrapsLines ? "Scroll" : "Wrap",
                identifier: "markdown.codeBlock.wrap"
            ) {
                wrapsLines.toggle()
            }
            headerButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                label: didCopy ? "Copied" : "Copy",
                identifier: "markdown.codeBlock.copy"
            ) {
                copy()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.themeBgHighlight)
    }

    private func headerButton(
        systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(theme.text.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .help(label)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
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
    @Environment(\.macTypographyRevision) private var typographyRevision
    let itemID: String
    let preview: String
    let hasMore: Bool
    let isDone: Bool
    var hiddenThinkingLabel: String? = nil
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
        let _ = typographyRevision
        // Match iOS: no "Thinking" title. Done gets a sparkle; streaming is
        // plain muted callout. WorkingIndicator already shows activity.
        let glyphSize = FontPreferenceStore.macMessagePointSize(forTextStyle: .callout)
        // The fold is a custom Layout with no text baseline; align by top.
        HStack(alignment: .top, spacing: 8) {
            if isDone, !preview.isEmpty {
                Image(systemName: "sparkle")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(theme.accent.purple.opacity(0.7))
                    .padding(.top, glyphSize * 0.15)
                    .accessibilityHidden(true)
            }
            thinkingBody
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macTimelineCard(
            theme.text.tertiary.opacity(isDone ? 0.08 : 0.06),
            stroke: AnyShapeStyle(theme.text.primary.opacity(0.06))
        )
        .contextMenu {
            if overflowsPaintedCap {
                Button(isExpanded ? "Show Less" : "Show All") {
                    isExpanded.toggle()
                }
            }
        }
        .accessibilityIdentifier("mac.timeline.thinkingRow")
        .accessibilityLabel(hiddenThinkingLabel ?? "Thinking")
        .accessibilityValue(foldAccessibilityValue)
        .accessibilityAction(named: isExpanded ? "Show Less" : "Show All") {
            guard overflowsPaintedCap else { return }
            isExpanded.toggle()
        }
    }

    @ViewBuilder
    private var thinkingBody: some View {
        if preview.isEmpty {
            if let hiddenThinkingLabel {
                Text(hiddenThinkingLabel)
                    .font(Font(FontPreferenceStore.macMessageFont(forTextStyle: .callout)))
                    .foregroundStyle(.themeComment)
            }
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

/// iOS message rows on a desktop column: the user bubble carries the blue
/// prompt glyph on its own surface; the assistant bubble is a quiet purple
/// card led by the model's provider mark.
private struct MarkdownTimelineBubble: View {
    @Environment(\.macTypographyRevision) private var typographyRevision
    let role: MacTimelineProseRole
    let timestamp: Date
    let text: String
    var images: [ImageAttachment] = []
    var itemID: String? = nil
    let context: ChatItemRowContext
    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    var body: some View {
        let _ = typographyRevision
        switch role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        }
    }

    private var userBubble: some View {
        let bodySize = FontPreferenceStore.macMessagePointSize(forTextStyle: .body)
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\u{276F}")
                .font(Font(FontPreferenceStore.macCodeFont(size: bodySize, weight: .semibold)))
                .foregroundStyle(theme.accent.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    MacUserMessageImageStrip(images: images)
                }
                prose
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macTimelineCard(themeID.palette.userMessageBg)
        .help("You \u{00B7} \(timestamp.relativeString())")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.timeline.userMessage")
        .accessibilityLabel("You, \(timestamp.relativeString())")
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacAssistantMessageHeader(model: context.model, timestamp: timestamp)
            prose
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macTimelineCard(theme.accent.purple.opacity(0.08))
        .accessibilityIdentifier("mac.timeline.assistantMessage")
    }

    @ViewBuilder
    private var prose: some View {
        if !text.isEmpty {
            MacMarkdownDocumentView(
                markdown: text,
                itemID: itemID,
                workspaceID: context.workspaceID,
                sessionID: context.sessionID,
                worktreeId: context.worktreeId,
                typography: .message
            )
            .textSelection(.enabled)
        }
    }
}

/// Model identity for an assistant message, where iOS puts its row badge.
/// The provider mark follows the session's model; Pi's mark stands in when
/// the model has no known provider.
private struct MacAssistantMessageHeader: View {
    @Environment(\.macTypographyRevision) private var typographyRevision
    let model: String?
    let timestamp: Date
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = typographyRevision
        let size = MacTimelineChromeType.labelSize
        let badge = (size * 1.55).rounded()
        HStack(spacing: 7) {
            Group {
                if let provider = modelProviderKey(model) {
                    ProviderGlyph(provider: provider, size: (badge * 0.62).rounded(), color: theme.text.primary)
                        .frame(width: badge, height: badge)
                        .background(
                            theme.text.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: badge * 0.32, style: .continuous)
                        )
                } else {
                    MacAssistantAvatarView(size: badge)
                }
            }
            .accessibilityIdentifier("mac.timeline.assistantAvatar")
            .accessibilityHidden(true)

            Text(MacModelSelection.shortDisplayName(for: model) ?? "Assistant")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
            Text(timestamp.relativeString())
                .font(.system(size: MacTimelineChromeType.captionSize))
                .foregroundStyle(theme.text.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TimelineBubble: View {
    @Environment(\.macTypographyRevision) private var typographyRevision
    let title: String
    let subtitle: String?
    let text: String
    let fill: Color
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = typographyRevision
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: MacTimelineChromeType.labelSize, weight: .semibold))
                    .foregroundStyle(theme.text.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: MacTimelineChromeType.captionSize))
                        .foregroundStyle(theme.text.secondary)
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(Font(FontPreferenceStore.macMessageFont(forTextStyle: .body)))
                    .foregroundStyle(theme.text.primary)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macTimelineCard(fill)
    }
}
