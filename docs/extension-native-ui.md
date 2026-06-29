# Extension native UI contract

This is Oppi's public contract for translating Pi extension UI into native Apple UI.

The contract has two jobs:

1. Keep terminal-first Pi extensions usable in Oppi.
2. Give extension authors a semantic path to native cards, sheets, rows, and display surfaces without writing Swift.

## Status

This document defines the version 1 behavior target. Oppi clients and server code can support the contract incrementally. When a block is unsupported, the client must fall back to the provided terminal/text fallback rather than failing the extension UI request.

Existing behavior still applies for the current protocol fields in `extension_ui_request` and `extension_ui_notification`. The native surface described here is additive.

## Core rule

Native UI requires explicit semantics. Oppi must not infer durable product behavior from arbitrary terminal art.

A Pi extension can always provide terminal output through `render(width): string[]`. Oppi can display that as a styled terminal fallback. To get native UI, the extension or bridge must provide a serializable native surface.

## Design goals

- One TypeScript extension UI can work in both Pi TUI and Oppi.
- Simple extension prompts render like native Oppi UI, especially the AskCard pattern.
- Persistent extension widgets render as generic extension surfaces, not extension-specific Swift panels.
- Opaque terminal components remain readable and selectable as fallback.
- Links, labels, and display state stay semantic across the bridge.
- iPhone and iPad use platform-appropriate presentation without changing extension code.

## Non-goals

- Oppi is not a terminal emulator.
- Oppi does not promise pixel-perfect ANSI or box-drawing reproduction.
- Third-party extensions cannot ship arbitrary native Swift views.
- This contract does not add extension-specific native UI.
- This contract does not replace Pi TUI in terminal mode.

## Surface model

A native extension UI payload is a versioned `ExtensionUINativeSurface`.

```ts
export interface ExtensionUINativeSurface {
  version: 1;
  id: string;
  source: "widget";
  presentation: ExtensionUINativePresentation;
  blocks: ExtensionUINativeBlock[];
  fallback?: ExtensionUINativeFallback;
}
```

### Presentation

```ts
export interface ExtensionUINativePresentation {
  style: "surfacePanel";
  title?: string;
  subtitle?: string;
}
```

Native surfaces are currently display-only widget snapshots. The `extension_ui_notification.widgetPlacement` field controls where the widget appears; placement is not part of the native surface envelope.

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
    | {
        type: "section";
        title?: string;
        subtitle?: string;
        blocks: ExtensionUINativeBlock[];
      }
    | { type: "activityList"; rows: ExtensionUIActivityRow[] }
    | {
        type: "progress";
        label?: string;
        value?: number;
        indeterminate?: boolean;
      }
    | { type: "terminal"; lines: ExtensionUITextSpan[][] }
    | { type: "code"; language?: string; text: string }
    | { type: "divider" }
    | { type: "spacer"; size?: "small" | "medium" | "large" }
  );
```

### Text spans

```ts
export interface ExtensionUITextSpan {
  text: string;
  role?:
    | "primary"
    | "secondary"
    | "muted"
    | "accent"
    | "success"
    | "warning"
    | "danger"
    | "code";
  traits?: Array<
    "bold" | "italic" | "monospaced" | "strikethrough" | "underline"
  >;
  link?: string;
}
```

Roles are semantic. The Apple client maps them to the active Oppi theme. Extensions must not depend on raw colors.

Accessibility metadata is optional but important for dense or symbolic UI. Native clients should derive labels from visible text when possible, then use `accessibility` to clarify glyph-only controls, progress rows, and terminal snapshots. Color must never be the only state signal.

### Blocking prompts

Blocking prompts are not native-surface blocks. They stay Pi-shaped in `extension_ui_request` and map directly to native iOS prompt presentations:

- `ask` maps to AskCard.
- `select`, `confirm`, and `input` map to inline AskCard-style prompt cards.
- `editor` maps to a native editor sheet.

`ask` is an Oppi-defined request method. It exists because Pi's standard dialog API does not include a portable multi-select or multi-question form request; terminal-only extensions can use `ctx.ui.custom()`, but RPC/mobile clients need semantic fields such as `questions`, `options`, `multiSelect`, and `allowCustom`.

The reference package is `pi-extensions/ask`. It registers a public Pi tool, uses `ctx.ui.ask()` when available, and falls back to `ctx.ui.custom()`, `ctx.ui.select()`, and `ctx.ui.input()` in plain Pi contexts.

This keeps prompt behavior compatible with Pi extension APIs and avoids a second interactive form protocol. Future native form or action support must add explicit event routing before becoming part of this contract.

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
}
```

Use activity lists for persistent task state: running jobs, queued work, progress, substeps, and recent results. `link` is a generic row navigation target, such as `oppi://session/<id>`, and must route through app-level link handling. The model is generic and must not encode extension-specific concepts in the protocol.

Recommended Apple state mapping:

