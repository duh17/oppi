# Chat Rendering Architecture

**Date:** February 2026

## Event Flow

```
Server (pi RPC)
  ↓ WebSocket
ServerMessage (raw JSON)
  ↓ WebSocketClient.decodeMessage()
AgentEvent (domain events)
  ↓ DeltaCoalescer (33ms batching for text/thinking/toolOutput)
[AgentEvent] batch
  ↓ TimelineReducer.processBatch()
[ChatItem] array + ToolOutputStore + ToolArgsStore
  ↓ ChatView (LazyVStack, keyed by renderVersion)
ChatItemRow (per-item view dispatch)
  ↓
UserMessageBubble | AssistantMessageBubble | ThinkingRow | ToolCallRow | ...
```

## Data Models

### ChatItem (timeline display)

Flat enum — one variant per visual row type:

```
.userMessage(id, text, images, timestamp)
.assistantMessage(id, text, timestamp)
.thinking(id, preview, hasMore, isDone)
.toolCall(id, tool, argsSummary, outputPreview, outputByteCount, isError, isDone)
.permission(PermissionRequest)
.permissionResolved(id, action)
.systemEvent(id, message)
.error(id, message)
```

Design decisions:
- `Equatable` for cheap SwiftUI diffing
- Tool output stored externally in `ToolOutputStore` (not in ChatItem)
- Tool args stored externally in `ToolArgsStore` (not in ChatItem)
- Preview fields capped at 500 chars
- Expansion state in `TimelineReducer.expandedItemIDs` (not in ChatItem)

### Stores (external state for tool calls)

| Store | Purpose | Capacity |
|---|---|---|
| `ToolOutputStore` | Full tool output text | 512KB/item, 4MB total, FIFO eviction |
| `ToolArgsStore` | Structured tool arguments | Unbounded (trimmed with items) |

### TraceEvent (historical replay)

Flat struct for JSONL trace entries. Types: `user`, `assistant`, `toolCall`,
`toolResult`, `thinking`, `system`, `compaction`.

Server-side `trace.ts` does the splitting: one API response with
`[thinking, text, toolCall, toolCall]` becomes 4 separate TraceEvents.

## Streaming vs Trace Loading

### Streaming (live WebSocket)

```
text_delta("Hello")  →  assistantBuffer += "Hello"; upsertAssistantMessage()
text_delta(" world") →  assistantBuffer += " world"; upsertAssistantMessage()
tool_start(bash, {command: "ls"})  →  finalizeAssistantMessage(); append toolCall
tool_output("file1\nfile2")  →  toolOutputStore.append(); updateToolCallPreview()
tool_end(bash)  →  updateToolCallDone()
text_delta("Done")  →  NEW assistantBuffer; upsertAssistantMessage()
agent_end  →  finalizeAssistantMessage(); finalizeThinking(); closeOrphanedTool()
```

Key: `finalizeAssistantMessage()` on `toolStart` splits text around tools.

### Trace Loading (reconnect/history)

```
TraceEvent(.assistant, "Hello world")  →  items.append(.assistantMessage)
TraceEvent(.toolCall, "bash", args)    →  items.append(.toolCall)
TraceEvent(.toolResult, output)        →  toolOutputStore.append()
TraceEvent(.assistant, "Done")         →  items.append(.assistantMessage)
```

The server's `trace.ts` already splits content blocks into separate events,
so `loadFromTrace` just appends sequentially.

## View Rendering

### Assistant Messages

```
AssistantMessageBubble
  → MarkdownText(text, isStreaming)
    → parseCodeBlocks(content)
      → [ContentBlock] array
        → .markdown(text)     → proseBlock() → Text(AttributedString) or plain Text
        → .codeBlock(lang, code, isComplete)
            → isStreaming && !isComplete → StreamingCodeBlockView (plain)
            → else → CodeBlockView (async syntax highlight)
        → .table(headers, rows) → TableBlockView (compact, scrollable)
```

Streaming optimization: `isStreaming: true` → prose uses plain `Text()`,
active code block uses plain monospaced text. Only finalized content gets
`AttributedString(markdown:)` and `SyntaxHighlighter`.

### Tool Calls

```
ToolCallRow
  → toolHeader (switch on tool name)
    → bash: "$ command..."
    → read/write/edit: icon + verb + file path (tappable)
    → generic: tool name + argsSummary
  → expandedContent (when expanded)
    → edit: DiffContentView (old vs new)
    → write: FileContentView (syntax highlighted)
    → read: FileContentView or ImageBlobView
    → other: ToolOutputContent (ANSI parsed text + inline images)
```

Two-stage expand not yet implemented. Currently shows full output on expand.

## JSONL Format (pi session files)

Each line is a JSON object with `type: "message"` and nested `message`:

```json
{"type":"message","message":{"role":"assistant","content":[
  {"type":"text","text":"\n\n"},
  {"type":"thinking","thinking":"..."},
  {"type":"text","text":"Here's what I found:"},
  {"type":"toolCall","id":"toolu_xxx","name":"bash","arguments":{"command":"ls"}}
],"stopReason":"toolUse"}}
```

```json
{"type":"message","message":{"role":"toolResult","toolCallId":"toolu_xxx","content":[
  {"type":"text","text":"file1\nfile2"}
]}}
```

The server's `trace.ts` flattens content arrays into individual `TraceEvent`s.
Whitespace-only text blocks (`"\n\n"`) are preserved in the JSONL but filtered
out by `TimelineReducer.loadFromTrace()` to avoid empty bubbles.

## Known Issues and Planned Improvements

### Markdown Rendering Gaps

Current `parseCodeBlocks` handles: prose, fenced code blocks, tables.

Missing (rendered as plain inline text):
- Ordered/unordered lists (numbered items, bullet points)
- Headings (`# H1`, `## H2`, etc.)
- Blockquotes (`> quoted text`)
- Horizontal rules (`---`)
- Nested list items

Performance impact of adding these: near-zero (see `chat-rendering-analysis.md`).

### Tool Output Expansion

Current: binary expand/collapse (full output or hidden).
Planned: two-stage expand (first 10-15 lines → "show all" → full output).

### AttributedString Caching

Current: re-created on every body evaluation of finalized `MarkdownText`.
Planned: cache by content identity to avoid re-parsing on scroll-into-view.

### Custom Tool Headers

Current: `recall`, `remember`, `todo` use generic header (tool name + argsSummary).
Planned: custom formatting (just query text for recall, just note text for remember).
