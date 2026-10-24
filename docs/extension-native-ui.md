# Extension native UI contract

API reference for how Oppi turns Pi extension UI into native Apple UI. Use it to keep a terminal-first Pi extension usable in Oppi, and to give an extension native cards, sheets, rows, and display surfaces without writing Swift. For packaging, tool output, and mobile do's and don'ts, see [Oppi extension behavior](extensions.md).

This is version 1 of the contract.

**Core rule:** native UI needs explicit semantics. An extension always provides terminal output through `render(width): string[]`, which Oppi shows as a styled terminal fallback. To get native UI, the extension returns a serializable native surface from `renderNative()`. Oppi never infers native behavior from terminal art.

**Non-goals:** Oppi is not a terminal emulator and does not reproduce ANSI or box drawing pixel for pixel. Extensions cannot ship native views or extension-specific native UI. This contract does not replace Pi TUI in terminal mode.

## Example

A widget that works in terminal Pi and Oppi:

```ts
ctx.ui.setWidget("review", () => ({
  render: () => ["Review running", "3 findings"],
  renderNative: () => ({
    version: 1,
    id: "widget:review",
    source: "widget",
    presentation: { style: "surfacePanel", title: "Review running", subtitle: "3 findings" },
    blocks: [
      {
        type: "activityList",
        id: "findings",
        rows: [{ id: "finding-1", title: "Fix retry state", subtitle: "High confidence", state: "warning" }],
      },
      { type: "markdown", id: "summary", markdown: "**Summary:** Review is still running." },
    ],
    fallback: { lines: ["Review running", "3 findings"] },
  }),
}));
```

`renderNative()` returns a plain object; extensions import nothing from Oppi. The server validates every surface and drops one that is malformed or over a limit. If `renderNative()` is absent or throws, Oppi uses `fallback`, then a sanitized terminal snapshot.

## Surface model

```ts
export interface ExtensionUINativeSurface {
  version: 1;
  id: string;
  source: "widget";
  presentation: ExtensionUINativePresentation;
  blocks: ExtensionUINativeBlock[];
  fallback?: ExtensionUINativeFallback;
}

export interface ExtensionUINativePresentation {
  style: "surfacePanel";
  title?: string;
  subtitle?: string;
}

export interface ExtensionUINativeFallback {
  text?: string;
  lines?: string[];
}
```

Native surfaces are display-only widget snapshots with no actions. Placement is not part of the surface: `extension_ui_notification.widgetPlacement` controls where the widget appears. Every surface produced from an opaque TUI component should include `fallback`. Clients use it when a block is unsupported, native rendering fails, or the platform prefers terminal-compatible display.

### Blocks

```ts
export interface ExtensionUIAccessibility {
  label?: string;
  value?: string;
  hint?: string;
}

export interface ExtensionUIBlockBase {
  id?: string;
  accessibility?: ExtensionUIAccessibility;
}

export type ExtensionUINativeBlock = ExtensionUIBlockBase &
  (
    | { type: "text"; spans: ExtensionUITextSpan[] }
    | { type: "markdown"; markdown: string }
    | { type: "section"; title?: string; subtitle?: string; blocks: ExtensionUINativeBlock[] }
    | { type: "activityList"; rows: ExtensionUIActivityRow[] }
    | { type: "progress"; label?: string; value?: number; indeterminate?: boolean }
    | { type: "terminal"; lines?: ExtensionUITextSpan[][]; text?: string }
    | { type: "code"; language?: string; text: string }
    | { type: "divider" }
    | { type: "spacer"; size?: "small" | "medium" | "large" }
    | { type: "table"; columns: string[]; rows: (string | number | null)[][]; truncated?: boolean }
    | {
        type: "chart";
        kind: "bar" | "line" | "pie";
        title?: string;
        labels: string[];
        series: Array<{ name?: string; values: number[] }>;
        truncated?: boolean;
      }
  );
```

Accessibility metadata is optional. Clients derive labels from visible text and use `accessibility` to clarify glyph-only controls, progress rows, and terminal snapshots. Color is never the only state signal.

On iOS, blocks use the chat timeline's renderers: `markdown` uses the chat Markdown view, `code` the highlighted code block (`language` drives highlighting), `terminal` and widget lines unwrapped horizontally scrolling monospaced text, `table` the delimited-table grid, and `chart` the Core Graphics bar, line, and pie renderers.

### Text spans

```ts
export interface ExtensionUITextSpan {
  text: string;
  role?: "primary" | "secondary" | "muted" | "accent" | "success" | "warning" | "danger" | "code";
  traits?: Array<"bold" | "italic" | "monospaced" | "strikethrough" | "underline">;
  link?: string;
}
```

