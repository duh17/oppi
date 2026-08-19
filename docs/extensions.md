# Oppi extension behavior

This page explains Oppi runtime behavior for pi extensions: what Oppi loads, how the workspace editor toggles Pi resources, what standalone pi sees, and how mobile displays terminal-oriented extension UI.

Use it when you install an extension for Oppi, adjust Pi resource settings from a workspace, or adapt a Pi extension so its prompts and tool output work well in the Apple app.

For Oppi's public native UI block contract and Apple presentation mapping, see [`extension-native-ui.md`](extension-native-ui.md). For media attachments in messages and expanded tool output, see [`attachment-rendering.md`](attachment-rendering.md).

This is not a general Pi extension-authoring guide. For pi package layout, lifecycle hooks, tool APIs, and terminal UI rendering, use pi's docs instead:

- pi extension docs: `@earendil-works/pi-coding-agent/docs/extensions.md`
- pi package docs: `@earendil-works/pi-coding-agent/docs/packages.md`
- pi examples: `@earendil-works/pi-coding-agent/examples/extensions/`

## Core rule

Pi owns ordinary skills and extensions. Normal Oppi-managed sessions resolve them for the session cwd through Pi's resource system; there is no `workspace.extensions` allowlist. Installing or running Oppi does not write `~/.pi/agent/settings.json`, run `pi install`, or enable anything in standalone Pi.

Oppi has one explicit server-owned exception: the built-in **Oppi** extension. It is pathless, off by default, and is not a Pi package or a row in Pi's filesystem resource settings. When enabled, it adds only the allowlisted `oppi` tool to ordinary non-sandbox Oppi-managed sessions. Sandbox sessions never receive or reserve this built-in tool. It never adds structured `ask`.

The shipped Oppi agent is separate. Its isolated control identity always has server-managed `oppi`, structured `ask`, and Pi's stock `read`, `edit`, `write`, `grep`, `find`, and `ls`, while disabling `bash`, user/project extensions, skills, prompt templates, and context files. Only the `oppi` tool uses the saved Oppi approval policy. Stock filesystem tools follow host process permissions: absolute paths are not constrained by Skill catalog metadata, and file mutations execute directly, bypassing Oppi approval and revision checks. The system prompt stays minimal and discovers CLI detail through `oppi help`.

## Server Skills and Extensions

Use the server's **Skills** and **Extensions** destinations to inspect and change the selected server's Pi user/global defaults. These catalog endpoints follow `pi config` semantics: Pi resolves user-scope candidates, including disabled entries, and toggles preserve Pi's ordered `+path`, `-path`, `!pattern`, and package-filter rules. Workspace Settings remain the authority for project overrides; a server default is not a claim about the effective state in every workspace.

The catalog is intentionally global and has no `cwd` parameter. It lists Pi-native user candidates from `~/.pi/agent`, `~/.agents/skills`, configured user settings, and configured packages. It does not install packages while listing. Provenance and enabled state come from Pi. Normal resource IDs are opaque path-derived identifiers, so a moved resource can receive a new ID.

Extensions list **Oppi** first. Its row has stable id `oppi`, built-in provenance, no filesystem `path`, and no removal action. It starts disabled. Its server-scoped configuration contains the Oppi tool availability, approval policy, a mobile output guide toggle, and a revision; updates use that revision to prevent stale client writes. The mobile output guide is independent of tool availability and is off by default.

### Oppi approval policies

- **Confirm destructive only** (default): reads and allowlisted non-destructive changes run directly; delete, remove, and archive actions require approval.
- **Confirm all changes**: reads run directly; every allowlisted mutation requires approval.
- **Read only**: allowlisted reads run directly; mutations fail with a deterministic read-only error and never open an approval prompt.

