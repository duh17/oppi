# Oppi extension behavior

This page explains Oppi runtime behavior for pi extensions: what Oppi loads, how Workspace Settings toggles Pi resources, what standalone pi sees, and how mobile displays terminal-oriented extension UI.

Use it when you install an extension for Oppi, adjust Pi resource settings from a workspace, or adapt a Pi extension so its prompts and tool output work well in the Apple app.

For Oppi's public native UI block contract and Apple presentation mapping, see [`extension-native-ui.md`](extension-native-ui.md). For media attachments in messages and expanded tool output, see [`attachment-rendering.md`](attachment-rendering.md).

This is not a general Pi extension-authoring guide. For pi package layout, lifecycle hooks, tool APIs, and terminal UI rendering, use pi's docs instead:

- [Pi extensions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) (`@earendil-works/pi-coding-agent/docs/extensions.md`)
- [Pi packages](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md) (`@earendil-works/pi-coding-agent/docs/packages.md`)
- Pi examples: `@earendil-works/pi-coding-agent/examples/extensions/`

## Core rule

Pi owns ordinary skills and extensions. Normal Oppi-managed sessions resolve them for the session cwd through Pi's resource system; there is no `workspace.extensions` allowlist. Installing or running Oppi does not write `~/.pi/agent/settings.json`, run `pi install`, or enable anything in standalone Pi.

Oppi registers no server-owned tool. Managed host sessions load a lifecycle-journal extension plus Pi's `mcp`, `codemode`, and `tool-search` built-ins. Managed sandbox sessions load the lifecycle-journal extension, `mcp`, and `tool-search`, and do not load `codemode`. On either kind of session, `-builtin:<name>`, an exact Agent extension selection, or another extension that registers the same tool, command, or flag can leave one of those built-ins out (see [Server configuration](server-configuration.md#mcp-servers-codemode-and-tool-search)). Oppi adds none of these to a terminal mirror session; the terminal's own Pi loads its built-ins according to its own settings. Managed workspace sessions and workspace-less Pi Control sessions use Pi's normal global and cwd-scoped configuration. This includes `SYSTEM.md`, `APPEND_SYSTEM.md`, settings, tools, Skills, prompt templates, and Extensions. A Pi extension can still register a tool named `oppi`, but Oppi does not reserve or manage that name.

Durable sessions (`experimental.serverDurable`) load native extensions instead of Pi's built-ins, so a durable coding session has no `codemode` tool and no `oppi` tool. The one exception is the durable control conversation (`oppi control open`, `oppi control send`): its `oppi_query` and `oppi_script` tools run JavaScript in a sandbox whose only capability is the `oppi` CLI. `oppi_query` only reads. In `oppi_script`, every write that is not a GET waits for a confirm card (Yes / Yes to all remaining in this script / No) showing the request and, for an update, a diff; there is no setting that skips it. No other durable session is offered these tools.

## Mobile don'ts

- Do not use `ctx.ui.custom()` for a decision the user must answer from the phone. Use `ctx.ui.ask()`, `ctx.ui.select()`, `ctx.ui.confirm()`, `ctx.ui.input()`, or `ctx.ui.editor()`.
- Put readable mobile output in `details.expandedText` (with `details.presentationFormat` when it applies). Collapsed summaries stay one line.
- Keep a terminal or text fallback. Oppi must show something readable when a native block is unsupported.

## Server Skills and Extensions

Use the server's **Skills** and **Extensions** destinations to inspect and change the selected server's Pi user/global defaults. These catalog endpoints follow `pi config` semantics: Pi resolves user-scope candidates, including disabled entries, and toggles preserve Pi's ordered `+path`, `-path`, `!pattern`, and package-filter rules. Workspace Settings remain the authority for project overrides; a server default is not a claim about the effective state in every workspace.

The catalog is intentionally global and has no `cwd` parameter. It lists Pi-native user candidates from `~/.pi/agent`, `~/.agents/skills`, configured user settings, and configured packages. It does not install packages while listing. Provenance and enabled state come from Pi. Normal resource IDs are opaque path-derived identifiers, so a moved resource can receive a new ID.

