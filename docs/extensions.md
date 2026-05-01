# Oppi extension behavior

This page explains how Oppi uses pi extensions at runtime. It is for workspace admins and developers who need to know what Oppi loads, what it filters, and what behaves differently on mobile.

For extension authoring details such as layouts, lifecycle hooks, tool APIs, and terminal UI rendering, use pi's docs instead:

- pi extension docs: `server/node_modules/@mariozechner/pi-coding-agent/docs/extensions.md`
- pi examples: `server/node_modules/@mariozechner/pi-coding-agent/examples/extensions/`

## What Oppi changes

Oppi keeps pi's extension system, then adds three rules on top:

1. **Oppi-owned first-party names**: `ask`, `subagents`, `voice`
2. **One reserved server-managed name**: `permission-gate`
3. **Workspace allowlist filtering** through `workspace.extensions`

Oppi also renders some extension UI differently on mobile.

## How extension loading works

At session startup, Oppi begins with pi's normal extension sources for the session working directory:

- auto-discovered extension directories (`~/.pi/agent/extensions/`, `.pi/extensions/`)
- settings-declared extension paths (`settings.json` `extensions` arrays)
- package-provided extensions installed through pi (`pi install`)

Oppi does not replace that discovery process. It filters and augments the result.

## Oppi-owned names

Oppi reserves one fully server-managed name:

- `permission-gate`

That name is never loaded from host extension paths.

Oppi also provides three first-party extension names:

- `ask`
- `subagents`
- `voice`

These are implemented by the Oppi server and exposed in the workspace extension picker so a workspace can opt into them without separately installing a pi package.

For `/reload`, Oppi loads small wrapper files under `oppi-extensions/extensions/`. Those wrappers are internal runtime shims for Oppi. They are not meant to be treated as generic package-installed pi extensions.

## Workspace allowlist behavior

If a workspace sets `extensions`, that field is authoritative. Only the listed optional extensions are enabled.

That means:

- include `ask`, `subagents`, or `voice` explicitly if you want them
- omitting one of those names disables it for that workspace
- `permission-gate` is not controlled through this list because it is server-managed

If `workspace.extensions` is unset, Oppi keeps normal pi discovery but leaves Oppi-owned first-party names off by default.

## Extension picker behavior

`GET /extensions` is the data source for the Oppi workspace editor. It is not a general-purpose pi reference API.

The picker response:

- resolves extensions through pi's normal settings and package resolver
- includes auto-discovered global and project-local extensions
- includes package-installed extensions
- includes settings-declared local extension paths
- includes Oppi-owned names (`ask`, `subagents`, `voice`)
- excludes managed names such as `permission-gate`
- deduplicates by extension name using pi precedence rules

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

If a terminal renderer or mobile sidecar produces multiple lines for a collapsed summary, Oppi should use the first line for the collapsed row and treat the remaining lines as expanded fallback content when no better `details.expandedText` / `presentationFormat` output exists.

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

## Permission gate

`permission-gate` is not a host extension you install or toggle per workspace.

Oppi replaces that behavior with an in-process permission system wired through the server and mobile approval flow.

## Relevant implementation files

These paths matter if you need to verify behavior against the codebase:

| File | Why it matters |
|---|---|
| `server/extensions/first-party.ts` | First-party and managed-name rules |
| `server/src/routes/skills.ts` | Workspace extension picker (`GET /extensions`) |
| `server/src/sdk-backend.ts` | Extension filtering and workspace allowlist behavior |
| `server/src/first-party-extension-runtime.ts` | Reload support for Oppi-owned extensions |
| `server/extensions/ask.ts` | First-party ask tool |
| `oppi-extensions/src/subagents/index.ts` | First-party subagents toolset |
| `server/extensions/voice.ts` | First-party voice tool |
| `server/src/mobile-renderer.ts` | Mobile tool-row rendering |

## When to read pi docs instead

Use pi's docs for:

- writing an extension
- supported extension directory layouts
- lifecycle hooks and custom tools
- terminal rendering with TUI components
- package-based extension distribution

Use this page only for Oppi-specific behavior and mobile/runtime gotchas.
