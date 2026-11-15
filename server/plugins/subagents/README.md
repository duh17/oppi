# subagents

Reference Pi extension. Not a product feature. Copy it if you want a `subagent` tool and a widget of this session's Oppi subagents.

`launch` creates a child through `oppi session create` and returns immediately. One async `oppi session wait` watches those ids so the widget can go to Done. With `supervise` left on, settlement, attention, stall, and wait failure start a visible parent turn. A timeout while a child is still running does not. Prompt-cache refresh is Pi's warmer; this extension does not send acknowledgment replies to keep it warm. `supervise: false` is the detached path: widget wait only, no settlement turn. A bash `oppi session create` this session saw is the same widget-only wait. Do not also call `oppi session wait`.

A row uses the general activity-row link, `oppi://session/<id>`. Oppi already opens that, and offers the session's menu on it. This package does not add a screen. A saved-agent emoji from `launch.agentIcon` is prefixed on the title. The activity row has no icon slot, so SF Symbol and genmoji icons are not drawn here. The pill shows only while a child needs you or works: its title is `Subagents`, and its subtitle counts the live children, most urgent first (`1 failed · 1 needs you · 2 working`). Finished children alone do not keep it on screen. The body lists every child in four sections, each left out when empty. **Needs You** lists children that ask a question or failed, oldest first. A failed child stays there until it is messaged or stopped. **Working** lists working children, the oldest run first, so a row does not move while it works. **Recent** lists the three newest finished children. **Earlier** holds every other finished child, newest first, behind one row (`40 finished`) that opens like any disclosure row, so the drawer stays short until you open it. A row's title is the child's name, its second line what changed (no state word: the section says it), and its third line the model.

Each child's row is a disclosure row: tapping it shows the child's newest answer as Markdown (the durable pill below reads answers; this package does not, so its rows show the rest), what it is doing now while it works, and a line with its full model, thinking level, spend, worktree, and run time. Its link moves to a trailing button, and touch and hold still gives the session's menu. Needs You and Recent answers show up to 1,500 characters; a working child's previous answer and an Earlier answer show up to 240. The server drops a native surface over its limits (64 KB, 32 KB of text, 80 blocks, 160 activity rows), so the panel is built under them: every child's row first, in section order, then answers with the room left. A thread too big for that (past about 70 children, one block per row) shows the newest children that fit, and a last row, `N more in Thread`, links to `oppi://thread/<the launching Oppi session id>`, which opens the session list with that thread. This package learns that id from the `launch.parentSessionId` of a child's `oppi session get`; until it has read one, that row has no link. In a terminal the same children are a compact band: a state mark, the name, and status and model when they fit. The raw session URL is not printed there. The model is a snapshot from `oppi session get`, taken when a child is launched or the parent session loads; it does not update continuously while the child works. Working, attention, and Done update through `oppi session wait`. A widget get is not a parent model turn. Neither is the observation timeout.

Durable sessions draw the same pill from the built-in `oppi.sessions` extension, this package's plugin (`server.ts` and `widget.ts`), which imports the same `subagents.ts` row helpers. A change to those helpers changes both pills. The durable pill knows more about each child, so its rows also show the current step, the question, the error or the answer's first line, the thinking level, the spend, the worktree's commits ahead and whether it is dirty (taken when a run ends), how long a finished run took, and, through the row's `since`, how long the current state has lasted.

## How it finds them

There is no children-list API. `parentSessionId` is stored on create, and `oppi session list` cannot filter by parent. Scanning that list would read every session.

This package only remembers launches from the current parent: the `subagent` tool, or a bash `oppi session create` it saw. Working, attention, and Done come from `oppi session wait`. It takes a one-time snapshot of the children the pill draws as rows, after a launch or parent reload, to capture names, emoji, model, and context usage; each refresh also looks at a few of the others in turn, so a deleted session leaves the count. It does not run a periodic refresh. A busy get does not clear Needs attention; wait still owns that.

```bash
oppi session get <id> --json
```

That is the public one-session API. A raw HTTP client would also need the owner token and port, which is worse for a copyable extension. A dedicated children route would be cleaner later. It does not exist, and this reference does not add one.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./server/plugins/subagents
```

Then, from a parent session:

```bash
oppi session create --workspace <workspace> --name scout --json --prompt "Reply with one word."
```

Tap the row to open that session. Reload the extension in an already-running session before expecting the widget.
