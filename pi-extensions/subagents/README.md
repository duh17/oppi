# subagents

Reference Pi extension. Not a product feature. Copy it if you want a `subagent` tool and a widget of this session's Oppi subagents.

`launch` creates a child through `oppi session create` and returns immediately. One async `oppi session wait` watches those ids so the widget can go to Done. With `supervise` left on, settlement, attention, stall, and wait failure start a visible parent turn. A timeout while a child is still running does not. Prompt-cache refresh is Pi's warmer; this extension does not send acknowledgment replies to keep it warm. `supervise: false` is the detached path: widget wait only, no settlement turn. A bash `oppi session create` this session saw is the same widget-only wait. Do not also call `oppi session wait`.

A row uses the general activity-row link, `oppi://session/<id>`. Oppi already opens that. This package does not add a screen. A saved-agent emoji from `launch.agentIcon` is prefixed on the title. The activity row has no icon slot, so SF Symbol and genmoji icons are not drawn here. The pill title is the count; the subtitle is working/done, not another copy of that count. Each expanded row shows a snapshot of the child's model and context usage from `oppi session get`, with a progress bar when the window is known. The snapshot is taken when a child is launched or the parent session loads; it does not update continuously while the child works. Working, attention, and Done still update through `oppi session wait`. A widget get is not a parent model turn. Neither is the observation timeout.

## How it finds them

There is no children-list API. `parentSessionId` is stored on create, and `oppi session list` cannot filter by parent. Scanning that list would read every session.

This package only remembers launches from the current parent: the `subagent` tool, or a bash `oppi session create` it saw. Working, attention, and Done come from `oppi session wait`. It takes a one-time snapshot of remembered children after a launch or parent reload to capture names, emoji, model, and context usage. It does not run a periodic refresh. A busy get does not clear Needs attention; wait still owns that.

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
