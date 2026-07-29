# Ask extension example

This portable Pi extension package registers an `ask` tool for clarifying questions through Pi's public `pi.registerTool()` API.

When Oppi provides `ctx.ui.ask()`, the tool renders a native AskCard. In plain Pi contexts, it falls back to terminal or standard dialog APIs.

It supports:

- multiple questions in one tool call
- single-select and multi-select options
- optional custom text answers
- native Oppi AskCard rendering through the documented `ctx.ui.ask()` request when available
- terminal TUI fallback through `ctx.ui.custom()`
- portable `select` / `input` fallback for other Pi UI contexts

## Local install for Oppi development

Install it like any other local Pi extension. From the Oppi repo root:

```bash
ln -sfn "$PWD/pi-extensions/ask" ~/.pi/agent/extensions/ask
```

Pi auto-discovers extensions in `~/.pi/agent/extensions/`, so new Oppi sessions load `ask` automatically. Use the workspace editor's extension toggles to enable or disable it per workspace; they write Pi resource settings for the workspace cwd.

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

In Oppi, this call renders a native multi-select AskCard. In a terminal Pi session, it renders a keyboard-driven terminal dialog.
