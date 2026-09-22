# subagents

Reference Pi extension. Not a product feature. Copy it if you want a widget of this session's Oppi subagents.

A row uses the general activity-row link, `oppi://session/<id>`. Oppi already opens that. This package does not add a screen.

## How it finds them

There is no children-list API. `parentSessionId` is stored on create, and `oppi session list` cannot filter by parent. Scanning that list would read every session.

This package only remembers `oppi session create` results from the current parent. It then asks the CLI for those ids alone:

```bash
oppi session get <id> --json
```

That is the public one-session API. A raw HTTP client would also need the owner token and port, which is worse for a copyable extension. A dedicated children route would be cleaner later. It does not exist, and this reference does not add one.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./pi-extensions/subagents
```

Then, from a parent session:

```bash
oppi session create --workspace <workspace> --name scout --json --prompt "Reply with one word."
```

Tap the row to open that session. Reload the extension in an already-running session before expecting the widget.