| Activity state | Meaning                                 | Visual treatment           |
| -------------- | --------------------------------------- | -------------------------- |
| `queued`       | waiting to start                        | muted or pending indicator |
| `running`      | active work or stopping                 | orange/working indicator   |
| `success`      | ready/completed successfully            | green/success indicator    |
| `warning`      | completed with caveat                   | orange/warning indicator   |
| `error`        | failed                                  | red/error indicator        |
| `inactive`     | stopped, dismissed, or no longer active | muted indicator            |

### Fallback

```ts
export interface ExtensionUINativeFallback {
  text?: string;
  lines?: string[];
}
```

Every native surface produced from an opaque TUI component should include fallback text or lines. Clients use fallback when a block is unsupported, native rendering fails, or the platform chooses terminal-compatible display.

## Display cleanup rules

Widget surface cleanup follows the existing server message lifecycle. Clients must treat native widget surfaces as stateful snapshots identified by `id`, not as append-only messages.

### Surface identity and updates

- `id` is stable for the lifetime of a displayed surface.
- A new surface with the same `id` replaces the previous snapshot.
- Widget IDs are derived from the extension widget key, such as `widget:<widgetKey>`.
- `extension_ui_notification.widgetPlacement` controls where the widget appears in Oppi.
- Clients may preserve local UI state such as expanded/collapsed rows across replacements when block IDs remain stable.

### Blocking prompts

Blocking prompts come from `ask`, `select`, `confirm`, `input`, and `editor`. They are not native widget surfaces.

Lifecycle:

1. Server emits a Pi-shaped `extension_ui_request` with a stable `id`.
2. Client displays one active blocking surface for the focused session.
3. User action sends `extension_ui_response`.
4. Server resolves the extension promise and broadcasts `extension_ui_settled`.
5. All clients dismiss the surface with that `id`.

Rules:

- The server is authoritative for timeout and cancellation.
- Clients can show countdowns from `timeoutAt`, but must not invent a successful response when a timeout expires locally.
- If another device responds first, `extension_ui_settled` dismisses the request everywhere.
- Late responses for settled IDs are ignored.
- Navigating away from a session does not cancel a blocking request. The request becomes pending attention for that session and restores when the user returns.
- If multiple blocking requests are pending for one session, clients present them in server order unless a later server message explicitly settles or replaces an earlier one.

### Persistent widget surfaces

Persistent native surfaces currently come from `setWidget(component)` when the component provides `renderNative()`.

Lifecycle:

1. Server emits an `extension_ui_notification` with a key or stable surface `id`.
2. Client stores the surface in per-session extension UI state.
3. Later notifications with the same key replace that surface.
4. An explicit clear removes the surface.
5. Session end, session deletion, or runtime disposal clears all persistent extension surfaces for that session.

Rules:

- `setWidget(key, undefined)` or an empty normalized widget clears that widget surface.
- Component widgets update by replacing snapshots after `tui.requestRender()`.
- Persistent surfaces survive normal turn boundaries and agent stops unless explicitly cleared.
- Persistent surfaces are scoped to the session, not the workspace globally.

### Fire-and-forget notifications

Fire-and-forget notifications come from `notify()`. They are not native widget surfaces.

Lifecycle:

- Clients may show them as toast, banner, sheet, or notification depending on severity and focus.
- They do not require `extension_ui_response`.
- They are not replayed as durable session UI after reconnect.

### Editor handoffs

`setEditorText()` and `pasteToEditor()` are one-shot editor handoffs, not persistent display surfaces.

Lifecycle:

- The client applies the text to the active composer for the target session.
- The text then belongs to the user-facing composer state.
- Later extension UI settlement does not remove or submit the staged text.

### Timeline rendering

Tool and custom-message renderers stay on the timeline path. They are not part of the current native widget-surface envelope.

Lifecycle:

- Tool call rows update during `tool_execution_start`, `tool_execution_update`, and `tool_execution_end`.
- Final output remains as timeline content.
- User expansion state is client-local.
- Custom message renderers persist with their session entry and clear only when the entry is no longer part of the displayed branch/history.

### Error and fallback lifecycle

If native rendering fails:

- the client renders `fallback` if present
- otherwise it renders a sanitized terminal snapshot when available
- otherwise it shows a compact unsupported-ui message with the surface title and source

A rendering failure must not settle or cancel the extension request by itself.

## Relation to Pi TUI lifecycle

This contract follows Pi TUI lifecycle concepts, but serializes them because Oppi runs over a client/server protocol.

