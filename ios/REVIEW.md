# Pi Remote iOS — Design Review (Final: Server Fixes Verified)

Review of server changes against Round 5 issues, plus final pass on the
complete iOS DESIGN.md + server codebase.

**Verdict: Ship it. Server and iOS design are aligned. Build Phase 1.**

---

## Round 5 Issue Resolution

| # | Issue | Severity | Status | Notes |
|---|-------|----------|--------|-------|
| 1 | Auto-scroll mechanism | High | ✅ Fixed | DESIGN.md has sentinel pattern, `withAnimation(nil)`, jump-to-latest |
| 2 | Server doesn't store assistant messages | **Critical** | ✅ Fixed | `extractAssistantText()` + `appendMessage()` on `message_end` |
| 3 | `saveSession()` blocks event loop | Medium | ✅ Fixed | `markSessionDirty()` + 1s debounce, `persistSessionNow()` for lifecycle |
| 4 | `__compaction`/`auto_retry` UI | Medium | ✅ Fixed | iOS design special-cases both; server unchanged (acceptable) |
| 5 | `agent_end` stale stats | Low | ✅ Fixed | `{ type: "state", session }` broadcast after lifecycle events |
| 6 | Non-text tool output dropped | Low | ✅ Documented | DESIGN.md notes v1 limitation |
| 7 | `toolOutput` coalescer bypass | Low | ✅ Accepted | Kept as-is |

All critical and medium issues are resolved. Clean work.

---

## Server Changes — Detailed Verification

### Assistant Message Storage ✅

`sessions.ts` `updateSessionFromEvent()` on `message_end`:

```typescript
const assistantText = this.extractAssistantText(message);
if (assistantText) {
    this.appendMessage(session, {
        role: "assistant",
        content: assistantText,
        timestamp: Date.now(),
        model: session.model,
        tokens,
        cost: usage?.cost,
    });
}
```

`extractAssistantText()` handles both string content and content-block arrays
(`text` and `output_text` part types). Correct — pi can return either format
depending on the model.

`appendMessage()` both writes to storage AND syncs the in-memory session
(messageCount, lastMessage, tokens, cost). The in-memory session stays
authoritative for `saveSession()` overwrites. No double-counting — the
on-disk session from `addSessionMessage()` and the in-memory session are
incremented by the same amounts, and `saveSession()` always overwrites with
the in-memory copy.

`GET /sessions/:id` now returns user + assistant messages. Reconnect works.

### Save Debouncing ✅

```
text_delta → updateSessionFromEvent → markSessionDirty(key)
                                          ↓ (1s timer)
                                      flushDirtySessions()
                                          ↓
                                      storage.saveSession()

agent_end → updateSessionFromEvent → persistSessionNow(key, session)
                                     (immediate, cancels dirty flag)
```

High-frequency events (deltas, tool output) queue a 1s batch. Lifecycle
events (agent_end, session stop/start) flush immediately. Node event loop
stays clear during streaming.

One minor note: `addSessionMessage()` inside `appendMessage()` still does
synchronous I/O. But this only fires on `message_end` (once per assistant
turn, not per delta), so it doesn't affect streaming smoothness.

### Session Stats Push ✅

```typescript
if (data.type === "agent_start" || data.type === "agent_end" || data.type === "message_end") {
    this.broadcast(key, { type: "state", session: active.session });
}
```

The iOS client now receives fresh `Session` (with tokens, cost, status) via
WebSocket at turn boundaries. No REST fetch needed to refresh session list
rows. The `state` message fires after `updateSessionFromEvent`, so the
session object has the latest values.

Event ordering the client sees:
```
{ type: "agent_end" }                    ← reducer transitions to idle
{ type: "state", session: { ... } }      ← sessionStore refreshes stats
```

Redundant signal, but the pipeline routes them to different stores
(AgentEvent pipeline vs SessionStore), so no conflict.

### Bonus Changes (Not From Review)

The agents also shipped:

1. **Abort fallback timer** — 5s after `abort`, if still busy, force-stops
   the session and broadcasts an error. Cleaned up on `agent_end` and session
   end. This matches the iOS design's "Force Stop Session" UX after ~5s.

2. **`stop` ClientMessage alias** — `{ type: "stop" }` handled same as
   `abort`. Matches the iOS design's stop button sending `"stop"`.

3. **WebSocket performance** — `perMessageDeflate: false` (no compression
   overhead on LAN), `{ compress: false }` on sends, `socket.setNoDelay(true)`
   (disable Nagle on upgrade). All correct for low-latency local streaming.

4. **`recordUserMessage()`** — Syncs in-memory session when `server.ts` stores
   a user message via `storage.addSessionMessage()`. Prevents `messageCount`
   and `lastMessage` from going stale on the active session object.

