# Extension native UI contract

This is Oppi's public contract for translating Pi extension UI into native Apple UI.

The contract has two jobs:

1. Keep terminal-first Pi extensions usable in Oppi.
2. Give extension authors a semantic path to native cards, sheets, forms, rows, and actions without writing Swift.

## Status

This document defines the version 1 behavior target. Oppi clients and server code can support the contract incrementally. When a field or block is unsupported, the client must fall back to the provided terminal/text fallback rather than failing the extension UI request.

Existing behavior still applies for the current protocol fields in `extension_ui_request` and `extension_ui_notification`. The native surface described here is additive.

## Core rule

Native UI requires explicit semantics. Oppi must not infer durable product behavior from arbitrary terminal art.

A Pi extension can always provide terminal output through `render(width): string[]`. Oppi can display that as a styled terminal fallback. To get native UI, the extension or bridge must provide a serializable native surface.

## Design goals

- One TypeScript extension UI can work in both Pi TUI and Oppi.
- Simple extension prompts render like native Oppi UI, especially the AskCard pattern.
- Persistent extension widgets render as generic extension surfaces, not extension-specific Swift panels.
- Opaque terminal components remain readable and selectable as fallback.
- Links, actions, labels, and selected state stay semantic across the bridge.
- iPhone and iPad use platform-appropriate presentation without changing extension code.

## Non-goals

- Oppi is not a terminal emulator.
- Oppi does not promise pixel-perfect ANSI or box-drawing reproduction.
- Third-party extensions cannot ship arbitrary native Swift views.
- This contract does not add subagent-specific UI.
- This contract does not replace Pi TUI in terminal mode.

## Surface model

A native extension UI payload is a versioned `ExtensionUINativeSurface`.

```ts
export interface ExtensionUINativeSurface {
  version: 1;
  id: string;
  revision?: number;
  source:
    | "ask"
    | "select"
    | "confirm"
    | "input"
    | "editor"
    | "custom"
    | "widget"
    | "status"
    | "tool"
    | "message";
  presentation: ExtensionUINativePresentation;
  lifecycle?: ExtensionUIDisplayLifecycle;
  blocks: ExtensionUINativeBlock[];
  actions?: ExtensionUINativeAction[];
  fallback?: ExtensionUINativeFallback;
}
```

### Presentation

```ts
export interface ExtensionUINativePresentation {
  style:
    | "inlineCard"
    | "sheet"
    | "fullScreen"
    | "surfacePanel"
    | "status"
    | "toast"
    | "timelineRow";
  placement?: "composer" | "aboveEditor" | "belowEditor" | "timeline" | "footer";
  title?: string;
  subtitle?: string;
  timeoutAt?: number;
  priority?: "low" | "normal" | "blocking";
}
```

Presentation values are hints. Apple clients choose the exact container for screen size, Dynamic Type, keyboard state, and content length.

### Display lifecycle

```ts
export interface ExtensionUIDisplayLifecycle {
  kind: "blocking" | "persistent" | "ephemeral" | "timeline" | "editorHandoff";
  updateMode?: "replace" | "append";
  clearOn?: Array<
    | "response"
    | "settled"
    | "explicitClear"
    | "sessionEnd"
    | "sessionDelete"
    | "runtimeDispose"
  >;
}
```

