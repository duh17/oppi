# Oppi extension behavior

This page only covers what Oppi changes or adds on top of pi's extension system.

For writing extensions, supported layouts, lifecycle hooks, tool APIs, and TUI renderers, use pi's docs:

- pi extension docs: `server/node_modules/@mariozechner/pi-coding-agent/docs/extensions.md`
- pi examples: `server/node_modules/@mariozechner/pi-coding-agent/examples/extensions/`

## What Oppi changes

Oppi adds three behaviors on top of normal pi extension loading:

1. **Oppi-owned first-party names and reserved managed names**
   - first-party workspace opt-in names: `ask`, `subagents`, `voice`
   - reserved server-managed name: `permission-gate`
2. **Workspace allowlist filtering** via `workspace.extensions`
3. **Mobile rendering** via server-side `StyledSegment[]`, not pi TUI components

## Architecture

```mermaid
flowchart TD
  subgraph Host[Host machine]
    GE[~/.pi/agent/extensions\nglobal pi extensions]
    PE[.pi/extensions\nproject-local pi extensions]
    MR[~/.pi/agent/mobile-renderers\nmobile renderer sidecars]
  end

  subgraph Server[Oppi server]
    EL[extension-loader.ts\nlistHostExtensions]
    SR[skills route\nGET /extensions]
    SS[session-start.ts\ninject ask, voice, and subagents]
    FR[first-party-extension-runtime.ts\nreloadable first-party runtime context]
    SB[sdk-backend.ts\nfilter managed names\napply workspace allowlist]
    PG[GateServer policy hook\nin-process permission gate]
    MRR[mobile-renderer.ts]
    SP[session-protocol.ts]
  end

  subgraph iOS[iOS app]
    WE[WorkspaceEditView]
    SEG[SegmentRenderer]
    TP[ToolPresentationBuilder]
  end

  GE --> EL
  PE --> EL
  EL --> SR --> WE
  GE --> SB
  PE --> SB
  SS --> FR --> SB
  PG --> SB
  MR --> MRR --> SP --> SEG --> TP
  SB --> SP
```

## Runtime behavior

### Host extensions

At session startup, Oppi starts from pi's normal extension set for the session cwd:

- auto-discovered extension dirs (`~/.pi/agent/extensions/`, `.pi/extensions/`)
- settings-declared extension paths (`settings.json` `extensions` arrays)
- package-provided extensions from `pi install` (git/npm/local package sources)

Oppi does not replace that mechanism. It filters it.

### Oppi-owned names

Oppi reserves one truly managed server-owned name:

- `permission-gate`

That name is filtered out of host discovery and owned by the server.

Oppi also ships first-party extensions from the repo-local `oppi-extensions` pi package:

- `ask` from `server/extensions/ask.ts`
- `subagents` from `server/extensions/subagents.ts`
- `voice` from `server/extensions/voice.ts`

They are loaded through reloadable file-based wrappers under `oppi-extensions/extensions/`.

### Workspace allowlist

When a workspace sets `extensions`, that list is an authoritative allowlist for optional extensions.
Include `ask`, `subagents`, or `voice` explicitly if you want them.

When `extensions` is unset, Oppi keeps normal pi discovery and does not auto-enable its own `oppi-extensions` names.

## Extension picker behavior

`GET /extensions` is not a generic pi reference API. It is the picker source for the Oppi workspace editor.

Behavior:

- resolves extensions via pi's settings/package resolver (same source graph pi uses at runtime)
- includes auto-discovered dirs (`~/.pi/agent/extensions/`, `<cwd>/.pi/extensions/`)
- includes package-installed extensions (for example `~/.pi/agent/git/...` and npm installs)
- includes settings-declared local extension paths
- includes Oppi-owned names so workspaces can enable `ask`, `subagents`, and `voice` without separately installing the package into pi
- excludes managed names
- deduplicates by extension name for UI display using pi precedence rules (project > user > package)

## Mobile rendering gotcha

Pi's `renderCall()` and `renderResult()` drive the terminal UI. Oppi iOS does not use them.

For mobile, Oppi uses server-side renderers that produce `StyledSegment[]`.

Sources:

- built-in renderers in `server/src/mobile-renderer.ts`
- optional sidecars in `~/.pi/agent/mobile-renderers/*.ts`

If an extension looks good in terminal pi but looks generic in Oppi, this is usually why.

## Permission gate gotcha

`permission-gate` is not a host extension you install or toggle per workspace.

Oppi replaces that behavior with an in-process gate wired through the server and mobile approval flow.

## File map

| File | Why it matters |
|---|---|
| `server/extensions/first-party.ts` | Reserved names and enablement rules |
| `server/extensions/ask.ts` | First-party ask tool |
| `server/extensions/subagents.ts` | First-party multi-agent tools |
| `server/extensions/voice.ts` | First-party voice tool |
| `server/src/extension-loader.ts` | Picker discovery for global + project-local extensions |
| `server/src/routes/skills.ts` | `GET /extensions` |
| `server/src/session-start.ts` | Injects first-party factories |
| `server/src/first-party-extension-runtime.ts` | Rebinds reloadable ask/voice/subagents runtime context |
| `server/src/sdk-backend.ts` | Filters managed names and applies workspace allowlist |
| `server/src/mobile-renderer.ts` | Mobile tool row renderers |
| `server/src/session-protocol.ts` | Sends `callSegments` and `resultSegments` to iOS |

## When to read pi docs instead

Go to pi's docs for:

- how to write an extension
- supported extension directory layouts
- event lifecycle details
- custom tools
- custom commands
- terminal rendering with TUI components
- package-based extension distribution

Use this page for Oppi-specific behavior and gotchas only.