The command allowlist is an application capability boundary, not a copy of every CLI command. It covers bounded JSON operations on Oppi-managed application state: `status`, `quota`, `models`, `workspace`, `worktree`, `agent`, `session`, `schedule`, and `config` (`show`/`get`/`validate` read; `set` is a mutation). Host lifecycle and credential operations (`init`, `serve`, `start`, `pair`, `server`, `token`, and `update`), host diagnostics/version output, root aliases, and the long-running NDJSON `session watch` stream remain excluded. Operator-facing config detail lives in [server-configuration.md](server-configuration.md). In the built-in agent tool, choose the smallest session disclosure step: `session list` for orientation, `session inspect --view summary` for current progress, `session inspect --view response` for only the latest response, `session inspect --view outline` for history, and bounded `messages`/`tools`/`trace-page`/`tool-output` reads only when the outline leaves a question. Use bounded `session wait <id...>` for monitoring, including `--all`. Defaults poll every 2s and may record a compact heartbeat every 60s; `--poll`/`--interval` and `--summary-every` override, and `--summary-every 0` disables heartbeats. One-session `session watch` calls alias to wait; `--until` and `--interval` normalize to `--for` and `--poll`. Multi-session watch, watch `--all`, and `any-change` streaming remain unavailable. Root and allowlisted-command help are available.

Unknown commands, unsupported subcommands, and file-backed mutation bodies are denied. `--prompt @-` and `--text @-` are read from stdin and inlined into the approved argument snapshot before policy evaluation. Inline prompt, system-prompt, message, definition, file-content, answer, and response bodies are redacted from rejected command summaries. The approval boundary uses normalized immutable input, so the approved command is the command executed.

The CLI produces both outputs for an allowlisted Oppi call: its redacted JSON envelope is model-facing content, and its complete ANSI human output is the expanded terminal result. The tool wrapper places the complete shell-quoted invocation before that result, so the expanded row reads like a normal terminal transcript without shortening inline prompts or other arguments.

### Mobile output guide

Enable **Mobile Output Guide** under **Extensions → Oppi** to tell agents which links and rich content Oppi can render in new and explicitly reloaded Oppi-managed host and sandbox sessions. The capability guide covers real workspace wiki links with uppercase one-based anchors, owner host-file wiki links for real absolute or `~` paths, inline workspace images and SVG, Mermaid, supported LaTeX, and wiki links to recognized workspace documents and media such as images, audio, video, PDF, HTML, Org, LaTeX, Mermaid, and Graphviz files. It does not prescribe response style, fabricate paths, or expose secrets. Oppi does not send viewport dimensions, and active sessions are not reloaded automatically.

The setting does not affect terminal-owned Mirror sessions or isolated Oppi control/default-Agent sessions. Saved Agent and workspace instructions remain in their existing precedence order. Non-text wiki-link icons are not part of this setting.

### When a change takes effect

New ordinary Oppi-managed sessions use the latest saved Oppi configuration. An active managed session keeps its existing extension runtime until `/reload` rebuilds it through Pi's full `AgentSession.reload()` lifecycle; reload applies the current enablement, policy, and mobile output guide before the next turn. A disabled configuration registers no `oppi` tool.

The server-wide model picker and provider-auth list rescan global/user provider extensions when `~/.pi/agent/settings.json` changes, when files under `extensions/` change (including one nested directory level such as `foo/index.ts`), when npm/git package metadata changes, or immediately after an extension is enabled or disabled. A server restart is not required for those catalog updates. The rescan never runs `npm install` or `git clone`; a package listed in settings but not already installed stays out of the picker until it is installed some other way. Active sessions still keep their own model runtime until `/reload` or a new session.

The built-in setting does not modify standalone Pi or terminal-owned mirrored sessions. A stopped disconnected mirror session evaluates the current setting only if it is explicitly promoted to Oppi-managed ownership. The dedicated Oppi control identity remains separate, always receives the tool, and uses the saved approval policy regardless of the ordinary-session enablement setting.

For ordinary Pi extensions, disabled rows are still visible in the server catalog. Pi does not execute disabled extension factories merely to manufacture diagnostics or contributed capabilities, so disabled rows can honestly show discovery state without a speculative load error. Enabled extensions can report Pi loader diagnostics and contributed tools or commands when Pi provides them.