Lifecycle values describe how the client keeps, updates, and clears a surface. If omitted, the client derives lifecycle from `source` and `presentation.style`.

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
    | {
        type: "choiceGroup";
        id: string;
        question: string;
        options: ExtensionUIChoice[];
        multiSelect?: boolean;
        allowCustom?: boolean;
        customPlaceholder?: string;
      }
    | { type: "form"; fields: ExtensionUIField[] }
    | { type: "settingsList"; items: ExtensionUISettingItem[] }
    | { type: "activityList"; rows: ExtensionUIActivityRow[] }
    | { type: "progress"; label?: string; value?: number; indeterminate?: boolean }
    | { type: "terminal"; lines: ExtensionUITextSpan[][] }
    | { type: "code"; language?: string; text: string }
    | { type: "image"; mimeType: string; dataRef: string; alt?: string }
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
  traits?: Array<"bold" | "italic" | "monospaced" | "strikethrough" | "underline">;
  link?: string;
}
```

Roles are semantic. The Apple client maps them to the active Oppi theme. Extensions must not depend on raw colors.

Accessibility metadata is optional but important for dense or symbolic UI. Native clients should derive labels from visible text when possible, then use `accessibility` to clarify glyph-only controls, progress rows, terminal snapshots, and custom images. Color must never be the only state signal.

### Choices

```ts
export interface ExtensionUIChoice {
  value: string;
  label: string;
  description?: string;
  selected?: boolean;
  disabled?: boolean;
}
```

Choice groups map to AskCard-style UI. Single-select groups submit one value. Multi-select groups submit an ordered array of selected values unless the backing API expects the existing ask JSON map.

### Form fields

```ts
export type ExtensionUIField =
  | {
      id: string;
      type: "text";
      label: string;
      placeholder?: string;
      value?: string;
      required?: boolean;
      sensitive?: boolean;
    }
  | {
      id: string;
      type: "textArea";
      label: string;
      placeholder?: string;
      value?: string;
      minLines?: number;
      maxLines?: number;
      sensitive?: boolean;
    }
  | { id: string; type: "toggle"; label: string; value: boolean; description?: string }
  | { id: string; type: "picker"; label: string; value?: string; options: ExtensionUIChoice[] };
```

Fields marked `sensitive` should render with privacy-preserving controls where practical, avoid echoing entered values in visible UI, and be redacted from logs and durable session history.

### Settings lists

```ts
export interface ExtensionUISettingItem {
  id: string;
  label: string;
  value: string;
  description?: string;
  values?: string[];
  disabled?: boolean;
}
```

A settings list represents rows whose value can change in place. If `values` is present, native clients can render a picker, segmented control, menu, or cycling button.

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
  actions?: ExtensionUINativeAction[];
}
```

Use activity lists for persistent task state: running jobs, queued work, progress, substeps, and recent results. `link` is a generic row navigation target, such as `oppi://session/<id>`, and must route through app-level link handling. The model is generic and must not encode extension-specific concepts such as subagents in the protocol.

Recommended Apple state mapping:

| Activity state | Meaning | Visual treatment |
| --- | --- | --- |
| `queued` | waiting to start | muted or pending indicator |
| `running` | active work or stopping | orange/working indicator |
| `success` | ready/completed successfully | green/success indicator |
| `warning` | completed with caveat | orange/warning indicator |
| `error` | failed | red/error indicator |
| `inactive` | stopped, dismissed, or no longer active | muted indicator |

### Built-in subagents surface mapping

The built-in Oppi subagents extension uses this contract as a first production fixture:

- Pi API: `ctx.ui.setWidget("subagents", component, { placement: "aboveEditor" })`
- Runtime: managed Oppi SDK runtime
- Native surface: `source: "widget"`, `presentation.style: "surfacePanel"`
- Native block: one `activityList` with generic rows
- Row link: `oppi://session/<sessionId>` routed through generic app navigation
- Fallback: terminal widget lines from `component.render(width)`

Subagent status mapping is deliberately generic and aligned with the workspace context bar: `starting`, `busy`, and `stopping` map to `running`, `ready` maps to `success`, `stopped` maps to `inactive`, and `error` maps to `error`. The widget shows active rows plus a bounded set of recent inactive rows.

### Actions

```ts
export interface ExtensionUINativeAction {
  id: string;
  label: string;
  role?: "primary" | "secondary" | "cancel" | "destructive";
  target?: "surface" | "block";
  value?: unknown;
  disabled?: boolean;
  confirmation?: {
    title: string;
    message?: string;
    confirmLabel?: string;
  };
  accessibility?: ExtensionUIAccessibility;
}
```

Actions become native buttons or row actions. Destructive actions must use the destructive role so Apple clients can style and confirm appropriately. Actions with `confirmation` require a native confirmation step before sending the event.

### Fallback

