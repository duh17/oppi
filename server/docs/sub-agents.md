# Sub-agents

Oppi's `subagents` extension lets an agent create and manage child sessions inside the same workspace. Use it when one session should delegate a task, wait for a result, or inspect another session's trace.

## Enabling the extension

`subagents` is a native Pi extension shipped with Oppi. It uses the same workspace/session APIs as the iOS client: create a session, list workspace sessions, inspect session traces, stop/resume sessions, and send generic session commands.

To use it in an Oppi SDK workspace, include `subagents` in that workspace's `extensions` list. If a workspace sets `extensions`, that list is authoritative. Omitting `subagents` disables it.

For mirrored Pi TUI sessions, install or load the same extension alongside `oppi-mirror`; the repo copy is `pi-extensions/oppi-subagents/index.ts`. The extension resolves the current Pi session by matching Pi's session UUID to Oppi's generic session summaries. Without a matching Oppi session, the tools report that subagents are unavailable.

## Tool surface

Sessions below the configured spawn depth get three tools:

- `spawn_agent`
- `inspect_agent`
- `send_message`

Sessions at the configured spawn depth get the non-spawning subset only:

- `inspect_agent`
- `send_message`

## spawn_agent

Create a new session in the current workspace.

| Parameter         | Type    | Default           | Description                                                                                                       |
| ----------------- | ------- | ----------------- | ----------------------------------------------------------------------------------------------------------------- |
| `message`         | string  | required          | Task prompt for the child. Include the context it needs because the child does not see the parent's conversation. |
| `name`            | string  | truncated message | Display name shown in the app and session tree.                                                                   |
| `profile`         | string  | none              | Optional built-in profile: `default`, `discovery`, `coding`, `review`, `research`.                                |
| `model`           | string  | inherited         | Model override for the child session.                                                                             |
| `thinking`        | string  | inherited         | Thinking level override: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`.                                      |
| `detached`        | boolean | `false`           | Create an independent session with no parent-child link. Detached sessions can spawn their own children.          |
| `wait`            | boolean | `false`           | Block until the child finishes its current task and return the result inline.                                     |
| `timeout_seconds` | number  | `1800`            | Maximum wait time when `wait=true`.                                                                               |

### Built-in profiles

Oppi supports built-in subagent profiles through the `profile` parameter:

- `default`: no specialized lane
- `discovery`: scoped codebase/source inspection
- `coding`: focused implementation with clear ownership
- `review`: correctness and regression review
- `research`: documentation, web/source research, and synthesis

Profiles add prompt guidance only. Model choice, thinking level, tools, and approval behavior stay with Pi and the explicit `spawn_agent` parameters.

### Fire-and-forget mode

By default, `spawn_agent` returns immediately with the child session ID.

When the child finishes, the parent receives a `subagent_result` message with final status, cost or context usage, and the child's last response.

If the parent is idle, Oppi appends that result without starting a new turn. If the parent is busy, Oppi queues it as a follow-up.

Parent agents should not poll or repeatedly inspect fire-and-forget children for status. For long-running work, including tasks that may take an hour, let the child run and wait for the automatic `subagent_result`; use `inspect_agent` only for debugging details or suspected stalls.

### Wait mode

With `wait=true`, the parent blocks until the child finishes its current task. Oppi then stops that child immediately and returns the result inline.

Use wait mode for sequential dependencies, not for long-running background work.

## inspect_agent

`inspect_agent` reads a session's JSONL trace.

Default and detail views:

1. **Full last response**: `inspect_agent(id)`
2. **Overview**: `inspect_agent(id, response: false)`
3. **Turn detail**: `inspect_agent(id, turn: N)`
4. **Tool detail**: `inspect_agent(id, turn: N, tool: M)`

Set `response: true` with `turn: N` to return that turn's assistant response text instead of the summarized turn view.

Works for both active and stopped sessions.

## send_message

Send a message to another session in the same workspace.

| Parameter  | Type                                             | Default  | Description                                                                 |
| ---------- | ------------------------------------------------ | -------- | --------------------------------------------------------------------------- |
| `id`       | string                                           | required | Target session ID.                                                          |
| `message`  | string                                           | required | Message content.                                                            |
| `behavior` | `"auto" \| "steer" \| "followUp" \| "prompt"` | `"auto"` | Delivery mode. `auto` steers busy sessions and prompts idle sessions. |

Delivery rules:

- **Idle**: starts a new turn
- **Busy + `steer`**: injected after current tool calls, before the next model call
- **Busy + `followUp`**: queued after the current turn finishes
- **`prompt`**: starts a new turn when the target is idle
- **Stopped**: automatically resumed, then delivered as a new prompt

Oppi prepends an origin marker such as `[From agent "Name" (id)]` so the recipient knows where the message came from.

Prefer `send_message` over spawning a new child when an earlier subagent already investigated the same area.

## Spawn tree and detached sessions

Each normal child session records `parentSessionId`, so sessions form a tree.

Defaults:

- `maxDepth = 1`
- a child cannot spawn grandchildren unless you raise that limit

If you need a fully independent session, use `detached: true`. Detached sessions are outside the spawn tree and keep full spawn capability.

## Visibility model

A parent waiting on a child receives coarse progress updates only: session name, status, and cost or context usage.

It does **not** receive the child's tool calls, streaming text, command snapshots, or full tool output.

This is deliberate. The detailed execution history stays in the child's own trace file and is available later through `inspect_agent`.

In wait mode, Oppi treats a child returning to `ready` after producing new output as completion and stops it immediately.

## Configuration

Configure subagents under `config.extensions.subagents`.

```json
{
  "extensions": {
    "subagents": {
      "maxDepth": 1,
      "defaultWaitTimeoutMs": 1800000
    }
  }
}
```

### Active configuration fields

These settings currently affect runtime behavior:

| Field                  | Default   | What it does                                                                    |
| ---------------------- | --------- | ------------------------------------------------------------------------------- |
| `maxDepth`             | `1`       | Maximum spawn depth for non-detached sessions. `0` disables spawning.           |
| `defaultWaitTimeoutMs` | `1800000` | Default timeout for `spawn_agent(wait=true)` when `timeout_seconds` is omitted. |

Use `profile` on `spawn_agent` to select a built-in preset such as `research`, `coding`, or `review`.

Examples:

```ts
spawn_agent({
  profile: "research",
  message: "Find the files that implement session queue replay. Do not edit files.",
});

spawn_agent({
  profile: "coding",
  message: "Implement the focused fix from this plan and run the narrowest relevant checks.",
});

spawn_agent({
  profile: "review",
  message: "Review the current diff for correctness, regressions, and missing tests.",
});
```

### Profile prompt style

Profiles keep the parent thread clean by adding role-specific prompt guidance to a fresh child session. They do not select models, thinking levels, tools, or approval rules.

Good spawned prompts are:

- **Role-specific**: research gathers context and sources, coding changes files, review looks for risk.
- **Explicit about scope**: include file areas, allowed edits, and what not to touch.
- **Output-shaped**: ask for file paths, links, findings, validation steps, or a handoff summary.

## Git safety

All sessions in a workspace share the same working directory.

Parallel spawning is fine when tasks touch different files. If multiple sessions may edit the same area, run them sequentially or use separate git worktrees.
