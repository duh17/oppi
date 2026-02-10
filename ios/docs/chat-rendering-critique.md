# Chat Rendering Critique — iOS vs pi TUI

> Feb 9, 2026. Full audit of iOS chat pipeline compared against pi TUI reference.

## Architecture Comparison

| Concern | pi TUI | iOS (PiRemote) |
|---------|--------|-----------------|
| Event source | Direct `subscribe()` on `AgentSession` | WebSocket → `ServerConnection` → `AgentEvent` |
| Batching | None — TUI renders on every event via `requestRender()` | `DeltaCoalescer` batches at 33ms |
| State model | Mutable components (Container, Box, Text) — mutated in-place | Value-type `ChatItem` enum in `@Observable` `TimelineReducer` |
| Tool rendering | `ToolExecutionComponent` per tool — stateful, updates args/result | `ToolCallRow` reads from `ToolOutputStore` + `ToolArgsStore` |
| Diff rendering | `computeEditDiff()` async + `renderDiff()` | `DiffEngine.compute()` sync + `DiffContentView` |
| Expand/collapse | Global toggle — all tools expand/collapse at once | Per-item — individual tool expand/collapse |

## What the TUI Gets Right That iOS Should Match

### 1. Streaming Tool Args Update

**TUI**: During `message_update`, the TUI creates a `ToolExecutionComponent` as soon as a
`toolCall` content block appears in the streaming message. As `toolcall_delta` events arrive
with partial arguments, it calls `component.updateArgs(content.arguments)` — the user sees
the bash command or file path being typed out in real-time.

**iOS**: The `TimelineReducer` only creates the `toolCall` ChatItem on `toolStart` — which
fires AFTER the full message is received and tool execution begins. During streaming, the user
sees nothing about the upcoming tool call. They go from reading assistant text straight to a
completed tool header.

**Gap**: iOS users miss the "agent is about to run X" preview moment. This is the biggest
functional gap.

**Fix**: The iOS wire protocol already has this data — `message_update` events include
`toolcall_start`, `toolcall_delta`, `toolcall_end`. The server translates these to
`tool_call_start`/`tool_call_delta` events. We should:
1. Add `AgentEvent.toolCallStreaming(sessionId:, toolCallId:, tool:, partialArgs:)` 
2. Create the ChatItem.toolCall on first `toolcall_start` with empty args, `isDone: false`
3. Update the args summary on each `toolcall_delta`
4. Tool already starts executing when `toolStart` fires — just update the existing item

### 2. Edit Diff Preview (Pre-Execution)

**TUI**: When `message_end` fires (args are complete, before execution), the TUI calls
`component.setArgsComplete()` which triggers async `computeEditDiff()`. The user sees the
diff BEFORE the edit tool runs. If the diff shows a mistake, they can abort.

**iOS**: The diff only appears AFTER the edit completes — inside the expanded `ToolCallRow`.
There's no pre-execution preview.

**Fix**: When the server sends `tool_execution_start` for an edit tool, immediately compute
the diff from `args.oldText` + `args.newText` and show it in the tool row body. This gives
the user the same preview window as the TUI.

### 3. Tool Background State Colors

**TUI**: Tools have three distinct background states:
- `toolPendingBg` (yellowish) — currently executing
- `toolSuccessBg` (greenish) — completed successfully  
- `toolErrorBg` (reddish) — failed

**iOS**: All tool rows use the same `tokyoBgHighlight.opacity(0.75)` regardless of state.
The only state indicator is the small status icon (play/check/x) in the header.

**Fix**: Add background tinting based on `isDone` + `isError`:
- Running: current neutral bg (or very subtle blue tint)
- Done + success: very subtle green tint  
- Done + error: subtle red tint  
Keep it subtle — the TUI's full-row bg tint works in a terminal but would be too heavy in iOS.

### 4. Bash Output Preview (Collapsed)

**TUI**: When a bash tool completes, the collapsed view shows the LAST 5 lines of output
(via `truncateToVisualLines`). This is brilliant — you see the most relevant output (exit
status, final result) without expanding.

**iOS**: Collapsed bash shows nothing — just the `$ command` header. You must expand to see
any output.

**Fix**: Show last 3-5 lines of output preview below the bash header when collapsed. Use
`outputPreview` (already stored in ChatItem, up to 500 chars) for this.

### 5. Read Tool: Syntax-Highlighted Preview

