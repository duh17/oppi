# Chat Rendering

Oppi renders agent conversations as a scrollable timeline of typed rows — assistant text, user messages, tool calls, compaction markers, and system events. Tool calls are the most complex: they have collapsed and expanded states, server-provided styled segments, and per-tool rendering logic.

This document covers the full rendering pipeline from server events to pixels.

## Architecture Overview

```
Pi CLI (RPC)
  │  tool_execution_start, tool_execution_end
  ▼
Oppi Server (session-protocol.ts)
  │  MobileRendererRegistry pre-renders StyledSegment[]
  │  Attaches callSegments to tool_start, resultSegments to tool_end
  ▼
WebSocket
  │  JSON messages with typed segments
  ▼
iOS (ServerMessage.swift)
  │  Decodes StyledSegment arrays
  ▼
ToolEventMapper → AgentEvent → DeltaCoalescer → TimelineReducer
  │  Stores segments in ToolSegmentStore
  │  Stores args in ToolArgsStore
  │  Stores output in ToolOutputStore
  │  Stores details in ToolDetailsStore
  ▼
ChatTimelineCollectionView
  │  Reads stores, calls ToolPresentationBuilder
  ▼
ToolPresentationBuilder
  │  Prefers server segments → falls back to hardcoded rendering
  │  Produces ToolTimelineRowConfiguration
  ▼
ToolTimelineRowContentView (UIKit)
  │  Renders collapsed title, trailing badge, expanded content
  ▼
Pixels
```

## Wire Format

### StyledSegment

The atomic unit of pre-rendered text. Each segment has text and an optional style:

```typescript
// Server (TypeScript)
interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}
```

```swift
// iOS (Swift)
struct StyledSegment: Codable, Sendable, Equatable {
    let text: String
    let style: Style?

    enum Style: String, Codable, Sendable {
        case bold, muted, dim, accent, success, warning, error
    }
}
```

### Tool Messages

Segments are attached to existing `tool_start` and `tool_end` WebSocket messages:

```json
{
  "type": "tool_start",
  "tool": "read",
  "args": { "path": "src/main.ts", "offset": 1, "limit": 50 },
  "toolCallId": "tc-001",
  "callSegments": [
    { "text": "read ", "style": "bold" },
    { "text": "src/main.ts", "style": "accent" },
    { "text": ":1-50", "style": "warning" }
  ]
}
```

```json
{
  "type": "tool_end",
  "tool": "recall",
  "toolCallId": "tc-002",
  "details": { "matches": 5, "topHeader": "Design doc" },
  "resultSegments": [
    { "text": "5 match(es)", "style": "success" },
    { "text": " — top: ", "style": "muted" },
    { "text": "[0.85] Design doc", "style": "dim" }
  ]
}
```

Segments are **optional**. When absent, iOS falls back to hardcoded rendering.

## Server: MobileRendererRegistry

The server pre-renders collapsed summary lines for each tool call. This mirrors pi's TUI `renderCall`/`renderResult` pattern, but produces serializable segments instead of terminal components.

**Source:** `server/src/mobile-renderer.ts`

### Interface

```typescript
interface MobileToolRenderer {
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}
```

### Registry

`MobileRendererRegistry` holds all renderers. It loads from two sources:

1. **Built-in renderers** — hardcoded in `mobile-renderer.ts` for standard tools
2. **Extension sidecars** — `*.mobile.ts` files alongside pi extensions

```typescript
class MobileRendererRegistry {
  // Render call segments. Returns undefined if no renderer or on error.
  renderCall(toolName: string, args: Record<string, unknown>): StyledSegment[] | undefined;

  // Render result segments. Returns undefined if no renderer or on error.
  renderResult(toolName: string, details: unknown, isError: boolean): StyledSegment[] | undefined;

  // Load a sidecar module and register its renderers.
  async loadSidecar(path: string): Promise<{ loaded: string[]; errors: string[] }>;

  // Discover and load all sidecars from the extensions directory.
  async loadAllSidecars(dir?: string): Promise<{ loaded: string[]; errors: string[] }>;
}
```

### Built-in Renderers

