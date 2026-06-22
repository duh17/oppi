# Oppi goal extension

Pi extension that prototypes Codex-style `/goal` behavior without Oppi server lifecycle hooks.

What it provides:

- `/goal <objective>` starts a durable session goal.
- `get_goal`, `create_goal`, and `update_goal` let the model inspect and update goal state.
- Goal snapshots persist as Pi custom session entries with `customType: "oppi-goal"`.
- An extension-owned outer loop queues a continuation message after the agent becomes idle while the goal is active.
- A persistent widget renders goal status, elapsed goal time, and task elapsed time in Pi and as an Oppi native extension surface when supported.

How it works:

```mermaid
flowchart TD
  User[User or model starts a goal] --> Create[Create or update SessionGoal]
  Create --> Persist[Append oppi-goal custom entry]
  Persist --> Widget[Render goal widget and status]
  Persist --> IdleCheck{Agent idle and no queued messages?}

  IdleCheck -- no --> Wait[Wait for agent_end or session_compact]
  Wait --> IdleCheck

  IdleCheck -- yes --> Budget{Continuation budget left?}
  Budget -- no --> Block[Mark goal blocked]
  Budget -- yes --> Context{Context usage below limit?}

  Context -- no --> CompactGuard{Pi compaction already in flight?}
  CompactGuard -- yes --> Wait
  CompactGuard -- no --> Compact[Request ctx.compact]
  Compact --> Wait

  Context -- yes --> Continue[Append updated goal with continuationCount + 1]
  Continue --> Send[Send oppi-goal-continuation follow-up]
  Send --> Agent[Agent works next step]
  Agent --> Tool[Agent calls update_goal]
  Tool --> Persist

  Tool --> Done{Complete, blocked, paused, or cleared?}
  Done -- yes --> Stop[Stop continuation loop]
  Done -- no --> IdleCheck
```

Useful commands:

```text
/goal Build the feature
/goal status
/goal pause [reason]
/goal resume
/goal complete [summary]
/goal block <reason>
/goal budget <continuations>
/goal clear
```

The widget updates periodically while a goal is active, so mobile surfaces can show timer-like elapsed durations. Task timing is inferred from task status transitions: `in_progress` starts a timer, and `completed` records the elapsed duration.

The continuation budget is a safety cap, not a target to spend. Continuation prompts ask the model to audit completion against real evidence and avoid stopping on weak proxy signals. If the model tries to mark a goal complete while listed tasks are still pending or in progress, the extension keeps the goal active and records the unfinished tasks in the summary.

The loop stops when the goal is complete, blocked, paused, cleared, reaches its continuation budget, or reaches the configured context-usage limit.
