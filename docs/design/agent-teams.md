# Agent Teams — Design Notes

Status: stale

Food for thought. Not a spec. Captures the ideas from researching Codex, Claude Code
Teams, and pi subagent, and how they might come together in oppi.

## The Idea

Agent sessions in oppi already run independently — each with its own trace, tools,
and context window. What's missing is a way for them to coordinate.

The proposal: a **team channel** — a shared broadcast message bus that agents and the
human can all read and write. Like a Slack channel for agents.

```
┌──────────────────────────────────────────────────────┐
│                  Team Channel                         │
│                                                       │
│  [Agent A] TestFactories.swift committed.             │
│  [Agent B] TestDoubles.swift committed.               │
│  [Chen]    Good. A: migrate network tests.            │
│            B: migrate store tests.                    │
│  [Agent A] Starting network test migration.           │
│  [Agent B] Starting store test migration.             │
│  [Agent A] Done. 158 lines removed. Committed e36ed3c.│
│                                                       │
└──────────────────────────────────────────────────────┘
     ▲          ▲          ▲          ▲
     │          │          │          │
  Session A  Session B  Session C   iOS App
  (private)  (private)  (private)  (Chen)
```

Each agent does deep work in its private session. The channel is where you
choose to share findings. Not every tool call — just the things worth telling
the team about.

## What We Learned from Other Systems

### Pi Subagent

- Agent definitions as `.md` files with YAML frontmatter (name, description,
  model, tools) and markdown body as system prompt
- Single `subagent` tool with 3 modes: single, parallel, chain
- `{previous}` placeholder for output forwarding in chains
- Subprocess per agent, NDJSON streaming, rich TUI rendering
- All synchronous — tool blocks until agent completes

Best idea: **agent definitions as simple files**

### Codex Multi-Agent

- 5 tools the model calls: `spawn_agent`, `send_input`, `resume_agent`,
  `wait`, `close_agent`
- In-process threads per agent (not subprocesses)
- Roles defined in TOML config with model/sandbox overrides
- Wait is a tool — model explicitly decides when to block
- Depth-limited spawning (agents can spawn sub-agents)

Best idea: **model-callable spawn/wait as LLM tools**

### Claude Code Agent Teams

- Lead agent + teammates, each a separate Claude Code instance
- Mailbox system: `message` (point-to-point) and `broadcast` (all)
- Shared task list with dependency tracking and self-claiming
- Human interacts by cycling through sessions (Shift+Down) or tmux panes
- Quality gate hooks: TeammateIdle, TaskCompleted
- No pre-configured agent prompts — model decomposes work naturally

Best idea: **peer communication + human as participant**

## What's Different About Oppi

None of these systems have a phone.

Codex is cloud-hosted and headless. Pi is terminal-bound. Claude Code gives you
tmux panes or Shift+Down cycling. All assume the human is at a keyboard.

Oppi has an iOS app that already:
- Shows all session status with live updates (WebSocket notifications)
- Handles permission approvals from the lock screen (Dynamic Island)
- Deep-links to any session (`oppi://session/<id>`)
- Streams tool activity, change stats, and errors in real-time

The phone is the monitoring surface. Fire-and-forget becomes the natural default
because the human doesn't need to be at the terminal to supervise.

## Design Principles

1. **Fire-and-forget is the default.** Spawn agents and move on. The phone monitors.

2. **The model is the orchestrator.** No scripted pipelines. Tools are primitives
   the LLM composes based on the task. It already knows how to decompose work.

3. **No built-in agent definitions.** The model writes spawn prompts naturally.
   Agent `.md` files are user convenience for repeated configs, not required.

4. **Tool restrictions are advisory, not enforced.** Bash can bypass any "read-only"
   tool list. Don't name agents "reader" when you can't enforce it.

5. **Broadcast channel, not directed messages.** All agents see all channel
   messages. Simpler to implement, simpler to render, and for 3-5 agents
   the noise is manageable. Agents self-filter relevance.

6. **Human is a channel member.** The iOS app renders the channel as a group
   chat. You can post messages, and idle agents react.

