# Oppi extension behavior

This page explains Oppi's runtime behavior for pi extensions: what Oppi loads, what workspaces can enable, what standalone pi sees, and how terminal-oriented extension UI appears on mobile.

For Oppi's public native UI block contract and Apple presentation mapping, see [`extension-native-ui.md`](extension-native-ui.md). For media attachments in messages and expanded tool output, see [`attachment-rendering.md`](attachment-rendering.md).

It is for Oppi workspace admins and Oppi developers. It is not an extension-authoring guide. For pi package layout, lifecycle hooks, tool APIs, and terminal UI rendering, use pi's docs instead:

- pi extension docs: `@earendil-works/pi-coding-agent/docs/extensions.md`
- pi package docs: `@earendil-works/pi-coding-agent/docs/packages.md`
- pi examples: `@earendil-works/pi-coding-agent/examples/extensions/`

## Core rule

Oppi does not inject extension tools into SDK sessions. Extension tools, including `ask`, load from Pi's own resource system, then pass through the workspace allowlist.

Approval behavior is extension-owned. If a session needs approval before an action, use a Pi extension that handles `tool_call` or session events and asks through `ctx.ui`.

Installing or running Oppi server must not write to `~/.pi/agent/settings.json`, run `pi install`, or implicitly enable any extension in standalone pi. Standalone pi only loads what the user explicitly installs or loads with pi.

## Extension surfaces

| Surface                 | Enabled by                                                  | Declared in                              | Loaded by          | Notes                                                                                                      |
| ----------------------- | ----------------------------------------------------------- | ---------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------- |
| Host pi extensions      | User/project pi settings, `pi install`, or `.pi/extensions` | User-owned pi config/package paths       | pi resource loader | Must work without Oppi server services                                                                     |
| Ask extension example   | Local/package install + workspace `extensions` allowlist    | `pi-extensions/ask`                      | pi resource loader | Portable Pi package: registers `ask`, uses native AskCard when available, then falls back to Pi UI APIs     |
| Browser video example   | Local/package install + workspace `extensions` allowlist    | `pi-extensions/browser-automation-video` | pi resource loader | Oppi-compatible Pi package: registers a public Pi tool and uses Oppi's attachment helper when available     |
| Mobile UI compatibility | Native Oppi client + server bridge                          | Protocol and UI bridge code              | Oppi server/client | Maps common `ctx.ui` calls to native cards/dialogs; see [`extension-native-ui.md`](extension-native-ui.md) |

This split keeps user consent clear: installing Oppi is not the same thing as installing a pi extension package.

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

Oppi keeps Pi's extension system, then adds these rules:

1. **Workspace allowlist filtering** through `workspace.extensions`.
2. **Mobile UI compatibility** for most standard extension input, confirm, ask, and approval UI calls.
3. **Stored attachment helpers** for tool-generated files through documented Oppi context helpers such as `ctx.attachments.addFile()`.

Oppi does not replace Pi discovery. It filters host-loaded extensions through the workspace allowlist. Extensions that ask for input or confirmation use the same mobile bridge as other Pi extension UI.

## Approval prompts

Approval behavior belongs to Pi extensions. Command classification, route decisions, and user prompts live inside extension handlers; Oppi renders the resulting UI but does not create a separate approval layer.

The behavior is the same shape for Oppi-owned sessions and mirrored terminal sessions:

- A Pi extension can intercept `tool_call`, `session_before_switch`, `session_before_fork`, or other Pi events.
- The extension can ask with `ctx.ui.ask()`, `ctx.ui.confirm()`, `ctx.ui.select()`, `ctx.ui.input()`, or `ctx.ui.editor()`.
- Oppi mobile renders those standard extension UI requests natively and sends responses through `extension_ui_response`.
- Standalone terminal Pi uses the same extension logic through its normal TUI.

## How extension loading works

At session startup, Oppi begins with pi's normal extension sources for the session working directory:

- auto-discovered extension directories (`~/.pi/agent/extensions/`, `.pi/extensions/`)
- settings-declared extension paths (`settings.json` `extensions` arrays)
- package-provided extensions installed through pi (`pi install`)

Oppi then prunes and filters that list before the session uses it:

- file extensions must be `.ts` or `.js`; `.test` and `.spec` files are ignored
- package `index` entries use the package identity for their allowlist name, such as `npm:@tintinweb/pi-subagents` becoming `tintinweb-subagents`
- directory-style entries such as `extensions/foo/index.ts` use `foo` as the extension name
- when `workspace.extensions` is set, host extensions must appear in that allowlist

After pruning, Oppi loads the remaining Pi extensions without injecting an extra Ask tool. Install or enable a Pi extension named `ask` when a workspace needs the ask tool.

## Reload behavior

`/reload` reloads host pi extensions, skills, prompts, and themes through pi's resource loader.

## Workspace allowlist behavior

If a workspace sets `extensions`, that field is authoritative for optional workspace extensions in Oppi SDK sessions.

That means:

- include `ask` explicitly if you want an Ask tool from an installed Pi extension named `ask`
- include a Pi extension name explicitly if you want it when the workspace has an allowlist
- omitting an extension name disables it for that workspace

If `workspace.extensions` is unset, Oppi keeps normal pi discovery.

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

Oppi's native extension UI behavior is specified in [`extension-native-ui.md`](extension-native-ui.md). That contract keeps blocking prompts Pi-shaped, maps standard `select`, `confirm`, `input`, and `editor` requests to native iOS prompt presentations, projects Pi UI state such as working rows, hidden thinking labels, and tool expansion, and defines display-only widget `ExtensionUINativeSurface` panels with blocks such as `text`, `markdown`, `section`, `activityList`, `progress`, `terminal`, and `code`.

The short version: native UI requires explicit semantics. Oppi renders semantic extension UI natively and uses sanitized terminal snapshots as fallback for opaque TUI components.

## Mobile rendering differences

Pi's terminal UI uses extension `renderCall()` and `renderResult()` hooks. Oppi iOS does not execute those TUI renderers.

On mobile, Oppi renders tool activity with native timeline rows. Rendering uses this fallback chain:

1. built-in mobile renderers in `server/src/mobile-renderer.ts`
2. optional sidecars in `~/.pi/agent/mobile-renderers/*.ts`
3. server-provided `StyledSegment[]` summaries for the collapsed row
4. generic extension output rendering from tool `content` and `details`

That means an extension can look polished in terminal pi but look generic in Oppi unless it provides mobile-friendly text, structured details, or a sidecar renderer.

### Generic mobile defaults

For extension tools without a dedicated mobile renderer, Oppi renders useful native output:

- collapsed row title defaults to the tool name plus a compact argument summary
- collapsed rows are treated as compact summaries, not rich output containers
- expanded output renders JSON objects/arrays as formatted JSON
- markdown-looking text renders as markdown
- unified diffs render with the native diff view
- code-like output can render with syntax highlighting when a language hint is present
- otherwise output renders as plain/ANSI text

Extension authors can improve the default expanded view by returning these `details` keys from the tool result:

| Key                  | Purpose                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------ |
| `expandedText`       | Text shown in the expanded mobile view instead of raw output                                                 |
| `presentationFormat` | One of `markdown`, `json`, `code`, or `diff`                                                                 |
| `language`           | Syntax hint for `presentationFormat: "code"`                                                                 |
| `filePath`           | File path hint for language detection and diff/code metadata                                                 |
| `startLine`          | Starting line number for code views                                                                          |
| `media`              | Stored media attachment metadata for expanded rows; see [`attachment-rendering.md`](attachment-rendering.md) |

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

Oppi maps fire-and-forget extension UI calls to generic native presentation above the composer:

- `ctx.ui.setTitle()` → card heading
- `ctx.ui.setStatus()` → status rows
- `ctx.ui.setWidget(string[])` → monospaced widget lines
- `ctx.ui.setWidget(component)` with `renderNative()` → display-only native surface panel
- `ctx.ui.notify()` → toast/banner
- `ctx.ui.setEditorText()` / `pasteToEditor()` → composer text handoff
- `ctx.ui.setWorkingMessage()` / `setWorkingVisible()` / `setWorkingIndicator()` → native timeline working row
- `ctx.ui.setHiddenThinkingLabel()` → thinking row accessibility and source metadata
- `ctx.ui.setToolsExpanded()` / `getToolsExpanded()` → native tool-row expansion state

This is a native mobile surface, not a terminal footer/header. `setFooter`, `setHeader`, arbitrary `custom()` components, and editor replacement remain terminal-first APIs; SDK sessions ignore them or preserve factories only when Pi compatibility requires it.

Mirror mode uses the same protocol surface from an interactive terminal Pi process. Keep the mirror-specific support table and first-wins dialog race rules in `docs/oppi-mirror.md#extension-ui-compatibility-matrix` rather than duplicating them here.

## Relevant implementation files

| File                                     | Why it matters                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------- |
| `pi-extensions/ask`                      | Ask extension example with multi-select support                           |
| `pi-extensions/browser-automation-video` | Oppi-compatible Pi extension package using the documented attachment helper |
| `server/src/routes/skills.ts`            | Workspace extension picker (`GET /extensions`)                            |
| `server/src/sdk-backend.ts`              | Pi resource loading and allowlist rules                                   |
| `server/src/sdk-ui-bridge.ts`            | Extension UI bridge from pi APIs to Oppi protocol events                  |
| `server/src/extension-ui-contract.ts`    | Shared extension UI request, notification, and settled message builders   |
| `server/src/mobile-renderer.ts`          | Mobile tool-row rendering                                                 |

## When to read pi docs instead

Use pi's docs for:

- writing an extension
- supported extension directory layouts
- lifecycle hooks and custom tools
- terminal rendering with TUI components
- package-based extension distribution

Use this page only for Oppi-specific behavior and mobile/runtime gotchas.