| Tool   | Call Example                                              | Result Example                         |
|--------|-----------------------------------------------------------|----------------------------------------|
| bash   | `$ npm test`                                              | (empty on success), `exit 127` (error) |
| read   | `read src/main.ts:1-50`                                   | `50/200 lines` (truncated)             |
| edit   | `edit src/main.ts`                                        | `applied :42`                          |
| write  | `write src/new-file.ts`                                   | `✓`                                    |
| grep   | `grep /TODO/ in src/ (*.ts)`                              | `100 match limit` (truncated)          |
| find   | `find *.ts in src/`                                       | (empty on success)                     |
| ls     | `ls src/`                                                 | (empty on success)                     |
| todo   | `todo create "Fix the bug"`                               | `Created "Fix the bug"`, `3/5 open`    |

### Wiring

The registry is instantiated once per `SessionManager` and passed through `TranslationContext`:

```
SessionManager
  └─ mobileRenderers: MobileRendererRegistry (loads sidecars at startup)
       └─ translationContext(active)
            └─ translatePiEvent(event, ctx)
                 ├─ tool_execution_start → ctx.mobileRenderers.renderCall() → callSegments
                 └─ tool_execution_end   → ctx.mobileRenderers.renderResult() → resultSegments
```

**Error resilience:** If a renderer throws, the registry catches the error and returns `undefined`. The message is sent without segments; iOS falls back to hardcoded rendering.

## Extension Sidecars

Extension authors provide mobile renderers via sidecar files alongside their pi extensions. No changes to pi are required.

### Convention

```
~/.pi/agent/extensions/
├── memory.ts              ← pi extension (TUI rendering)
├── memory.mobile.ts       ← mobile renderers (segments)
├── todos.ts
├── todos.mobile.ts
└── my-ext/
    ├── index.ts           ← pi extension
    └── mobile.ts          ← mobile renderers
```

The server discovers sidecars by scanning for `*.mobile.ts` (or `*.mobile.js`) files and `mobile.ts` inside extension directories.

### Format

Sidecars are plain TypeScript (or JavaScript) modules. They export a default object keyed by tool name:

```typescript
// memory.mobile.ts
interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}

interface MobileToolRenderer {
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}

const renderers: Record<string, MobileToolRenderer> = {
  remember: {
    renderCall(args) {
      const line = String(args.text || "").split("\n")[0].slice(0, 60);
      return [
        { text: "remember ", style: "bold" },
        { text: `"${line}"`, style: "muted" },
      ];
    },
    renderResult(details: any, isError) {
      if (isError) return [{ text: "failed", style: "error" }];
      return [
        { text: "✓ Saved ", style: "success" },
        { text: `→ ${details?.file ?? "journal"}`, style: "muted" },
      ];
    },
  },
  recall: {
    renderCall(args) {
      return [
        { text: "recall ", style: "bold" },
        { text: `"${args.query}"`, style: "muted" },
      ];
    },
    renderResult(details: any, isError) {
      if (isError) return [{ text: `Error: ${details?.error}`, style: "error" }];
      const count = details?.matches ?? 0;
      if (count === 0) return [{ text: "No matches", style: "dim" }];
      return [{ text: `${count} match(es)`, style: "success" }];
    },
  },
};

export default renderers;
```

### Loading

Sidecars are loaded via `await import(path)` — Node 25 natively strips TypeScript types at import time. No compilation step, no jiti, no extra dependencies.

The server loads all sidecars at `SessionManager` construction. Sidecar renderers override built-in renderers with the same tool name (e.g., `todos.mobile.ts` overrides the built-in `todo` renderer).

## iOS: Event Pipeline

### Message Decoding

`ServerMessage.swift` decodes `callSegments` and `resultSegments` as `[StyledSegment]?`:

```swift
case .toolStart(tool, args, toolCallId, callSegments)
case .toolEnd(tool, toolCallId, details, isError, resultSegments)
```

### Event Mapping

`ToolEventMapper` passes segments through to `AgentEvent`:

```swift
// ToolEventMapper.start()
.toolStart(sessionId:, toolEventId:, tool:, args:, callSegments:)

// ToolEventMapper.end()
.toolEnd(sessionId:, toolEventId:, details:, isError:, resultSegments:)
```

### Storage

`TimelineReducer` stores segments in `ToolSegmentStore`, a `@MainActor @Observable` keyed store:

```swift
// On toolStart
toolSegmentStore.setCallSegments(callSegments, for: toolEventId)

// On toolEnd
toolSegmentStore.setResultSegments(resultSegments, for: toolEventId)
```

There are four parallel stores for tool data, all keyed by tool event ID:

| Store              | Data                             | Source              |
|--------------------|----------------------------------|---------------------|
| `ToolArgsStore`    | Structured args `[String: JSONValue]` | `tool_start.args`  |
| `ToolOutputStore`  | Streaming text output            | `tool_output`       |
| `ToolDetailsStore` | Structured result details        | `tool_end.details`  |
| `ToolSegmentStore` | Pre-rendered call/result segments | `tool_start`/`tool_end` |

All stores are cleared together on session reset, history reload, and memory warnings.

## iOS: Rendering Pipeline

### ToolPresentationBuilder

**Source:** `ios/Oppi/Features/Chat/Output/ToolPresentationBuilder.swift`

Builds a `ToolTimelineRowConfiguration` from a `ChatItem.toolCall`. The builder receives segments via its `Context`:

```swift
struct Context {
    let args: [String: JSONValue]?
    let expandedItemIDs: Set<String>
    let fullOutput: String
    let isLoadingOutput: Bool
    let callSegments: [StyledSegment]?     // from ToolSegmentStore
    let resultSegments: [StyledSegment]?   // from ToolSegmentStore
}
```

#### Fallback Chain

```
1. Server segments present?
   → SegmentRenderer.attributedString(callSegments) → segmentAttributedTitle
   → SegmentRenderer.trailingAttributedString(resultSegments) → segmentAttributedTrailing

2. No segments?
   → Hardcoded per-tool switch (bash, read, edit, write, todo, remember, recall)
   → Produces title, toolNamePrefix, toolNameColor, trailing

3. Unknown tool, no segments?
   → tool name + raw argsSummary
```

The builder always runs the hardcoded path for **expanded content** (diffs, code, markdown, ANSI). Segments only control the **collapsed** row appearance.

### SegmentRenderer

**Source:** `ios/Oppi/Features/Chat/Timeline/SegmentRenderer.swift`

Maps `[StyledSegment]` to `NSAttributedString` using Tokyo Night theme colors:

| Segment Style | Color               | Font Weight |
|---------------|---------------------|-------------|
| `bold`        | `tokyoFg`           | Bold        |
| `muted`       | `tokyoFgDim`        | Regular     |
| `dim`         | `tokyoComment`      | Regular     |
| `accent`      | `tokyoCyan`         | Regular     |
| `success`     | `tokyoGreen`        | Regular     |
| `warning`     | `tokyoYellow`       | Regular     |
| `error`       | `tokyoRed`          | Regular     |
| (none)        | `tokyoFg`           | Regular     |

Methods:

```swift
// Collapsed title: full attributed string
SegmentRenderer.attributedString(from: [StyledSegment]) -> NSAttributedString

// Trailing badge: smaller font, attributed
SegmentRenderer.trailingAttributedString(from: [StyledSegment]) -> NSAttributedString?

// For icon tinting
SegmentRenderer.toolNamePrefix(from: [StyledSegment]) -> String?
SegmentRenderer.toolNameColor(from: [StyledSegment]) -> UIColor?

// Plain text (copy, accessibility)
SegmentRenderer.plainText(from: [StyledSegment]) -> String
```

### ToolTimelineRowContentView

**Source:** `ios/Oppi/Features/Chat/Timeline/ToolTimelineRowContent.swift`

The UIKit content view renders two new fields from `ToolTimelineRowConfiguration`:

```swift
let segmentAttributedTitle: NSAttributedString?     // overrides title label
let segmentAttributedTrailing: NSAttributedString?  // overrides trailing label
```

When `segmentAttributedTitle` is set, it replaces the `ToolRowTextRenderer.styledTitle()` path. When `segmentAttributedTrailing` is set, it replaces the plain `trailing` string.

### Collapsed vs Expanded

| Aspect | Collapsed | Expanded |
|--------|-----------|----------|
| **Title line** | Server segments or hardcoded summary | Same |
| **Trailing badge** | Server result segments or hardcoded | Hidden (replaced by expanded content) |
| **Content** | Hidden | ToolPresentationBuilder expanded content |
| **Content types** | N/A | bash output, code viewer, diff, markdown, todo card, media |