## Extension surfaces

| Surface                 | Enabled by                                                    | Declared in                              | Loaded by          | Notes                                                                                                         |
| ----------------------- | ------------------------------------------------------------- | ---------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------- |
| Host pi extensions      | User/project pi settings, `pi install`, or `.pi/extensions`   | User-owned pi config/package paths       | pi resource loader | Must work without Oppi server services                                                                        |
| Ask extension example   | Pi package/settings install or auto-discovered extension path | `pi-extensions/ask`                      | pi resource loader | Portable Pi package: registers `ask`, uses native AskCard when available, then falls back to Pi UI APIs       |
| Active goal extension   | User Pi resource settings or auto-discovered extension path   | Standalone `pi-goal` package             | pi resource loader | Canonical durable-goal implementation maintained in its own repository                                        |
| Disabled goal prototype | Not enabled                                                   | `pi-extensions/goal`                     | not loaded         | Preserved while compaction recovery, task timing, and snapshot migration are audited in the pi-goal workspace |
| Browser video example   | Pi package/settings install or auto-discovered extension path | `pi-extensions/browser-automation-video` | pi resource loader | Oppi-compatible Pi package: registers a public Pi tool and uses Oppi's attachment helper when available       |
| Related work extension  | Pi package/settings install or auto-discovered extension path | `pi-extensions/related`                  | pi resource loader | Portable Pi package: agent-authored related-work board; generic widget + URL/wiki rendering                   |
| Mobile UI compatibility | Native Oppi client + server bridge                            | Protocol and UI bridge code              | Oppi server/client | Maps common `ctx.ui` calls to native cards/dialogs; see [`extension-native-ui.md`](extension-native-ui.md)    |

This split keeps consent clear: installing Oppi does not install a pi extension package.

## Ask extension example

`pi-extensions/ask` is a portable Pi package. It registers the `ask` tool through public `pi.registerTool()` APIs and supports multiple questions, `multiSelect`, and custom text answers.

Rendering path:

1. **Oppi / RPC:** use the documented `ctx.ui.ask()` request, rendered by iOS as a native AskCard.
2. **Terminal Pi:** use `ctx.ui.custom()` for a keyboard-driven terminal dialog.
3. **Other Pi UI contexts:** use `ctx.ui.select()` and `ctx.ui.input()` fallbacks.

`ctx.ui.ask()` is an Oppi-defined UI request because plain Pi's standard dialog API does not include a multi-question or multi-select form. The extension stays portable by checking for `ctx.ui.ask()` and using Pi UI fallbacks when it is absent.

## Goal extension ownership

The canonical active implementation is the standalone `pi-goal` package, maintained in its own repository and enabled through the user's Pi resources. It registers `/goal`, `goal_update`, and `goal_status`, persists goal state as Pi custom session entries, queues continuation turns through Pi lifecycle hooks, and supplies terminal and Oppi-native widget rendering.

The Oppi repository keeps `pi-extensions/goal` disabled as a migration reference. Do not enable it alongside `pi-goal`: both implementations use the `oppi-goal` custom entry type and `goal` widget key, but their persisted snapshots and model-tool contracts differ. The prototype remains preserved until a dedicated pi-goal workspace audit decides how to handle its explicit compaction recovery, per-task timing, and snapshot migration behavior.

Oppi does not own goal lifecycle policy. Its role is normal Pi resource loading, resource-setting edits from the workspace UI, and rendering extension widgets through the native extension UI contract when available.

## Pi package layout

Pi's standard package model is the source of truth. A package can declare resources under the `pi` key:

```json
{
  "keywords": ["pi-package"],
  "pi": {
    "extensions": ["./extensions/my-extension.ts"],
    "skills": ["./skills"],
    "prompts": ["./prompts"],
    "themes": ["./themes"]
  }
}
```