### Mobile output guide

Enable **Mobile Output Guide** under **Server Detail → Configuration** to tell agents which links and rich content Oppi can render in new and explicitly reloaded managed host, sandbox, and Pi Control sessions. The capability guide covers real workspace and owner-host wiki links with uppercase one-based anchors, inline images and SVG, inline `![]()` / `![[]]` embeds for existing Oppi-backed image, audio, and video files, fenced Mermaid flowchart (also graph), sequence, class, state, ER, gantt, pie, timeline, mindmap, xyChart, journey, quadrantChart, gitGraph, sankey, and kanban diagrams, fenced GeoJSON and TopoJSON maps, LaTeX, session deep links, and viewers for recognized documents and media. Other Mermaid types show an unsupported placeholder. File `[label](path)` and `[[path]]` remain ordinary file links. Remote URLs, HTML `<video>`, HTML `<audio>`, and attachment IDs are not embeds. It does not prescribe response style, fabricate paths, or expose secrets. Oppi does not send viewport dimensions, and active sessions are not reloaded automatically.

The setting does not affect terminal-owned Mirror sessions. Saved Agent and workspace instructions remain in their existing precedence order. Non-text wiki-link icons are not part of this setting. A global `SYSTEM.md` replacement does not suppress the guide because the guide is an Oppi append capability.

### When a change takes effect

New managed sessions use the latest Mobile Output Guide setting. An active managed session keeps its current prompt resources until `/reload` rebuilds it through Pi's full `AgentSession.reload()` lifecycle. Reload applies the current guide before the next turn.

The server-wide model picker and provider-auth list rescan global/user provider extensions when `~/.pi/agent/settings.json` changes, when files under `extensions/` change (including one nested directory level such as `foo/index.ts`), when npm/git package metadata changes, or immediately after an extension is enabled or disabled. A server restart is not required for those catalog updates. The rescan never runs `npm install` or `git clone`; a package listed in settings but not already installed stays out of the picker until it is installed some other way. Active sessions still keep their own model runtime until `/reload` or a new session.

The setting does not modify standalone Pi or terminal-owned mirrored sessions. A stopped disconnected mirror session evaluates the current guide only if it is explicitly promoted to Oppi-managed ownership.

For ordinary Pi extensions, disabled rows are still visible in the server catalog. Pi does not execute disabled extension factories merely to manufacture diagnostics or contributed capabilities, so disabled rows can honestly show discovery state without a speculative load error. Enabled extensions can report Pi loader diagnostics and contributed tools or commands when Pi provides them.

## Provider quota extension API

A globally enabled Pi extension can add quota data to **Server → Model Providers**, the model picker, `oppi quota`, and `oppi models`. Register the model provider with Pi first, then emit an Oppi quota declaration **inside the extension factory**. The quota callback runs only when a client requests `/server/provider-quotas`; do not fetch usage while the factory loads. Plain Pi ignores the declaration. **To show quota under Connected on the Server screen, sign in to the provider there or with Pi `/login` first.** An environment-only API key enables the model picker and `oppi quota`, but the Server screen classifies providers as Connected only when credentials are saved in Pi's auth store.

The example below is a template, **not an Anthropic integration**. Replace the example endpoint, model metadata, and response fields with your provider's documented contract before installing it. Save it as a Pi extension (for example, `~/.pi/agent/extensions/example-quota.ts`); do not put API keys in the file.