```ts
export interface ExtensionUINativeFallback {
  text?: string;
  lines?: string[];
}
```

Every native surface produced from an opaque TUI component should include fallback text or lines. Clients use fallback when a block is unsupported, native rendering fails, or the platform chooses terminal-compatible display.

## Display lifecycle rules

Surface lifecycle is part of the public contract. Clients must treat surfaces as stateful UI identified by `id`, not as append-only messages.

### Surface identity and updates

- `id` is stable for the lifetime of a displayed surface.
- A new surface with the same `id` replaces the previous snapshot unless `lifecycle.updateMode` is `"append"`.
- Blocking request IDs come from `extension_ui_request.id`.
- Persistent widget/status IDs are derived from the session plus extension key, such as `widget:<widgetKey>` or `status:<statusKey>`.
- Timeline IDs are derived from the tool call ID, message entry ID, or custom message ID.
- `revision` increments when the backing surface state changes. Clients use it to ignore stale non-blocking native events.
- Clients may preserve local UI state such as expanded/collapsed rows across replacements when block IDs remain stable.

### Blocking surfaces

Blocking surfaces come from `ask`, `select`, `confirm`, `input`, `editor`, and blocking `custom()` flows.

Lifecycle:

1. Server emits `extension_ui_request` with a stable `id` and optional `nativeSurface`.
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

### Persistent surfaces

Persistent surfaces come from `setTitle`, `setStatus`, `setWidget`, optional native footer/header mappings, and non-blocking custom status surfaces.

Lifecycle:

1. Server emits an `extension_ui_notification` with a key or stable surface `id`.
2. Client stores the surface in per-session extension UI state.
3. Later notifications with the same key replace that surface.
4. An explicit clear removes the surface.
5. Session end, session deletion, or runtime disposal clears all persistent extension surfaces for that session.

Rules:

- `setStatus(key, undefined)` clears that status surface.
- `setWidget(key, undefined)` or an empty normalized widget clears that widget surface.
- Component widgets update by replacing snapshots after `tui.requestRender()`.
- Persistent surfaces survive normal turn boundaries and agent stops unless explicitly cleared.
- Persistent surfaces are scoped to the session, not the workspace globally.

### Ephemeral surfaces

Ephemeral surfaces come from `notify()` and short non-blocking alerts.

Lifecycle:

- Clients may show them as toast, banner, sheet, or notification depending on severity and focus.
- They do not require `extension_ui_response`.
- They are not replayed as durable session UI after reconnect, except when the server also sends a persistent surface.

### Editor handoff

`setEditorText()` and `pasteToEditor()` are one-shot editor handoffs, not persistent display surfaces.

Lifecycle:

- The client applies the text to the active composer for the target session.
- The text then belongs to the user-facing composer state.
- Later extension UI settlement does not remove or submit the staged text.

### Timeline surfaces

Tool and custom-message surfaces are tied to session history.

Lifecycle:

- Tool call surfaces update during `tool_execution_start`, `tool_execution_update`, and `tool_execution_end`.
- Partial snapshots replace earlier snapshots for the same tool call.
- Final snapshots remain as timeline content.
- User expansion state is client-local.
- Custom message surfaces persist with their session entry and clear only when the entry is no longer part of the displayed branch/history.

### Error and fallback lifecycle

If native rendering fails:

- the client renders `fallback` if present
- otherwise it renders a sanitized terminal snapshot when available
- otherwise it shows a compact unsupported-ui message with the surface title and source

A rendering failure must not settle or cancel the extension request by itself.

## Relation to Pi TUI lifecycle

This contract follows Pi TUI lifecycle concepts, but serializes them because Oppi runs over a client/server protocol.