5. **Active session reference fix** — `handleClientMessage` now receives
   `activeSession` (live reference) instead of the initial `session` snapshot.
   Previously the prompt handler used a stale copy.

6. **REST `POST /sessions/:id/stop`** — Stops session without WebSocket.
   Returns updated session. Handles both active (graceful stop) and inactive
   (just set status) sessions.

7. **Orphaned container cleanup** on server start and shutdown.

All good additions. No issues.

---

## Remaining Nits (None Blocking)

### 1. `tool_output.isError` Never Populated (Cosmetic)

`types.ts` defines `isError?: boolean` on `tool_output`. The iOS design uses
it for "Error output: auto-expanded, red tinted." But `translateEvent` never
sets it:

```typescript
case "tool_execution_update": {
    const content = event.partialResult?.content?.[0];
    if (content?.type === "text") {
        return { type: "tool_output", output: content.text };
        //                                    ^ no isError
    }
}
```

**Impact:** Error tool output renders the same as normal output. The iOS
client can't auto-expand errors because it can't distinguish them.

**v2 fix:** Check if pi's `tool_execution_end` event carries error status
and backfill `isError` on the preceding output. Or: check `content.type`
for error-specific types (if pi uses them).

**v1 workaround:** All tool output is collapsed by default. Users tap to
expand. Acceptable — you lose the auto-expand affordance but nothing breaks.

### 2. `auto_retry_start` Still Maps to `error` (Server-Side)

The iOS design handles this correctly (checks for "Retrying (" prefix and
renders as info row instead of red error card). But the server-side mapping
is conceptually wrong — retries aren't errors. This works for v1 because the
iOS client special-cases it. For v2, consider a `system_notice` message type.

### 3. Redundant Disk Write After `message_end`

`appendMessage()` → `storage.addSessionMessage()` writes session+messages
to disk. Then `markSessionDirty()` queues another write 1s later. The second
write is redundant (reads back the same data and overwrites with identical
in-memory session). Harmless — one extra file write per assistant turn.

If it bothers you: skip `markSessionDirty()` after `appendMessage()`. But
not worth the code churn.

---

## Server ↔ iOS Protocol Alignment

Final check — every `ServerMessage` type has a corresponding iOS handler:

| Server Message | iOS Handler | Verified |
|---------------|-------------|----------|
| `connected` | ConnectionState + SessionStore | ✅ |
| `state` | SessionStore refresh | ✅ |
| `agent_start` | AgentEvent.agentStart → reducer | ✅ |
| `agent_end` | AgentEvent.agentEnd → reducer | ✅ |
| `text_delta` | AgentEvent.textDelta → coalescer → reducer | ✅ |
| `thinking_delta` | AgentEvent.thinkingDelta → coalescer → reducer | ✅ |
| `tool_start` | AgentEvent.toolStart → ToolEventMapper → reducer | ✅ |
| `tool_output` | AgentEvent.toolOutput → ToolOutputStore + reducer | ✅ |
| `tool_end` | AgentEvent.toolEnd → reducer | ✅ |
| `error` | AgentEvent.error → reducer (or system notice for retry) | ✅ |
| `session_ended` | SessionStore status + inline system card | ✅ |
| `permission_request` | PermissionStore + notification surface | ✅ |
| `permission_expired` | PermissionStore removal + UI update | ✅ |
| `permission_cancelled` | PermissionStore removal | ✅ |
| `extension_ui_request` | ExtensionDialogView sheet | ✅ |
| `extension_ui_notification` | ExtensionStatusView / ignore | ✅ |

Every `ClientMessage` type has a server handler:

| Client Message | Server Handler | Verified |
|---------------|---------------|----------|
| `prompt` | storage.addSessionMessage + sessions.sendPrompt | ✅ |
| `steer` | sessions.sendSteer (v2, deferred) | ✅ |
| `follow_up` | sessions.sendFollowUp (v2, deferred) | ✅ |
| `abort` | sessions.sendAbort + fallback timer | ✅ |
| `stop` | → abort alias | ✅ |
| `get_state` | sessions.getActiveSession → send state | ✅ |
| `permission_response` | gate.resolveDecision | ✅ |
| `extension_ui_response` | sessions.respondToUIRequest | ✅ |

No gaps. Protocol is fully aligned.

---

## Final Verdict

**The design is ready. Start building.**

- Server: all critical fixes landed, protocol is complete for v1
- iOS design: comprehensive, realistic, accounts for edge cases
- Performance: rendering pipeline will hit 60fps, debounced I/O won't stutter
- Reconnect: works now that assistant messages are stored
- Remaining nits are cosmetic and documented as v1 limitations

Build order: Phase 1 from the implementation plan. Start with networking +
models + stores, then the permission card (the money feature), then chat view
with streaming.