```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("example-cloud", {
    name: "Example Cloud",
    api: "openai-completions",
    baseUrl: "https://example.invalid/v1",
    apiKey: "$EXAMPLE_API_KEY",
    models: [{
      id: "example-model", name: "Example Model", reasoning: false,
      input: ["text"], contextWindow: 100000, maxTokens: 8000,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    }],
  });

  pi.events.emit("oppi:provider-quota:v1", {
    providerId: "example-cloud",
    displayName: "Example Cloud",
    async fetch({ signal, getAuth }: {
      signal: AbortSignal;
      getAuth: () => Promise<{ apiKey?: string } | undefined>;
    }) {
      const auth = await getAuth(); // scoped to example-cloud; never returns a refresh token
      if (!auth?.apiKey) return { authenticated: false, windows: [] };
      const response = await fetch("https://example.invalid/usage", {
        headers: { Authorization: `Bearer ${auth.apiKey}` }, signal,
      });
      if (!response.ok) throw new Error(`Usage request failed (${response.status})`);
      const usage = await response.json() as { usedPercent: number; resetAt: number };
      return {
        authenticated: true,
        planType: null,
        windows: [{
          key: "five_hour", shortLabel: "5h", title: "5-hour",
          usedPercent: usage.usedPercent,
          limitWindowSeconds: 18_000, resetAt: usage.resetAt,
          includeWeekdayInReset: false,
        }],
        credits: null, prepaidBalanceCents: null,
      };
    },
  });
}
```

**Declaration contract (`oppi:provider-quota:v1`):** `providerId` must match a provider registered by the same globally enabled extension resource and match `^[a-z0-9][a-z0-9._-]{0,79}$`. `displayName` is optional; it defaults to the ID. `fetch({ signal, getAuth })` returns a promise with `authenticated: boolean` and `windows: []` (up to 12). `getAuth()` resolves the provider's Pi request auth (`apiKey`, `headers`, `baseUrl`) and may refresh OAuth; it does not expose the stored credential or refresh token. For an unauthenticated account return `{ authenticated: false, windows: [] }`. Oppi does not call the callback when the provider has no configured auth.

Each window needs `key`, `shortLabel`, `title`, `usedPercent` (finite, 0–100), `limitWindowSeconds` and `resetAt` (nonnegative integer seconds or `null`), and `includeWeekdayInReset: boolean`. Optional result fields are `planType: string | null`, `credits: { hasCredits: boolean, unlimited: boolean, balance: string | null } | null`, `prepaidBalanceCents: number | null` (nonnegative integer cents), and `error: string`. Oppi computes `remainingPercent`, pacing, and `fetchedAt`; extra fields are discarded. Strings, windows, and errors are bounded. Invalid results become a generic error row rather than breaking the quota screen. Do not put tokens or upstream response bodies in errors.

The server loads declarations from global/user Pi resources, not project-local extensions. If two declarations claim one ID, Oppi ignores both quota callbacks and reports a diagnostic. An extension-registered provider ID replaces that ID's built-in quota adapter **even without a quota callback**, so a custom token is never sent to a built-in quota URL. The one exception is a stream-only wrapper: `registerProvider(id, { api, name, streamSimple })` with no `oauth`, `apiKey`, `baseUrl`, `headers`, `authHeader`, `models`, `refreshModels`, `images`, or `classifiers` inherits the built-in auth and endpoint, so the built-in quota adapter stays. A native provider, or any registration with one of those overrides, owns the ID. A quota declaration for the ID always wins over the built-in adapter. Removing or disabling the extension restores the built-in adapter. The quota route rescans global provider resources when they change; the callback has a 10-second deadline and must honor `signal`. Each quota request invokes the callback; cache upstream responses in the extension when needed. Active model sessions still need `/reload` to pick up provider changes. Pi currently stores one credential per provider ID, and the existing Oppi screen shows one quota row per provider; this API does not add OMP-style multiple-subscription accounts. There is no Pi quota API yet; this event channel is Oppi's extension-facing bridge, not a Pi model-provider method.

## Extension surfaces