Roles are semantic; the Apple client maps them to the active Oppi theme. Do not depend on raw colors.

### Activity lists

```ts
export interface ExtensionUIActivityRow {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  state?: "queued" | "running" | "success" | "warning" | "error" | "inactive";
  progress?: number;
  link?: string;
  children?: ExtensionUIActivityRow[];
  blocks?: ExtensionUINativeBlock[];
}
```

Use activity lists for persistent task state: running jobs, queued work, substeps, and recent results.

| State | Meaning | Treatment |
| --- | --- | --- |
| `queued` | Waiting to start | Muted or pending |
| `running` | Active work or stopping | Orange, working |
| `success` | Ready or completed | Green |
| `warning` | Completed with caveat | Orange, warning |
| `error` | Failed | Red |
| `inactive` | Stopped, dismissed, or no longer active | Muted |

- `link` is a row navigation target such as `oppi://session/<id>` and routes through app-level link handling.
- `blocks` makes the row a disclosure row: tapping shows or hides those blocks under it. They are ordinary blocks (Markdown with links, terminal output, code, progress, nested activity lists) and count against the surface limits one nesting level below the list. If the row also has a `link`, the link gets its own trailing button. Clients build disclosure content only while shown, and keep a row open across snapshots while its `id` is stable.
- Keep the model generic; do not encode extension-specific concepts.

### Terminal output

A `terminal` block carries styled `lines` or raw `text`. `text` is output as a program wrote it: SGR colors, carriage returns, and cursor motion. iOS resolves it with the same terminal engine as bash tool output, with terminal effects disabled, so progress bars redraw in place and escapes never show as text. A client without that engine shows the plain projection: escapes stripped, and only the text after each line's last carriage return.

`text` is a bounded snapshot, not a stream. Send the output tail on each widget update. For live command output, use one activity row per command with its tail in `blocks`, so the client renders only output someone opened:

```ts
{
  type: "activityList",
  rows: [{
    id: "bash-3",
    title: "bash-3",
    subtitle: "npm test",
    state: "running",
    blocks: [{ type: "terminal", id: "output:bash-3", text: tail }],
  }],
}
```

### Links

`span.link` and `activityRow.link` are real URLs and do not accept `[[wiki]]` grammar. `markdown` blocks follow the chat link policy: wiki links rewrite to resource-reference URLs and then open through the chat handlers. Links are untrusted content and go through normal platform URL handling.

### Limits

The server drops a surface that is malformed or over a limit, except tables and charts, which it clips and marks `truncated: true`. Clients show a truncation notice. Move large content to uploads or file paths rather than inline JSON.

| Limit | Value |
| --- | --- |
| Surface size | 64 KB |
| Blocks | 80; nesting depth 6 |
| Text | 32 KB across the surface; 320 spans |
| Terminal lines | 160 |
| Activity rows | 160 |
| Table | 32 columns, 200 rows, 200 characters per cell |
| Chart | 48 labels, 8 series |
| Working indicator | 24 frames of up to 16 characters; interval 80 ms to 60 s |
| Working message and status text | 160 characters |

## Blocking prompts

Blocking prompts are not native-surface blocks. They stay Pi-shaped in `extension_ui_request` and map to native iOS presentations:

| Request | Presentation |
| --- | --- |
| `ask` | AskCard inline, full-screen when expanded |
| `select`, `confirm`, `input` | Inline AskCard-style prompt card |
| `editor` | Native editor sheet |

`ask` is Oppi-defined, because Pi's standard dialog API has no portable multi-select or multi-question form; it adds `questions`, `options`, `multiSelect`, and `allowCustom`. The reference package `pi-extensions/ask` uses `ctx.ui.ask()` when available and falls back to `ctx.ui.custom()`, `select()`, and `input()` in plain Pi.

Responses return through `extension_ui_response`:

```ts
export type ExtensionUIResponse = {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
};
```

Lifecycle:

1. The server emits an `extension_ui_request` with a stable `id`.
2. The client shows one active blocking surface for the focused session.
3. The user acts and the client sends `extension_ui_response`.
4. The server resolves the extension promise and broadcasts `extension_ui_settled`.
5. All clients dismiss the surface with that `id`.

Rules:

- The server is authoritative for timeout and cancellation. Clients can show a countdown from `timeoutAt` but must not invent a successful response when it expires locally, or auto-submit.
- If another device answers first, `extension_ui_settled` dismisses the request everywhere. Late responses for settled IDs are ignored.
- Leaving a session does not cancel a request; it stays pending for that session and returns when the user does.
- Pending requests replay after reconnect until settled. With several pending in one session, clients present them in server order.
- Do not attach native surfaces to `ask`, `select`, `confirm`, `input`, or `editor`.

