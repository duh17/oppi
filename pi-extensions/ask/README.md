# Ask extension example

This is a normal Pi extension that registers an `ask` tool for clarifying questions.
It supports:

- multiple questions in one tool call
- single-select and multi-select options
- optional custom text answers
- native Oppi AskCard rendering through `ctx.ui.ask()` when available
- terminal TUI fallback through `ctx.ui.custom()`
- portable `select` / `input` fallback for other Pi UI contexts

## Local install for Oppi development

Install it like any other local Pi extension. From the Oppi repo root:

```bash
ln -sfn "$PWD/pi-extensions/ask" ~/.pi/agent/extensions/ask
```

Then enable `ask` in the workspace extension allowlist.

## Example tool call

```json
{
  "questions": [
    {
      "id": "targets",
      "question": "Which targets should I update?",
      "options": [
        { "value": "server", "label": "Server" },
        { "value": "ios", "label": "iOS" },
        { "value": "docs", "label": "Docs" }
      ],
      "multiSelect": true
    }
  ],
  "allowCustom": true
}
```

In Oppi, this renders as a native multi-select AskCard. In a terminal Pi session, it renders as a keyboard-driven terminal dialog.
