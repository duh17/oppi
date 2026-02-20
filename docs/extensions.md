# Extension Support

How Oppi handles pi extensions end-to-end: discovery, selection, spawning, mobile rendering, and adding new ones.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Host Machine                                        │
│                                                      │
│  ~/.pi/agent/extensions/                             │
│    ├── memory.ts          ← pi extension (symlink)   │
│    ├── todos.ts           ← pi extension (symlink)   │
│    └── permission-gate.ts ← managed (hidden from UI) │
│                                                      │
│  ~/.pi/agent/mobile-renderers/                       │
│    ├── memory.ts          ← mobile renderer          │
│    └── todos.ts           ← mobile renderer          │
│                                                      │
└──────────────────────┬───────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────┐
│  Oppi Server                                         │
│                                                      │
│  extension-loader.ts                                 │
│    listHostExtensions()  → GET /extensions            │
│    resolveWorkspaceExtensions()  → --extension flags  │
│                                                      │
│  mobile-renderer.ts                                  │
│    Built-in renderers (bash, read, edit, write, …)   │
│    + ~/.pi/agent/mobile-renderers/ → StyledSegment[]  │
│                                                      │
│  session-spawn.ts                                    │
│    pi --mode rpc                                     │
│      --no-extensions              ← suppress auto    │
│      --extension permission-gate  ← always loaded    │
│      --extension memory.ts        ← workspace picks  │
│      --extension todos.ts                            │
│                                                      │
│  session-protocol.ts                                 │
│    tool_execution_start → renderCall(toolName, args)  │
│    tool_execution_end   → renderResult(toolName, …)   │
│    Segments sent in WS messages to iOS                │
│                                                      │
└──────────────────────┬───────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────┐
│  iOS App                                             │
│                                                      │
│  WorkspaceEditView                                   │
│    GET /extensions → toggle checkboxes               │
│    workspace.extensions = ["memory", "todos"]        │
│                                                      │
│  StyledSegment (model)                               │
│    text: String, style: bold|muted|dim|accent|…      │
│                                                      │
│  SegmentRenderer                                     │
│    StyledSegment[] → NSAttributedString              │
│    Maps styles to Tokyo Night theme colors           │
│                                                      │
│  ToolPresentationBuilder                             │
│    callSegments → collapsed tool row title            │
│    resultSegments → trailing badge                   │
│                                                      │
└──────────────────────────────────────────────────────┘
```

## How It Works

### 1. Discovery

`listHostExtensions()` scans `~/.pi/agent/extensions/` and returns all entries except:

- Hidden files (`.` prefix)
- `permission-gate` (managed by oppi-server, always loaded)

Results are served via `GET /extensions` to the iOS app.

### 2. Selection

iOS `WorkspaceEditView` shows discovered extensions as toggleable checkboxes. Selected names are stored in `workspace.extensions: string[]`. The text field also supports manual entry for extensions not auto-discovered.

### 3. Spawning

When a session starts (`session-spawn.ts`):

1. `--no-extensions` suppresses pi's auto-discovery of `~/.pi/agent/extensions/`
2. `--extension <path>` is added for permission-gate (always)
3. `resolveWorkspaceExtensions(workspace.extensions)` resolves names → paths
4. Each resolved extension gets `--extension <path>`

This gives oppi full control over which extensions load per workspace.

### 4. Mobile Rendering

Pi extensions define TUI renderers via `renderCall()`/`renderResult()` that produce terminal UI components. These don't work on iOS. Instead, oppi uses a parallel **mobile renderer** system that produces serializable `StyledSegment[]`:

```typescript
interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}

interface MobileToolRenderer {
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}
```

**Two sources of mobile renderers:**

| Source | Location | Covers |
|--------|----------|--------|
| Built-in | `server/src/mobile-renderer.ts` | `bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`, `todo` |
| User renderers | `~/.pi/agent/mobile-renderers/*.ts` | Custom extension tools (`remember`, `recall`, etc.) |

User renderers live in a **separate directory** from pi extensions (`~/.pi/agent/mobile-renderers/`). This prevents the pi CLI from trying to load them as extensions — they're pure rendering hints, not extension modules.

Segments are injected into WS messages by `session-protocol.ts`:
- `toolStart` → includes `callSegments`
- `toolEnd` → includes `resultSegments`

iOS renders them via `SegmentRenderer` → `NSAttributedString` with theme-mapped colors.

## Adding a New Extension

### Step 1: Write the Pi Extension

Follow [pi's extension docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md). Key points:

```typescript
// ~/.pi/agent/extensions/my-ext.ts (or in dotfiles, symlinked)
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "my_tool",
    label: "My Tool",
    description: "What it does",
    parameters: Type.Object({
      action: Type.String(),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      return {
        content: [{ type: "text", text: "Result for LLM" }],
        details: { someData: "..." },  // Available to mobile renderer
      };
    },
    // Optional TUI renderers (for terminal pi, not iOS)
    renderCall(args, theme) { /* ... */ },
    renderResult(result, options, theme) { /* ... */ },
  });
}
```

Test locally with `pi -e ./my-ext.ts`.

### Step 2: Install to Extensions Directory

```bash
# Option A: Symlink from dotfiles (recommended)
ln -s ~/.config/dotfiles/shared/pi/extensions/my-ext.ts ~/.pi/agent/extensions/my-ext.ts