## Widgets

Persistent surfaces come from `setWidget(component)` when the component provides `renderNative()`.

- A surface `id` is stable while displayed, and a new surface with the same `id` replaces the previous snapshot. Widget IDs derive from the widget key, such as `widget:<widgetKey>`. Clients can keep local state such as expanded rows across replacements while block IDs stay stable.
- `setWidget(key, undefined)` or an empty normalized widget clears that surface. Component widgets update by replacing snapshots after `tui.requestRender()`.
- The managed bridge sends at most one snapshot per widget key every 250 ms. `requestRender()` and repeated `setWidget(key, ...)` share that limit and the newest content wins. A new key sends at once and a clear is never delayed, so extensions need no render timer.
- A full-screen reader opened from a surface follows replacements for the same `id` and keeps the last snapshot after the widget is cleared.
- Surfaces survive turn boundaries and agent stops unless cleared, are scoped to the session, and clear on session end, session deletion, or runtime disposal. Reconnecting clients receive persistent surfaces again.

### Placement

`aboveEditor` (or no placement) renders in a strip above the composer, and `belowEditor` in a separate strip below it. A widget never moves to the other strip.

```text
aboveEditor strip
[ Agents · 1 running ] [ Tools · 2 active ] [ Git · +3.5k -118 ]

composer

belowEditor strip
[ Fleet · 2 sessions ] [ Queue · 1 follow-up ]
```

- A collapsed strip is one row of pills that scrolls horizontally; empty strips are hidden. One pill is one widget or one standalone status entry. The pill label comes from, in order: native `presentation.title` and `subtitle`, an attached `setStatus` value, the `widgetKey`, then the first fallback line. Accessibility sizes can change row height or promote content to a sheet, but the collapsed state stays bounded.
- Each placement has one drawer. Tapping a pill opens that widget there, tapping another pill replaces the content, and tapping the active pill or the collapse control closes it. The drawer has a maximum height and scrolls; long content can open full screen. `renderNative()` content renders as native blocks; a widget without it shows the sanitized terminal fallback.
- `setStatus(key, text)` attaches to a widget when `key === widgetKey`. If exactly one status and one widget share an extension scope, a client can attach them by scope. Other statuses render as standalone pills in the same group.
- Native blocks are viewport-independent. Clients decide iPhone, iPad, Dynamic Type, color scheme, and scroll ownership locally.

### Notifications, editor handoffs, and the working row

- **`notify()`** is fire-and-forget: a muted temporary chip above the composer; tap to read it. It needs no response and is not replayed after reconnect.
- **`setEditorText()` and `pasteToEditor()`** are one-shot handoffs to the target session's composer. The text then belongs to the user; later settlement neither removes nor submits it.
- **`setWorkingIndicator`, `setWorkingMessage`, and `setStatus`** are data, not terminal frames, so Oppi projects them cheaply:
  - iOS animates custom frames locally from `frames` and `intervalMs`. `frames: []` hides the working glyph; `undefined` restores the native spinner.
  - `setWorkingMessage()` updates the timeline working row while the session is busy.
  - `setStatus(key, text)` is keyed composer-adjacent state that persists until cleared.
  - Hosts strip control sequences, cap sizes, coalesce duplicate payloads, and throttle high-frequency updates. iOS owns Dynamic Type, VoiceOver labels, Reduce Motion, color, and spacing.
  - Terminal-only fonts or private-use glyphs can fall back to the native spinner or plain text. Branch on `ctx.mode === "tui"` for exact terminal glyphs and give other modes portable frames.
- **Tool and custom-message renderers** stay on the timeline path, not in surfaces. Tool rows update during `tool_execution_start`, `_update`, and `_end`, and final output stays in the timeline. Expansion state is client-local. Custom message renderers persist with their session entry.

### Rendering failure

If native rendering fails, the client renders `fallback`, then a sanitized terminal snapshot, then a compact unsupported-UI message with the surface title and source. A rendering failure never settles or cancels the extension request.

## Mapping from Pi extension APIs