**TUI**: Collapsed read tools show the first 10 lines with syntax highlighting based on
file extension. The file content is visible without expanding.

**iOS**: Collapsed read shows nothing. Expanding shows full `FileContentView` with line
numbers and syntax highlighting — that part is actually excellent.

**Fix**: Show first 3-5 lines of file content below the header when collapsed, using the
same syntax highlighting. Preview is already in `outputPreview`.

## What iOS Gets Right That TUI Doesn't

### 1. Per-Item Expand/Collapse
iOS lets users expand individual tool calls. TUI is all-or-nothing. iOS wins here.

### 2. File Navigation
iOS has tappable file paths that open `RemoteFileView`. TUI can't do this (it's a terminal).

### 3. Diff View
iOS `DiffContentView` with colored accent bars, gutter prefixes, syntax highlighting on
context lines, and proper horizontal scrolling is excellent. The TUI's diff is good but iOS
has better visual affordances.

### 4. Lazy Output Loading
iOS evicts old tool output from memory and lazy-loads it from the server trace when
expanded. Smart memory management that the TUI doesn't need (terminal sessions are ephemeral).

### 5. Image Rendering
iOS `ImageBlobView` with tap-to-zoom is great. Terminal image support is hacky (Kitty
protocol, PNG conversion, etc.)

### 6. JSON Pretty-Print View
iOS `JSONFileView` with pretty-printing + syntax highlighting is nice polish.

### 7. Markdown Toggle
`MarkdownFileView` with raw/rendered toggle — good for inspecting markdown output.

## Reliability Issues

### R1. Tool Event Ordering Assumption

**ToolEventMapper** assumes strictly sequential tool events:
```
v1 assumption: tool events are strictly sequential (one open tool at a time)
```

This is wrong. The pi RPC protocol supports parallel tool execution. If the LLM requests
multiple tool calls in one message, `tool_execution_start` events for different tools can
interleave. The `toolCallId` field disambiguates them.

**Current behavior**: If two tools start before the first ends, `currentToolEventID` gets
overwritten and output for the first tool gets attributed to the second.

**Fix**: The mapper already prefers `toolCallId` when provided. The only risk is servers
that don't send `toolCallId` — for those, the sequential assumption holds because pi
processes tools sequentially. So this is fine for now, but the comment is misleading.

### R2. `closeOrphanedTool()` Only Closes Last Item

From the summary: `closeOrphanedTool()` in `TimelineReducer.swift:483` only closes the
LAST item. If multiple tools are orphaned (e.g., abort during parallel execution), only
the last one gets cleaned up.

**Fix**: Scan ALL items and close any unfinished `.toolCall` items.

### R3. History/Live Race Window

When switching sessions, `loadBestAvailableHistory()` loads the trace, then the WebSocket
starts delivering live events. Events that arrive between trace load and WS subscription
are lost.

**Fix**: Sequence numbering (tracked in TODO-fb28452c). Short-term: load trace, THEN
subscribe, and handle duplicate events via tool call ID dedup.

### R4. No Streaming Indicator for Assistant Message

When the assistant is streaming text, there's no visual indicator that it's still generating.
The TUI shows a spinner animation in the status bar. iOS has no equivalent.

**Fix**: Add a subtle pulsing cursor or "..." at the end of the streaming assistant message.
Or use the `isStreaming` flag on `MarkdownText` to show a cursor.

## Performance Issues (Already Tracked)

Covered in TODO-9768f53b (Phase 1 fixes already applied):
- [x] O(1) item lookups via `itemIndexByID`
- [x] Skip `AttributedString(markdown:)` during streaming
- [x] Cache `parseCodeBlocks()`
- [ ] Pre-decode user message images off main thread

## Recommended Priority

### Must-Have (core experience gaps)
1. **Bash output preview when collapsed** — users need to see command results without expanding
2. **Tool state background tinting** — pending/success/error must be visually distinct
3. **Fix `closeOrphanedTool()` to close ALL unfinished tools** — reliability

### Should-Have (parity with TUI)
4. **Streaming tool args** — show tool name + partial args as they arrive
5. **Read/write file preview when collapsed** — first few lines visible
6. **Edit diff preview before execution** — show diff while tool runs

### Nice-to-Have (polish)
7. **Streaming cursor indicator** — pulsing dot or cursor at end of streaming text
8. **Find/grep/ls smart headers** — pattern, path, glob display (currently generic)