| Surface                 | Enabled by                                                    | Declared in                              | Loaded by          | Notes                                                                                                         |
| ----------------------- | ------------------------------------------------------------- | ---------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------- |
| Host pi extensions      | User/project pi settings, `pi install`, or `.pi/extensions`   | User-owned pi config/package paths       | pi resource loader | Must work without Oppi server services                                                                        |
| Ask extension example   | Pi package/settings install or auto-discovered extension path | `pi-extensions/ask`                      | pi resource loader | Portable Pi package: registers `ask`, uses native AskCard when available, then falls back to Pi UI APIs       |
| Subagents example       | Pi package/settings install or auto-discovered extension path | `pi-extensions/subagents`                | pi resource loader | Reference tool and widget. Launches children, checks in every 4 minutes while supervised, and refreshes only those ids. |
| Background jobs example | Pi package/settings install or auto-discovered extension path | `pi-extensions/background-jobs`          | pi resource loader | Reference tool. Backgrounds a long shell command and delivers the output as a follow-up.                      |
| Browser video example   | Pi package/settings install or auto-discovered extension path | `pi-extensions/browser-automation-video` | pi resource loader | Oppi-compatible Pi package: registers a public Pi tool and uses Oppi's attachment helper when available       |
| Mobile UI compatibility | Native Oppi client + server bridge                            | Protocol and UI bridge code              | Oppi server/client | Maps common `ctx.ui` calls to native cards/dialogs; see [`extension-native-ui.md`](extension-native-ui.md)    |

This split keeps consent clear: installing Oppi does not install a pi extension package.

## Reference extension examples

`pi-extensions/subagents` and `pi-extensions/background-jobs` are copyable examples, not Oppi product features. Installing Oppi does not enable them. Link the package into `~/.pi/agent/extensions/` or run `pi -e ./pi-extensions/<name>` when you want that behavior.

`subagents` registers `subagent`. A launch returns immediately and one async `oppi session wait` per parent, not a session-list scan, updates the widget: Done when the child is idle, Needs attention when a dialog is pending. Supervised launches also start a visible parent turn on settle or attention, and otherwise send one parent check-in about every 4 minutes so the prompt cache stays warm. Detached tool launches and a bash `oppi session create` from this parent get the widget wait only. A row uses the existing `oppi://session/<id>` link. It does not add a screen or a children-list API.

`background-jobs` registers `background_job`. A shell command that is still running after 15 seconds, or one that ends in `&`, becomes a job. The composer pill shows it, and the output is injected as a follow-up. Polling a running job is blocked. While jobs run, it keeps the final turn open unless `oppi session get` confirms the session does not auto-stop; it asks once, the first time a turn would end with a job running. Plain Pi, a missing CLI, or a failed lookup keeps the turn open.

## Ask extension example

`pi-extensions/ask` is a portable Pi package. It registers the `ask` tool through public `pi.registerTool()` APIs and supports multiple questions, `multiSelect`, and custom text answers.

Rendering path:

1. **Oppi / RPC:** use the documented `ctx.ui.ask()` request, rendered by iOS as a native AskCard.
2. **Terminal Pi:** use `ctx.ui.custom()` for a keyboard-driven terminal dialog.
3. **Other Pi UI contexts:** use `ctx.ui.select()` and `ctx.ui.input()` fallbacks.

`ctx.ui.ask()` is an Oppi-defined UI request because plain Pi's standard dialog API does not include a multi-question or multi-select form. The extension stays portable by checking for `ctx.ui.ask()` and using Pi UI fallbacks when it is absent.

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
2. **Pi resource toggles** from Workspace Settings → Skills and Extensions. Each toggle applies at once and writes Pi resource settings (`+` / `-` entries) for skills and extensions; it does not write a workspace-level extension allowlist.
3. **A server-scoped Mobile Output Guide**, appended to managed sessions when enabled under Server Detail.
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
| `ctx.ui.notify()`                                                              | non-blocking status                                           | muted attributed chip above the chat composer; tap to read the message               |
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