| Pi TUI lifecycle concept | Native contract behavior |
| --- | --- |
| Component factory creates an object | Server creates a native surface with a stable `id` |
| `render(width)` returns current lines | `renderNative(context)` returns current semantic blocks, or fallback lines are rendered |
| `tui.requestRender()` schedules redraw | Server emits a replacement snapshot for the same surface `id` |
| `handleInput(data)` mutates focused component state | `ExtensionUINativeEvent` mutates the backing component or resolves a blocking request |
| `invalidate()` clears render caches | Next native/terminal snapshot is recomputed; clients may also re-render locally for theme/size changes |
| `dispose()` releases component resources | Explicit clear, request settlement, session end, or runtime disposal removes the surface |
| `ctx.ui.custom()` replaces the editor until `done()` | Blocking native surface stays active until response/settlement/cancel |
| `ctx.ui.custom(..., { overlay })` creates a focused overlay | Native presentation uses sheet/full-screen/popover hints rather than terminal overlay coordinates |
| `setWidget(key, ...)` persists until replaced or cleared | Persistent keyed surface persists until explicit clear/session cleanup |
| `setStatus(key, ...)` persists until cleared | Persistent keyed status surface persists until explicit clear/session cleanup |
| `notify()` is fire-and-forget | Ephemeral native toast/banner/sheet, not durable state |

The main difference is authority. In terminal Pi, the in-process TUI owns focus and disposal directly. In Oppi, the server owns request state and sends snapshots; Apple clients render those snapshots and send responses/events back. Clients can dismiss optimistically after a response is accepted, but `extension_ui_settled` remains the authoritative cross-device cleanup signal.

## Managed runtime and mirrored runtime

Oppi has two Pi execution modes, and the native UI contract applies differently to each.

### Managed Oppi runtime

Managed sessions run through Oppi's server-owned SDK backend. Oppi creates the `ctx.ui` bridge, so the server can translate extension UI at the source.

Behavior:

- `ask`, `select`, `confirm`, `input`, `editor`, `notify`, `setTitle`, `setStatus`, `setWidget(string[])`, and `setEditorText` can be converted to native surfaces directly.
- `setWidget(component)` and `custom()` component factories run in the server process, so the bridge can call `renderNative()` when present.
- If `renderNative()` is absent, the bridge can call `render(width)` and send terminal fallback lines.
- Server-side request state is authoritative. `extension_ui_settled` clears blocking UI across clients.
- Persistent surfaces are scoped to the managed session and clear on explicit clear, session end, session deletion, or runtime disposal.

This is the primary implementation path for the full native contract.

### Mirrored terminal runtime

Mirrored sessions are interactive terminal Pi sessions connected to Oppi through the mirror bridge. The terminal Pi process keeps execution ownership and owns the real TUI component objects.

Behavior:

- Standard semantic UI requests (`ask`, `select`, `confirm`, `input`, `editor`, `notify`, `setTitle`, `setStatus`, and simple widget text) can map to the same native surfaces as managed sessions because their protocol payloads are already semantic.
- Blocking UI is first-wins across terminal and Oppi clients. If the terminal answers first, Oppi receives settlement and dismisses. If Oppi answers first, the bridge forwards the response to terminal Pi and terminal Pi settles the request.
- Custom TUI component objects are not available to the Oppi server unless the mirror bridge explicitly forwards native snapshots or terminal fallback snapshots.
- `renderNative()` for mirrored custom components requires bridge capability support. Without that capability, custom component trees remain terminal-first and Oppi must fall back to the existing compatibility behavior or show them as terminal-only.
- Terminal-specific footer/header/editor replacement and raw terminal input APIs remain terminal-owned unless a future bridge capability defines a native equivalent.

### Runtime support table

| Capability | Managed Oppi runtime | Mirrored terminal runtime |
| --- | --- | --- |
| Standard dialogs (`ask`, `select`, `confirm`, `input`, `editor`) | Native surface generated by server bridge | Native surface generated from forwarded semantic request |
| Fire-and-forget status/title/widget text | Native persistent surface | Native persistent surface from forwarded notification |
| Component widget terminal fallback | Server can call `render(width)` | Requires bridge-forwarded snapshot; otherwise terminal-only |
| Component widget `renderNative()` | Server can call directly | Requires mirror bridge native-snapshot capability |
| Blocking custom component interaction | Server compatibility loop or native events | Terminal-owned unless bridge supports native events |
| Footer/header/editor replacement | Limited native mapping or ignored | Terminal-owned |
| Lifecycle authority | Oppi server SDK state | Terminal Pi state, mirrored through bridge |
| Cross-device cleanup | `extension_ui_settled` from server | `extension_ui_settled` mirrored from terminal/server bridge |