| Pi API | Native surface | Apple rendering | Fallback |
| --- | --- | --- | --- |
| `ctx.ui.ask()` / Oppi `ask` tool | Pi request fields | AskCard inline, expanded full-screen | existing AskCard behavior |
| `ctx.ui.select(title, options)` | Pi request fields | AskCard-style inline | terminal/TUI select |
| `ctx.ui.confirm(title, message)` | Pi request fields | compact confirmation card | terminal/TUI confirm |
| `ctx.ui.input()` | Pi request fields | inline text prompt | terminal/TUI input |
| `ctx.ui.editor()` | Pi request fields | editor sheet | terminal/TUI editor |
| `ctx.ui.notify()` | notification fields | muted chip above the iOS composer | terminal/TUI notify |
| `ctx.ui.onTerminalInput()` | terminal-owned input stream | no native mapping | no-op unsubscribe in SDK sessions |
| `ctx.ui.setTitle()` | title notification | extension surface heading | terminal window/tab title |
| `ctx.ui.setStatus()` | status text fields | generic status projection/chips | text status |
| `ctx.ui.setWidget(string[])` | `widgetLines` | terminal strip/drawer fallback | styled line card |
| `ctx.ui.setWidget(component)` | `renderNative()` if present | native strip/drawer blocks | terminal snapshot |
| `ctx.ui.custom()` | TUI component | no native mapping | resolves undefined in SDK sessions |
| `ctx.ui.setFooter()` | terminal-owned/footer text | no native mapping | ignored in SDK sessions |
| `ctx.ui.setHeader()` | terminal-owned/header text | no native mapping | ignored in SDK sessions |
| `ctx.ui.setWorkingMessage()` | working-row text | native timeline working row | default working text |
| `ctx.ui.setWorkingVisible()` | working-row visibility | hide/show native working row | visible by default |
| `ctx.ui.setWorkingIndicator()` | working indicator frames | static/animated/hidden row indicator | default native spinner |
| `ctx.ui.setHiddenThinkingLabel()` | hidden thinking label | thinking row accessibility/source metadata | default thinking label |
| `ctx.ui.pasteToEditor()` | `set_editor_text` notification | composer text handoff | same as `setEditorText()` in RPC |
| `ctx.ui.setEditorText()` | `set_editor_text` notification | composer text handoff | host-owned editor text handoff |
| `ctx.ui.getEditorText()` | not portable synchronously | empty string | empty string in RPC |
| `ctx.ui.getToolsExpanded()` | bridge-local state | current native tool expansion flag | `false` by default |
| `ctx.ui.setToolsExpanded()` | tool expansion state | expand/collapse native tool rows | collapsed by default |
| `ctx.ui.setEditorComponent()` | not portable | no native mapping | preserve factory only |
| `ctx.ui.getEditorComponent()` | not portable | no native mapping | return preserved factory |
| `ctx.ui.addAutocompleteProvider()` | terminal-owned autocomplete | no native mapping | ignored in SDK sessions |
| `ctx.ui.theme` | snapshot render theme | terminal snapshot styling helper | text-preserving theme shim |
| `ctx.ui.getAllThemes()` | terminal-owned theme registry | no native mapping | empty list in SDK sessions |
| `ctx.ui.getTheme()` | terminal-owned theme registry | no native mapping | undefined in SDK sessions |
| `ctx.ui.setTheme()` | terminal-owned theme switching | no native mapping | unsupported result in SDK sessions |
| `renderCall` / `renderResult` | timeline renderer output | current mobile renderer / raw text | current mobile renderer / raw text |
| `registerMessageRenderer()` | custom message text | current mobile renderer / raw text | raw custom message text |

### Pi TUI components

| Component or pattern | Native block | Apple design |
| --- | --- | --- |
| `Text` | `text` or `markdown` | selectable native text with wrapping and Dynamic Type |
| `Markdown` | `markdown` | compact chat Markdown with the chat link policy |
| `Box` | `section` | rounded card, theme background, subtle stroke |
| `Container` | `section.blocks` | vertical stack |
| `Spacer` | `spacer` | native spacing token |
| `Loader` / `CancellableLoader` / `BorderedLoader` | `progress` | progress row or card |
| tabular query results | `table` | the delimited-table grid |
| categorical numeric series | `chart` | Core Graphics bar, line, or pie |
| arbitrary ANSI or box drawing | `terminal` | monospaced selectable card |
| `Image`, `SettingsList`, overlay `custom(..., { overlay })` | terminal fallback | no native mapping |
| `SelectList`, `Input`, `Editor` | terminal fallback | use `ctx.ui.select()`, `input()`, or `editor()` |

### Pi TUI lifecycle

In terminal Pi the TUI owns focus and disposal. In Oppi the server owns request state and sends snapshots; clients render them and return responses. Clients may dismiss optimistically after a response is accepted, but `extension_ui_settled` stays the authoritative cleanup signal.

