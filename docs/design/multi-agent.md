# Multi-Agent Design

**Status:** Living document — reflects shipped state + roadmap  
**Canonical source:** This file replaces the stale `server/extensions/subagent/DESIGN.md` and `.internal/docs-design/agent-teams.md`.

## Core Insight

The phone changes everything about multi-agent orchestration.

Pi subagent, Codex, and Claude Code Teams all assume the human is at a keyboard monitoring terminal output. Oppi has an iOS app that streams session activity, handles permissions from the lock screen, and deep-links to any session. Fire-and-forget becomes the natural default because supervision doesn't require the terminal.

The model is the orchestrator. It gets primitive tools and composes them as the task demands. No scripted pipelines, no required agent definition files, no workflow DSL.

## Design Principles

1. **Fire-and-forget is the default.** Spawn agents and move on. The phone is the monitoring surface.
2. **The model writes the prompts.** Agent `.md` definitions are optional convenience for repeated configs. The model decomposes work naturally in the spawn message.
3. **Flat hierarchy.** One level of delegation. Children do focused work without spawning further. If you need an independent peer, use detached mode.
4. **Full response retrieval.** The parent must be able to read the complete output of any child. Truncation killed early audit/analysis workflows until the `response` param and JSONL trace reading fixed it.
5. **Two spawn modes, one tool.** `spawn_agent` handles both tree children and independent sessions. The `detached` flag is the only fork point.
6. **Tool restrictions are advisory.** Bash can bypass any "read-only" tool list. Don't pretend sandboxing exists when it doesn't. Scope constraints live in the prompt, not tool registration.

## What Shipped

### Tools

| Tool | Purpose |
|------|---------|
| `spawn_agent(message, ...)` | Create + start + prompt a session. Default: child in tree. `detached: true`: independent session. `wait: true`: block for result. |
| `check_agents()` | Non-blocking status poll. Tree-wide cost aggregation. |
| `inspect_agent(id, ...)` | Progressive trace disclosure. Overview → turn → tool detail. `response: true` returns full assistant text. |

### Spawn Modes

```
spawn_agent(message)
  → Child session. parentSessionId set.
  → Visible in check_agents and inspect_agent.
  → No spawn tools registered (cannot delegate further).
  → Monitored by parent + iOS app.

spawn_agent(message, detached: true)
  → Independent session. No parentSessionId.
  → NOT visible in check_agents (not in tree).
  → Gets full capabilities including its own spawn_agent.
  → Monitored only via iOS app.
```

### Server Infrastructure

- `parentSessionId` on Session type — REST, persistence, WebSocket state broadcasts
- `spawnChildSession()` — creates session with parent link, broadcasts to parent subscribers
- `spawnDetachedSession()` — creates session in same workspace, no parent link
- Spawn tools conditionally registered: only for sessions where `!parentSessionId`
- Tree utilities: `getSpawnDepth`, `getRootSessionId`, `getDescendants`, `computeTreeCost`
- Session limits: 10/workspace, 20 global

### iOS

- Session tree with collapsible parent-child hierarchy in workspace detail
- Child status bar in parent ChatView
- Parent breadcrumb in child ChatView — tap to navigate back
- See [session-tree-list.md](session-tree-list.md) for full tree UI spec

### Response Retrieval

Every path to a child's response previously truncated it. Fixed in commit 64bcfe1:

| Path | Truncation |
|------|-----------|
| `inspect_agent(id)` overview | 200 chars (preview — intentional) |
| `inspect_agent(id, turn: N)` | 5000 chars |
| `inspect_agent(id, response: true)` | Full text, no truncation |
| `inspect_agent(id, turn: N, response: true)` | Full text for that turn |
| `spawn_agent(wait: true)` | Full text from JSONL trace |

## Design Decisions

### Why children can't spawn