Managed and mirrored sessions must render the same semantic request payloads the same way on Apple clients. Differences are allowed only where terminal ownership prevents Oppi from seeing or controlling opaque component objects.

## Native-renderable Pi TUI components

A Pi TUI component can add native semantics while keeping the standard terminal contract.

```ts
import type { Component } from "@earendil-works/pi-tui";

export interface NativeRenderableComponent extends Component {
  renderNative?(context: NativeRenderContext): ExtensionUINativeSurface;
  handleNativeEvent?(event: ExtensionUINativeEvent): void;
}

export interface NativeRenderContext {
  target: "oppi-native-v1";
  capabilities: string[];
  locale?: string;
}

export type ExtensionUINativeEvent =
  | { type: "action"; actionId: string; value?: unknown }
  | { type: "fieldChange"; fieldId: string; value: unknown }
  | { type: "selectionChange"; groupId: string; values: string[] }
  | { type: "submit"; value?: unknown }
  | { type: "cancel" };
```

Pi TUI calls `render(width)` and `handleInput(data)`. Oppi calls `renderNative()` when present. If native rendering is absent or throws, Oppi uses `fallback` or a sanitized terminal snapshot.

Native surfaces should be viewport-independent. Apple clients decide iPhone, iPad, Dynamic Type, and color-scheme layout locally. If a future feature needs true per-client rendering, it must add an explicit client render request protocol instead of overloading the broadcast surface snapshot.

## Mapping from Pi extension APIs

| Pi API | Native surface | Apple rendering | Fallback |
| --- | --- | --- | --- |
| `ctx.ui.ask()` / Oppi `ask` tool | `choiceGroup[]` | AskCard inline, expanded full-screen | existing AskCard behavior |
| `ctx.ui.select(title, options)` | one `choiceGroup` | AskCard-style inline for small prompts; sheet for long lists | select sheet |
| `ctx.ui.confirm(title, message)` | confirmation choice/action | compact confirmation card or sheet | confirm sheet |
| `ctx.ui.input()` | `form` with text field | inline/card or sheet text field | input sheet |
| `ctx.ui.editor()` | `form` with text area | full-screen editor sheet | editor sheet |
| `ctx.ui.notify()` | `toast` or `sheet` | transient toast/sheet | existing toast sheet |
| `ctx.ui.setStatus()` | `status` surface/chip | extension surface status rows/chips | text status |
| `ctx.ui.setWidget(string[])` | `terminal` block | extension surface panel | styled line card |
| `ctx.ui.setWidget(component)` | `renderNative()` if present | surface panel blocks | terminal snapshot |
| `ctx.ui.custom()` | `renderNative()` if present | sheet/full-screen/inline according to presentation | compatibility control loop |
| `ctx.ui.setFooter()` | `status` or footer surface | optional mobile status surface | ignored when not supported |
| `ctx.ui.setHeader()` | `section` / surface panel | optional startup/session surface | ignored when not supported |
| `ctx.ui.setWorkingMessage()` | `progress` | streaming row status | ignored when not supported |
| `ctx.ui.setWorkingIndicator()` | `progress.indeterminate` | spinner/progress status | ignored when not supported |
| `ctx.ui.setEditorComponent()` | not portable | no native mapping | preserve factory only |
| `ctx.ui.addAutocompleteProvider()` | future composer suggestion provider | native composer suggestions | ignored when not supported |
| `renderCall` / `renderResult` | `timelineRow` blocks | native tool row summaries/details | current mobile renderer / raw text |
| `registerMessageRenderer()` | `message` surface | native custom message card | raw custom message text |

## Mapping from Pi TUI components