| Pi TUI concept | Native behavior |
| --- | --- |
| Component factory creates an object | Server creates a surface with a stable `id` |
| `render(width)` | `renderNative(context)` returns semantic blocks, or fallback lines render |
| `tui.requestRender()` | Server emits a replacement snapshot for the same `id` |
| `handleInput(data)` | Terminal-owned; native event forwarding is not supported |
| `invalidate()` | Next snapshot is recomputed; clients can re-render locally for theme or size changes |
| `dispose()` | Clear, request settlement, session end, or runtime disposal removes the surface |
| `ctx.ui.custom()` and overlays | Terminal-owned |
| `setWidget(key, ...)`, `setStatus(key, ...)` | Persist until replaced, cleared, or session cleanup |

`renderNative` receives this context and component type:

```ts
export interface NativeRenderableComponent extends Component {
  renderNative?(context: NativeRenderContext): ExtensionUINativeSurface;
}

export interface NativeRenderContext {
  target: "oppi-native-v1";
  capabilities: string[];
  locale?: string;
}
```

## Managed and mirrored sessions

| Capability | Managed Oppi session | Mirrored terminal session |
| --- | --- | --- |
| Standard dialogs (`ask`, `select`, `confirm`, `input`, `editor`) | Native iOS presentation from Pi request fields | Native presentation from the forwarded request; first answer wins across terminal and Oppi |
| Status, title, widget text, `notify` | Native notification or persistent projection | Same, from the forwarded notification |
| Component widget terminal fallback | Server calls `render(width)` | Needs a bridge-forwarded snapshot; otherwise terminal-only |
| Component widget `renderNative()` | Server calls it directly | Needs the mirror bridge native-snapshot capability |
| Custom component interaction | Terminal-first compatibility loop | Terminal-owned |
| Footer, header, editor replacement | Limited mapping or ignored | Terminal-owned |
| Lifecycle authority | Oppi server SDK state | Terminal Pi state, mirrored through the bridge |
| Cross-device cleanup | `extension_ui_settled` from the server | `extension_ui_settled` mirrored from the terminal and bridge |

In managed sessions Oppi creates the `ctx.ui` bridge, so the server translates extension UI at the source. `getEditorText` returns an empty string, `getToolsExpanded` returns the bridge's native tool expansion state, and `onTerminalInput`, `setFooter`, `setHeader`, `custom`, `addAutocompleteProvider`, and theme switching are no-op or unsupported shims. In mirrored sessions the terminal Pi process owns the real component objects. Both kinds render the same semantic payloads the same way; they differ only where terminal ownership hides opaque components.

## Capabilities and fallback

The server advertises these capability levels and clients must support at least text fallback:

| Capability | Level |
| --- | --- |
| `extension-native-ui:v1:text-fallback` | `fallback.text`, `fallback.lines`, and `terminal` blocks |
| `extension-native-ui:v1:prompt-native` | Standard Pi dialog mappings from `extension_ui_request` |
| `extension-native-ui:v1:surface-native` | All blocks and persistent surface panels |
| `extension-native-ui:v1:osc8-links` | OSC 8 hyperlinks in terminal fallback as tappable links |

Terminal fallback is part of the contract:

- Lines are sanitized before reaching clients. Unknown escape sequences are stripped.
- ANSI SGR styles map to `ExtensionUITextSpan` roles and traits, and OSC 8 hyperlinks map to `span.link`.
- Box drawing stays text. Fallback blocks are selectable when practical and need a useful linear accessibility label.
- Fallback never crashes the chat timeline.

## Presentation guardrails

- **Modality:** use modal UI only for a narrow user-facing task, and never stack extension sheets: queue or replace them. Blocking prompts have a clear Cancel or Ignore. Confirm before closing a modal that would lose typed text. Long inline content promotes to a sheet or full screen instead of nested same-axis scrolling above the composer.
- **Accessibility:** support Dynamic Type, VoiceOver, Full Keyboard Access, Switch Control, and reduced motion. Visible controls are at least 44×44 pt. Pair color with text, icons, or shape. Avoid flashing, blinking spinners, and layout-jumping progress rows. Keep streaming updates height-stable.
- **Trust:** label surfaces with their source (extension, workspace, or session) when a prompt could surprise. Make it clear when a response goes to the running session. Do not echo sensitive fields, persist them in chat history, or log them. Extension text and links are untrusted.
- **No downloaded code:** surfaces are data rendered by the app. Clients never download or execute extension code, and surfaces cannot call native platform APIs.
- **Generic rendering:** keep widgets in the generic strips and drawers, with no extension-specific panels. A widget snapshot never gets unbounded inline height.
