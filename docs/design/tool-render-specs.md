# Tool Render Specs — Dynamic Extension Rendering

## Problem

Tool call rendering in oppi is hardcoded. `ToolPresentationBuilder` switches on tool name → native UI. When pi loads a new extension with custom tools, the iOS app falls through to a `default` case that dumps raw text/JSON. Extension authors have no way to influence how their tools appear on mobile.

Meanwhile, pi extensions already define `renderCall` and `renderResult` for the terminal TUI — but this output never reaches the iOS app.

## Goal

Allow pi extensions to declaratively describe how their tool calls should render in oppi, without requiring an app update. Render specs travel over WebSocket and are interpreted by a generic native renderer at runtime.

## Non-Goals

- WebView-based rendering (too heavy per tool call, doesn't feel native)
- Dynamic Swift code loading (forbidden by App Store)
- Replacing hardcoded renderers for built-in tools (bash/read/edit/write keep native renderers)

## Architecture

```
Extension                    Server                     iOS App
─────────                    ──────                     ───────
pi.registerTool({          tool_start msg            ToolPresentationBuilder
  renderSpec: { ... }  →   includes renderSpec  →      ↓
})                                                   has spec? → DynamicToolRenderer
                                                     no spec?  → default (ANSI text)
```

### Lifecycle

1. Extension registers a tool with optional `renderSpec` field
2. Server includes `renderSpec` in `tool_start` message (alongside `tool`, `args`, `toolCallId`)
3. iOS caches render specs keyed by tool name (persists for session lifetime)
4. `ToolPresentationBuilder.build()` checks spec registry before the hardcoded `switch`
5. If a spec exists, `DynamicToolRenderer` interprets it → `ToolTimelineRowConfiguration`
6. If no spec, falls back to existing `default` case (with ANSI text support)

### Fallback Chain

```
1. Hardcoded native renderer (bash, read, edit, write, todo, remember, recall)
2. Render spec from extension (dynamic)
3. ANSI terminal text from pi-tui renderCall/renderResult (forwarded by server)
4. Raw text dump (current default)
```

## Render Spec Schema

### Top-Level

```typescript
interface ToolRenderSpec {
  /** Collapsed row presentation */
  collapsed: CollapsedSpec;
  /** Expanded presentation (shown on tap) */
  expanded?: ExpandedSpec;
}
```

### Collapsed Spec

The collapsed state is always a single row: icon + title + trailing badge.

```typescript
interface CollapsedSpec {
  /** SF Symbol name for tool icon (e.g. "brain.head.profile", "globe") */
  icon?: string;
  /** Icon tint color — named theme color */
  iconColor?: ThemeColor;
  /** Title template — supports Mustache-like interpolation from args */
  title: string;
  /** Right-aligned trailing text template — from args or output */
  trailing?: string;
  /** Title line break mode: "truncateTail" (default), "truncateMiddle" */
  titleLineBreak?: "truncateTail" | "truncateMiddle";
}
```

### Expanded Spec

The expanded state renders one or more content blocks in a vertical stack.

```typescript
interface ExpandedSpec {
  /** Content blocks rendered in vertical stack order */
  blocks: ExpandedBlock[];
  /** Data source: "args" renders from tool args, "output" from tool result (default: "output") */
  source?: "args" | "output";
}
```

### Expanded Blocks

Each block maps to an existing iOS rendering component:

```typescript
type ExpandedBlock =
  | TextBlock
  | MarkdownBlock
  | CodeBlock
  | KeyValueBlock
  | BadgesBlock
  | ListBlock
  | AnsiBlock;

/** Plain or styled text */
interface TextBlock {
  type: "text";
  /** Template string with {{arg}} interpolation */
  content: string;
  /** Text style */
  style?: "default" | "monospace" | "error" | "dim";
}

/** Rendered markdown content */
interface MarkdownBlock {
  type: "markdown";
  /** Template string — output rendered as markdown */
  content: string;
}

/** Code block with optional syntax highlighting and line numbers */
interface CodeBlock {
  type: "code";
  /** Template string for code content */
  content: string;
  /** Syntax language for highlighting */
  language?: string;
  /** Starting line number (enables line number gutter) */
  startLine?: number;
}

/** Key-value pairs rendered as a compact table */
interface KeyValueBlock {
  type: "kv";
  /** Array of {key, value} pairs — both support templates */
  pairs: Array<{ key: string; value: string }>;
}

/** Horizontal scrolling tag badges */
interface BadgesBlock {
  type: "badges";
  /** Template that resolves to array (e.g. "{{args.tags}}") or comma-separated string */
  items: string;
  /** Badge tint color */
  color?: ThemeColor;
}

/** Item list with optional status badges */
interface ListBlock {
  type: "list";
  /** Template that resolves to array of objects */
  items: string;
  /** Field name for item title text */
  titleField: string;
  /** Field name for optional status badge */
  statusField?: string;
  /** Field name for optional subtitle */
  subtitleField?: string;
  /** Maximum items to display before "+N more" */
  maxItems?: number;
}

/** Pre-rendered ANSI terminal text (forwarded from pi-tui) */
interface AnsiBlock {
  type: "ansi";
  /** ANSI-escaped text string */
  content: string;
}
```

### Template Interpolation

Templates use `{{path}}` syntax with simple expressions:

```
{{args.text}}              → args["text"] string value
{{args.tags}}              → args["tags"] array value
{{output}}                 → full tool output text
{{output.field}}           → parsed JSON output field
{{args.text | firstLine}}  → first line of text
{{args.text | truncate:80}} → truncated to 80 chars
{{args.tags | join:", "}}  → array joined with separator
{{args.tags | count}}      → array length as string
```

**Filters** (pipe-separated, left to right):

| Filter | Description |
|--------|-------------|
| `firstLine` | First line of multiline text |
| `truncate:N` | Truncate to N characters with ellipsis |
| `join:SEP` | Join array with separator |
| `count` | Array length or string character count |
| `default:VALUE` | Fallback if empty/nil |

### Theme Colors

Named color tokens that map to the iOS app's Tokyo Night palette:

```typescript
type ThemeColor =
  | "fg"       // primary text
  | "dim"      // muted/secondary text
  | "comment"  // de-emphasized
  | "red"
  | "green"
  | "yellow"
  | "blue"
  | "cyan"
  | "purple"
  | "orange";
```

## Examples

### Remember Tool

```json
{
  "collapsed": {
    "icon": "brain.head.profile",
    "iconColor": "yellow",
    "title": "{{args.text | firstLine | truncate:80}}",
    "trailing": "{{args.tags | join:\", \" | truncate:40}}"
  },
  "expanded": {
    "source": "args",
    "blocks": [
      { "type": "markdown", "content": "{{args.text}}" },
      { "type": "badges", "items": "{{args.tags}}", "color": "blue" }
    ]
  }
}
```

### Recall Tool

```json
{
  "collapsed": {
    "icon": "brain.head.profile",
    "iconColor": "yellow",
    "title": "\"{{args.query | truncate:60}}\"",
    "trailing": "{{output | lineCount}} matches"
  },
  "expanded": {
    "blocks": [
      { "type": "ansi", "content": "{{output}}" }
    ]
  }
}
```

### Hypothetical Weather Extension

```json
{
  "collapsed": {
    "icon": "cloud.sun",
    "iconColor": "cyan",
    "title": "{{args.location | default:\"current\"}}",
    "trailing": "{{output.temperature | default:\"…\"}}"
  },
  "expanded": {
    "blocks": [
      {
        "type": "kv",
        "pairs": [
          { "key": "Location", "value": "{{output.location}}" },
          { "key": "Temperature", "value": "{{output.temperature}}" },
          { "key": "Conditions", "value": "{{output.conditions}}" },
          { "key": "Wind", "value": "{{output.wind}}" }
        ]
      },
      { "type": "markdown", "content": "{{output.forecast}}" }
    ]
  }
}
```

### Hypothetical Search Extension

```json
{
  "collapsed": {
    "icon": "magnifyingglass",
    "iconColor": "green",
    "title": "\"{{args.query | truncate:60}}\"",
    "trailing": "{{output.results | count}} results"
  },
  "expanded": {
    "blocks": [
      {
        "type": "list",
        "items": "{{output.results}}",
        "titleField": "title",
        "subtitleField": "url",
        "maxItems": 10
      }
    ]
  }
}
```

## Wire Protocol Changes

### `tool_start` Message

Add optional `renderSpec` field:

```typescript
// server → iOS
{
  type: "tool_start",
  tool: "weather",
  args: { location: "Seattle" },
  toolCallId: "tc_123",
  renderSpec?: ToolRenderSpec    // NEW — optional
}
```

The server attaches the render spec from the extension's tool definition. iOS caches it by tool name for the session lifetime.

### Pi Extension API Addition

```typescript
pi.registerTool({
  name: "weather",
  label: "Weather",
  description: "Fetch weather forecast",
  parameters: Type.Object({ ... }),
  
  // Existing TUI renderers (terminal)
  renderCall(args, theme) { ... },
  renderResult(result, options, theme) { ... },
  
  // NEW: Mobile render spec (iOS/Android)
  renderSpec: {
    collapsed: {
      icon: "cloud.sun",
      iconColor: "cyan",
      title: "{{args.location | default:\"current\"}}",
    },
    expanded: {
      blocks: [
        { type: "markdown", content: "{{output}}" }
      ]
    }
  }
});
```

### ANSI Fallback

For extensions without `renderSpec`, the server can optionally forward the pi-tui rendered text. Add optional `renderCall` field to `tool_start`:

```typescript
{
  type: "tool_start",
  tool: "custom_tool",
  args: { ... },
  toolCallId: "tc_456",
  renderCall?: string    // ANSI-escaped text from pi-tui renderCall()
}
```

And optional `renderResult` field to `tool_end`:

```typescript
{
  type: "tool_end",
  tool: "custom_tool",
  toolCallId: "tc_456",
  renderResult?: string  // ANSI-escaped text from pi-tui renderResult()
}
```

iOS uses these as styled text when no native renderer or render spec exists.

## iOS Implementation

### New Files

```
Oppi/Core/Rendering/
  ToolRenderSpec.swift          — Codable model for render spec JSON
  ToolRenderSpecRegistry.swift  — Cache specs by tool name
  ToolRenderSpecInterpreter.swift — Template interpolation engine  
  DynamicToolRenderer.swift     — Spec → ToolTimelineRowConfiguration
```

### ToolRenderSpec.swift

```swift
struct ToolRenderSpec: Codable, Sendable {
    let collapsed: CollapsedSpec
    let expanded: ExpandedSpec?
}

struct CollapsedSpec: Codable, Sendable {
    let icon: String?
    let iconColor: String?
    let title: String
    let trailing: String?
    let titleLineBreak: String?
}

struct ExpandedSpec: Codable, Sendable {
    let blocks: [ExpandedBlock]
    let source: String?
}

enum ExpandedBlock: Codable, Sendable {
    case text(content: String, style: String?)
    case markdown(content: String)
    case code(content: String, language: String?, startLine: Int?)
    case kv(pairs: [KVPair])
    case badges(items: String, color: String?)
    case list(items: String, titleField: String, statusField: String?,
              subtitleField: String?, maxItems: Int?)
    case ansi(content: String)
}

struct KVPair: Codable, Sendable {
    let key: String
    let value: String
}
```

### ToolRenderSpecRegistry.swift

```swift
@MainActor
final class ToolRenderSpecRegistry {
    static let shared = ToolRenderSpecRegistry()
    
    private var specs: [String: ToolRenderSpec] = [:]
    
    func register(tool: String, spec: ToolRenderSpec) {
        specs[ToolCallFormatting.normalized(tool)] = spec
    }
    
    func spec(for tool: String) -> ToolRenderSpec? {
        specs[ToolCallFormatting.normalized(tool)]
    }
    
    func clearAll() { specs.removeAll() }
}
```

### ToolPresentationBuilder Integration

```swift
static func build(...) -> ToolTimelineRowConfiguration {
    // 1. Check hardcoded native renderers
    switch normalizedTool {
    case "bash", "read", "edit", "write", "todo", "remember", "recall":
        // existing native rendering
        ...
    default:
        break
    }
    
    // 2. Check render spec registry
    if let spec = ToolRenderSpecRegistry.shared.spec(for: tool) {
        return DynamicToolRenderer.build(spec: spec, ...)
    }
    
    // 3. Check for forwarded ANSI text
    if let ansiText = context.renderCallText {
        // render as ANSI-styled text
        ...
    }
    
    // 4. Raw default
    ...
}
```

### Template Interpolation

The template engine is deliberately simple — no loops, no conditionals, just path resolution + filters. This keeps the attack surface small and the implementation fast.

```swift
enum TemplateInterpolator {
    /// Resolve "{{args.text | firstLine | truncate:80}}" against context.
    static func resolve(
        _ template: String,
        args: [String: JSONValue]?,
        output: String
    ) -> String
}
```

Parsing: regex for `\{\{(.+?)\}\}` → split on ` | ` → resolve path → apply filters left-to-right.

Path resolution:
- `args.X` → look up in structured args dict
- `output` → full tool output string
- `output.X` → try JSON-parsing output, look up field

Filter implementations: `firstLine`, `truncate:N`, `join:SEP`, `count`, `default:V` — all pure functions on `String` or `[JSONValue]`.

## Component Mapping

Each block type maps to an existing iOS rendering component:

| Block Type | iOS Component | Already Exists? |
|-----------|--------------|-----------------|
| `text` | `UILabel` with attributed string | ✅ `ToolRowTextRenderer.makeANSIOutputPresentation` |
| `markdown` | `AssistantMarkdownContentView` | ✅ used in expanded tool rows |
| `code` | `ToolRowTextRenderer.makeCodeAttributedText` + line numbers | ✅ used for read tool |
| `kv` | New: simple `UILabel` rows with key:value pairs | 🆕 trivial |
| `badges` | Horizontal `UIStackView` with capsule labels | ✅ `TodoStatusBadge` pattern |
| `list` | Vertical `UIStackView` with title + optional badges | ✅ `TodoToolListCard` pattern |
| `ansi` | `ANSIParser.attributedString` → `UILabel` | ✅ `ToolRowTextRenderer` |

Only `kv` is truly new. Everything else reuses existing rendering paths.

## Migration Path

### Phase 1: ANSI Fallback (cheapest, immediate value)
- Server forwards `renderCall` / `renderResult` ANSI text in tool messages
- iOS renders unknown tools with ANSI parser instead of raw text
- All existing extensions get better mobile rendering for free

### Phase 2: Render Spec (full dynamic rendering)
- Add `renderSpec` to pi's `ToolDefinition` type
- Server includes spec in `tool_start` messages
- iOS implements `DynamicToolRenderer` with template interpolation
- Extension authors can opt into structured mobile rendering

### Phase 3: Hardcoded → Spec Migration
- Convert hardcoded remember/recall renderers to use render specs
- Prove the spec vocabulary covers real-world needs
- Keep bash/read/edit/write as native (too complex for specs)

## Open Questions

1. **Spec versioning** — Should specs declare a version for forward compat? Probably yes: `"specVersion": 1`
2. **Streaming support** — Expanded blocks that update during `tool_output` streaming. ANSI block handles this naturally. Others may need a `streaming: true` flag.
3. **Interaction** — Copy-to-clipboard, tap-to-navigate. Out of scope for v1; can add `action` fields to blocks later.
4. **Conditional blocks** — `"if": "{{output.error}}"` to conditionally show error styling. Out of scope for v1; keep simple.
5. **Image blocks** — Support `data:` URIs or URL-based images in expanded view. Add when needed.