Early design allowed depth-limited spawning (MAX_SPAWN_DEPTH=2). In practice, the model rarely composed multi-level trees well, and the resource implications of unbounded recursive spawning were hard to reason about.

Simpler model: children do the work. If you need a peer, use `detached: true` from the root session. The detached session is a full citizen — it can spawn its own children.

### Why inspect_agent exists (not in original design)

The original spec had check_agents for status and wait for blocking. During implementation, a gap appeared: the parent needs to understand *what* a child did, not just whether it finished. Reading files, checking git log, or re-doing analysis defeats the purpose of delegation.

`inspect_agent` fills this with progressive disclosure: overview first (cheap), drill into turns or tools only when investigating problems. The `response: true` flag was added later when audit/analysis workflows showed that even 500-char truncation was too aggressive.

### Why detached mode instead of a separate dispatch tool

The dispatch-session personal skill (CLI-based, REST API) predates spawn_agent. It creates sessions without parent links. Rather than maintaining two code paths, `detached: true` on spawn_agent provides the same behavior from inside a session. The dispatch skill remains useful for CLI/automation contexts where no parent session exists.

### Why wait is a param, not a separate tool

The original design had `wait_agents` as a separate tool for blocking on multiple children. In practice, `spawn_agent(wait: true)` handles the common case (sequential chain). For parallel fan-out, fire-and-forget + `check_agents` polling works well enough with the prompt guideline "don't poll in a tight loop."

A blocking `check_agents(wait: true)` that returns when any child transitions to terminal would eliminate polling entirely. This is a future optimization, not a blocker.

## Research Sources

Summarized from the original research (full notes in `.internal/docs-design/agent-teams.md`):

| System | Key idea we adopted | Key idea we rejected |
|--------|--------------------|--------------------|
| **Pi subagent** | Agent definitions as `.md` files (deferred, not rejected) | Synchronous-only execution. Subprocess per agent. |
| **Codex** | Model-callable spawn/wait as LLM tools | TOML config. In-process threads. |
| **Claude Code Teams** | Peer messaging concept (deferred) | Shared task list with dependency tracking. tmux-based monitoring. |

## Future Phases

### Peer Messaging (deferred)

`message_agent(target, message)` — send a follow-up prompt to a sibling session. Enables phase-based workflows where Agent A tells Agent B "shared fixtures are ready" without parent involvement.

`broadcast(message)` — post to all team members. Possibly as a team channel view in the iOS app (group chat of agents + human).

Server requires: new message routing through WebSocket, `teamId` on sessions for broadcast scoping.

### Agent Definitions (deferred)

`.md` files with YAML frontmatter (name, description, model, thinking, policy) and system prompt body. Discovery: workspace `.pi/agents/` then user `~/.pi/agent/agents/`. Project overrides user for same-name files.

Not rejected — just not needed yet. The model writes good spawn prompts without them. Definitions become useful when you have recurring agent roles across many sessions.

### Blocking check_agents (future optimization)

`check_agents(wait: true)` — holds the response until at least one child transitions to terminal. Eliminates polling loops. Implementation: subscribe to child state changes, resolve when any fires.

### Cascade Stop

Stopping a parent should stop all children. The idle timer should check for active children before auto-stopping a parent. See [session-tree-list.md](session-tree-list.md) for server changes required.

## Files

| File | Role |
|------|------|
| `server/src/spawn-agent-extension.ts` | Tool registration, schemas, trace parsing, renderers, wait mode |
| `server/src/spawn-agent-extension.test.ts` | 64 tests |
| `server/src/session-start.ts` | Conditional extension injection (root/detached only) |
| `server/src/sessions.ts` | `spawnChildSession`, `spawnDetachedSession`, `listChildSessions` |
| `server/src/session-coordinators.ts` | Wiring through coordinator bundle |
| `server/src/session-protocol.ts` | Session message counters, `lastMessage` truncation |
| `server/src/types.ts` | `Session.parentSessionId` |
