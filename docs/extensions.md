# Oppi extension behavior

What Oppi loads for a session, which Pi extension rules Oppi adds, and how to make an extension work well on a phone. For the extension API itself (package layout, lifecycle hooks, tools, TUI rendering), use Pi's docs:

- [Pi extensions](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) and [Pi packages](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md)
- Pi examples: `@earendil-works/pi-coding-agent/examples/extensions/`

Related: [Extension native UI](extension-native-ui.md) (prompts, widgets, native blocks) and [Attachment rendering](attachment-rendering.md) (images, audio, video).

## What Oppi loads

Pi owns skills and extensions. Oppi resolves them for the session's working directory through Pi's resource system. A host workspace has no extension allowlist, and Oppi never runs `pi install` or enables anything in standalone Pi by itself. Installing Oppi does not install a Pi extension package. Oppi writes `~/.pi/agent/settings.json` only for the Extensions toggles you flip. The shipped [Auto-Name](#auto-name) package shows in the Extensions lists without an entry there; turning it on adds one, and turning it off or `oppi uninstall` removes it.

Pi's normal sources are auto-discovered directories (`~/.pi/agent/extensions/`, `.pi/extensions/`), `extensions` paths in `settings.json`, and packages installed with `pi install`.

A sandbox session loads these only by opt-in, because their code runs on the host ([Host extensions](sandbox.md#host-extensions)). A Pi package whose classic extensions act on nothing of the host, such as one whose only tool asks the user, declares `"oppi": { "classicRuntimes": ["host", "sandbox"] }` in its `package.json` and loads in sandbox sessions without one. It defaults to `["host"]`. A single-file extension has no package, so it stays host-only, and so does a package inside the sandbox's workspace folder.

Oppi adds a lifecycle-journal extension and Pi's built-ins to each managed session, plus two tools only when they apply: `notify` for top-level sessions while a device has push on for the server ([Push notifications](server-configuration.md#push-notifications)), and `speak` while a Live Voice call is attached. `notify` comes from the built-in `oppi-notify` plugin, which is on by default; turn it off from its row in **Server Settings → Extensions** or with `oppi extensions disable oppi-notify`, in durable and classic sessions alike. A plugin of your own can send the same push through `oppiHost().notify` ([Plugins](#plugins)). Pi's built-ins by session:

| Session | Built-ins loaded |
| --- | --- |
| Managed host | `mcp`, `codemode`, `tool-search` |
| Managed sandbox | `mcp`, `tool-search` (no `codemode`) |
| Durable (host and sandbox) | Durable versions of `mcp`, `codemode`, and `tool_search`, and plugins instead of Pi's extensions ([Plugins](#plugins)). An Agent's exact selection keeps `codemode` only with `builtin:codemode`. |
| Oppi Mirror | None; the terminal's own Pi loads its built-ins |

`-builtin:<name>` in Pi settings, an Agent's exact extension selection, or another extension that registers the same tool, command, or flag can leave a built-in out ([MCP, codemode, and tool search](server-configuration.md#mcp-servers-codemode-and-tool-search)). A Pi extension can register a tool named `oppi`; Oppi does not reserve that name.

Workspace Settings → Skills and Extensions toggles write Pi resource settings: `+path` enables a resource that is otherwise filtered out, `-path` disables one Pi would load, and package resources use the same filtering inside the package entry. Temporary resources cannot be edited from Oppi. Sandbox workspaces also have a `workspace.tools` allowlist for VM-backed tools only.

## Oppi Control sessions

An Oppi Control session is the workspace-less session Oppi opens for **Edit with Oppi** and the create composers ([Using Oppi](usage.md#edit-with-oppi)). Each request starts a new one; the target, the request, and any staged review comments are its first message. It runs on the server's durable engine on every server, with or without `experimental.serverDurable`, and opens in the regular chat. A server restart resumes it.

- **Prompt:** Oppi's own setup prompt, which describes Oppi's surfaces and points at these docs, and the [Mobile Output Guide](#mobile-output-guide) while it is on. It does not load your global `SYSTEM.md`, `APPEND_SYSTEM.md`, `AGENTS.md`, or Skills, and no project context.
- **Oppi tools:** one tool per Oppi action (`agents_list`, `agents_create`, `schedules_run`, `sessions_send`, `workspaces_get`, …) and `oppi` for any other CLI command. pi-durable's `codemode` runs scripts that call the same tools as `tools.<name>(…)`; a script resumes after a server restart without rerunning finished calls. Read tools only read.
- **Confirm cards:** every write through the Oppi tools waits for a confirm card that says in plain words what changes: a title with the action and the item by name (`Change Agent “QA reviewer”?`), a one-line summary, each field with its old and new value (long text, and the message a write sends, as a text block or line diff; every value is shown as code, never as formatting; characters a screen cannot show, such as invisible Unicode tag characters, appear as a counted marker like `⟨45 hidden characters⟩`, and a warning says how many it shows that way, while ordinary emoji show whole; a value is never cut short), a plain warning when an update has no expected version or the current record could not be read, and last the method and path. The card comes from the request the server is about to send and the records it read, never from the model's description. A direct call offers the action's own button (**Apply Change**, **Create Agent**, **Run Schedule**, …) or **Cancel**; inside a codemode script the card also offers **Apply All in This Script**. No setting skips it. A cancelled card sends nothing.
- **Host tools:** `read`, `bash`, `edit`, and `write`, for Skills, extensions, themes, Pi's global configuration, and `oppi config` and `oppi dictionary`. The session runs as the server's host user. These get no card: the prompt tells the session to say what a file edit changes and to show a command that writes and wait for your yes, which is an instruction to the model, not an enforced confirmation. `bash` can run any command, the `oppi` CLI included.
- **Not loaded:** Pi extensions, MCP servers, and your plugins. `ask`, `codemode`, and the tools above are the whole set.

No other session gets the Oppi tools.

Older iOS builds keep working: `POST /control-sessions` accepts their `domain`, `intent`, `targetId`, and `targetName` fields and starts an Oppi Control session.

## Mobile Output Guide

**Server Settings → Mobile Output Guide** (off by default) tells agents when to link and embed files and which Markdown Oppi renders: wiki links to workspace and host files, inline images, audio, video and USDZ, session links, Mermaid diagrams, maps, supported math, linked files that open in rendered viewers, and the forms that stay plain text. Its full text is in [Document viewers](document-viewers.md#agent-instructions); embeds are in [Attachment rendering](attachment-rendering.md).

- It applies to new and reloaded managed host and sandbox sessions and Oppi Control sessions, on either engine. It does not prescribe response style, fabricate paths, or expose secrets, and Oppi sends no viewport dimensions.
- It is an append, so a global `SYSTEM.md` replacement does not suppress it. It comes last among Oppi's appends: after the Oppi docs hint, the `oppi` CLI hint, and the workspace prompt. A saved Agent whose instructions replace the system prompt does not get it.
- It does not change standalone Pi or terminal-owned Mirror sessions. A stopped Mirror session reads the current guide only if you promote it to Oppi-managed.

## Prompt hints

Oppi adds nothing to a session's prompt unless you turn it on. Besides the Mobile Output Guide, two switches in **Server Settings** add one short hint each to new and reloaded managed host sessions:

- **Oppi Docs Hint** (`oppiDocsPrompt`) names the folder of Oppi's packaged docs, so an agent can answer questions about Oppi from them.
- **Oppi CLI Hint** (`oppiCliPrompt`) tells an agent how to list, start, message, and stop other sessions with `oppi session`.

Both are off on a new server. A server that ran an earlier version had both on, and keeps them on after the update; the first start saves that as its setting. Sandbox sessions, Oppi Control sessions, and terminal-owned sessions never get them. `oppi config set oppiDocsPrompt.enabled true` sets one from the host.

A workspace's own prompt (**Workspace Settings → Instructions**) and a saved Agent's instructions are text you wrote, and are always sent. Tools that Oppi offers carry their own descriptions and guidelines, as every tool does; turning the tool's feature or extension off removes them. In durable sessions, the `godot_*` tools and their guideline follow the **Godot Pane** feature switch.

## When a change takes effect

- A new managed session uses the latest Mobile Output Guide setting. An active session keeps its prompt resources until `/reload`, which rebuilds it through Pi's full `AgentSession.reload()` (extensions, skills, prompts, themes, system-prompt files, and the guide) before the next turn.
- The server's model picker and provider-auth list rescan provider extensions when `~/.pi/agent/settings.json` changes, when files under `extensions/` change (one nested directory level included), when npm or git package metadata changes, and right after an extension is enabled or disabled. No restart is needed. The rescan never runs `npm install` or `git clone`, so a package listed in settings but not installed stays out of the picker. Active sessions keep their model runtime until `/reload` or a new session.

## Skills and Extensions pages

The server's **Skills** and **Extensions** destinations show and change Pi's user-scope defaults, following `pi config` semantics: toggles preserve Pi's ordered `+path`, `-path`, `!pattern`, and package-filter rules. Workspace Settings stay the authority for project overrides, so a server default is not a claim about every workspace.

The **Skills** page groups the catalog by **Needs Attention**, **Enabled**, and **Disabled**, and its search filters by name, description, package, and source as you type. A Skill's page has its server default switch, where it comes from, Pi's findings, and **Browse Files**: each folder is a page of its own, and a file opens in the file viewer, with the editor and **Edit with Session** for an editable Skill's own files. The page is drawn from what the server sends, so it needs a server of the same release, and it shows nothing saved while the server is unreachable.

The catalog has no working directory. It lists Pi-native user candidates from `~/.pi/agent`, `~/.agents/skills`, configured user settings, and configured packages, and it never installs packages. Provenance and enabled state come from Pi. Resource IDs are opaque and path-derived, so a moved resource can get a new ID. Disabled extensions stay visible but are not executed, so a disabled row shows no load error or contributed tools; enabled ones can show Pi loader diagnostics and contributed tools or commands.

The server's extension list (`oppi extensions list`) also has its [plugins](#plugins), Oppi's built-ins included. A Pi package with a plugin is one row under its classic extension's ID; a plugin without a classic extension has a row of its own, listed only for clients that ask for plugin rows, so an Agent's extension picker never offers one. A plugin's row names its tools, hooks, prompt sections, wraps, and tasks, whether it is required, and why it failed to load; when a reload failed and its previous code still runs, the row says so.

The app's **Extensions** page lists the same rows. Oppi's own plugins sit under **Built into Durable Sessions**, and one the durable runtime needs reads **Always on**. Every other row is marked **Plugin**, **Pi extension**, or both, and **Built-in** where it applies, and a row that is turned off shows an outlined mark. A row that failed to load is under **Needs Attention**, and its page shows the error first. An extension's page has an **About** card: its type, where it comes from (with its path), and, for a plugin, where it runs. **Tools** lists each tool with the first line of its description; a Pi package that is also a plugin lists its durable-session tools and its Pi-session tools apart. A tool opens a page with its description, its parameters, its full JSON Schema, and, for a Pi extension's tool, the prompt snippet and guidelines Pi adds while the tool is active. **Prompt Sections** lists a plugin's sections. A section whose text is the same in every conversation opens in the reader as the plugin writes it, before another plugin's wrap can change it; a section written for each conversation says so and opens nothing ([how the page reads a section](#plugins)). Hooks by task, wraps, and tasks follow. **Reload** (the bar button) runs `oppi extensions reload` and shows what loaded, what kept its previous code, what was removed, and what failed, under **Last Reload**.

The workspace **Extensions** picker starts from the extensions Pi resolves for the session's folder, also scans global and project `.pi/extensions` so newly copied files appear, and names them as follows:

- Files must end in `.ts` or `.js`; `.test` and `.spec` files are ignored.
- Package entries use the package identity (`npm:@tintinweb/pi-subagents` shows as `tintinweb-subagents`); `extensions/foo/index.ts` shows as `foo`.
- Duplicates resolve by Pi's resource-loader precedence. Extensions named `ask` are allowed.
- A toggle only applies to resources Pi resolves; a scanned file Pi cannot match fails with `Pi resource not found for cwd`.
- For a host folder, the picker shows its [project trust](server-configuration.md#project-trust-in-managed-host-sessions). A `distrusted` folder lists no project-local extensions or settings and refuses toggles, because Pi ignores the project settings a toggle would write. An `ask` folder lists them, because an unanswered session prompt allows them.

## Auto-Name

`auto-name` is a Pi extension that names an unnamed session from its first message: a small model writes a 2–6 word title and the extension calls Pi's `setSessionName()`, which Oppi lists and shows like any other name. It replaces the built-in **Auto-Name** setting and works in terminal Pi, Oppi sessions, and durable sessions. It never renames a session that has a name (yours, one given at creation such as `oppi session create --name`, or another extension's), titles only a session's first message, and when no title can be made (no model, no credentials, a 15-second timeout) leaves the session unnamed and logs the reason once.

Oppi ships the package in its npm install, at `plugins/auto-name` next to the server's `src`. It shows as `auto-name` in the sidebar's **Extensions** page, off until you turn it on. While it is off, Pi's settings do not list it, so terminal Pi does not see it.

- **On and off:** turn it on or off with the **Enabled** switch on the `auto-name` page, opened from **Extensions** in the sidebar (every session, durable ones included; the server reloads durable extensions for you) or, for classic sessions, in a workspace's **Extensions** list (that workspace only). Turning it on in the sidebar adds the package to Pi's user settings with its extension on, so terminal Pi titles sessions too; turning it off removes that entry. A workspace's switch writes that folder's `.pi/settings.json` instead. In terminal Pi it follows `pi config`. Durable sessions load user-scope packages, so a workspace's list does not change them.
- **Off entries:** an entry that turns the extension off loads nothing, so `oppi serve` removes one at start. Older servers listed the package that way at their first start.
- **Model:** `~/.pi/agent/auto-name.json` holds `{ "model": "provider/model-id" }`, read for each title. Without it the extension uses the cheapest small model of the session's provider: an id with `haiku`, `flash`, `mini`, `nano`, `lite`, or `small` as a whole part, non-reasoning first. On OpenRouter it stays with the session model's vendor, so a Claude session does not title through another vendor's model, and `:batch` variants are skipped. With no small model it uses the session's own. OpenAI Codex subscription models cannot answer a plain completion, so a Codex session names nothing by default and logs once that you should set `auto-name.json` (for example `{ "model": "anthropic/claude-haiku-5-5" }`). A configured model that is not available names nothing too; there is no silent fallback to a model you did not choose. A title is one request of about 30 output tokens to that provider, so it follows the same [privacy boundary](privacy.md#model-providers-and-server-extensions) as the session's other model calls.
- **If the install moves:** the entry points into the install. At each start, a listed copy whose path is gone (a Node version switch under nvm, a reinstall elsewhere) is pointed at the current install.
- **Your own copy:** a package you linked yourself into `~/.pi/agent/extensions/auto-name` is the same extension, so Oppi lists nothing beside it, and if Oppi had already listed its copy, the next start removes that entry so one copy loads.
- **Upgrading from the built-in setting:** if `config.json` had `autoTitle.enabled: true` with a model, the first start on the new version keeps that behavior. Any command that loads the config (`oppi config get`, `oppi pair`, `oppi serve`) first copies `config.json` to `$OPPI_DATA_DIR/backups/config-pre-auto_title_to_extension_v1-<time>.json`, removes `autoTitle`, and notes its model; if the copy fails, the config does not load. The next `oppi serve` writes the model to `auto-name.json` (keeping a file that is already there) and lists the package **on**. `autoTitle` that was off, or on without a model (which titled nothing), is only removed. Update the app and the server together: an older app opens a Settings page for the removed `/server/auto-title` endpoints and gets an error.

## Cached compaction

`cached-compaction` is a built-in plugin, off until you turn it on, that makes a durable session's compactions read the provider's prompt cache. Durable sessions only; classic sessions and terminal Pi keep Pi's own compaction.

Without it, a compaction sends the model a new request: a summarizer prompt and the older part of the conversation written out as one message, with caching off. The provider bills every token of that part as new input, even when it cached the same conversation a minute earlier. With it, while the conversation's cache is still warm, the summary request is the conversation's own last request (the same system prompt, tools, messages, model, and thinking level) plus one instruction to summarize. The provider reads that prefix from its cache, which costs a fraction of new input. The summary keeps pi-durable's format and replaces the same older part, and the recent messages stay as they were.

- **When it applies:** to every compaction of a session that selects it: `/compact`, and the ones pi-durable starts near the context limit. It applies only while the newest answer is younger than 90% of the cache lifetime: an hour when that answer wrote one-hour cache, otherwise five minutes. Older than that, or with caching turned off, the cache is likely gone, so pi-durable summarizes as usual.
- **Only when it is cheaper:** pi-durable's request cuts each tool result to 2,000 characters and leaves out thinking, so for a history made mostly of tool output it can be a small part of the context. Before each compaction the plugin estimates both requests at the model's prices (its cache read and the cache write of the newest answer, against pi-durable's uncached input) and leaves the compaction to pi-durable when that costs less.
- **Fallback:** when the model's reply is not a plain text summary (it calls a tool, stops early, or fails), pi-durable's own summarizer runs. That compaction then pays for both requests.
- **Cost:** the summary request is counted in the session's usage like any other.
- **On and off:** `oppi extensions enable cached-compaction`, or its row in **Server Settings → Extensions**. New sessions get it at once, and an open one the next time it attaches. `oppi extensions disable cached-compaction` turns it off.

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
| `presentationFormat: "org"` | Render `expandedText` as Org (TODO states, priorities, tags, dates, links), read-only |
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

Oppi stops a session idle for the configured idle timeout (10 minutes by default). An extension that will wake its session later, such as a running background job or a supervised child session, keeps it alive by reporting its pending total:

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

These packages are copyable classic Pi extensions; installing Oppi does not enable them in classic sessions or terminal Pi. `ask`, `subagents`, `background-jobs`, and `auto-name` live with their durable plugins in `server/plugins/<name>`, the others in `pi-extensions/<name>`. Link a package into `~/.pi/agent/extensions/` or run `pi -e <path>`.

| Package | Registers | Behavior |
| --- | --- | --- |
| `ask` | `ask` | Multiple questions, `multiSelect`, custom answers. Uses `ctx.ui.ask()` (native AskCard) in Oppi, `ctx.ui.custom()` in terminal Pi, and `select()`/`input()` elsewhere. `ctx.ui.ask()` is Oppi-defined, so the extension checks for it first. |
| `subagents` | `subagent` | A launch returns at once; one async `oppi session wait` per parent updates the widget (Done when idle, Needs attention on a pending dialog). Supervised launches start a parent turn on settle or attention and otherwise check in about every 4 minutes to keep the prompt cache warm. Durable sessions have a built-in `subagent` tool and do not need it. |
| `background-jobs` | `background_job` | A shell command still running after 15 seconds, or ending in `&`, becomes a job shown in the composer pill, and its output arrives as a follow-up. In a durable session, the pill shows the latest output line, and tapping it lists the jobs; each one still running shows its live output and **Stop**. The live output stays in server memory and never reaches the model. Polling a running job is blocked. It reports through the [pending wake API](#pending-wake-extension-api) and keeps the final turn open unless `oppi session get` confirms the session does not auto-stop. A job that dies with its process (restart, reload, Stop) is reported once with the next turn and is not rerun. |
| `auto-name` | none | Names an unnamed session from its first message with a small model, in terminal Pi, classic sessions, and durable sessions. Shipped with Oppi and listed off; see [Auto-Name](#auto-name). |
| `browser-automation-video` | A browser tool | Records WebM with `agent-browser`, converts it to H.264 MP4, stores it with `ctx.attachments.addFile()` when available, and returns it in `details.media[]`. |

Oppi loads no `ask` tool of its own. Install or enable an extension named `ask` when a workspace session needs one.

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

## Plugins

Plugins run only in [durable sessions](usage.md#durable-sessions). A classic session, and terminal Pi, run a package's classic `index.ts` and never its plugin. To try a plugin:

1. Turn on **Server Settings → Durable Sessions**, or run `oppi config set experimental.serverDurable true` and restart the server.
2. Put the plugin in `~/.pi/agent/plugins/<name>/` and run `oppi extensions reload`. `oppi extensions list` shows its row, its tools, and any load error.
3. Start a durable session: in Quick Session, tap the **Classic** pill to make it **∞ Durable**, or run `oppi session create --workspace <id> --prompt <text> --engine durable`.

A plugin follows the layout of [Chord's plugin guide](https://github.com/earendil-works/pi/blob/main/packages/chord/docs/plugin-authoring.md): a folder with a `package.json` whose `name` is the plugin's, and a `server.ts` whose default export is a facet. The facet contributes one durable extension to Oppi's `Extensions` registry. One folder can hold both entries of a feature, with shared code next to them:

```text
my-feature/
  package.json   { "name": "my-feature", "pi": { "extensions": ["./index.ts"] } }
  server.ts      the plugin (durable sessions)
  index.ts       the classic Pi extension (classic sessions, terminal Pi)
```

The tools, tasks, hooks, and documents a plugin defines are pi-durable's. The [pi-durable README](https://github.com/earendil-works/pi/tree/main/packages/durable#readme) is their reference: [Tools](https://github.com/earendil-works/pi/tree/main/packages/durable#tools), [Environment](https://github.com/earendil-works/pi/tree/main/packages/durable#environment) for `api.env`, and [Your Own State](https://github.com/earendil-works/pi/tree/main/packages/durable#your-own-state) for `defineDoc`, `api.commit`, and `api.snapshot`, with its full [state example](https://github.com/earendil-works/pi/blob/main/packages/durable/test/examples/10-extension-state.ts).

### Example plugins

Oppi ships four example plugins. They are real built-ins that you can read, run, and copy, and they are off until you turn them on:

| Plugin | What it shows | Source |
| --- | --- | --- |
| `example-release-notes` | A tool that runs a command through the session's environment and returns its output. | [server/plugins/example-release-notes](https://github.com/duh17/oppi/tree/main/server/plugins/example-release-notes) |
| `example-bookmarks` | Two tools that keep their state in a durable document, which survives a server restart. | [server/plugins/example-bookmarks](https://github.com/duh17/oppi/tree/main/server/plugins/example-bookmarks) |
| `example-board` | A panel: a pill and a drawer, with a **Done** button that saves to a document. Each chat has its own board, and the panel returns after a server restart. The whole plugin is printed in [A panel plugin](extension-native-ui.md#a-panel-plugin). | [server/plugins/example-board](https://github.com/duh17/oppi/tree/main/server/plugins/example-board) |
| `example-shelf` | A panel of [tiles](extension-native-ui.md#tiles): the files a chat wrote, its subagents, and its game, each opening in the panel's pane. It has no tool; a hook draws it again after each round of tool calls. | [server/plugins/example-shelf](https://github.com/duh17/oppi/tree/main/server/plugins/example-shelf) |

Turn one on with `oppi extensions enable example-bookmarks` (or `example-release-notes`, `example-board`, `example-shelf`), or with its row in **Server Settings → Extensions**. New durable sessions get it at once, and an open one the next time it attaches. `oppi extensions disable <name>` turns it off again.

To start your own plugin from an example, copy its folder to `~/.pi/agent/plugins/<your-name>/`. Then rename the package, the extension, its tools, and any document `kind`. A built-in keeps its names even while it is off, so a copy that keeps them fails to load.

### Types

`oppi/v1` and `oppi/v1/schema` ship their types in the `oppi-server` package. To type-check a plugin, install the package in the plugin's folder under the name `oppi`, at your server's version (`oppi --version`):

```bash
npm install --save-dev oppi@npm:oppi-server@<version>
```

Use Node's module resolution in `tsconfig.json`, and `"type": "module"` in `package.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  }
}
```

Then `npx tsc` checks every `import … from "oppi/v1"`. The installed copy is for the type checker only: when the server loads the plugin, it hands the plugin its own `oppi/v1`. CI type-checks the example plugins this way, from a folder outside the repository.

This is the core of `example-release-notes`. `api.env.exec()` resolves to the exit code only: the command's output arrives in `onOutput` chunks.

```ts
const releaseNotes = defineTool({
  name: "example_release_notes",
  description: "Read the latest release notes: the top of CHANGELOG.md in the working directory.",
  parameters: obj({ lines: opt(num()) }),
  replay: "safe", // a read: safe to run again after a restart
  async execute(args, api, context) {
    if (!api.env) throw new Error("No execution environment is available.");
    let text = "";
    const result = await api.env.exec(
      ["head", "-n", String(args.lines ?? 60), "CHANGELOG.md"],
      { onOutput: (chunk) => (text += chunk) },
      context,
    );
    if (!result.ok) return { output: [{ type: "text", text: result.error.message }], isError: true };
    return { output: [{ type: "text", text }], isError: result.value.exitCode !== 0 };
  },
});

export default defineFacet((_host, self) =>
  self.contribute(Extensions, defineExtension({ name: "example-release-notes", runtimes: ["host", "sandbox"], tools: [releaseNotes] })),
);
```

### Plugin state

A plugin keeps state in a pi-durable document. `example-bookmarks` defines one and writes it in a commit:

```ts
const Bookmarks = defineDoc<{ items: Bookmark[] }>({
  kind: "oppi.example.bookmarks",
  version: 1,
  scope: "session", // one list per Oppi chat
  initial: () => ({ items: [] }),
  checkpointWhen: () => false, // required
});

// In a tool's execute():
await api.commit(async (tx) => {
  (await tx.doc(Bookmarks)).items.push({ url: args.url, title: args.title ?? args.url, addedAt: api.now() });
}, context);
```

The store and its scopes map to Oppi like this:

- Each durable chat has its own durable store, which is one pi-durable Session. A `scope: "session"` document is per chat: the chat's conversations share it, including its forks and the subagents it starts. Another chat has its own copy and starts from `initial`.
- A `scope: "conversation"` document is per conversation within the chat.
- No document scope is shared across chats. To share state between chats, write a file of your own (through `api.env` or Node's file APIs).
- A document change is stored with its commit, so it survives a server restart. A plugin needs no save code.
- `checkpointWhen` is required, and a definition without it fails only at the first write.

- `oppi/v1` is Oppi's plugin API: `defineFacet`, the `Extensions` registry, pi-durable's authoring API (`defineTool`, `defineTask`, `hook`, `section`, `defineDoc`, …) and Oppi's host API below. `oppi/v1/schema` is pi-schema's builders.
- `defineExtension` takes `runtimes`: `"host"`, `"sandbox"`, or both; it defaults to `["host"]`. Add `"sandbox"` only if every command and file access goes through `api.env`.
- A package lists several plugins in `"chord": { "plugins": ["./a", "plugins/*", "!plugins/draft"] }` (paths, globs, `!` exclusions). A listed folder may be a link; one that leads out of the package is refused. A file `<name>.server.ts` directly in `~/.pi/agent/plugins/` is a single-file plugin.
- A Pi package is found through its classic entry, so a plugin with no `index.ts` (no `pi.extensions`) belongs in `~/.pi/agent/plugins/`. A Pi package is a plugin only when its top has a `server.ts` or its `package.json` lists `chord.plugins`; a classic-only package is skipped without a message, and one that still declares the old `oppi.durable` manifest is reported until it gets a `server.ts`.

A plugin that shows Oppi UI imports it from `oppi/v1`: `requestUI` for dialogs, `surface()` for panels ([A panel plugin](extension-native-ui.md#a-panel-plugin)), and the `DurableUI` and `DurableInputCards` documents for status, widgets, and transcript cards. A hook or task that only needs the Oppi Session id of its own conversation (for a link, say) reads `(await api.snapshot(DurableSessionDoc, api.conversationId, context))?.sessionId`, with `DurableSessionDoc` from `oppi/v1`. One that also reads or sets the Session's name calls `await oppiHost().sessionName(api, context)` for its `sessionId`, `get()` and `set(name)`, as `auto-name` does from a generation hook. It names the Session of the conversation `api` is for and takes no Session id, so an extension cannot name another Session by mistake; extension code is trusted like the rest of the server process, and the host cannot tell a hand-built `api` from pi-durable's.

`await oppiHost().sessionActivity(api, context)` reads, the same way, what that Session has done. It only reads; nothing in it changes the Session. It resolves to `{ sessionId, changedFiles, children }`: `changedFiles` are the files its `edit` and `write` calls named, as plain paths inside its working folder (at most 100; a path outside the folder is left out), and `children` are its subagent Sessions, oldest first, each `{ id, name? }`. It resolves to `undefined` for a conversation without a Session.

A hook or task has no `api.env` for `oppiHost().surfaces(env)`. `await oppiHost().sessionSurfaces(api, context)` returns the same surface loop for the Session the conversation is for, or `undefined` while it has no live Session; `example-shelf` publishes through it after each round of tool calls.

A tool sends a push to your devices with `oppiHost().notify(api.env)`, the same send behind Oppi's `notify` tool. It returns a function that takes `{ title, body }` and resolves to a `NotifyOutcome` (both types are in `oppi/v1`), or `undefined` when the conversation has no Oppi Session. The push goes out under the same rules as `notify`: only for a top-level session while a device has push on (`{ status: "off" }` otherwise), at most once a minute per session across all plugins (`throttled`), and with the title and body cut to fit ([Push notifications](server-configuration.md#push-notifications)). This works whether `oppi-notify` is on or off, so you can turn Oppi's tool off and offer your own.

```ts
const ping = defineTool({
  name: "ping_me",
  description: "Send the user a push notification.",
  parameters: obj({ title: str(), body: str() }),
  async execute(args, api) {
    const send = oppiHost().notify(api.env);
    const outcome = send ? await send(args) : { status: "off" as const };
    return { output: [{ type: "text", text: outcome.status }], details: outcome };
  },
});
```

- **Where Oppi looks:** its built-in plugins first, then yours: `~/.pi/agent/plugins/`, and the enabled user-scope Pi packages, resolved as Pi resolves classic extensions (`~/.pi/agent/extensions/<name>/`, packages from `settings.json` and `pi install`, the same enable and disable settings). A saved Agent that selects a package's classic extension gets its plugin in a durable session. Project `.pi/extensions` packages are never loaded.
- **Shared modules:** `oppi/v1`, `oppi/v1/schema`, `@earendil-works/pi-durable`, `@earendil-works/chord`, `@earendil-works/pi-ai`, and `@earendil-works/pi-schema` resolve to the server's own copies, so the server's durable runtime knows your documents and tasks. Ship `server.ts` and every file it imports in the package's `files`.
- **Tool schemas:** build them with pi-schema's builders (`obj`, `str`, `opt`, ...). An `obj()` rejects arguments it does not declare, and the model sees which field was unknown; pass `{ open: true }` to accept others.
- **Which sessions get it:** every durable session whose runtime the extension lists, next to the built-in tools. A sandbox session also gets a host-only one when the workspace's `sandboxConfig.hostExtensions` lists its classic extension's ID, or a saved Agent you start selects it ([Host extensions](sandbox.md#host-extensions)). Oppi Control sessions select none.
- **Clashes:** an extension name, tool name, or task name another plugin already has is a load error for the newcomer: Oppi's built-ins keep theirs, and a plugin already loaded keeps its own. So are an extension with two tools or two sections of one name, a section key pi-durable does not accept, and a tool of Oppi's own (`read`, `bash`, `codemode`, …). A package named like one of Oppi's built-in plugins (such as `ask`, linked from a checkout) counts as that built-in and is skipped.
- **Loading:** when the server opens its durable store, on `oppi extensions reload`, and on `/reload` in a durable session. A plugin that fails to load is reported in the server log and the reload output; the others load, and no plugin of yours can keep the durable runtime from opening.
- **Reload without a restart:** a reload discovers every plugin again and re-reads each `server.ts` and the files it imports, Oppi's built-ins included. Every session on the server shares the new code: an installed extension is replaced in place, so a running tool call finishes on its old code and the next call uses the new code. A plugin that fails to load keeps its previous code, and `/reload` then reports the error. A plugin that is gone is uninstalled. A session picks up a newly added extension the next time it attaches (open, resume, or server restart).
- **Turn one off:** `oppi extensions list` shows the same list as the app's Extensions page: every classic extension and every plugin, Oppi's built-ins included, whether it is a plugin, a Pi extension or both, whether it is on, whether it is required, and why it failed to load. A Pi package with a plugin is one row: turning it off turns off its classic extension in Pi's settings, and its plugin with it. Of the built-ins, `oppi-sql-explorer` (`sql-explorer`), `oppi-godot`, `oppi-mcp-screen`, and `oppi-notify` (`oppi.notify`) can be turned off, and the four [examples](#example-plugins) and [`cached-compaction`](#cached-compaction) ship off; the server needs the others. For a plugin without a classic extension, `oppi extensions disable <name>` leaves it out of durable sessions without uninstalling it, and `oppi extensions enable <name>` brings it back (stored as `experimental.durableExtensions.disabled`; no restart). The ones that ship off are the other way round: `enable` lists them in `experimental.durableExtensions.enabled`, and `disable` removes them. New sessions follow at once and an open session the next time it attaches. A saved Agent session that selected a disabled extension starts without it, shows a session warning, and keeps running without it after you enable it again; start the Agent anew to get it.
- **Trust:** the code runs in the Oppi server process with your permissions, like a classic extension. It is not sandboxed, even for sandbox sessions.
- **Prompt sections on the Extensions page:** to show a section's text, the server calls its `render` once per load, outside any conversation, with an `input` and a `context` that throw on any read. A render that returns a string without reading them shows that string. One that reads them, throws, returns nothing, returns a promise, or returns more than 32 KB shows as written for each conversation. An `async` render is never called, so it always shows as written for each conversation. Keep `render` free of side effects, and never keep `input` or `context`: a kept one throws when your code reads it later. A slow synchronous render blocks the server while it runs, once per load.