| Pi TUI lifecycle concept                                    | Native contract behavior                                                                               |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Component factory creates an object                         | Server creates a native surface with a stable `id`                                                     |
| `render(width)` returns current lines                       | `renderNative(context)` returns current semantic blocks, or fallback lines are rendered                |
| `tui.requestRender()` schedules redraw                      | Server emits a replacement snapshot for the same surface `id`                                          |
| `handleInput(data)` mutates focused component state         | Terminal-owned compatibility behavior; native event forwarding is future work                          |
| `invalidate()` clears render caches                         | Next native/terminal snapshot is recomputed; clients may also re-render locally for theme/size changes |
| `dispose()` releases component resources                    | Explicit clear, request settlement, session end, or runtime disposal removes the surface               |
| `ctx.ui.custom()` replaces the editor until `done()`        | Terminal-first compatibility surface                                                                   |
| `ctx.ui.custom(..., { overlay })` creates a focused overlay | Terminal-owned unless a future bridge capability defines a native equivalent                           |
| `setWidget(key, ...)` persists until replaced or cleared    | Persistent keyed surface persists until explicit clear/session cleanup                                 |
| `setStatus(key, ...)` persists until cleared                | Persistent keyed status text persists until explicit clear/session cleanup                             |
| `notify()` is fire-and-forget                               | Ephemeral native toast/banner/sheet, not durable state                                                 |

The main difference is authority. In terminal Pi, the in-process TUI owns focus and disposal directly. In Oppi, the server owns request state and sends snapshots; Apple clients render those snapshots and send responses/events back. Clients can dismiss optimistically after a response is accepted, but `extension_ui_settled` remains the authoritative cross-device cleanup signal.

## Managed runtime and mirrored runtime

Oppi has two Pi execution modes, and the native UI contract applies differently to each.

### Managed Oppi runtime

Managed sessions run through Oppi's server-owned SDK backend. Oppi creates the `ctx.ui` bridge, so the server can translate extension UI at the source.

Behavior:

- `ask`, `select`, `confirm`, `input`, `editor`, `notify`, `setTitle`, `setStatus`, `setWidget(string[])`, `setEditorText`, `pasteToEditor`, working-row customizations, `setHiddenThinkingLabel`, and `setToolsExpanded` are translated from Pi-shaped payloads into native iOS presentations.
- `getEditorText` returns an RPC-compatible empty string, while `getToolsExpanded` returns the bridge-local native tool expansion state.
- `setWidget(component)` factories run in the server process, so the bridge can call `renderNative()` when present.
- If `renderNative()` is absent, the bridge can call `render(width)` and send terminal fallback lines.
- Terminal-owned APIs such as `onTerminalInput`, `setFooter`, `setHeader`, `custom`, `addAutocompleteProvider`, and theme switching are no-op or unsupported compatibility shims unless the table below says otherwise.
- Server-side request state is authoritative. `extension_ui_settled` clears blocking UI across clients.
- Persistent surfaces are scoped to the managed session and clear on explicit clear, session end, session deletion, or runtime disposal.

This is the primary implementation path for the current native contract.

### Mirrored terminal runtime

Mirrored sessions are interactive terminal Pi sessions connected to Oppi through the mirror bridge. The terminal Pi process keeps execution ownership and owns the real TUI component objects.

Behavior:

- Standard semantic UI requests (`ask`, `select`, `confirm`, `input`, `editor`, `notify`, `setTitle`, `setStatus`, simple widget text, editor text handoff, working-row state, hidden thinking labels, and tool expansion state) can map to the same native presentations as managed sessions because their protocol payloads are already semantic.
- Blocking UI is first-wins across terminal and Oppi clients. If the terminal answers first, Oppi receives settlement and dismisses. If Oppi answers first, the bridge forwards the response to terminal Pi and terminal Pi settles the request.
- Custom TUI component objects are not available to the Oppi server unless the mirror bridge explicitly forwards native snapshots or terminal fallback snapshots.
- `renderNative()` for mirrored widget components requires bridge capability support. Without that capability, component trees remain terminal-first and Oppi must fall back to the existing compatibility behavior or show them as terminal-only.
- Terminal-specific footer/header/editor replacement and raw terminal input APIs remain terminal-owned unless a future bridge capability defines a native equivalent.

### Runtime support table

| Capability                                                       | Managed Oppi runtime                                     | Mirrored terminal runtime                                                |
| ---------------------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------ |
| Standard dialogs (`ask`, `select`, `confirm`, `input`, `editor`) | Native iOS presentation generated from Pi request fields | Native iOS presentation generated from forwarded semantic request        |
| Fire-and-forget status/title/widget text                         | Native notification or persistent projection             | Native notification or persistent projection from forwarded notification |
| Component widget terminal fallback                               | Server can call `render(width)`                          | Requires bridge-forwarded snapshot; otherwise terminal-only              |
| Component widget `renderNative()`                                | Server can call directly                                 | Requires mirror bridge native-snapshot capability                        |
| Blocking custom component interaction                            | Terminal-first compatibility loop                        | Terminal-owned unless bridge supports native events                      |
| Footer/header/editor replacement                                 | Limited native mapping or ignored                        | Terminal-owned                                                           |
| Lifecycle authority                                              | Oppi server SDK state                                    | Terminal Pi state, mirrored through bridge                               |
| Cross-device cleanup                                             | `extension_ui_settled` from server                       | `extension_ui_settled` mirrored from terminal/server bridge              |