Only put an entry in `pi.extensions` when the extension has a documented plain Pi path. An Oppi-compatible Pi extension can detect documented Oppi helpers such as `ctx.attachments.addFile()`, but it needs a plain Pi path when that helper is absent. Tools that require Oppi storage, session spawning, trace inspection, workspace admin APIs, or mobile-only behavior need a server API instead of private `SdkBackend` state.

Users must opt in explicitly:

```bash
pi install <package-or-path>
# or temporary for one run:
pi -e <package-or-path>
```

## What Oppi changes

Oppi keeps Pi's extension system and adds these rules:

1. **Cwd-scoped Pi resource resolution** for host sessions. User settings, project settings, installed packages, and auto-discovered extension directories remain the source of truth.
2. **Pi resource toggles** from the workspace editor. The editor writes Pi resource settings (`+` / `-` entries) for skills and extensions; it does not write a workspace-level extension allowlist.
3. **A server-scoped built-in Oppi extension**, configured separately from Pi resources and disabled until the server owner enables it.
4. **Mobile UI compatibility** for most standard extension input, confirm, ask, and approval UI calls.
5. **Stored attachment helpers** for tool-generated files through documented Oppi context helpers such as `ctx.attachments.addFile()`.

Oppi does not replace Pi discovery. Extensions that ask for input or confirmation use the same mobile bridge as other Pi extension UI.

## Mobile compatibility checklist

Build the extension as a normal Pi extension first. Then make the user-facing parts semantic enough for Oppi to render without a terminal.

### Minimum path

1. Ship a real Pi package or extension path that works in standalone Pi.
2. Ask the user through `ctx.ui.ask()`, `ctx.ui.select()`, `ctx.ui.confirm()`, `ctx.ui.input()`, or `ctx.ui.editor()` when mobile users need to respond.
3. Keep tool `content` concise for the model, and put readable mobile output in `details.expandedText` with `details.presentationFormat`.
4. Put generated images and video in stored attachment metadata, not markdown links or inline base64. Use the audio presentation shape for audio cards. For PDFs and generic files, return a workspace/session-accessible path or link in `content` / `details.expandedText`; `details.media[]` does not render them today.
5. Keep collapsed timeline summaries one line. Rich text, JSON, diffs, code, logs, and media belong in expanded content.
6. Provide terminal/text fallback for custom widgets. Oppi must be able to show something readable when native blocks are unsupported.
7. Test both paths: terminal Pi and an Oppi workspace with the extension enabled.

### What translates to mobile

| Pi / Oppi extension API                                                        | Use it for                                                    | Oppi mobile behavior                                                                 |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `ctx.ui.ask()`                                                                 | multi-question prompts, multi-select, optional custom answers | native AskCard; portable extensions need a Pi fallback because `ask` is Oppi-defined |
| `ctx.ui.select()`                                                              | one choice from a short list                                  | native prompt card                                                                   |
| `ctx.ui.confirm()`                                                             | yes/no decisions such as approval gates                       | native confirmation card                                                             |
| `ctx.ui.input()`                                                               | one short text answer                                         | native text prompt                                                                   |
| `ctx.ui.editor()`                                                              | longer text input                                             | native editor sheet                                                                  |
| `ctx.ui.notify()`                                                              | non-blocking status                                           | toast, banner, or notification-style UI                                              |
| `ctx.ui.setTitle()`                                                            | session or extension heading                                  | extension surface heading                                                            |
| `ctx.ui.setStatus()`                                                           | persistent status text                                        | status row or chip                                                                   |
| `ctx.ui.setWidget(string[])`                                                   | compact persistent widget text                                | terminal strip/drawer fallback                                                       |
| `ctx.ui.setWidget(component)` with `renderNative()`                            | structured persistent widget                                  | native strip/drawer with fallback                                                    |
| `ctx.ui.setWorkingMessage()` / `setWorkingVisible()` / `setWorkingIndicator()` | working-row customization                                     | native timeline working row                                                          |
| `ctx.ui.setEditorText()` / `pasteToEditor()`                                   | hand text to the composer                                     | one-shot composer text handoff                                                       |
| `ctx.ui.setToolsExpanded()` / `getToolsExpanded()`                             | default tool expansion state                                  | native tool-row expansion state                                                      |

