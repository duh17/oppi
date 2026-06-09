# Chat Model Selection

Oppi does not define a top-level server default chat model. If Oppi does not choose an explicit model for a new session, it leaves the model unset and lets the Pi SDK use Pi's normal settings and trace fallback.

Pi settings live in the Pi agent settings file, for example `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-5.5",
  "defaultThinkingLevel": "xhigh"
}
```

## Initial model precedence

New Oppi-created chat sessions resolve their initial model in one shared helper, `resolveInitialChatModel`:

1. Explicit request model.
2. Source session model, when the flow has an origin, selected session, or fork source.
3. Workspace `defaultModel`.
4. No Oppi model. Pi chooses from its settings, existing trace metadata, provider defaults, or first available model.

Model IDs stored in Oppi workspace defaults should use canonical `provider/model-id` form, such as `ds4/deepseek-v4-flash`.

## Flow notes

- Workspace “New Session” uses an explicit request model, then the workspace default, then Pi settings.
- Quick Session sheet sends the last/current explicit quick-session model when present; otherwise the server applies the workspace default, then Pi settings. It displays workspace defaults but does not send them as client overrides.
- Quick-action sessions inherit the selected/source session model when available, otherwise use the workspace default, then Pi settings.
- Fork sessions preserve the source session model before falling back to workspace/Pi defaults.
- Local session imports intentionally do not apply the workspace default unless the client passes an explicit model. This lets Pi restore the imported trace’s original model.

## Non-goals

- No top-level `oppi` server `defaultModel` config.
- No per-client hidden default model. Clients should only send a model when the user explicitly chooses one.
