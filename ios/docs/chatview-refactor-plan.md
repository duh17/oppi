# ChatView Refactor Plan

> Feb 9, 2026. Based on review of chat-rendering-critique.md against current code.

## Status of Critique Items

### Already Fixed (no action needed)

| Critique Item | Status | Where |
|--------------|--------|-------|
| Tool state background tinting | Done | `ToolCallRow.stateBackground/stateBorder` — green/red/neutral |
| Bash output preview collapsed | Done | `ToolCallRow.bashCollapsedPreview` — last 3 lines |
| Read file preview collapsed | Done | `ToolCallRow.fileCollapsedPreview` — first 3 lines |
| Edit +/- summary collapsed | Done | `ToolCallRow.editCollapsedPreview` |
| `closeOrphanedTool` only closes last | Done | `closeAllOrphanedTools()` scans ALL items |
| Streaming cursor indicator (R4) | Done | `StreamingCursor` component in `AssistantMessageBubble` |

### Still Open

| Critique Item | Priority | Complexity |
|--------------|----------|------------|
| Streaming tool args preview | Should-have | Medium — server + iOS |
| Edit diff preview before execution | Nice-to-have | Low — iOS only |
| ChatView structural decomposition | Must-have | Medium — iOS only |
| ToolCallRow decomposition | Should-have | Medium — iOS only |
| History/live race window (R3) | Should-have | High — server + iOS |

## ChatView Structural Analysis

Current `ChatView.swift`: ~450 lines mixing 5 concerns:

1. **Connection lifecycle** (connectToSession, loadBestAvailableHistory, traceAppearsComplete, disconnectIfCurrentGeneration)
2. **Scroll management** (scrollAnchor, scrollTask, onChange handlers, sentinel)
3. **UI composition** (body, toolbar, sheets, alerts)
4. **Action handlers** (sendPrompt, sendBashCommand, cycleThinkingLevel, compactContext, newSessionInWorkspace, stopAgent, forceStopSession, reconcileSessionState)
5. **Stop/force-stop state machine** (isStopping, showForceStop, isForceStopInFlight, forceStopTask, reconcileTask)

15 `@State` properties is a signal that the view manages too many independent state dimensions.

### Proposed Decomposition

```
ChatView.swift (body + composition only, ~120 lines)
├── ChatSessionManager.swift (@Observable, connection lifecycle + history loading)
├── ChatScrollController.swift (@Observable, scroll anchor + debounced scroll)
├── ChatActionHandler.swift (@Observable, prompt/stop/steer/bash/model actions)
└── Sub-views (already extracted):
    ├── SessionToolbar
    ├── ChatInputBar
    ├── SessionOutlineView
    ├── ModelPickerSheet
    ├── ChatEmptyState (private, keep inline)
    ├── WorkingIndicator (private, keep inline)
    └── SessionEndedFooter (private, keep inline)
```

### ChatSessionManager

Owns: connection lifecycle, history loading, reconnect, state reconciliation.

```swift
@MainActor @Observable
final class ChatSessionManager {
    let sessionId: String
    private(set) var isConnected = false
    private(set) var connectionGeneration = 0

    // Replaces: connectToSession(), loadBestAvailableHistory(),
    // traceAppearsComplete(), disconnectIfCurrentGeneration(),
    // reconcileSessionState(), reconcileTask
    
    func connect(connection: ServerConnection, reducer: TimelineReducer, 
                 sessionStore: SessionStore) async { ... }
    func disconnect() { ... }
    func reconnect() { connectionGeneration &+= 1 }
}
```

### ChatScrollController

Owns: scroll state, debounced auto-scroll, scroll-to-target.

```swift
@MainActor @Observable
final class ChatScrollController {
    private let anchor = ScrollAnchorState()
    private var scrollTask: Task<Void, Never>?
    var scrollTargetID: String?
    var needsInitialScroll = false

    var isNearBottom: Bool { anchor.isNearBottom }
    func onSentinelAppear() { anchor.isNearBottom = true }
    func onSentinelDisappear() { anchor.isNearBottom = false }
    func handleRenderVersionChange(proxy: ScrollViewProxy) { ... }
    func scrollToBottom(proxy: ScrollViewProxy) { ... }
    func scrollToItem(_ id: String, proxy: ScrollViewProxy) { ... }
    func cancelPendingScroll() { ... }
}
```

### ChatActionHandler

Owns: prompt sending, stop/force-stop state machine, model changes, compaction.

```swift
@MainActor @Observable
final class ChatActionHandler {
    private(set) var isStopping = false
    private(set) var showForceStop = false
    private(set) var isForceStopInFlight = false
    // Replaces 5 @State vars + 6 action methods

    func sendPrompt(text: String, images: [PendingImage], ...) { ... }
    func sendBash(_ command: String, ...) { ... }
    func stop(connection: ServerConnection, ...) { ... }
    func forceStop(connection: ServerConnection, ...) { ... }
    func cycleThinking(connection: ServerConnection) { ... }
    func compact(connection: ServerConnection) { ... }
    func newSession(connection: ServerConnection) { ... }
    func cleanup() { ... }
}
```