Managed and mirrored sessions must render the same semantic request payloads the same way on Apple clients. Differences are allowed only where terminal ownership prevents Oppi from seeing or controlling opaque component objects.

## Native-renderable Pi TUI components

A Pi TUI component can add native semantics while keeping the standard terminal contract.

```ts
import type { Component } from "@earendil-works/pi-tui";

export interface NativeRenderableComponent extends Component {
  renderNative?(context: NativeRenderContext): ExtensionUINativeSurface;
}

export interface NativeRenderContext {
  target: "oppi-native-v1";
  capabilities: string[];
  locale?: string;
}
```

Pi TUI calls `render(width)` and `handleInput(data)`. Oppi calls `renderNative()` for widget snapshots when present. If native rendering is absent or throws, Oppi uses `fallback` or a sanitized terminal snapshot.

Author-facing usage stays on the existing widget API:

```ts
ctx.ui.setWidget("review", () => ({
  render: () => ["Review running", "3 findings"],
  renderNative: () => ({
    version: 1,
    id: "widget:review",
    source: "widget",
    presentation: {
      style: "surfacePanel",
      title: "Review running",
      subtitle: "3 findings",
    },
    blocks: [
      {
        type: "activityList",
        id: "findings",
        rows: [
          {
            id: "finding-1",
            title: "Fix retry state",
            subtitle: "High confidence",
            state: "warning",
          },
        ],
      },
      {
        type: "markdown",
        id: "summary",
        markdown: "**Summary:** Review is still running.",
      },
    ],
    fallback: { lines: ["Review running", "3 findings"] },
  }),
}));
```

Extension authors describe the widget state with semantic blocks. Apple clients own the screen budget and interaction policy. A widget snapshot does not grant unbounded inline height.

### Widget placement and collapsed budget

Pi's widget placement maps to two separate composer-adjacent strips:

- `aboveEditor` or an omitted placement renders in the strip above the composer.
- `belowEditor` renders in the strip below the composer.
- The two placements remain separate. A widget from one placement must not move into the other strip to fill space.

```text
aboveEditor strip
[ Agents · 1 running ] [ Tools · 2 active ] [ Git · +3.5k -118 ]

composer

belowEditor strip
[ Fleet · 2 sessions ] [ Queue · 1 follow-up ]
```

Each visible strip has a bounded collapsed state:

- The collapsed strip uses one row of pills. Pills scroll horizontally when they overflow.
- A collapsed widget must not add vertical height beyond the strip budget. Empty strips are hidden.
- One pill represents one widget or one standalone status entry.
- The pill label comes from, in order: native `presentation.title` and `presentation.subtitle`, an attached `setStatus` value, the `widgetKey`, then the first fallback line.
- Accessibility sizes can change the exact row height or promote content to a sheet, but the collapsed state remains bounded.

Each placement has one expanded drawer:

- Tapping a pill opens that widget in the drawer for the same placement.
- Tapping another pill replaces the drawer content instead of stacking another card.
- Tapping the active pill or collapse control closes the drawer.
- The drawer has a maximum height and scrolls internally. Long content can open full screen.
- `renderNative()` content renders as native blocks. Widgets without `renderNative()` render the sanitized terminal fallback in the drawer and full-screen view.

`setStatus(key, text)` attaches to a widget when `key === widgetKey`. If exactly one status and one widget share an extension scope, a client can attach the status by scope. Other status entries render as standalone pills in the same placement group.

Native blocks stay viewport-independent; clients decide iPhone, iPad, Dynamic Type, color scheme, and scroll ownership locally. If a future feature needs true per-client rendering, it must add an explicit client render request protocol instead of overloading the broadcast surface snapshot.

## Mapping from Pi extension APIs

