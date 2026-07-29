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
3. Workspace `defaultModel`.
4. No Oppi model. Pi chooses from its settings, existing trace metadata, provider defaults, or first available model.

Model IDs stored in Oppi workspace defaults should use canonical `provider/model-id` form, such as `ds4/deepseek-v4-flash`.

Before submitting a request, the Oppi CLI resolves `--model` for `session create` and new-session `schedule create` through the server `/models` catalog. The catalog is filtered by Pi `enabledModels`, accepts fuzzy text such as `sonnet`, prefers subscription/OAuth-backed matches over API-key matches, and sends the canonical `provider/model-id` to the server. If no match exists, the CLI error lists the exact available model IDs so an agent can retry with a valid value.

## Flow notes

- Workspace “New Session” uses an explicit request model, then the workspace default, then Pi settings.
- The Quick Session sheet sends the last or current explicit quick-session model when present. Otherwise, the server applies the workspace default, then Pi settings. The sheet displays workspace defaults but does not send them as client overrides.
- Quick-action sessions inherit the selected or source session model when available. Otherwise, they use the workspace default, then Pi settings.
- Fork sessions preserve the source session model before they fall back to workspace or Pi defaults.
- Local session imports intentionally skip the workspace default unless the client passes an explicit model. This lets Pi restore the imported trace’s original model.

## Non-goals

- No top-level `oppi` server `defaultModel` config.
- No per-client hidden default model. Clients should only send a model when the user explicitly chooses one.