Terminal-first APIs such as `ctx.ui.custom()`, `setFooter`, `setHeader`, `setEditorComponent`, and raw terminal input remain terminal-owned unless the extension also provides a semantic native surface or a standard blocking prompt. Do not use those APIs for a decision the user must answer from the phone.

### Working row and status projection

Use `ctx.ui.setWorkingIndicator()`, `ctx.ui.setWorkingMessage()`, and `ctx.ui.setStatus()` for lightweight extension state that should work in terminal Pi and Oppi.

```typescript
ctx.ui.setWorkingIndicator({ frames: ["·", "•", "●", "•"], intervalMs: 120 });
ctx.ui.setWorkingMessage("Checking files…");
ctx.ui.setStatus("working-words", "shuffled · 18 phrases");
```

Oppi treats these calls as bounded data rendered by the app:

- working indicators are `frames + intervalMs`; the iOS client animates frames locally
- working messages appear in the timeline working row while the session is busy
- status entries are keyed session state near the composer and persist until cleared
- ANSI/control sequences are stripped and long frame/message/status text is capped
- iOS owns layout, color, Dynamic Type, VoiceOver labels, and Reduce Motion behavior

If an extension uses terminal-only glyphs, colors, or fonts, branch on `ctx.mode === "tui"` and provide plain Unicode or text frames for other modes. Arbitrary `ctx.ui.custom()` animation is terminal-owned and does not project to iPhone.

### Tool output that renders well

Oppi reads the normal Pi tool result, looks for structured `details` fields, then falls back to generic text parsing.

```typescript
return {
  content: [{ type: "text", text: "Created release notes." }],
  details: {
    expandedText: "# Release notes\n\n- Added mobile extension defaults",
    presentationFormat: "markdown",
  },
};
```

Use these fields when they apply:

| Details field                                              | Mobile behavior                                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `expandedText`                                             | text shown when the user expands the tool row                                                           |
| `presentationFormat: "markdown"`                           | render `expandedText` as markdown                                                                       |
| `presentationFormat: "json"`                               | render structured output as formatted JSON                                                              |
| `presentationFormat: "code"` with `language` or `filePath` | render code with syntax highlighting                                                                    |
| `presentationFormat: "diff"`                               | render a unified diff                                                                                   |
| `startLine`                                                | set the first code line number                                                                          |
| `media`                                                    | render stored image and video attachment rows; see [`attachment-rendering.md`](attachment-rendering.md) |

For generated images or video, prefer Oppi's attachment helper when it is available:

```typescript
const video = await ctx.attachments.addFile({
  path: mp4Path,
  kind: "video",
  mimeType: "video/mp4",
  fileName: "browser-run.mp4",
  deleteSource: true,
});

return {
  content: [{ type: "text", text: "Recorded browser run." }],
  details: { media: [video] },
};
```

Portable extensions need a non-Oppi fallback, such as writing the output path into `content`, when `ctx.attachments` is unavailable.

### Native widgets

Use native widgets for display-only state: progress, task lists, status summaries, and links to existing Oppi destinations. The extension still owns its terminal renderer.

A widget component that works well in both places has:

- `render()` for terminal Pi
- `renderNative()` for Oppi
- `fallback.lines` or `fallback.text` for clients that do not understand a native block
- stable IDs for rows that update over time

On mobile, Oppi groups widgets by Pi placement instead of rendering every widget as a separate vertical card:

- `aboveEditor` widgets appear in a strip above the composer.
- `belowEditor` widgets appear in a strip below the composer.
- Each collapsed strip uses one row of pills; overflow scrolls horizontally.
- Tapping a pill opens that widget in the placement's shared drawer. Tapping another pill replaces the drawer content.
- The expanded drawer is height-bounded and scrolls internally. Long content can open full screen.