| Pi API                             | Native surface                 | Apple rendering                            | Fallback                           |
| ---------------------------------- | ------------------------------ | ------------------------------------------ | ---------------------------------- |
| `ctx.ui.ask()` / Oppi `ask` tool   | Pi request fields              | AskCard inline, expanded full-screen       | existing AskCard behavior          |
| `ctx.ui.select(title, options)`    | Pi request fields              | AskCard-style inline                       | terminal/TUI select                |
| `ctx.ui.confirm(title, message)`   | Pi request fields              | compact confirmation card                  | terminal/TUI confirm               |
| `ctx.ui.input()`                   | Pi request fields              | inline text prompt                         | terminal/TUI input                 |
| `ctx.ui.editor()`                  | Pi request fields              | editor sheet                               | terminal/TUI editor                |
| `ctx.ui.notify()`                  | notification fields            | transient toast/sheet                      | existing toast sheet               |
| `ctx.ui.onTerminalInput()`         | terminal-owned input stream    | no native mapping                          | no-op unsubscribe in SDK sessions  |
| `ctx.ui.setTitle()`                | title notification             | extension surface heading                  | terminal window/tab title          |
| `ctx.ui.setStatus()`               | status text fields             | generic status projection/chips            | text status                        |
| `ctx.ui.setWidget(string[])`       | `widgetLines`                  | terminal strip/drawer fallback             | styled line card                   |
| `ctx.ui.setWidget(component)`      | `renderNative()` if present    | native strip/drawer blocks                 | terminal snapshot                  |
| `ctx.ui.custom()`                  | TUI component                  | no native mapping                          | resolves undefined in SDK sessions |
| `ctx.ui.setFooter()`               | terminal-owned/footer text     | no native mapping                          | ignored in SDK sessions            |
| `ctx.ui.setHeader()`               | terminal-owned/header text     | no native mapping                          | ignored in SDK sessions            |
| `ctx.ui.setWorkingMessage()`       | working-row text               | native timeline working row                | default working text               |
| `ctx.ui.setWorkingVisible()`       | working-row visibility         | hide/show native working row               | visible by default                 |
| `ctx.ui.setWorkingIndicator()`     | working indicator frames       | static/animated/hidden row indicator       | default native spinner             |
| `ctx.ui.setHiddenThinkingLabel()`  | hidden thinking label          | thinking row accessibility/source metadata | default thinking label             |
| `ctx.ui.pasteToEditor()`           | `set_editor_text` notification | composer text handoff                      | same as `setEditorText()` in RPC   |
| `ctx.ui.setEditorText()`           | `set_editor_text` notification | composer text handoff                      | host-owned editor text handoff     |
| `ctx.ui.getEditorText()`           | not portable synchronously     | empty string                               | empty string in RPC                |
| `ctx.ui.getToolsExpanded()`        | bridge-local state             | current native tool expansion flag         | `false` by default                 |
| `ctx.ui.setToolsExpanded()`        | tool expansion state           | expand/collapse native tool rows           | collapsed by default               |
| `ctx.ui.setEditorComponent()`      | not portable                   | no native mapping                          | preserve factory only              |
| `ctx.ui.getEditorComponent()`      | not portable                   | no native mapping                          | return preserved factory           |
| `ctx.ui.addAutocompleteProvider()` | terminal-owned autocomplete    | no native mapping                          | ignored in SDK sessions            |
| `ctx.ui.theme`                     | snapshot render theme          | terminal snapshot styling helper           | text-preserving theme shim         |
| `ctx.ui.getAllThemes()`            | terminal-owned theme registry  | no native mapping                          | empty list in SDK sessions         |
| `ctx.ui.getTheme()`                | terminal-owned theme registry  | no native mapping                          | undefined in SDK sessions          |
| `ctx.ui.setTheme()`                | terminal-owned theme switching | no native mapping                          | unsupported result in SDK sessions |
| `renderCall` / `renderResult`      | timeline renderer output       | current mobile renderer / raw text         | current mobile renderer / raw text |
| `registerMessageRenderer()`        | custom message text            | current mobile renderer / raw text         | raw custom message text            |

### Working indicator and status rules

`setWorkingIndicator`, `setWorkingMessage`, and `setStatus` are semantic extension UI state. Oppi projects them automatically and cheaply because the payload is data, not terminal frames.

Example fixture shape:

```ts
ctx.ui.setWorkingIndicator({ frames: ["·", "•", "●", "•"], intervalMs: 120 });
ctx.ui.setWorkingMessage("Checking files…");
ctx.ui.setStatus("working-words", "shuffled · 18 phrases");
```

Rules:

- iOS animates custom working frames locally from `frames + intervalMs`.
- `frames: []` hides the working glyph; `undefined` restores the native spinner.
- `setWorkingMessage()` updates the timeline working row while the session is busy.
- `setStatus(key, text)` updates keyed composer-adjacent session chrome and persists until cleared.
- Hosts strip terminal control sequences, cap frame/message/status sizes, coalesce duplicate payloads, and throttle high-frequency text updates.
- iOS owns Dynamic Type, VoiceOver labels, Reduce Motion, color, spacing, and fallback.
- Terminal-only fonts or private-use glyphs can fall back to the native spinner or plain text on iOS. Extensions that want exact terminal glyphs can branch on `ctx.mode === "tui"` and provide portable Unicode/text frames elsewhere.

## Mapping from Pi TUI components

| Pi TUI component or pattern                       | Native block           | Apple design                                                           |
| ------------------------------------------------- | ---------------------- | ---------------------------------------------------------------------- |
| `Text`                                            | `text` or `markdown`   | native `Text` with wrapping and Dynamic Type                           |
| `Markdown`                                        | `markdown`             | existing markdown renderer                                             |
| `Box`                                             | `section`              | rounded card, theme background, subtle stroke                          |
| `Container`                                       | `section.blocks`       | vertical stack                                                         |
| `Spacer`                                          | `spacer`               | native spacing token                                                   |
| `Image`                                           | terminal/text fallback | future native support requires scoped image references                 |
| `SelectList`                                      | terminal fallback      | use `ctx.ui.select()` for native blocking prompts                      |
| `SettingsList`                                    | terminal fallback      | future native support requires form/event routing                      |
| `Input`                                           | terminal fallback      | use `ctx.ui.input()` for native blocking prompts                       |
| `Editor`                                          | terminal fallback      | use `ctx.ui.editor()` for the native editor sheet                      |
| `Loader` / `CancellableLoader` / `BorderedLoader` | `progress`             | progress row/card                                                      |
| overlay `custom(..., { overlay })`                | terminal fallback      | future native support requires explicit presentation and event routing |
| arbitrary ANSI/box drawing                        | `terminal`             | monospaced selectable fallback card                                    |

