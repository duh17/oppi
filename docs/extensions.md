# Oppi extension behavior

This page explains Oppi's runtime behavior for pi extensions: what Oppi loads, what workspaces can enable, what standalone pi sees, and how terminal-oriented extension UI appears on mobile.

It is for Oppi workspace admins and Oppi developers. It is not an extension-authoring guide. For pi package layout, lifecycle hooks, tool APIs, and terminal UI rendering, use pi's docs instead:

- pi extension docs: `@earendil-works/pi-coding-agent/docs/extensions.md`
- pi package docs: `@earendil-works/pi-coding-agent/docs/packages.md`
- pi examples: `@earendil-works/pi-coding-agent/examples/extensions/`

## Core rule

Oppi server-owned tools live in `server/extensions/` and are enabled per workspace. They are not pi package resources.

Installing or running Oppi server must not write to `~/.pi/agent/settings.json`, run `pi install`, or implicitly enable any extension in standalone pi. Standalone pi only loads what the user explicitly installs or loads with pi.

## Extension surfaces

| Surface | Enabled by | Declared in | Loaded by | Notes |
|---|---|---|---|---|
| Host pi extensions | User/project pi settings, `pi install`, or `.pi/extensions` | User-owned pi config/package paths | pi resource loader | Must work without Oppi server services |
| Oppi built-ins | Workspace `extensions` allowlist | `server/extensions/` | Oppi `SdkBackend` inline factories | Can use Oppi server storage, sessions, and admin APIs |
| `permission-gate` | Oppi server policy | Server-managed, not package-declared | Oppi server | Never loaded from host extension paths |
| Mobile UI compatibility | Native Oppi client + server bridge | Protocol and UI bridge code | Oppi server/client | Maps common `ctx.ui` calls to native cards/dialogs |

This split keeps user consent clear: installing Oppi is not the same thing as installing a pi extension package.

## If we add a pi package later

Pi's standard package model is still the source of truth. A future package can declare resources under the `pi` key:

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

Only put an entry in `pi.extensions` when that extension works in plain pi. Tools that need Oppi storage, session spawning, trace inspection, workspace admin APIs, or mobile-only behavior belong in `server/extensions/`.

If Oppi later ships a standalone package, users must opt in explicitly:

```bash
pi install <package-or-path>
# or temporary for one run:
pi -e <package-or-path>
```

## What Oppi changes

Oppi keeps pi's extension system, then adds these rules:

1. **Built-in workspace extensions**: `ask`, `subagents`, `voice`, and `oppi-admin`.
2. **One server-managed policy name**: `permission-gate`.
3. **Workspace allowlist filtering** through `workspace.extensions`.
4. **Mobile UI compatibility** for common extension UI calls.

Oppi does not replace pi discovery. It filters host-loaded extensions and injects server-owned built-ins when the workspace explicitly enables them.

## How extension loading works

At session startup, Oppi begins with pi's normal extension sources for the session working directory:

- auto-discovered extension directories (`~/.pi/agent/extensions/`, `.pi/extensions/`)
- settings-declared extension paths (`settings.json` `extensions` arrays)
- package-provided extensions installed through pi (`pi install`)

Oppi then filters out server-owned names from those host paths and injects enabled built-ins as in-process factories.

## Reload behavior

`/reload` still reloads host pi extensions, skills, prompts, and themes through pi's resource loader.

Oppi built-ins are server code. `/reload` recreates their inline factory registrations for the active session, but it does not hot-reload edited `server/extensions/*.ts` source files. Changing built-in implementation code requires restarting or rebuilding the Oppi server.

## Oppi-owned names

`permission-gate` is fully server-managed. It is backed by Oppi's policy server and is never loaded from host extension paths.

Oppi also exposes these built-in extension names in the workspace extension picker:

- `ask`
- `subagents`
- `voice`
- `oppi-admin`

A workspace can opt into those names without installing a pi package. That workspace opt-in affects Oppi server sessions only; it does not install anything into standalone pi.

## Workspace allowlist behavior

If a workspace sets `extensions`, that field is authoritative. Only the listed optional extensions are enabled.

That means:

- include `ask`, `subagents`, `voice`, or `oppi-admin` explicitly if you want them
- omitting one of those names disables it for that workspace
- `permission-gate` is not controlled through this list because it is server-managed

If `workspace.extensions` is unset, Oppi keeps normal pi discovery but leaves Oppi built-ins off by default.

## Extension picker behavior

`GET /extensions` is the data source for the Oppi workspace editor. It is not a general-purpose pi reference API.

The picker response:

- resolves host extensions through pi's normal settings and package resolver
- includes auto-discovered global and project-local extensions
- includes package-installed extensions
- includes settings-declared local extension paths
- includes Oppi built-ins (`ask`, `subagents`, `voice`, `oppi-admin`)
- excludes managed names such as `permission-gate`
- deduplicates by extension name using Oppi built-ins first, then pi host extensions

## Mobile rendering differences

Pi's terminal UI uses extension `renderCall()` and `renderResult()` hooks. Oppi iOS does not execute those TUI renderers.

On mobile, Oppi renders tool activity with native timeline rows. Rendering uses this fallback chain:

