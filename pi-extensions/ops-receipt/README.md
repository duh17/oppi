# ops-receipt

Demonstration-only Pi extension. Not a product feature. Example of **subagent status** cards: a parent session stamps the timeline when a child settles.

Uses `appendEntry` + `registerEntryRenderer`, so the stamp is **not** sent to the model.

When a bash tool finishes `oppi session wait` or `oppi session inspect --json`:

- idle / stopped → `Child done`
- attention → `Child needs you`

Collapsed render is two lines (title, body). Oppi shows that as the existing custom timeline card while this extension is loaded.

## Try it

```bash
pi -e ./pi-extensions/ops-receipt
```

Then in a parent session:

```bash
oppi session wait <child-id> --for either --json
```

Busy inspects are ignored. Tool output payloads are not copied onto the card.