## Apple design mapping

### Inline composer card

Use for small blocking choices where the next user action is obvious:

- short `ask` requests
- `select` with a small option set
- `confirm` with a short message
- simple `input` when the field is the whole task

Design requirements:

- reuse AskCard visual language
- keep options tappable with comfortable hit areas
- preserve Ignore/Cancel/Send controls
- expand to a full-screen view when question text or options exceed inline limits
- support Dynamic Type and VoiceOver page announcements

### Sheet

Use for medium-complexity UI:

- editor requests
- unsupported blocking extension requests that need readable fallback text

Design requirements:

- use `NavigationStack`
- put Cancel in the cancellation toolbar slot
- put the primary action in the confirmation toolbar slot or bottom action bar
- constrain readable width on iPad

### Full-screen flow

Use for large or editing-heavy UI:

- `editor`
- multi-question ask with long text
- custom surfaces that need stable navigation

Design requirements:

- use a clear navigation header
- use a bottom action bar for submit/cancel where appropriate
- preserve keyboard-safe layout
- support text selection for read-only long content

### Extension widget strips

Use for persistent widgets and optional status projections:

- `setTitle`
- `setStatus`
- `setWidget`
- non-blocking native surfaces

Design requirements:

- render `aboveEditor` and `belowEditor` as separate composer-adjacent strips
- keep the collapsed state to one pill row per strip with horizontal overflow
- open one bounded drawer per strip; tapping another widget replaces drawer content instead of stacking cards
- support title, status chips, activity rows, progress rows, and terminal fallback blocks
- keep the renderer generic; do not add extension-specific Swift panels
- keep streaming updates height-stable where practical

### Timeline row

Use for tool and custom message renderers:

- `renderCall`
- `renderResult`
- `registerMessageRenderer`

Design requirements:

- collapsed rows stay compact and stable
- expanded details carry rich output
- semantic styles map to the active theme
- multiline rich content belongs in expanded content, not collapsed chrome

## Apple, App Review, and human-interaction guardrails

The native contract should feel like an Apple app, not a remote terminal with prettier paint.

### Modality and focus

- Use modality only for a narrow, user-facing task.
- Never stack extension sheets. Queue or replace them and let the user dismiss one modal before another appears.
- Blocking prompts need an obvious Cancel/Ignore path.
- If dismissing a modal would lose typed text, confirm before closing.
- Long inline content should promote to a sheet or full-screen flow instead of adding nested same-axis scrolling above the composer.
- Full-screen native flows must not become arbitrary app-within-app navigation hierarchies.

### Accessibility and comfort

- Support Dynamic Type, VoiceOver, Full Keyboard Access, Switch Control, and reduced motion.
- Maintain 44x44 pt as the practical minimum iOS/iPadOS hit target for visible controls.
- Do not rely on color alone for state; pair roles with text, icons, or shape.
- Minimize time-boxed UI. `timeoutAt` can explain server state, but clients should not auto-submit or silently remove important content on a local timer.
- Avoid high-frequency flashing, blinking spinners, or layout-jumping progress rows.
- Terminal fallback needs a useful linear accessibility label, not just box drawing.

### Trust and provenance

- Label surfaces with their source when the prompt could be surprising, such as the extension name, workspace, or session.
- Make it clear when a response will be sent to the running session/server.
- Sensitive fields must not be echoed, persisted in chat history, or written to routine logs.
- Extension text and links are untrusted content. Links route through normal platform URL handling and app navigation policy.

### App Review posture

This contract keeps extension UI App-Review-friendly by treating native surfaces as data rendered by the Oppi app, not downloaded native code.

- Apple clients must not download or execute extension code.
- Future extension actions must not access native platform APIs directly; they must send responses/events to the server.
- The app must not present a general-purpose extension marketplace, plug-in store, or purchase flow through native surfaces.
- Remote or third-party extension content must follow the app's privacy, safety, and moderation posture.
- If extension UI exposes user-generated content, objectionable-content reporting/moderation responsibilities still apply.
- Review notes should describe non-obvious self-hosted runtime and extension UI behavior when shipping this feature.

## Response and event model

Blocking prompts return through the existing `extension_ui_response` channel.

```ts
export type ExtensionUIResponse = {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
};
```

Future non-blocking native interactions can use an extension UI event message.