1. built-in mobile renderers in `server/src/mobile-renderer.ts`
2. optional sidecars in `~/.pi/agent/mobile-renderers/*.ts`
3. server-provided `StyledSegment[]` summaries for the collapsed row
4. generic extension output rendering from tool `content` and `details`

That means an extension can look polished in terminal pi but still look generic in Oppi unless it provides mobile-friendly text, structured details, or a sidecar renderer.

### Generic mobile defaults

For extension tools without a dedicated mobile renderer, Oppi still tries to render useful native output:

- collapsed row title defaults to the tool name plus a compact argument summary
- collapsed rows are treated as compact summaries, not rich output containers
- expanded output renders JSON objects/arrays as formatted JSON
- markdown-looking text renders as markdown
- unified diffs render with the native diff view
- code-like output can render with syntax highlighting when a language hint is present
- otherwise output renders as plain/ANSI text

Extension authors can improve the default expanded view by returning these `details` keys from the tool result:

| Key | Purpose |
|---|---|
| `expandedText` | Text shown in the expanded mobile view instead of raw output |
| `presentationFormat` | One of `markdown`, `json`, `code`, or `diff` |
| `language` | Syntax hint for `presentationFormat: "code"` |
| `filePath` | File path hint for language detection and diff/code metadata |
| `startLine` | Starting line number for code views |

Example:

```typescript
return {
  content: [{ type: "text", text: "Created release notes." }],
  details: {
    expandedText: "# Release notes\n\n- Added mobile extension defaults",
    presentationFormat: "markdown",
  },
};
```

Use `content` for the LLM-facing result. Use `details.expandedText` when the best mobile display text should differ from the concise result text.

### Compatibility policy for terminal-first extensions

Oppi's goal is safe best-effort compatibility with terminal pi extensions. Mobile should show something useful without letting terminal-oriented layouts destabilize the chat timeline.

Rules for mobile compatibility:

- preserve terminal extension behavior where practical
- do not require terminal extensions to ship an Oppi-specific renderer
- keep collapsed tool rows height-stable
- treat rich or multiline output as expanded content, not collapsed row chrome
- prefer structured tool `details` over terminal-rendered snapshots when both exist

If a terminal renderer or mobile sidecar produces multiple lines for a collapsed summary, Oppi uses the first line for the collapsed row and treats the remaining lines as expanded fallback content when no better `details.expandedText` / `presentationFormat` output exists.

Priority for expanded output:

1. `details.expandedText` plus `details.presentationFormat`
2. generic parsing of the tool's text output (`json`, markdown, diff, code hints)
3. sanitized terminal/mobile-renderer snapshot fallback
4. plain text

### Mobile renderer sidecars

Mobile renderer sidecars are compatibility adapters for collapsed timeline summaries. They are not the general extension UI system and should not own rich output rendering.

Current sidecars live in `~/.pi/agent/mobile-renderers/*.ts` and return `StyledSegment[]` for tool call/result summaries. Segment styles are semantic, not raw colors:

- `bold`
- `muted`
- `dim`
- `accent`
- `success`
- `warning`
- `error`

The iOS app maps those semantic styles to the active theme. Sidecars should not choose raw colors.

Durable sidecar contract:

- use sidecars for short collapsed summaries only
- keep summaries single-line whenever possible
- avoid embedding markdown, tables, large JSON, logs, or multiline terminal layouts in summary segments
- put rich readable output in tool result `details.expandedText` with `presentationFormat`
- if a summary contains newlines, Oppi may normalize it for timeline stability

This keeps user-installed terminal extensions broadly compatible while making mobile behavior predictable.

### Persistent extension surface

Oppi maps fire-and-forget extension UI calls to a compact native card above the composer:

- `ctx.ui.setTitle()` → card heading
- `ctx.ui.setStatus()` → status rows
- `ctx.ui.setWidget()` → monospaced widget lines
- `ctx.ui.notify()` → toast/banner
- `ctx.ui.setEditorText()` / `pasteToEditor()` → composer text handoff

This is a native mobile surface, not a terminal footer/header. `setFooter`, `setHeader`, arbitrary `custom()` components, and editor replacement remain terminal-first APIs with limited compatibility behavior in Oppi.

## Relevant implementation files

| File | Why it matters |
|---|---|
| `server/extensions/built-ins.ts` | Built-in and managed-name rules |
| `server/src/routes/skills.ts` | Workspace extension picker (`GET /extensions`) |
| `server/src/sdk-backend.ts` | Extension filtering, built-in injection, and workspace allowlist behavior |
| `server/src/sdk-ui-bridge.ts` | Extension UI bridge from pi APIs to Oppi protocol events |
| `server/extensions/ask.ts` | Built-in ask tool |
| `server/extensions/subagents/` | Built-in subagents toolset |
| `server/extensions/voice.ts` | Built-in voice tool |
| `server/extensions/oppi-admin.ts` | Built-in workspace/admin tool |
| `server/src/mobile-renderer.ts` | Mobile tool-row rendering |

## When to read pi docs instead

Use pi's docs for:

- writing an extension
- supported extension directory layouts
- lifecycle hooks and custom tools
- terminal rendering with TUI components
- package-based extension distribution

Use this page only for Oppi-specific behavior and mobile/runtime gotchas.
