# Chat Model Selection

Oppi has no top-level server default chat model. When it does not choose an explicit model for a new session, it leaves the model unset. The Pi SDK then uses Pi's normal settings and trace fallback.

Pi settings live in the Pi agent settings file, for example `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.5",
  "defaultThinkingLevel": "xhigh"
}
```

## Initial model precedence

One shared helper, `resolveInitialChatModel`, resolves the initial model for new Oppi-created chat sessions:

1. Explicit request model.
2. Source session model, when the flow has an origin, selected session, or fork source.
3. No Oppi model. Pi chooses from its settings, existing trace metadata, provider defaults, or first available model.

Before submitting a request, the Oppi CLI resolves `--model` for `session create` and new-session `schedule create` through the server `/models` catalog. The catalog is filtered by Pi `enabledModels`, accepts fuzzy text such as `sonnet`, prefers subscription/OAuth-backed matches over API-key matches, and sends the canonical `provider/model-id` to the server. `--model` can include an optional `:thinking` suffix such as `sonnet:high`. An explicit `--thinking` value wins over that suffix. If no match exists, the CLI error lists the exact available model IDs so an agent can retry with a valid value.

`session create` and `agent create` / `update` also accept Pi tool-policy flags: `--tools` / `-t`, `--exclude-tools` / `-xt`, `--no-tools` / `-nt`, and `--no-builtin-tools` / `-nbt`. Without `--agent`, `session create` writes those values onto the workspace create body as inline `sessionDefaults`. With `--agent`, they go to saved-Agent `overrides`. On `agent create` / `update`, the same flags overlay `sessionDefaults` in `--definition` / `--definition-json`.

## Flow notes

- Workspace “New Session” sends a model only when the caller explicitly selects one. Otherwise, Pi settings choose it.
- Quick and Guided Control sessions start without a model override unless the user chooses one in the current composer.
- Quick-action sessions inherit the selected or source session model when available. Otherwise, Pi settings choose it.
- Fork sessions preserve the source session model before they fall back to Pi settings.
- Local session imports use an explicit request model when present. Otherwise, Pi restores the imported trace’s original model.
- A normal model-picker row changes only the active session. The star selects the same model and persists it as Pi's global default.

## Non-goals

- No top-level `oppi` server `defaultModel` config.
- No per-client hidden default model. Clients should only send a model when the user explicitly chooses one.