At session startup, Oppi uses Pi's normal extension sources for the session working directory. Oppi registers no server-owned tool. Managed host sessions load a lifecycle-journal extension plus Pi's `mcp`, `codemode`, and `tool-search` built-ins. Managed sandbox sessions load the lifecycle-journal extension, `mcp`, and `tool-search`, and do not load `codemode`. On either kind of session, `-builtin:<name>`, an exact Agent extension selection, or another extension that registers the same tool, command, or flag can leave one of those built-ins out. Oppi adds none of these to a terminal mirror session; the terminal's own Pi loads its built-ins according to its own settings.

Pi's normal sources are:

- auto-discovered extension directories (`~/.pi/agent/extensions/`, `.pi/extensions/`)
- settings-declared extension paths (`settings.json` `extensions` arrays)
- package-provided extensions installed through pi (`pi install`)

Pi resolves the resources for the session cwd. The picker starts with those resolved resources, also scans global and project `.pi/extensions` directories so newly copied files appear, and normalizes extension names:

- file extensions must be `.ts` or `.js`; `.test` and `.spec` files are ignored in the picker
- package `index` entries use the package identity for display, such as `npm:@tintinweb/pi-subagents` becoming `tintinweb-subagents`
- directory-style entries such as `extensions/foo/index.ts` use `foo` as the extension name

Enable/disable writes only match Pi-resolved resources. A direct-scan entry that Pi's resolver cannot match can appear in the picker but fail with `Pi resource not found for cwd` if toggled.

Oppi loads Pi-resolved extensions without injecting an extra Ask tool. Install or enable a Pi extension named `ask` when a workspace or Pi Control session needs it.

## Reload behavior

`/reload` rebuilds an active Oppi-managed session through Pi's full `AgentSession.reload()` lifecycle. It reloads host Pi extensions, skills, prompts, themes, system-prompt files, and the current Mobile Output Guide setting before the next turn. Terminal-owned mirrored sessions keep terminal ownership and are not changed by this server setting.

## Pi resource toggle behavior

Current Oppi workspaces do not store `extensions`. Extension enablement comes from Pi resource settings for the session cwd.

Workspace Settings can toggle skills and extensions by writing Pi settings:

- `+path` enables a resource that is otherwise filtered out.
- `-path` disables a resource that Pi would otherwise load.
- Package resources use the same `+` / `-` filtering inside the package entry.
- Temporary resources cannot be edited from Oppi.

This is Pi resource filtering, not a workspace-owned allowlist or denylist. A host-backed workspace starts sessions with whatever Pi resolves for that cwd after those settings are applied. Sandbox workspaces still have a separate `workspace.tools` allowlist for VM-backed tools only.

## Extension picker behavior

`GET /extensions` is the data source for Workspace Settings → Extensions. It is not a general-purpose pi reference API.

The picker response:

- resolves host extensions through pi's normal settings and package resolver
- also scans global and project `.pi/extensions` directories so newly copied files appear on the next scan
- includes auto-discovered global and project-local extensions
- includes package-installed extensions
- includes settings-declared extension paths
- allows host/project/package extensions named `ask`
- deduplicates by extension name using pi resource-loader precedence
- for a host folder, adds `projectTrust` (`trusted`, `ask`, or `distrusted`), the answer a session would reach without prompting ([project trust](server-configuration.md#project-trust-in-managed-host-sessions))
- omits project-local extensions and project settings when `projectTrust` is `distrusted`; `ask` lists them, because an unanswered session prompt allows them
- `POST /pi/resources/enabled` returns `409` for a `distrusted` folder, because Pi ignores the project settings a toggle would write

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

For older servers that omit both `inputPresentation` and `outputPresentation`, OppiCore supplies the registry's declarations for the exact built-in names `bash`, `read`, `write`, `edit`, and `ask`. This is the single intentional client tool-name exception, owned by `BuiltInToolFacts.swift` before shared inspection is built. Any producer input or output fact suppresses the entire fallback. Names are not normalized: `functions.read`, `Read`, `put_file`, and other undeclared tools stay generic. The fallback does not invent output availability or session-setting authority.

On iOS, generic expanded tool rows show one Markdown document with **Input**, optional **Calls**, and **Output** sections. Terminal-kind rows use a separate command panel and text viewport, with the sidecar on open. File and diff facts select the existing native file viewers. Interactive rows use the same Input/Output inspection independently of their answer-message receipt. Audio/image/media presentations keep native attachment renderers with Input and Calls alongside output. Section labels appear only when the document has more than one section.

Input shows non-empty arguments as a form table, source-code fences, or labeled text/JSON blocks. Calls shows Pi's recorded nested calls with status, literal compact arguments, duration, and errors. An incomplete record shows a notice. Live child executions carrying `parentToolCallId` update the parent's Calls rather than add top-level rows, in managed and Mirror sessions. The parent result replaces the live records and supplies the same Calls after reload. Invocation-like output is retained; the app does not strip it based on a tool name.

The server can emit `display: { title, group?, verbatim? }` on tool calls and nested-call records. Without summary segments, iOS uses `group · Title` and applies one sentence-case humanizer to the title fact (for example, `getActivityDetail` becomes “Get activity detail”). `verbatim: true` preserves a provided title exactly. With no display fact, older-server rows keep their raw names. Input and Raw retain raw tool names; Raw also retains nested-call records.

MCP display facts currently use the live tool definition's label/namespace, then result `details.server`/`details.tool` for history, then Pi's `mcp__<server>__<tool>` naming convention. History restores sanitized server spellings from the session workspace's configured MCP names when the match is unique (for example, `dev_radius` → `dev-radius`). If config is missing or ambiguous, it retains the raw namespace fallback. MCP-provided `title`, `annotations.title`, and `serverInfo.title` are not shown yet: Pi drops tool titles before its public session boundary and does not expose its MCP connections. Oppi does not infer a title from description or use `serverInfo.name` as the group. No icons are carried or fetched in this release.

Expanded output uses this order:

1. `details.expandedText` plus `details.presentationFormat`
2. the tool's text, parsed as JSON (including a text preamble followed by JSON), a unified diff, Markdown, or fenced plain text
3. structured `details`, rendered as the same generic form when text is empty; Pi TUI result hooks are not executed
4. the waiting status while the tool runs

JSON objects become form tables in wire key order. Scalar object arrays become tables when they have at most eight columns. Other arrays become lists of forms. JSON strings, MCP content wrappers, and Promise.allSettled results are unwrapped without tool-name checks. Rendered previews are bounded; the full-screen reader's **Raw** toggle retains all arguments, including null/empty fields, and available raw output. Raw identifies output previews and their total byte count when known. Raw loads full output by tool-call ID when a source is available, including in stopped sessions. If that source is unavailable, the preview notice remains. Double-tap opens the same document with a **Rendered / Raw** toggle. Copy output still copies the tool's raw text.

Sidecars provide short collapsed summaries and optional semantic facts. Each tool renderer can declare source-code, command, or file fields:

```typescript
export default {
  custom: {
    inputPresentation: { fields: { source: { role: "code", language: "python" } } },
    renderCall(args) { return [{ text: "custom ", style: "bold" }]; },
    renderResult(details, isError) { return []; },
  },
  put_file: {
    inputPresentation: { fields: { target: { role: "filePath" }, payload: { role: "fileContent" } } },
    outputPresentation: { kind: "fileContent", provenance: "requested" },
    renderCall(args) {
      return [{ text: "store ", style: "bold" }, { text: String(args.target ?? ""), style: "accent" }];
    },
    renderResult(details, isError) { return []; },
  },
  choose_next: {
    outputPresentation: { kind: "interactive" },
    renderCall(args) { return [{ text: "Choose next", style: "bold" }]; },
    renderResult(details, isError) { return []; },
  },
  run_thing: {
    inputPresentation: { fields: { command: { role: "command", language: "shell" } } },
    outputPresentation: { kind: "terminal" },
    renderCall(args) {
      return [{ text: "$ ", style: "bold" }, { text: String(args.command ?? ""), style: "accent" }];
    },
    renderResult(details, isError) { return []; },
  },
};
```

`run_thing` receives the same iOS command panel and terminal viewport as built-in `bash`. The registry matches Pi's exact tool name; aliases such as `functions.bash` do not inherit facts. The server sends `outputPresentation` on live start/update and history calls, and resolves it again on results. Explicit `details.outputPresentation` wins over the static declaration. `details.expandedText` also wins: `presentationFormat: "terminal"` keeps terminal semantics; other formats select the generic document. Unknown explicit kinds degrade to structured output.

`outputPresentation.kind: "interactive"` declares the question/answer lifecycle used by built-in `ask`. Any exact tool name can declare it, including `choose_next`. Result `details.questions` and `details.answers` supply the answer receipt; the fact does not create an input prompt. Use `ctx.ui.ask()` for the actual prompt. Interactive tools stay out of automatic expand-all, and emit one answer message per call. Inspection remains available independently of settlement. A tool without interactive semantics emits no answer receipt. Exact built-in `ask` receives those semantics through the compatibility fallback only when both producer-fact fields are absent.

Glyphs are derived in the shared Apple builder from terminal, file and interactive facts, or explicit audio/image/media details. Sidecars declare semantics, not symbol names or views. Generic tools retain the default glyph; a textual prefix such as `$` or `ask` does not select one. Voice reply settings require the registry-declared `outputPresentation.settingEffect: "voiceReplyMode"` fact and a valid successful `details.kind: "voice_reply_mode"` and `mode` payload. Result details alone cannot grant setting authority.

File facts use `filePath`, `fileContent`, and `edits` input roles. `edits` is an array of `{ oldText, newText }` pairs. Optional `lineOffset` and `lineLimit` fields describe one-based read ranges. File roles do not require a language. `outputPresentation.kind` can be `fileContent` or `diffOfEdits`; `provenance: "requested"` identifies input content, and `"result"` identifies tool-result content. Built-in read declares result file content; write declares requested file content; edit declares result diffs. The app uses a result patch or Pi's numbered `details.diff` when available, otherwise it labels an args-derived diff **Requested**. Partial write/edit arguments stay previewable while running. A successful requested-file-content operation offers **Open Current File**, which reads the file as it is now, not the historical requested bytes. The same facts work for any exact tool name, including `put_file`. Older-server exact built-ins keep native file/diff inspection through the compatibility facts; arbitrary tools such as `put_file` still need producer facts.

Every tool result carries `outputAvailability: { complete, totalBytes?, source? }`, derived from Pi's `details.truncation` and `details.fullOutputPath`. `source: "sidecar"` enables full-output reads by tool-call ID; the fact never contains the private path. Terminal-kind output uses the JSON text path: a suffix under 8 KiB, then a throttled tail replace (80 lines, 16 KiB). The full log is the sidecar on an explicit open, not a live byte-log resync. The iOS reader loads full output when a source is available, including in stopped sessions. Exact built-in `bash` receives terminal semantics through the compatibility fallback when both producer-fact fields are absent; undeclared names remain generic. Old apps ignore the additive facts.

Oppi sends `inputPresentation` on live tool start/update and history tool calls. History resolves hints against the current renderer registry, not a saved per-call declaration. The built-in codemode hint declares `code` as JavaScript. Invalid hints are omitted and logged. Segment style is a closed semantic set: `bold`, `muted`, `dim`, `accent`, `success`, `warning`, or `error`. Invalid sidecar segments are also omitted and logged. Put rich output in `details.expandedText`, not sidecar summary lines.

Mirror mode uses the same semantic request payloads from an interactive terminal Pi process. Mirror-specific first-wins dialog behavior lives in [`oppi-mirror.md`](oppi-mirror.md#extension-ui-compatibility-matrix).

## When to read pi docs instead

Use pi's docs for:

- writing an extension
- supported extension directory layouts
- lifecycle hooks and custom tools
- terminal rendering with TUI components
- package-based extension distribution

Use this page only for Oppi-specific behavior and mobile/runtime gotchas.