### Result: ChatView body becomes ~120 lines

```swift
struct ChatView: View {
    let sessionId: String
    @Environment(...) private var connection, sessionStore, reducer
    @State private var sessionManager: ChatSessionManager
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()
    @State private var inputText = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var showOutline = false
    @State private var showModelPicker = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            SessionToolbar(...)
            chatTimeline
            inputArea
        }
        .sheets(...)
        .task(id: sessionManager.connectionGeneration) { ... }
        .onAppear { ... }
        .onDisappear { ... }
    }

    private var chatTimeline: some View { ... }
    private var inputArea: some View { ... }
}
```

## ToolCallRow Decomposition

Current `ToolCallRow`: ~420 lines with 5 environment deps, inline arg parsing, 6 header variants, 3 collapsed previews, expanded content routing, lazy loading.

### Proposed Structure

```
ToolCallRow.swift (~100 lines — dispatch + shared chrome)
├── Headers/
│   ├── BashToolHeader.swift
│   ├── FileToolHeader.swift (read/write/edit)
│   ├── SearchToolHeader.swift (grep/find/ls)
│   └── GenericToolHeader.swift
├── Previews/
│   ├── BashOutputPreview.swift
│   ├── FileContentPreview.swift
│   └── EditDiffPreview.swift
└── ToolExpandedContent.swift (expanded content routing)
```

The shared chrome (background, border, expand/collapse, context menu, lazy loading) stays in `ToolCallRow`. The tool-specific rendering dispatches to focused sub-views.

## Streaming Tool Args (Critique Item 1)

### Problem
Server's `translateEvent` only extracts `text_delta` and `thinking_delta` from `message_update`. Pi RPC also sends tool-call content blocks during `message_update` (the `content_block_start` + `content_block_delta` pattern from the Anthropic API), but the server drops them.

### Fix (server + iOS)

**Server** (`sessions.ts` `translateEvent` for `message_update`):
```typescript
case "message_update": {
    const evt = event.assistantMessageEvent;
    if (evt?.type === "text_delta") {
        return [{ type: "text_delta", delta: evt.delta }];
    }
    if (evt?.type === "thinking_delta") {
        return [{ type: "thinking_delta", delta: evt.delta }];
    }
    // NEW: forward tool call streaming events
    if (evt?.type === "content_block_start" && evt.contentBlock?.type === "tool_use") {
        return [{ type: "tool_call_streaming", toolCallId: evt.contentBlock.id, 
                  tool: evt.contentBlock.name, partialArgs: "" }];
    }
    if (evt?.type === "input_json_delta") {
        return [{ type: "tool_call_streaming_delta", 
                  partialInput: evt.partial_json }];
    }
    return [];
}
```

**iOS**: Add `AgentEvent.toolCallStreaming` case. `TimelineReducer` creates a toolCall item on first streaming event with `isDone: false`, updates `argsSummary` on deltas. `toolStart` event then just updates the existing item (matched by `toolCallId`).

### Risk
Medium — requires checking what event types pi RPC actually forwards during `message_update`. The Anthropic API sends `content_block_start`, `content_block_delta`, `content_block_stop`, but pi's `subscribe` callback may aggregate them differently.

## Edit Diff Preview Before Execution (Critique Item 2)

Simple iOS-only change: in `ToolCallRow.expandedContent`, when `isEditTool && !isDone` (still executing), show the diff from args immediately instead of waiting for `isDone`:

```swift
if isEditTool, 
   let oldText = args?["oldText"]?.stringValue,
   let newText = args?["newText"]?.stringValue {
    DiffContentView(oldText: oldText, newText: newText, filePath: toolFilePath)
}
```

Currently the `isEditTool` branch in `expandedContent` requires `!isError` but not `isDone`. Check: it already works. The fix is just ensuring the tool row auto-expands for edit tools during execution (or shows the diff in the collapsed preview).

## Implementation Order

### Phase 1: ChatView decomposition (reliability + maintainability)
1. Extract `ChatSessionManager` — connection lifecycle, history loading
2. Extract `ChatScrollController` — scroll state management
3. Extract `ChatActionHandler` — action methods, stop state machine
4. Slim down `ChatView.body` to composition only
5. Add tests for `ChatSessionManager` (connect, reconnect, history loading)
6. Add tests for `ChatActionHandler` (stop state transitions)

### Phase 2: ToolCallRow decomposition (maintainability)
1. Extract tool-specific headers into focused views
2. Extract collapsed preview views
3. Extract `ToolExpandedContent` router
4. Keep shared chrome in `ToolCallRow`

### Phase 3: Streaming tool args (feature)
1. Verify what pi RPC sends in `message_update` for tool calls
2. Update `translateEvent` in `sessions.ts` to forward tool call streaming
3. Add `AgentEvent.toolCallStreaming` + `toolCallStreamingDelta`
4. Update `TimelineReducer` to create/update tool items on streaming events
5. Test with real session

### Phase 4: Edit diff preview + polish
1. Show diff in collapsed preview for edit tools
2. Auto-expand edit tools during execution
3. Consider pre-execution diff preview in collapsed state