```ts
export interface ExtensionUINativeEventMessage {
  type: "extension_ui_event";
  id: string;
  event: ExtensionUINativeEvent;
}
```

Clients that do not support future non-blocking events must ignore them or fall back to blocking Submit/Cancel behavior.

## Terminal fallback behavior

Terminal fallback is part of the public contract.

- Rendered lines must be sanitized before reaching Apple clients.
- Unknown escape sequences must be stripped.
- ANSI SGR styles can map to semantic `ExtensionUITextSpan.role` and traits.
- OSC-8 hyperlinks can map to `span.link`.
- Box drawing remains text.
- Fallback terminal blocks must be selectable when practical.
- Terminal fallback must not crash the chat timeline.

## Compatibility levels

A client can claim one of these support levels:

1. **Text fallback**: supports `fallback.text`, `fallback.lines`, and `terminal` blocks.
2. **Prompt native**: supports standard Pi dialog mappings from `extension_ui_request`.
3. **Surface native**: supports `text`, `markdown`, `section`, `activityList`, `progress`, `terminal`, `code`, `divider`, `spacer`, and persistent surface panels.
4. **Interactive native**: supports future field changes and non-blocking actions through an explicit event message.
5. **Timeline native**: supports future native tool/message renderers.

Oppi clients must behave as level 1 at minimum.

## Protocol requirements before implementation

The native surface contract depends on a few operational rules beyond the block schema.

### Capability negotiation

Clients and runtimes must advertise native UI support before relying on native-only behavior.

Recommended capability names:

- `extension-native-ui:v1:text-fallback`
- `extension-native-ui:v1:prompt-native`
- `extension-native-ui:v1:surface-native`
- `extension-native-ui:v1:interactive-native`
- `extension-native-ui:v1:timeline-native`
- `extension-native-ui:v1:osc8-links`

Managed runtimes can assume the server bridge understands the schema, but still need client capability checks before sending interactive-only native events. Mirrored runtimes must advertise whether the bridge can forward native snapshots for custom component objects.

### Replay and reconnect

Blocking requests and persistent surfaces must be recoverable after reconnect.

- Pending blocking requests are replayed until settlement.
- Persistent surfaces should be included in session catch-up or session state, or the runtime must resend them when a client reconnects.
- Ephemeral notifications are not replayed.
- Timeline surfaces replay with session history.

### Payload limits

Server implementations must bound native UI payload size.

- Block count, nesting depth, text length, terminal lines, and image/data references need explicit limits.
- Large content should move to existing upload/file/data-reference paths rather than inline JSON.
- Clients must show a fallback truncation notice when limits are hit.
- High-frequency updates such as progress/activity widgets must be throttled.

### Safety and links

Native UI is display and input only. It must not grant extensions direct client-side execution.

- Future actions must return events or responses to the server/extension; clients must not execute extension-defined commands locally.
- External links require normal platform URL handling and can be restricted by scheme.
- Internal links such as `oppi://session/<id>` should route through generic app navigation, not extension-specific code.
- Future image/data references must be scoped to the session/workspace and checked by the server.

### Authoring API

Extension authors should use the exported TypeScript types and small helpers from `server/src/extension-ui-contract.ts` when they are authored inside this repository. The helper is structural and optional: extensions can still implement `renderNative()` without importing Oppi, but official types and builders reduce drift.

### Test matrix

Implementation should validate at least these fixtures:

- `ask` single select, multi-select, custom answer, timeout, and cross-device settlement
- `select`, `confirm`, and `input` mapped to AskCard-style UI, with `editor` mapped to the editor sheet
- `setEditorText` and `pasteToEditor` mapped to native composer handoff
- `setTitle`, `setStatus`, and `setWidget` displayed as persistent native surfaces and cleared by explicit Pi-style empty notifications
- `setWidget(..., { placement })` mapped to separate `aboveEditor` and `belowEditor` strips
- collapsed strip height capped at one pill row, with horizontal overflow and hidden empty strips
- one expanded drawer per placement, with tap-to-replace behavior across widgets in the same strip
- working-row message, visibility, static indicator, animated indicator, hidden indicator, reset behavior, hidden-thinking source labels, and tool expansion state
- display block mapping for text, markdown, progress, activity lists, terminal, and code
- activity row links through generic `oppi://session/<id>` navigation
- component widget with `renderNative()`
- component widget without `renderNative()` terminal fallback
- managed runtime and mirrored runtime paths
- iPhone and iPad screenshots for native prompt, widget strips, expanded drawer, and fallback terminal content

## Recommended rollout and complexity budget

The contract is intentionally broader than the first implementation. Implement it in layers so native UI improves without turning extension surfaces into a second app framework.

### Phase 1: stabilize fallback and cleanup

- Keep current terminal/text fallback reliable.
- Add native surface types to notification/display protocol and Swift decoders with unknown-block fallback.
- Implement capability flags, replay rules, payload limits, and cleanup behavior.
- Do not add non-blocking native events yet.