# Option B: Copy directly
cp my-ext.ts ~/.pi/agent/extensions/my-ext.ts
```

The extension now appears in `GET /extensions` and the iOS workspace editor.

### Step 3: Create a Mobile Renderer (Optional but Recommended)

Without a renderer, iOS falls back to raw tool name + text output. With one, you get styled collapsed summaries.

```typescript
// ~/.pi/agent/mobile-renderers/my-ext.ts

interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}

interface MobileToolRenderer {
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}

const renderers: Record<string, MobileToolRenderer> = {
  my_tool: {
    renderCall(args) {
      return [
        { text: "my_tool ", style: "bold" },
        { text: String(args.action || ""), style: "accent" },
      ];
    },
    renderResult(details: any, isError) {
      if (isError) return [];
      return [{ text: "✓", style: "success" }];
    },
  },
};

export default renderers;
```

**Key rules for mobile renderers:**
- Location: `~/.pi/agent/mobile-renderers/<name>.ts`
- Default export: `Record<string, MobileToolRenderer>` keyed by tool name
- One file can cover multiple tools from the same extension
- Keep summaries short — they're collapsed one-liners on mobile
- Never throw — return `[]` as fallback

### Step 4: Restart Server

The server loads renderers at startup. Restart to pick up new ones:

```bash
launchctl kickstart -k gui/$(id -u)/dev.chenda.oppi
```

### Step 5: Enable in Workspace

Open iOS → workspace settings → toggle the new extension on.

## Style Guide for Mobile Renderers

### Segment Styles → iOS Colors

| Style | iOS Color | Usage |
|-------|-----------|-------|
| `bold` | `themeFg` (bold font) | Tool name prefix |
| `muted` | `themeFgDim` | Secondary info (quoted text, values) |
| `dim` | `themeComment` | Tertiary info (tags, counts, metadata) |
| `accent` | `themeCyan` | Primary arguments (paths, commands) |
| `success` | `themeGreen` | Success indicators (✓, counts) |
| `warning` | `themeYellow` | Truncation, limits, cautions |
| `error` | `themeRed` | Errors, non-zero exit codes |

### Patterns

**Tool call (collapsed title):**
```
[bold: "toolname "] [accent: "primary-arg"] [dim: "metadata"]
```

**Result (trailing badge):**
```
[success: "✓ Done"]           — simple success
[success: "3/5 open"]         — counts
[warning: "truncated"]        — limits hit
[]                            — empty = no badge (error icon shows separately)
```

## Managed Extensions

### permission-gate

Always loaded by `session-spawn.ts`. Never appears in `GET /extensions`. Connects to oppi-server via TCP localhost socket to route tool approvals through the iOS app.

Located at: `server/extensions/permission-gate/`

### Future: Built-in Renderers

For pi's built-in tools (`bash`, `read`, `edit`, etc.), mobile renderers live directly in `server/src/mobile-renderer.ts`. These don't need user renderer files — they're always available.

To add a new built-in tool renderer, add it to `BUILTIN_RENDERERS` in `mobile-renderer.ts`.

## File Reference

| File | Purpose |
|------|---------|
| `server/src/extension-loader.ts` | Discovery, validation, resolution of host extensions |
| `server/src/mobile-renderer.ts` | `MobileRendererRegistry`, built-in renderers, user renderer loading |
| `server/src/session-spawn.ts` | Pi spawn args including `--extension` flags |
| `server/src/session-protocol.ts` | Injects `callSegments`/`resultSegments` into WS messages |
| `~/.pi/agent/extensions/*.ts` | Pi extensions (auto-discovered) |
| `~/.pi/agent/mobile-renderers/*.ts` | User-provided mobile renderers |
| `server/extensions/permission-gate/` | Managed permission gate extension |
| `ios/.../StyledSegment.swift` | Segment model |
| `ios/.../SegmentRenderer.swift` | Segment → NSAttributedString |
| `ios/.../ToolPresentationBuilder.swift` | Segments → tool row UI |

## Relationship to Pi

Oppi reuses pi's extension system verbatim — same TypeScript format, same `ExtensionAPI`, same tool registration. The differences:

| Aspect | Pi (Terminal) | Oppi (Mobile) |
|--------|--------------|---------------|
| Discovery | Auto-discovers `~/.pi/agent/extensions/` | Suppressed; explicit `--extension` flags |
| Rendering | TUI `Component` objects via `renderCall`/`renderResult` | `StyledSegment[]` via `~/.pi/agent/mobile-renderers/` |
| UI interaction | `ctx.ui.confirm()`, `ctx.ui.select()` etc. | Forwarded via RPC → WS → iOS native dialogs |
| Permission gate | Interactive TUI confirm dialog | TCP socket → iOS push notification + banner |
| Selection | All discovered extensions load | Per-workspace toggle in iOS settings |

Pi's extension docs are the canonical reference for writing extensions:
- Extension API: [pi docs/extensions.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md)
- Custom tools: Same doc, "Custom Tools" section
- Tool rendering: Same doc, "Custom Rendering" section
- State management: Same doc, "State Management" section