If a widget does not provide `renderNative()`, Oppi uses the sanitized terminal snapshot from `render(width)` as the fallback drawer content. That keeps terminal-first extensions readable on iPhone, but row-level native behavior such as activity-row links requires `renderNative()`.

Keep native widgets generic. They are data rendered by Oppi, not downloaded Swift views. If the user needs to click a row, use a normal app link such as `oppi://session/<id>` and let Oppi route it.

### Common mistakes

- Returning a beautiful `renderResult()` TUI component but no `details.expandedText`; the phone can only show generic text.
- Putting long markdown, tables, or logs into the collapsed summary.
- Requiring `ctx.ui.custom()` for approval or input.
- Embedding base64 video/audio or local file paths in markdown.
- Assuming installing Oppi installs or enables your extension in standalone Pi.
- Depending on raw ANSI colors instead of semantic roles or plain fallback text.
- Assuming a persistent widget owns unbounded vertical space in the collapsed mobile composer area.

## Approval prompts

Approval behavior belongs to Pi extensions. Command classification, route decisions, and user prompts live inside extension handlers; Oppi renders the resulting UI but does not create a separate approval layer.

The behavior is the same shape for Oppi-owned sessions and mirrored terminal sessions:

- A Pi extension can intercept `tool_call`, `session_before_switch`, `session_before_fork`, or other Pi events.
- The extension can ask with `ctx.ui.ask()`, `ctx.ui.confirm()`, `ctx.ui.select()`, `ctx.ui.input()`, or `ctx.ui.editor()`.
- Oppi mobile renders those standard extension UI requests natively and sends responses through `extension_ui_response`.
- Standalone terminal Pi uses the same extension logic through its normal TUI.

## How extension loading works

At session startup, Oppi begins with pi's normal extension sources for the session working directory. An enabled built-in Oppi extension is added separately only for ordinary Oppi-managed sessions; it is not a Pi resource source.

Pi's normal sources are:

- auto-discovered extension directories (`~/.pi/agent/extensions/`, `.pi/extensions/`)
- settings-declared extension paths (`settings.json` `extensions` arrays)
- package-provided extensions installed through pi (`pi install`)

Pi resolves the resources for the session cwd. The picker starts with those resolved resources, also scans global and project `.pi/extensions` directories so newly copied files appear, and normalizes extension names:

- file extensions must be `.ts` or `.js`; `.test` and `.spec` files are ignored in the picker
- package `index` entries use the package identity for display, such as `npm:@tintinweb/pi-subagents` becoming `tintinweb-subagents`
- directory-style entries such as `extensions/foo/index.ts` use `foo` as the extension name

Enable/disable writes only match Pi-resolved resources. A direct-scan entry that Pi's resolver cannot match can appear in the picker but fail with `Pi resource not found for cwd` if toggled.

Oppi loads Pi-resolved extensions without injecting an extra Ask tool into ordinary workspace sessions. Install or enable a Pi extension named `ask` when a normal workspace Agent needs it. The shipped Oppi agent has its own server-managed `ask` registration because its isolated runtime intentionally disables normal extension discovery.

## Reload behavior

`/reload` rebuilds an active Oppi-managed session through Pi's full `AgentSession.reload()` lifecycle. It reloads host Pi extensions, skills, prompts, and themes, and applies the current server-owned Oppi enablement and approval snapshot before the next turn. Terminal-owned mirrored sessions keep terminal ownership and are not changed by this server setting.

## Pi resource toggle behavior

Current Oppi workspaces do not store `extensions`. Extension enablement comes from Pi resource settings for the session cwd.

The workspace editor can toggle skills and extensions by writing Pi settings:

- `+path` enables a resource that is otherwise filtered out.
- `-path` disables a resource that Pi would otherwise load.
- Package resources use the same `+` / `-` filtering inside the package entry.
- Temporary resources cannot be edited from Oppi.