Expanded content is always rendered by iOS from raw tool output — it's too rich for pre-rendering (syntax highlighting, scrollable viewports, interactive diffs).

## Adding a New Tool Renderer

### Server-side (built-in)

Add a renderer to `BUILTIN_RENDERERS` in `server/src/mobile-renderer.ts`:

```typescript
const myTool: MobileToolRenderer = {
  renderCall(args) {
    return [
      { text: "my_tool ", style: "bold" },
      { text: String(args.target || ""), style: "accent" },
    ];
  },
  renderResult(details: any, isError) {
    if (isError) return [{ text: "failed", style: "error" }];
    return [{ text: `${details?.count ?? 0} items`, style: "success" }];
  },
};
```

### Extension sidecar

Create `~/.pi/agent/extensions/my-ext.mobile.ts`:

```typescript
export default {
  my_tool: {
    renderCall(args: Record<string, unknown>) {
      return [{ text: "my_tool ", style: "bold" }, { text: String(args.x), style: "accent" }];
    },
    renderResult(details: any, isError: boolean) {
      return [{ text: isError ? "failed" : "done", style: isError ? "error" : "success" }];
    },
  },
};
```

No iOS changes needed. The segment pipeline handles it automatically.

### iOS-only (hardcoded, no server segments)

If you need iOS-specific rendering without server support, add a case to `ToolPresentationBuilder.buildCollapsed()`:

```swift
case "my_tool":
    result.title = args?["target"]?.stringValue ?? "my_tool"
    result.toolNamePrefix = "my_tool"
    result.toolNameColor = UIColor(Color.tokyoCyan)
```

This is the legacy path. Prefer server segments for new tools.

## Testing

### Server

```bash
cd server && npx vitest run tests/mobile-renderer.test.ts          # 30 unit tests
cd server && npx vitest run tests/mobile-renderer-sidecars.test.ts  # 15 sidecar tests
cd server && npx vitest run tests/pi-event-replay.test.ts           # integration tests
```

### iOS

Segment rendering tests:
- `OppiTests/SegmentRendererTests.swift` — `SegmentRenderer` unit tests
- `OppiTests/ToolPresentationSegmentTests.swift` — `ToolPresentationBuilder` segment integration

Protocol decoding tests:
- `OppiTests/ProtocolSnapshotTests.swift` — decodes `callSegments`/`resultSegments` from fixtures
- `OppiTests/ServerMessageTests.swift` — `tool_start`/`tool_end` decoding with segments

### Protocol fixtures

- `protocol/server-messages.json` — canonical server message snapshots including `tool_start_with_segments` and `tool_end_with_details` (with `resultSegments`)
- `protocol/pi-events.json` — canonical pi RPC events for replay testing

## File Reference

### Server

| File | Purpose |
|------|---------|
| `src/mobile-renderer.ts` | `MobileRendererRegistry`, `StyledSegment`, built-in renderers, sidecar discovery/loading |
| `src/session-protocol.ts` | Calls registry at `tool_execution_start`/`tool_execution_end` translation time |
| `src/sessions.ts` | Instantiates registry, loads sidecars at startup |
| `src/types.ts` | `callSegments`/`resultSegments` on `tool_start`/`tool_end` message types |

### iOS

| File | Purpose |
|------|---------|
| `Core/Models/StyledSegment.swift` | `Codable` segment model |
| `Core/Runtime/ToolSegmentStore.swift` | `@Observable` keyed store for call/result segments |
| `Core/Runtime/ToolEventMapper.swift` | Passes segments from `ServerMessage` to `AgentEvent` |
| `Core/Runtime/TimelineReducer.swift` | Stores segments in `ToolSegmentStore` |
| `Features/Chat/Timeline/SegmentRenderer.swift` | `[StyledSegment] → NSAttributedString` |
| `Features/Chat/Output/ToolPresentationBuilder.swift` | Prefers segments, falls back to hardcoded |
| `Features/Chat/Timeline/ToolTimelineRowContent.swift` | Renders `segmentAttributedTitle`/`segmentAttributedTrailing` |

### Extension sidecars

| File | Tools |
|------|-------|
| `~/.pi/agent/extensions/memory.mobile.ts` | `remember`, `recall` |
| `~/.pi/agent/extensions/todos.mobile.ts` | `todo` |