| Pi TUI component or pattern | Native block | Apple design |
| --- | --- | --- |
| `Text` | `text` or `markdown` | native `Text` with wrapping and Dynamic Type |
| `Markdown` | `markdown` | existing markdown renderer |
| `Box` | `section` | rounded card, theme background, subtle stroke |
| `Container` | `section.blocks` | vertical stack |
| `Spacer` | `spacer` | native spacing token |
| `Image` | `image` | native image preview with alt/fallback text |
| `SelectList` | `choiceGroup` | AskCard option cards or list rows |
| `SettingsList` | `settingsList` | form/list rows with value chips or toggles |
| `Input` | text field | native text field |
| `Editor` | text area | native editor sheet/full-screen |
| `Loader` / `CancellableLoader` / `BorderedLoader` | `progress` + cancel action | progress row/card with Cancel button |
| overlay `custom(..., { overlay })` | sheet/full-screen/popover presentation hint | iPhone sheet/full-screen; iPad readable sheet/popover |
| arbitrary ANSI/box drawing | `terminal` | monospaced selectable fallback card |

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

- long select lists
- settings lists
- forms with multiple fields
- custom native surfaces with actions

Design requirements:

- use `NavigationStack`
- put Cancel in the cancellation toolbar slot
- put the primary action in the confirmation toolbar slot or bottom action bar
- use native `Form`/`List` rows when the content is row-like
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

### Extension surface panel

Use for persistent widgets and status:

- `setTitle`
- `setStatus`
- `setWidget`
- non-blocking native surfaces

Design requirements:

- render as a generic extension card above the composer or in session chrome
- support title, status rows/chips, activity rows, and terminal fallback blocks
- keep the surface generic; do not add extension-specific Swift panels
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
- Destructive actions require destructive role styling and, when the consequence is not obvious, an explicit confirmation.
- Extension text and links are untrusted content. Links route through normal platform URL handling and app navigation policy.

### App Review posture

This contract keeps extension UI App-Review-friendly by treating native surfaces as data rendered by the Oppi app, not downloaded native code.

- Apple clients must not download or execute extension code.
- Extension actions must not access native platform APIs directly; they send responses/events to the server.
- The app must not present a general-purpose extension marketplace, plug-in store, or purchase flow through native surfaces.
- Remote or third-party extension content must follow the app's privacy, safety, and moderation posture.
- If extension UI exposes user-generated content, objectionable-content reporting/moderation responsibilities still apply.
- Review notes should describe non-obvious self-hosted runtime and extension UI behavior when shipping this feature.

## Response and event model

Blocking surfaces return through the existing `extension_ui_response` channel. Native value payloads are additive.

```ts
export type ExtensionUINativeResponse =
  | { type: "extension_ui_response"; id: string; value?: string; confirmed?: boolean; cancelled?: boolean }
  | { type: "extension_ui_response"; id: string; nativeValue?: Record<string, unknown>; cancelled?: boolean };
```

Non-blocking native interactions can use an extension UI event message.

```ts
export interface ExtensionUINativeEventMessage {
  type: "extension_ui_event";
  id: string;
  revision?: number;
  event: ExtensionUINativeEvent;
}
```

Clients that do not support non-blocking events must disable those actions or fall back to blocking Submit/Cancel behavior.

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
2. **Prompt native**: supports `choiceGroup`, simple `form`, and standard dialog mappings.
3. **Surface native**: supports `section`, `settingsList`, `activityList`, `progress`, and persistent surface panels.
4. **Interactive native**: supports `ExtensionUINativeEventMessage` for field changes and non-blocking actions.
5. **Timeline native**: supports `timelineRow` native tool/message renderers.

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

- Actions return events or responses to the server/extension; clients do not execute extension-defined commands locally.
- External links require normal platform URL handling and can be restricted by scheme.
- Internal links such as `oppi://session/<id>` should route through generic app navigation, not extension-specific code.
- Destructive actions must use `role: "destructive"` and can require native confirmation.
- Image/data references must be scoped to the session/workspace and checked by the server.

### Authoring API

Extension authors need a small TypeScript helper package or exported type set for native surfaces. The helper should be structural and optional: extensions can implement `renderNative()` without importing Oppi, but official types and builders reduce drift.

### Test matrix

Implementation should validate at least these fixtures:

- `ask` single select, multi-select, custom answer, timeout, and cross-device settlement
- `select`, `confirm`, `input`, and `editor` mapped to AskCard/sheet/full-screen UI
- `SelectList`, `SettingsList`, `Loader`, `Markdown`, and `Image` native block mapping
- activity row links through generic `oppi://session/<id>` navigation
- component widget with `renderNative()`
- component widget without `renderNative()` terminal fallback
- tintinweb `pi-subagents` as a terminal-first compatibility fixture
- managed runtime and mirrored runtime paths
- iPhone and iPad screenshots for native prompt, surface panel, and fallback terminal card

## Recommended rollout and complexity budget

The contract is intentionally broader than the first implementation. Implement it in layers so native UI improves without turning extension surfaces into a second app framework.

### Phase 1: stabilize fallback and lifecycle

- Keep current terminal/text fallback reliable.
- Add native surface types to protocol and Swift decoders with unknown-block fallback.
- Implement capability flags, replay rules, payload limits, and cleanup behavior.
- Do not add non-blocking native events yet.

### Phase 2: native blocking prompts

- Map `ask`, `select`, `confirm`, `input`, and simple `editor` to `choiceGroup` and `form`.
- Reuse AskCard and existing dialog/sheet flows.
- Validate timeout, cancel, cross-device first-wins settlement, and reconnect.

### Phase 3: persistent native surfaces

- Render `section`, `text`, `markdown`, `progress`, `activityList`, and `terminal` in the generic extension surface panel.
- Update by replacement using stable IDs and `revision`.
- Throttle widget/status updates.

### Phase 4: authoring and selected component support

- Publish TypeScript types/builders for `renderNative()`.
- Support `renderNative()` for managed runtime component widgets and custom components.
- Keep mirrored component support behind explicit bridge capability flags.

### Phase 5: interactive and timeline native UI

- Add `extension_ui_event` only after blocking/persistent surfaces are stable.
- Add native timeline rows for tool/message renderers.
- Add richer data references such as images only when server scoping, limits, and caching are clear.

Defer anything that requires arbitrary client-side execution, nested modal navigation, hidden extension marketplaces, per-client server rendering, or live remote component focus until there is a concrete product need and a reviewable threat model.

## Example: select as native choice group

```json
{
  "version": 1,
  "id": "req-123",
  "source": "select",
  "presentation": {
    "style": "inlineCard",
    "placement": "composer",
    "title": "Pick a strategy",
    "priority": "blocking"
  },
  "blocks": [
    {
      "type": "choiceGroup",
      "id": "selection",
      "question": "Pick a strategy",
      "options": [
        { "value": "small", "label": "Small patch", "description": "Minimal, safest change" },
        { "value": "refactor", "label": "Refactor", "description": "Larger cleanup with more risk" }
      ]
    }
  ],
  "fallback": {
    "lines": ["Pick a strategy", "1. Small patch", "2. Refactor"]
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
    "placement": "aboveEditor",
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

- add `nativeSurface?: ExtensionUINativeSurface` to extension UI request and notification payloads
- generate native surfaces for existing semantic APIs before trying to parse terminal output
- detect `renderNative()` on custom/widget components
- preserve terminal fallback fields for unsupported clients
- keep protocol changes forward-compatible

Apple implementations:

- decode unknown blocks without failing the whole message
- render supported blocks natively
- render unsupported blocks with fallback content
- keep AskCard as the reference for `choiceGroup`
- keep persistent widgets in a generic extension surface panel
- avoid extension-specific Swift UI for generic surfaces

## Acceptance criteria

- Existing ask behavior remains compatible.
- `select`, `confirm`, and `input` can render as AskCard-style native UI when appropriate.
- A component with `renderNative()` renders native blocks in Oppi and terminal UI in Pi.
- A component without `renderNative()` renders a terminal fallback and does not crash.
- Widget/status rendering stays generic.
- OSC-8 links survive fallback as tappable links when clients support links.
- iPhone and iPad screenshots cover native prompt, native surface panel, and terminal fallback paths.

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