This is Pi resource filtering, not a workspace-owned allowlist or denylist. A host-backed workspace starts sessions with whatever Pi resolves for that cwd after those settings are applied. Sandbox workspaces still have a separate `workspace.tools` allowlist for VM-backed tools only.

## Extension picker behavior

`GET /extensions` is the data source for the Oppi workspace editor. It is not a general-purpose pi reference API.

The picker response:

- resolves host extensions through pi's normal settings and package resolver
- also scans global and project `.pi/extensions` directories so newly copied files appear on the next scan
- includes auto-discovered global and project-local extensions
- includes package-installed extensions
- includes settings-declared extension paths
- allows host/project/package extensions named `ask`
- deduplicates by extension name using pi resource-loader precedence

## Native extension UI contract

Oppi's native extension UI behavior is specified in [`extension-native-ui.md`](extension-native-ui.md). That contract keeps blocking prompts Pi-shaped, maps standard `select`, `confirm`, `input`, and `editor` requests to native iOS prompt presentations, projects Pi UI state such as working rows, hidden thinking labels, and tool expansion, and defines display-only widget `ExtensionUINativeSurface` snapshots with blocks such as `text`, `markdown`, `section`, `activityList`, `progress`, `terminal`, and `code`.

Native UI requires explicit semantics. Oppi renders semantic extension UI natively and uses sanitized terminal snapshots as fallback for opaque TUI components. On mobile, persistent widgets are grouped into bounded `aboveEditor` and `belowEditor` strips, with one expanded drawer per placement.

## Mobile rendering fallback

Pi's terminal UI uses extension `renderCall()` and `renderResult()` hooks. Oppi iOS does not execute those TUI renderers.

For tool rows, Oppi uses this order:

1. built-in mobile renderers in `server/src/mobile-renderer.ts`
2. optional collapsed-summary sidecars in `~/.pi/agent/mobile-renderers/*.ts`
3. server-provided `StyledSegment[]` summaries for the collapsed row
4. generic rendering from tool `content` and `details`

Expanded output uses this order:

1. `details.expandedText` plus `details.presentationFormat`
2. generic parsing of the tool text as JSON, markdown, diff, or code
3. sanitized terminal/mobile-renderer snapshot fallback
4. plain text

Sidecars are for short collapsed summaries only. Segment style is a closed semantic set: `bold`, `muted`, `dim`, `accent`, `success`, `warning`, or `error`. Invalid sidecar output is omitted and logged by the server because the Apple protocol mirror decodes this set strictly. Put rich readable output in `details.expandedText` instead of sidecar summary lines.

Mirror mode uses the same semantic request payloads from an interactive terminal Pi process. Mirror-specific first-wins dialog behavior lives in [`oppi-mirror.md`](oppi-mirror.md#extension-ui-compatibility-matrix).

## Relevant implementation files

| File                                     | Why it matters                                                              |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `pi-extensions/ask`                      | Ask extension example with multi-select support                             |
| Standalone `pi-goal` package             | Canonical active goal extension repository                                  |
| `pi-extensions/goal`                     | Disabled prototype retained for the documented migration audit              |
| `pi-extensions/browser-automation-video` | Oppi-compatible Pi extension package using the documented attachment helper |
| `server/src/routes/skills.ts`            | Workspace extension picker (`GET /extensions`)                              |
| `server/src/sdk-backend.ts`              | Pi resource loading and SDK session setup                                   |
| `server/src/sdk-ui-bridge.ts`            | Extension UI bridge from pi APIs to Oppi protocol events                    |
| `server/src/extension-ui-contract.ts`    | Shared extension UI request, notification, and settled message builders     |
| `server/src/mobile-renderer.ts`          | Mobile tool-row rendering                                                   |

## When to read pi docs instead

Use pi's docs for:

- writing an extension
- supported extension directory layouts
- lifecycle hooks and custom tools
- terminal rendering with TUI components
- package-based extension distribution

Use this page only for Oppi-specific behavior and mobile/runtime gotchas.
