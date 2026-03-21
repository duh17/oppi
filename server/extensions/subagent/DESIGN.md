# Oppi Subagent Extension — Design

> **Superseded by [`docs/design/multi-agent.md`](../../../docs/design/multi-agent.md).** This file is the original pre-implementation spec. Kept for historical reference — the actual implementation diverged significantly.

## Overview

A pi extension that gives the LLM tools to orchestrate subagent sessions through the
oppi server API. Combines ideas from three systems:

- **Pi subagent**: agent definitions as `.md` files (composable, file-based)
- **Codex multi-agent**: model-callable spawn/wait/check tools (LLM is the orchestrator)
- **Claude Code Teams**: peer-to-peer messaging between agents (no parent bottleneck)
- **Oppi (unique)**: fire-and-forget + iOS app as monitoring surface

The default mode is fire-and-forget: spawn agents and move on. The iOS app shows
every session's status, streams activity, and handles permissions. The parent agent's
context window stays clean. Synchronous wait is opt-in for chain workflows.

## Agent Definitions

An agent is a `.md` file with YAML frontmatter and a system prompt body.
Follows pi's format with two oppi-specific additions (`thinking`, `policy`).

```markdown
---
name: test-migrator
description: Migrates test files to shared support infrastructure
tools: read, write, edit, bash
model: openai-codex/gpt-5.3-codex
thinking: medium
policy: auto-approve
---

You are a test migration specialist for the Oppi iOS project.
Always read shared support files before modifying tests.
Use @testable import Oppi and import Testing (Swift Testing, not XCTest).
Commit with conventional commits (fix:, feat:, chore:).
```

### Schema

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | yes | — | Agent identifier for `spawn_agent` |
| `description` | string | yes | — | Shown to LLM for agent selection |
| `tools` | string | no | all | Comma-separated tool whitelist |
| `model` | string | no | parent's model | Model override |
| `thinking` | string | no | parent's level | off/minimal/low/medium/high/xhigh |
| `policy` | string | no | parent's policy | Policy mode override |

The markdown body is the system prompt prepended to the task message.

### Discovery

Project-level agents override user-level agents with the same name.

```
spawn_agent({ agent: "test-migrator", message: "..." })
  1. workspace .pi/agents/test-migrator.md
  2. ~/.pi/agent/agents/test-migrator.md
  3. Not found → error with available agent list
```

### Built-in Agents

Shipped with the extension as defaults. Users can override by creating a
file with the same name.

| Name | Model | Tools | Description |
|------|-------|-------|-------------|
| `worker` | parent's | all | General-purpose, full capabilities |
| `scout` | lighter model | read, grep, find, ls, bash | Fast read-only recon |
| `reviewer` | parent's | read, grep, find, ls, bash | Code review, no writes |

## Tool Surface

### spawn_agent

Create a session, start its pi process, send a task.

```
spawn_agent({
  agent?: "test-migrator",   // agent definition name (optional)
  message: "Migrate network tests to shared support",
  name?: "migrate: network", // session display name
  wait?: false,              // fire-and-forget (default) or block
})
→ { agent_id, name, status }
```

- If `agent` is provided, the agent definition's model/thinking/tools/policy/system-prompt
  are applied to the new session.
- If `agent` is omitted, the session inherits the parent's configuration and
  only `message` is sent as the prompt.
- `wait: true` blocks until terminal status, returns last message + stats.

### check_agents

Non-blocking status poll. Reads from the in-memory status map maintained
by the WebSocket notifications subscription.

```
check_agents({
  ids?: ["session-abc", "session-def"],  // specific IDs (default: all spawned)
})
→ { agents: [{ id, name, status, cost, duration_ms, last_message? }] }
```

### wait_agents

Block until specified agents reach terminal status.

```
wait_agents({
  ids: ["session-abc", "session-def"],
  timeout_ms?: 300000,     // default 5min, max 30min
})
→ { agents: [...], timed_out: boolean }
```

### message_agent

Send a message to any sibling session. The receiving agent gets it as
a follow-up prompt. Any spawned agent can call this — not just the parent.

```
message_agent({
  target: "session-def",    // target session ID or agent name
  message: "Shared factories are ready at ios/OppiTests/Support/TestFactories.swift"
})
→ { delivered: true }
```

### broadcast

Send a message to all spawned agents in the current team.

```
broadcast({
  message: "Phase 1 complete. Shared support files committed. Proceed with Phase 2."
})
→ { delivered_to: ["session-abc", "session-def", "session-ghi"] }
```

## Communication Architecture

```
           ┌──────────────────────────┐
           │      oppi server         │
           │                          │
           │  ┌────── /stream ──────┐ │
           │  │  WebSocket mux      │ │
           │  │  event ring/session │ │
           │  └──┬──────┬──────┬───┘ │
           └─────┼──────┼──────┼─────┘
                 │      │      │
         ┌───────┘      │      └───────┐
         ▼              ▼              ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │ Parent   │  │ Agent A  │  │ Agent B  │
   │ session  │  │ session  │  │ session  │
   │          │  │          │  │          │
   │ spawn_   │  │ message_ │  │ message_ │
   │ agent()  │  │ agent()  │  │ agent()  │
   └──────────┘  └──────────┘  └──────────┘
                      │              ▲
                      └──────────────┘
                    peer-to-peer via server
```