## Tool Surface

| Tool | Description |
|------|-------------|
| `spawn_agent` | Create session, send task, join team channel. Fire-and-forget by default; `wait: true` blocks. |
| `post` | Post a message to the team channel. All members (agents + human) see it. |
| `check_agents` | Non-blocking status of team members. Reads from in-memory map fed by WS notifications. |
| `wait_agents` | Block until specified agents reach terminal status. For chain workflows. |

`spawn_agent` without an `agent` field works — just sends the message as a prompt
with the parent's configuration inherited. Agent `.md` files are optional overrides.

## Agent Definitions (Optional)

Pi's format with two oppi additions:

```markdown
---
name: ios-fixer
description: Fixes iOS build errors and test failures
model: openai-codex/gpt-5.3-codex
thinking: medium
policy: auto-approve
---
You work on the Oppi iOS project. When given a build error or test failure,
find the root cause and fix it. Run xcodebuild to verify. Commit when green.
```

Discovery: workspace `.pi/agents/` then user `~/.pi/agent/agents/`.
Project overrides user for same-name files.

## Session Lifecycle in a Team

```
spawned  → session created, joins team channel
busy     → working on task in private session
idle     → task done, checking channel for new work
stopped  → session ended, visible in channel history
```

What wakes an idle agent:
- Channel message from human → delivered as steer (immediate)
- Channel message from agent → delivered as follow-up (next idle)
- Nothing within timeout → auto-stop (default 60s)

## iOS Surfaces

### Team Channel View

A new view alongside existing session chat. Renders as a group chat timeline.
Tap an agent name to jump to its private session.

### Subagent Status Bar

Collapsible bar in the parent session's ChatView (above input field).
Shows spawned agent status, tap to expand or navigate.

### Dynamic Island (existing)

Already tracks aggregate session counts. Works for free with team sessions
since they're regular oppi sessions.

## Server Changes

### Team Channel

```typescript
interface TeamChannel {
  teamId: string;
  parentSessionId: string;
  memberSessionIds: Set<string>;
  messages: EventRing;
}
```

### New Message Types

```typescript
// Client → Server
| { type: "team_post"; teamId: string; message: string }

// Server → Client (delivered to all team members)
| { type: "team_message"; teamId: string; fromSessionId: string;
    fromName?: string; message: string; timestamp: number }
```

### Session Metadata

Sessions gain `teamId` and `parentSessionId` fields.

## Open Questions

- Should the channel have structure (like Claude Code's task list) or be
  free-form text only? Leaning free-form — the model manages coordination
  naturally, and a task list adds protocol complexity.

- How does an agent's pi extension know it's in a team? Environment variable
  set by the server? A new RPC command? The extension needs to register the
  `post` tool and subscribe to channel messages.

- Token cost: every channel message becomes a follow-up prompt for idle agents.
  With 5 chatty agents, that's 5x the cost of directed messages. Acceptable
  for 3-5 agents but wouldn't scale to 20+. Fine for the solo builder use case.

- Should the channel persist across session restarts? If Agent A stops and
  restarts, does it see channel history? Probably yes — the EventRing already
  supports catch-up replay via sinceSeq.

## Comparison

| | Pi Subagent | Codex | Claude Code Teams | Oppi (proposed) |
|---|---|---|---|---|
| Communication | None (report to parent) | send_input (parent→child) | Mailbox (point-to-point) + broadcast | Team channel (broadcast) |
| Coordination | Chain mode `{previous}` | Model composes tools | Shared task list + dependencies | Free-form channel messages |
| Human interaction | Terminal (parent session) | N/A (cloud) | Cycle through sessions | iOS app group chat |
| Monitoring | TUI (parent terminal) | Cloud dashboard | tmux panes | Phone (Dynamic Island + app) |
| Default mode | Synchronous (blocks) | Synchronous (blocks) | Asynchronous (lead manages) | Fire-and-forget |
| Agent definitions | `.md` files (required) | TOML config (required) | None (model writes prompts) | `.md` files (optional) |
