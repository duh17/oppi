# Oppi extension behavior

What Oppi loads for a session, which Pi extension rules Oppi adds, and how to make an extension work well on a phone. For the extension API itself (package layout, lifecycle hooks, tools, TUI rendering), use Pi's docs:

- [Pi extensions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) and [Pi packages](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md)
- Pi examples: `@earendil-works/pi-coding-agent/examples/extensions/`

Related: [Extension native UI](extension-native-ui.md) (prompts, widgets, native blocks) and [Attachment rendering](attachment-rendering.md) (images, audio, video).

## What Oppi loads

Pi owns skills and extensions. Oppi resolves them for the session's working directory through Pi's resource system. There is no workspace extension allowlist, and Oppi never writes `~/.pi/agent/settings.json`, runs `pi install`, or enables anything in standalone Pi. Installing Oppi does not install a Pi extension package.

Pi's normal sources are auto-discovered directories (`~/.pi/agent/extensions/`, `.pi/extensions/`), `extensions` paths in `settings.json`, and packages installed with `pi install`.

Oppi adds a lifecycle-journal extension and Pi's built-ins to each managed session, plus two tools only when they apply: `notify` for top-level sessions while a device has push on for the server ([Push notifications](server-configuration.md#push-notifications)), and `speak` while a Live Voice call is attached. Pi's built-ins by session:

| Session | Built-ins loaded |
| --- | --- |
| Managed host | `mcp`, `codemode`, `tool-search` |
| Managed sandbox | `mcp`, `tool-search` (no `codemode`) |
| Durable | None of Pi's; native durable extensions instead ([Durable extensions](#durable-extensions)) |
| Oppi Mirror | None; the terminal's own Pi loads its built-ins |

`-builtin:<name>` in Pi settings, an Agent's exact extension selection, or another extension that registers the same tool, command, or flag can leave a built-in out ([MCP, codemode, and tool search](server-configuration.md#mcp-servers-codemode-and-tool-search)). A Pi extension can register a tool named `oppi`; Oppi does not reserve that name.

Workspace Settings → Skills and Extensions toggles write Pi resource settings: `+path` enables a resource that is otherwise filtered out, `-path` disables one Pi would load, and package resources use the same filtering inside the package entry. Temporary resources cannot be edited from Oppi. Sandbox workspaces also have a `workspace.tools` allowlist for VM-backed tools only.

## Pi Control sessions