### Phase 2: native blocking prompts

- Map `ask`, `select`, `confirm`, `input`, and simple `editor` to AskCard and editor sheet flows from Pi request fields.
- Reuse AskCard and existing dialog/sheet flows.
- Validate timeout, cancel, cross-device first-wins settlement, and reconnect.

### Phase 3: persistent native surfaces

- Render `section`, `text`, `markdown`, `progress`, `activityList`, and `terminal` in the generic extension widget strips and drawers.
- Update by replacement using stable widget IDs.
- Throttle widget updates.

### Phase 4: authoring and selected component support

- Keep TypeScript types/builders for `renderNative()` exported from the shared contract and migrate in-repo extensions onto them.
- Support `renderNative()` for managed runtime component widgets.
- Keep mirrored component support behind explicit bridge capability flags.

### Phase 5: interactive and timeline native UI

- Add `extension_ui_event` only after blocking/persistent surfaces are stable.
- Revisit native `custom()` component interaction only after event routing is proven necessary and Pi-compatible.
- Add native timeline rows for tool/message renderers.
- Add richer data references such as images only when server scoping, limits, and caching are clear.

Defer anything that requires arbitrary client-side execution, nested modal navigation, hidden extension marketplaces, per-client server rendering, or live remote component focus until there is a concrete product need and a reviewable threat model.

## Example: widget as native surface panel

```json
{
  "version": 1,
  "id": "widget:jobs",
  "source": "widget",
  "presentation": {
    "style": "surfacePanel",
    "title": "Jobs"
  },
  "blocks": [
    {
      "type": "activityList",
      "id": "jobs",
      "rows": [
        {
          "id": "job-1",
          "title": "Review",
          "subtitle": "Running",
          "state": "running"
        },
        {
          "id": "job-2",
          "title": "Tests",
          "subtitle": "Queued",
          "state": "queued"
        }
      ]
    }
  ],
  "fallback": {
    "lines": ["● Review", "○ Tests"]
  }
}
```

## Example: persistent activity widget

```json
{
  "version": 1,
  "id": "widget-agents",
  "source": "widget",
  "presentation": {
    "style": "surfacePanel",
    "title": "Pi extension UI"
  },
  "blocks": [
    {
      "type": "activityList",
      "rows": [
        {
          "id": "a1",
          "title": "Refactor auth module",
          "subtitle": "Agent · 5 tool uses · 33.8k tokens",
          "detail": "editing 2 files",
          "state": "running"
        },
        {
          "id": "a2",
          "title": "Find auth files",
          "subtitle": "Explore · 3 tool uses",
          "detail": "searching",
          "state": "running"
        }
      ]
    }
  ],
  "fallback": {
    "lines": [
      "● Agents",
      "├─ Agent Refactor auth module · 5 tool uses",
      "│  ⎿ editing 2 files",
      "└─ Explore Find auth files · 3 tool uses"
    ]
  }
}
```

## Implementation requirements

Server implementations:

- keep blocking `extension_ui_request` payloads Pi-shaped; do not attach Oppi-only native surfaces to `ask`, `select`, `confirm`, `input`, or `editor`
- add `nativeSurface?: ExtensionUINativeSurface` only to notification/display payloads such as `setWidget`
- detect `renderNative()` on widget components
- preserve terminal fallback fields for unsupported clients
- keep protocol changes forward-compatible

Apple implementations:

- decode unknown blocks without failing the whole message
- render supported blocks natively
- render unsupported blocks with fallback content
- keep AskCard as the reference for standard Pi prompt requests
- keep persistent widgets in generic extension strips and drawers
- avoid extension-specific Swift UI for generic surfaces

## Acceptance criteria

- Existing ask behavior remains compatible.
- `select`, `confirm`, and `input` can render as AskCard-style native UI when appropriate.
- A widget component with `renderNative()` renders native blocks in Oppi and terminal UI in Pi.
- A widget component without `renderNative()` renders a terminal fallback and does not crash.
- Widget rendering stays generic, and status text remains generic.
- Persistent widgets are grouped by placement into bounded strips instead of unbounded stacked cards.
- OSC-8 links survive fallback as tappable links when clients support links.
- iPhone and iPad screenshots cover native prompt, widget strips, expanded drawers, and terminal fallback paths.

## Related files

- `server/src/extension-ui-contract.ts`
- `server/src/sdk-ui-bridge.ts`
- `server/src/pi-tui-mirror-runtime.ts`
- `server/src/types/protocol.ts`
- `clients/apple/Oppi/Core/Models/ServerMessage.swift`
- `clients/apple/Oppi/Core/Models/ExtensionUIRequest+Presentation.swift`
- `clients/apple/Oppi/Features/Chat/Composer/AskCard.swift`
- `clients/apple/Oppi/Features/Chat/Composer/AskCardExpanded.swift`
- `clients/apple/Oppi/Features/Chat/ChatView.swift`