Each session subscribes to the server's WebSocket at `notifications` level.
`message_agent` and `broadcast` are routed through the server — the server
injects the message into the target session's event stream, which the target's
pi extension receives and delivers as a follow-up prompt.

### Fire-and-Forget Flow

```
User: "Dispatch 3 agents to refactor the test suite"

LLM calls:
  spawn_agent({ agent: "worker", message: "create TestFactories.swift...", name: "factories" })
  spawn_agent({ agent: "worker", message: "create TestWaiters.swift...", name: "waiters" })
  spawn_agent({ agent: "worker", message: "create TestDoubles.swift...", name: "doubles" })

LLM responds:
  "Dispatched 3 agents. Monitor from your phone."

User monitors via iOS app. Agents run independently.
When done, user asks parent: "how did they do?"

LLM calls:
  check_agents()
→ All 3 done, shows status/cost summary.
```

### Peer-to-Peer Flow

```
User: "Refactor tests in 2 phases — shared support first, then migrate callers"

LLM calls:
  spawn_agent({ agent: "worker", message: "Create TestFactories.swift...", name: "phase1-factories" })
  spawn_agent({ agent: "worker", message: "Create TestDoubles.swift...", name: "phase1-doubles" })
  spawn_agent({ agent: "worker", message: "Migrate network tests. Wait for a message from 
    phase1-factories and phase1-doubles before starting.", name: "phase2-network" })

Phase 1 agents complete. Each messages phase2-network:
  message_agent({ target: "phase2-network", message: "TestFactories.swift committed. Exports: ..." })
  message_agent({ target: "phase2-network", message: "TestDoubles.swift committed. Exports: ..." })

Phase 2 agent receives both messages, starts its migration.
No parent involvement needed for the handoff.
```

### Synchronous Chain Flow

```
User: "Scout the auth module, then plan a refactor"

LLM calls:
  result = spawn_agent({ agent: "scout", message: "Find all auth code...", wait: true })
  ← blocks until scout finishes →
  ← returns: { last_message: "Found 12 files..." }

  spawn_agent({ agent: "worker", message: "Plan refactor based on: {result.last_message}" , wait: true })
  ← blocks until worker finishes →

LLM synthesizes the plan.
```

## iOS App Integration

### Monitoring Surface

The iOS app already provides full visibility:
- Session list shows all agents with status badges (working/idle/error)
- Live Activity / Dynamic Island shows aggregate counters
- Deep links: `oppi://session/<id>` navigates to any session

### Subagent Status Bar (new component)

A collapsible bar in the parent's ChatView, above the input field:

```
┌───────────────────────────────────────┐
│ ⏳ 2 working · ✓ 1 done    [expand]  │  ← collapsed
├───────────────────────────────────────┤
│ ⏳ factories    codex   1:42       →  │  ← expanded: tap → navigate
│ ✓  waiters      codex  $0.12      →  │
│ ⏳ doubles      codex   1:38       →  │
│                           [collapse]  │
└───────────────────────────────────────┘
```

- Reads spawned session IDs from tool result details in the chat timeline
- Status updates from SessionStore (already fed by WS notifications)
- Tap row → `oppi://session/<id>` → navigates to that session's ChatView

## Server Changes Required

### New ClientMessage Types

```typescript
// Peer-to-peer message routing
| {
    type: "peer_message";
    targetSessionId: string;
    message: string;
    fromSessionId: string;
    requestId?: string;
  }
// Broadcast to all sessions in a team
| {
    type: "peer_broadcast";
    message: string;
    fromSessionId: string;
    teamId: string;         // groups sessions spawned by the same parent
    requestId?: string;
  }
```

### New ServerMessage Types

```typescript
// Delivered to target session
| {
    type: "peer_message";
    fromSessionId: string;
    fromSessionName?: string;
    message: string;
  }
```

### Session Metadata

Sessions need a `parentSessionId` field and a `teamId` to group siblings.
The server uses `teamId` for broadcast routing.

## Implementation Phases

### Phase 1: Core (spawn + check + fire-and-forget)

- Pi extension: `spawn_agent`, `check_agents` tools
- Agent definition discovery (`.md` files from workspace + user dirs)
- WebSocket notifications subscription for status tracking
- In-memory agent status map

### Phase 2: Wait + Peer Messaging

- `wait_agents` tool with WebSocket-based blocking
- `message_agent` and `broadcast` tools
- Server: `peer_message` routing between sessions
- Server: `teamId` tracking on sessions

### Phase 3: iOS UI

- SubagentStatusBar component in ChatView
- Parse spawned session IDs from tool result details
- Navigation via `oppi://session/<id>`

### Phase 4: Polish

- Custom TUI rendering (renderCall/renderResult)
- Built-in agent definitions (worker, scout, reviewer)
- Completion checks (run command after agent idle, retry on failure)

## Design Principles

1. **Fire-and-forget is the default.** The phone is the monitoring surface.
2. **The LLM is the orchestrator.** Tools are primitives it composes freely.
3. **Agents are `.md` files.** Simple, composable, version-controlled.
4. **Peer messaging bypasses the parent.** Agents unblock each other directly.
5. **The server is the mailbox.** All communication routes through the existing
   WebSocket infrastructure. No new transport layer.
