# working-words

A small Pi extension fixture for Oppi extension UI projection.

It rotates randomized working phrases during an agent run and uses only portable Pi UI APIs:

```ts
ctx.ui.setWorkingIndicator({ frames: ["·", "•", "●", "•"], intervalMs: 120 });
ctx.ui.setWorkingMessage("Checking files…");
ctx.ui.setStatus("working-words", "shuffled · 16 phrases");
```

Terminal Pi renders the working indicator and message through the TUI. Oppi receives the same semantic UI requests and renders them as native iOS working-row and status state.

## Try it

```bash
pi -e ./pi-extensions/working-words
```

Then start a prompt. Use `/working-words` to preview the state without waiting for a model turn.

This fixture is intentionally generic: Oppi must not branch on this package name.