A Pi Control session is the workspace-less session Oppi opens for **Edit with Oppi** ([Using Oppi](usage.md#edit-with-oppi)). It uses Oppi's own short setup prompt, which describes Oppi's surfaces and points at these docs. It does not load your global `SYSTEM.md`, `APPEND_SYSTEM.md`, `AGENTS.md`, or Skills.

- **Tools:** only `read`, `bash`, `edit`, and `write` are active, plus `ask` when an installed extension provides it.
- **Extensions:** they still load, so provider registrations and `ask` work. Their other tools are not active.
- **Mobile Output Guide:** applies when it is on ([below](#mobile-output-guide)).
- **Authority:** the session runs as the server's host user and can run any command through `bash`, including the `oppi` CLI. Its prompt tells it to show each `oppi` write and wait for your yes. That is an instruction to the model, not an enforced confirmation like the durable control conversation's.

The durable control conversation (`oppi control open`, `oppi control send`) is separate and needs `experimental.serverDurable`. It has one tool per Oppi action (`agents_list`, `agents_create`, `schedules_run`, `sessions_send`, … and `oppi` for any CLI command) plus pi-durable's `codemode`, whose scripts call the same tools as `tools.<name>(…)` and resume after a server restart without rerunning finished calls. Read tools only read. Every write waits for a confirm card showing the request and, for an update, a diff: Yes or No for a direct call, plus Yes to all remaining in this script inside a codemode script. No setting skips it. No other durable session gets these tools.

## Mobile Output Guide

**Server Settings → Mobile Output Guide** tells agents which links and rich content Oppi renders: wiki links to workspace and owner-host files, inline images, audio, video and USDZ, Mermaid diagrams, maps, LaTeX, session links, and document viewers. See [Document viewers](document-viewers.md) and [Attachment rendering](attachment-rendering.md).

- It applies to new and reloaded managed host, sandbox, and Pi Control sessions. It does not prescribe response style, fabricate paths, or expose secrets, and Oppi sends no viewport dimensions.
- It is an append, so a global `SYSTEM.md` replacement does not suppress it. Saved Agent and workspace instructions keep their precedence.
- It does not change standalone Pi or terminal-owned Mirror sessions. A stopped Mirror session reads the current guide only if you promote it to Oppi-managed.

## When a change takes effect

- A new managed session uses the latest Mobile Output Guide setting. An active session keeps its prompt resources until `/reload`, which rebuilds it through Pi's full `AgentSession.reload()` (extensions, skills, prompts, themes, system-prompt files, and the guide) before the next turn.
- The server's model picker and provider-auth list rescan provider extensions when `~/.pi/agent/settings.json` changes, when files under `extensions/` change (one nested directory level included), when npm or git package metadata changes, and right after an extension is enabled or disabled. No restart is needed. The rescan never runs `npm install` or `git clone`, so a package listed in settings but not installed stays out of the picker. Active sessions keep their model runtime until `/reload` or a new session.

## Skills and Extensions pages

The server's **Skills** and **Extensions** destinations show and change Pi's user-scope defaults, following `pi config` semantics: toggles preserve Pi's ordered `+path`, `-path`, `!pattern`, and package-filter rules. Workspace Settings stay the authority for project overrides, so a server default is not a claim about every workspace.

The catalog has no working directory. It lists Pi-native user candidates from `~/.pi/agent`, `~/.agents/skills`, configured user settings, and configured packages, and it never installs packages. Provenance and enabled state come from Pi. Resource IDs are opaque and path-derived, so a moved resource can get a new ID. Disabled extensions stay visible but are not executed, so a disabled row shows no load error or contributed tools; enabled ones can show Pi loader diagnostics and contributed tools or commands.

The workspace **Extensions** picker starts from the extensions Pi resolves for the session's folder, also scans global and project `.pi/extensions` so newly copied files appear, and names them as follows:

- Files must end in `.ts` or `.js`; `.test` and `.spec` files are ignored.
- Package entries use the package identity (`npm:@tintinweb/pi-subagents` shows as `tintinweb-subagents`); `extensions/foo/index.ts` shows as `foo`.
- Duplicates resolve by Pi's resource-loader precedence. Extensions named `ask` are allowed.
- A toggle only applies to resources Pi resolves; a scanned file Pi cannot match fails with `Pi resource not found for cwd`.
- For a host folder, the picker shows its [project trust](server-configuration.md#project-trust-in-managed-host-sessions). A `distrusted` folder lists no project-local extensions or settings and refuses toggles, because Pi ignores the project settings a toggle would write. An `ask` folder lists them, because an unanswered session prompt allows them.

## Make an extension work on a phone

Build a normal Pi extension first, then make the user-facing parts semantic enough for Oppi to render without a terminal.

**Do not:**

- Use `ctx.ui.custom()` for a decision the user must answer on the phone. Use `ctx.ui.ask()`, `select()`, `confirm()`, `input()`, or `editor()`.
- Put long Markdown, tables, or logs in the collapsed summary, or rely on a `renderResult()` TUI component without `details.expandedText`.
- Embed base64 video or audio or local file paths in Markdown.
- Depend on raw ANSI colors instead of plain fallback text.
- Assume a persistent widget owns unbounded vertical space.

**Do:**

1. Ship a package or extension path that works in standalone Pi, and test both terminal Pi and an Oppi workspace.
2. Keep tool `content` concise for the model and put readable output in `details.expandedText` with `details.presentationFormat`. Keep collapsed summaries to one line.
3. Put generated images and video in stored attachment metadata ([Attachment rendering](attachment-rendering.md)). For PDFs and generic files, return a workspace or session path or link in `content` or `details.expandedText`; `details.media[]` does not render them.
4. Give custom widgets a terminal or text fallback.

### What translates

| Pi API | Use for | Oppi behavior |
| --- | --- | --- |
| `ctx.ui.ask()` | Multi-question prompts, multi-select, custom answers | Native AskCard. `ask` is Oppi-defined, so portable extensions need a Pi fallback |
| `ctx.ui.select()` | One choice from a short list | Native prompt card |
| `ctx.ui.confirm()` | Yes/no decisions, approval gates | Native confirmation card |
| `ctx.ui.input()` | One short text answer | Native text prompt |
| `ctx.ui.editor()` | Longer text | Native editor sheet |
| `ctx.ui.notify()` | Non-blocking status | Muted chip above the composer; tap to read |
| `ctx.ui.setTitle()` / `setStatus()` | Heading, persistent status | Surface heading, status chip |
| `ctx.ui.setWidget()` | Persistent display state | Strip and drawer ([Native widgets](#native-widgets)) |
| `ctx.ui.setWorkingMessage()` / `setWorkingVisible()` / `setWorkingIndicator()` | Working row | Native timeline working row |
| `ctx.ui.setEditorText()` / `pasteToEditor()` | Hand text to the composer | One-shot composer handoff |
| `ctx.ui.setToolsExpanded()` / `getToolsExpanded()` | Tool expansion default | Native tool-row state |

`ctx.ui.custom()`, `setFooter`, `setHeader`, `setEditorComponent`, and raw terminal input stay terminal-owned unless the extension also provides a semantic surface or standard prompt. The full mapping and rules are in [Extension native UI](extension-native-ui.md).

Working indicator, message, and status are bounded data the app renders:

```typescript
ctx.ui.setWorkingIndicator({ frames: ["·", "•", "●", "•"], intervalMs: 120 });
ctx.ui.setWorkingMessage("Checking files…");
ctx.ui.setStatus("working-words", "shuffled · 18 phrases");
```

If an extension uses terminal-only glyphs, colors, or fonts, branch on `ctx.mode === "tui"` and give other modes plain Unicode or text frames.

### Tool output

Oppi reads the normal Pi tool result, looks for structured `details`, then falls back to generic text parsing.

```typescript
return {
  content: [{ type: "text", text: "Created release notes." }],
  details: {
    expandedText: "# Release notes\n\n- Added mobile extension defaults",
    presentationFormat: "markdown",
  },
};
```

| `details` field | Mobile behavior |
| --- | --- |
| `expandedText` | Text shown when the user expands the tool row |
| `presentationFormat: "markdown"` / `"json"` / `"diff"` | Render `expandedText` as Markdown, formatted JSON, or a unified diff |
| `presentationFormat: "code"` with `language` or `filePath` | Syntax-highlighted code |
| `startLine` | First code line number |
| `media` | Stored image and video rows ([Attachment rendering](attachment-rendering.md)) |

For generated images or video, use Oppi's attachment helper when `ctx.attachments` exists, and write the output path into `content` when it does not:

```typescript
const video = await ctx.attachments.addFile({
  path: mp4Path, kind: "video", mimeType: "video/mp4",
  fileName: "browser-run.mp4", deleteSource: true,
});
return {
  content: [{ type: "text", text: "Recorded browser run." }],
  details: { media: [video] },
};
```

### Native widgets

Use native widgets for display-only state: progress, task lists, status summaries, and links to Oppi destinations such as `oppi://session/<id>`. A widget component that works in both places has `render()` for terminal Pi, `renderNative()` for Oppi, `fallback.lines` or `fallback.text`, and stable IDs for rows that update.

A widget without `renderNative()` shows the sanitized terminal snapshot from `render(width)`, which keeps it readable but has no row-level native behavior such as activity-row links. Placement, strips, and drawers are in [Extension native UI](extension-native-ui.md#placement).

Widgets are data rendered by Oppi, not downloaded Swift views.

## Approval prompts

Approval behavior belongs to Pi extensions. Command classification, route decisions, and prompts live in extension handlers; Oppi renders the resulting UI and adds no approval layer. An extension can intercept `tool_call`, `session_before_switch`, `session_before_fork`, or other Pi events and ask with `ctx.ui.ask()`, `confirm()`, `select()`, `input()`, or `editor()`. Oppi renders those requests natively and returns answers through `extension_ui_response`. Oppi-owned and mirrored terminal sessions behave the same, and standalone terminal Pi runs the same logic through its TUI.

## Oppi event channels

Plain Pi has no listener for these `pi.events` channels, so an emit there is a no-op.

### Provider quota extension API

A globally enabled Pi extension can add quota data to **Server Settings → Model Providers**, the model picker, `oppi quota`, and `oppi models`. Register the provider with Pi first, then emit a quota declaration **inside the extension factory**. The callback runs only when a client requests quota, so do not fetch usage while the factory loads. To show quota under Connected, sign in to the provider in the app or with Pi `/login`; an environment-only API key enables the model picker and `oppi quota` but not Connected.

The example is a template, **not an Anthropic integration**. Replace the endpoint, model metadata, and response fields with your provider's documented contract. Do not put API keys in the file.

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

**Declaration (`oppi:provider-quota:v1`):**

- `providerId` must match a provider registered by the same globally enabled extension and `^[a-z0-9][a-z0-9._-]{0,79}$`. `displayName` is optional and defaults to the ID.
- `fetch({ signal, getAuth })` returns `{ authenticated: boolean, windows: [] }` with up to 12 windows. `getAuth()` resolves the provider's Pi request auth (`apiKey`, `headers`, `baseUrl`) and can refresh OAuth, but never exposes the stored credential or refresh token. Oppi does not call `fetch` when the provider has no configured auth. For an unauthenticated account return `{ authenticated: false, windows: [] }`.
- Each window needs `key`, `shortLabel`, `title`, `usedPercent` (finite, 0–100), `limitWindowSeconds` and `resetAt` (nonnegative integer seconds or `null`), and `includeWeekdayInReset: boolean`.
- Optional result fields: `planType: string | null`, `credits: { hasCredits: boolean, unlimited: boolean, balance: string | null } | null`, `prepaidBalanceCents: number | null` (nonnegative integer cents), and `error: string`. Do not put tokens or upstream response bodies in errors.
- Oppi computes `remainingPercent`, pacing, and `fetchedAt`, and discards extra fields. Strings, windows, and errors are bounded. An invalid result becomes a generic error row.

**Rules:**

- Declarations load only from global or user Pi resources, not project-local extensions. If two declarations claim one ID, Oppi ignores both and reports a diagnostic.
- An extension-registered provider ID replaces that ID's built-in quota adapter **even without a quota callback**, so a custom token never reaches a built-in quota URL. The exception is a stream-only wrapper, `registerProvider(id, { api, name, streamSimple })` with none of `oauth`, `apiKey`, `baseUrl`, `headers`, `authHeader`, `models`, `refreshModels`, `images`, or `classifiers`: it inherits the built-in auth and endpoint, so the built-in adapter stays. A quota declaration for the ID always wins. Removing or disabling the extension restores the built-in adapter.
- The callback has a 10-second deadline and must honor `signal`. Each quota request invokes it, so cache upstream responses in the extension. Active sessions need `/reload` to pick up provider changes.
- Pi stores one credential per provider ID, and the quota screen shows one row per provider; multiple subscription accounts are not supported. Pi has no quota API; this channel is Oppi's bridge.

### Pending wake extension API

Oppi stops a session idle for the configured idle timeout (one hour by default). An extension that will wake its session later, such as a running background job or a supervised child session, keeps it alive by reporting its pending total:

```typescript
pi.events.emit("oppi:pending-wake:v1", { source: "my-extension", count: runningJobs.size });
```

Emit again whenever the total changes, and emit `count: 0` from `session_shutdown`. `source` is a stable name for your extension; each emit replaces that source's previous total. While any source reports a count above zero, the idle timeout waits, and an `--auto-stop` session does not stop when its turn ends (the turn the wake starts stops it). A user's Stop still stops it. Count only work that will actually wake the session; a hold nothing will release keeps the session loaded until someone stops it.

A server restart ends the extension's process and the work inside it. By default, a restart sends an idle session that held such work the same continuation prompt a mid-turn session gets.

- Persist what you started (for example with `pi.appendEntry`) and tell the agent on the next `session_start` with `deliverAs: "nextTurn"`, as `background-jobs` does. That turn explains what was lost.
- Pass `survivesRestart: true` if your extension re-arms its wait on `session_start`, as `subagents` does, so the restart does not prompt.
- Report queued notices with `lost: <count>` next to `count` from `session_start`, and `lost: 0` once a turn starts (`agent_start`). After any restart, including a crash, Oppi sends the continuation prompt to a resumed session that reports `lost` above zero. `lost` does not hold the idle timeout; after a Stop, the user's next message carries the notice.

Durable sessions do not use this channel: their background jobs and subagent reports hold the idle timeout and recover on their own.

## Reference extension examples

`pi-extensions/*` packages are copyable examples, not Oppi product features, and installing Oppi does not enable them. Link a package into `~/.pi/agent/extensions/` or run `pi -e ./pi-extensions/<name>`.

| Package | Registers | Behavior |
| --- | --- | --- |
| `ask` | `ask` | Multiple questions, `multiSelect`, custom answers. Uses `ctx.ui.ask()` (native AskCard) in Oppi, `ctx.ui.custom()` in terminal Pi, and `select()`/`input()` elsewhere. `ctx.ui.ask()` is Oppi-defined, so the extension checks for it first. |
| `subagents` | `subagent` | A launch returns at once; one async `oppi session wait` per parent updates the widget (Done when idle, Needs attention on a pending dialog). Supervised launches start a parent turn on settle or attention and otherwise check in about every 4 minutes to keep the prompt cache warm. Durable sessions have a built-in `subagent` tool and do not need it. |
| `background-jobs` | `background_job` | A shell command still running after 15 seconds, or ending in `&`, becomes a job shown in the composer pill, and its output arrives as a follow-up. Polling a running job is blocked. It reports through the [pending wake API](#pending-wake-extension-api) and keeps the final turn open unless `oppi session get` confirms the session does not auto-stop. A job that dies with its process (restart, reload, Stop) is reported once with the next turn and is not rerun. |
| `browser-automation-video` | A browser tool | Records WebM with `agent-browser`, converts it to H.264 MP4, stores it with `ctx.attachments.addFile()` when available, and returns it in `details.media[]`. |

Oppi loads no `ask` tool of its own. Install or enable an extension named `ask` when a workspace or Pi Control session needs one.

## Tool-row rendering

Oppi iOS does not run Pi's TUI `renderCall()` and `renderResult()` hooks. A tool row uses the first source that applies:

1. Oppi's built-in mobile renderers.
2. Collapsed-summary sidecars in `~/.pi/agent/mobile-renderers/*.ts`.
3. Server-provided `StyledSegment[]` summaries.
4. Generic rendering from `content` and `details`.

Expanded output uses this order: `details.expandedText` with `presentationFormat`; the tool's text parsed as JSON (including a text preamble before JSON), a unified diff, Markdown, or fenced plain text; structured `details` when text is empty; then a waiting status while the tool runs. JSON objects become form tables in key order, and other arrays become lists. Double-tap a row to open the full-screen reader, whose **Rendered / Raw** toggle keeps all arguments and the available full output under **Raw**. Generic rows show **Input**, optional **Calls** (Pi's recorded nested calls with status, duration, and errors), and **Output**.

A sidecar is a default-exported object keyed by the exact Pi tool name (`functions.bash` does not inherit facts from `bash`). Each entry gives short collapsed summaries and optional semantic facts:

```typescript
export default {
  put_file: {
    inputPresentation: { fields: { target: { role: "filePath" }, payload: { role: "fileContent" } } },
    outputPresentation: { kind: "fileContent", provenance: "requested" },
    renderCall(args) {
      return [{ text: "store ", style: "bold" }, { text: String(args.target ?? ""), style: "accent" }];
    },
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

| Fact | Values and effect |
| --- | --- |
| Segment `style` | `bold`, `muted`, `dim`, `accent`, `success`, `warning`, or `error`. Invalid segments are dropped and logged. Put rich output in `details.expandedText`, not summary lines. |
| `inputPresentation.fields.<name>.role` | `code` (with `language`), `command`, `filePath`, `fileContent`, or `edits` (an array of `{ oldText, newText }`). Optional `lineOffset` and `lineLimit` fields describe one-based read ranges. File roles need no language. |
| `outputPresentation.kind` | `terminal` (the same command panel and terminal viewport as `bash`), `fileContent`, `diffOfEdits`, or `interactive`. Unknown kinds degrade to structured output. |
| `outputPresentation.provenance` | `requested` (input content) or `result` (tool-result content) for file kinds. |
| `outputPresentation.settingEffect` | `voiceReplyMode` is honored only with a valid successful `details.kind: "voice_reply_mode"` and `mode`; result details alone cannot grant setting authority. |

- Explicit `details.outputPresentation` wins over the static declaration. `details.expandedText` also wins: `presentationFormat: "terminal"` keeps terminal semantics and other formats select the generic document.
- `kind: "interactive"` declares the question and answer lifecycle that built-in `ask` uses. `details.questions` and `details.answers` supply the answer receipt; the fact creates no prompt, so use `ctx.ui.ask()` for that. Interactive tools stay out of automatic expand-all and emit one answer message per call.
- Built-in `read` declares result file content, `write` requested file content, and `edit` result diffs; the same facts work for any exact tool name. A successful requested-file-content row offers **Open Current File**, which reads the file as it is now.
- Every result carries `outputAvailability: { complete, totalBytes?, source? }` derived from Pi's `details.truncation` and `details.fullOutputPath`. `source: "sidecar"` lets the reader load full output by tool-call ID, including in stopped sessions; the fact never contains the private path.
- Sidecars declare semantics, not symbols or views. Generic tools keep the default glyph.
- Oppi shows MCP tools as `group · Title` from the live tool label and namespace, then result `details.server` and `details.tool`, then Pi's `mcp__<server>__<tool>` naming. MCP-provided titles and icons are not shown. Input and Raw keep raw tool names.

Mirror mode sends the same semantic request payloads from a terminal Pi process; its first-wins dialog behavior is in the [compatibility matrix](oppi-mirror.md#extension-ui-compatibility-matrix).

## Durable extensions

Durable sessions (`experimental.serverDurable`) do not run a package's classic `index.ts`. A package adds a durable entry and declares it in `package.json`:

```json
{
  "name": "release-notes",
  "pi": { "extensions": ["./index.ts"] },
  "oppi": { "durable": { "entry": "./durable.ts", "runtimes": ["host"] } }
}
```

- `entry` is a path inside the package starting with `./`. A `.js` path whose file is missing finds its `.ts` source.
- `runtimes` lists `"host"`, `"sandbox"`, or both; it defaults to `["host"]`. Add `"sandbox"` only if every command and file access goes through `api.env`.
- A package without `oppi.durable` has no durable entry. An invalid manifest (unknown keys, a missing file, an unknown runtime) is a load error.

The entry's default export is a plain pi-durable extension, or an array of them:

```ts
// ~/.pi/agent/extensions/release-notes/durable.ts
import { Type } from "typebox";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";

export default defineExtension({
  name: "release-notes",
  tools: [
    defineTool({
      name: "release_notes",
      description: "Read the latest release notes.",
      parameters: Type.Object({}),
      replay: "safe", // a read; rerun after a crash
      async execute(_args, api, context) {
        const result = await api.env!.exec("cat CHANGELOG.md", {}, context);
        return { output: [{ type: "text", text: result.ok ? result.value.stdout : result.error.message }] };
      },
    }),
  ],
});
```

An extension that shows Oppi UI imports it from `oppi/durable`: `requestUI` for dialogs, and the `DurableUI` and `DurableInputCards` documents for status, widgets, and transcript cards.

- **Where Oppi looks:** enabled user-scope Pi packages, resolved as Pi resolves classic extensions (`~/.pi/agent/extensions/<name>/`, packages from `settings.json` and `pi install`, the same enable and disable settings). Project `.pi/extensions` packages and single-file extensions have no durable entry.
- **Shared modules:** `@earendil-works/pi-durable`, `@earendil-works/chord`, `@earendil-works/pi-ai`, `typebox`, and `oppi/durable` resolve to the server's own copies, so your documents and tasks belong to the server's durable store. Ship the entry and every file it imports in the package's `files`.
- **Which sessions get it:** every durable session whose runtime the extension lists, next to the built-in tools. The durable control conversation selects none. A name, tool name, or task name another extension already uses is refused, as are an extension with two tools or two sections of one name and a section key pi-durable does not accept. A package that provides one of Oppi's own durable extensions (such as `ask`) is skipped.
- **Loading:** when the server opens its durable store, and on `oppi extensions reload`. A package that fails to load or install is reported in the server log and the reload output; the others load, and no user package can keep the durable runtime from opening.
- **Reload without a restart:** `oppi extensions reload` re-reads every durable entry and the files it imports, Oppi's bundled ones included. An installed extension is replaced in place: a running tool call finishes on its old code, and the next call uses the new code. A package that fails to load keeps its previous code. A package that is gone is uninstalled. A session picks up a newly added extension the next time it attaches (open, resume, or server restart).
- **Turn one off:** `oppi extensions list` shows every durable extension, Oppi's built-ins (such as `sql-explorer`) included, and whether it is on. `oppi extensions disable <name>` leaves it out of durable sessions without uninstalling it, and `oppi extensions enable <name>` brings it back (stored as `experimental.durableExtensions.disabled`; no restart). New sessions follow at once and an open session the next time it attaches. A saved Agent session that selected a disabled extension starts without it, shows a session warning, and keeps running without it after you enable it again; start the Agent anew to get it.
- **Trust:** the code runs in the Oppi server process with your permissions, like a classic extension. It is not sandboxed, even for sandbox sessions.
