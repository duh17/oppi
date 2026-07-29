# working-words

A small Pi extension fixture for Oppi extension UI projection.

During an agent run, it rotates random working phrases using only portable Pi UI APIs:

```ts
ctx.ui.setWorkingIndicator({ frames: ["·", "•", "●", "•"], intervalMs: 120 });
ctx.ui.setWorkingMessage("Checking files…");
ctx.ui.setStatus("working-words", "shuffled · 16 phrases");
```

Terminal Pi renders the working indicator and message in the TUI. Oppi receives the same semantic UI requests and renders native iOS working-row and status state.

## Try it

```bash
pi -e ./pi-extensions/working-words
```

Then start a prompt. Use `/working-words` to preview the state without a model turn.

This fixture is intentionally generic: Oppi must not branch on this package name.
