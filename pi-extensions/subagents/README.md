# subagents

Reference Pi extension. Not a product feature. Copy it if you want a `subagent` tool and a widget of this session's Oppi subagents.

`launch` creates a child through `oppi session create` and returns immediately. One async `oppi session wait` watches those ids so the widget can go to Done. With `supervise` left on, a finished child also starts a visible parent turn. A timeout while the parent is idle sends a short check-in, about every 4 minutes, which is a real model turn. That is the prompt-cache warm the old 4-minute wait produced by returning. A widget refresh does not do it. `supervise: false` is the detached path: widget wait only, no check-in and no settlement turn. A bash `oppi session create` this session saw is the same widget-only wait. Do not also call `oppi session wait`.

A row uses the general activity-row link, `oppi://session/<id>`. Oppi already opens that. This package does not add a screen. A saved-agent emoji from `launch.agentIcon` is prefixed on the title. The activity row has no icon slot, so SF Symbol and genmoji icons are not drawn here. The pill title is the count; the subtitle is working/done, not another copy of that count. Each expanded row shows the child's model and context usage from `oppi session get`, with a progress bar when the window is known. Those fields refresh every few seconds while the widget is up. A widget get is not a parent model turn.

## How it finds them

There is no children-list API. `parentSessionId` is stored on create, and `oppi session list` cannot filter by parent. Scanning that list would read every session.

This package only remembers launches from the current parent: the `subagent` tool, or a bash `oppi session create` it saw. Working, attention, and Done come from `oppi session wait`. Names, emoji, model, and context usage come from `oppi session get` on those ids while the widget is up. A busy get does not clear Needs attention; wait still owns that.

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
