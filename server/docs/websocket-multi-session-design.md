# WebSocket Architecture: Multi-Session & Notification Mapping

Last updated: 2026-02-09 (revised: Live Activity audit per Apple ActivityKit docs + HIG)

> Historical design note: this document captures migration analysis across phases.
> Canonical current routes are in `README.md` and `src/routes.ts`.

## Current State

### Server (`oppi-server/src/server.ts`)
- **One WS per session:** `GET /workspaces/:wid/sessions/:sid/stream` → per-session WebSocket
- **User connection tracking:** `Map<userId, Set<WebSocket>>` — multiple WS connections per user already supported
- **Broadcast:** `broadcastToUser(userId, msg)` sends to ALL open WS connections for that user
- **Push fallback:** When no WS connections open → APNs push notification
- **Session lifecycle:** WS open → `startSession()` → subscribe to session events → drain queued messages
- **No multiplexing:** Each WS carries events for exactly one session

### iOS Client (`WebSocketClient.swift`, `ServerConnection.swift`)
- **v1 one-stream policy:** `connect(sessionId:)` disconnects previous WS first
- **Single pipeline:** `ServerConnection` owns one `WebSocketClient`, one `TimelineReducer`, one `DeltaCoalescer`
- **Session switching:** Disconnect old → reset pipeline → connect new (full teardown/rebuild)
- **Silence watchdog:** Detects zombie WS (TCP alive, no frames) → force reconnect

### Notifications
- **Local notifications:** `PermissionNotificationService` fires `UNNotification` when backgrounded
- **Remote push:** APNs via `push.ts` when no WS connected (permission requests, session events)
- **Live Activity:** One `Activity<PiSessionAttributes>` at a time (matches one-stream policy)
- **No thread grouping:** No `threadIdentifier` on notifications — all permissions are flat
- **No workspace/session scoping:** Notifications don't indicate which workspace they belong to

---

## Problem

The current architecture is strictly one-session-at-a-time. For multi-workspace supervision:

1. User has 3 workspaces: `coding`, `research`, `ops`
2. Each workspace may have 1+ active sessions
3. User is chatting with `coding` session but needs to see that `ops` got a permission request
4. Scheduled runs in `research` complete → user needs a grouped notification
5. User switches to `ops` workspace → needs instant catch-up without full reconnect

**The v1 one-stream model forces the user to miss events from non-active sessions.**

---

## Design: Multiplexed WebSocket

### Option A: Single Multiplexed WS (recommended)

One WebSocket connection, all sessions multiplexed. Every `ServerMessage` gains a `sessionId` field.

```
Phone ──── 1 WebSocket ──── Server
              ↕ all sessions for this user
```

**Why:**
- One TCP connection to manage (battery, reconnect, keepalive)
- Server already has `broadcastToUser` — just tag messages with sessionId
- Permission requests from ANY session arrive on the single pipe
- iOS can route by sessionId to the appropriate reducer/store
- Matches how Slack/Discord/Teams work (one socket, many channels)

**Server changes:**
```ts
// Upgrade path changes from historical session-scoped stream endpoint to /stream
// Server subscribes the WS to ALL active sessions for this user

// Every ServerMessage gets sessionId
type ServerMessage =
  | { type: "text_delta"; sessionId: string; delta: string }
  | { type: "permission_request"; sessionId: string; ... }
  | { type: "workspace_event"; workspaceId: string; ... }  // new
  // ...

// Client subscribes/unsubscribes to session streams
type ClientMessage =
  | { type: "subscribe"; sessionId: string }     // start receiving events
  | { type: "unsubscribe"; sessionId: string }   // stop receiving events
  | { type: "prompt"; sessionId: string; message: string; ... }  // all commands scoped
  // ...
```

**iOS changes:**
- `WebSocketClient` connects once (not per-session)
- `ServerConnection` demuxes by sessionId → per-session reducers
- Active chat session gets full streaming (text_delta, thinking_delta)
- Background sessions get lightweight events (permission_request, session_ended, error)

### Option B: Multiple WS Connections (rejected)

One WebSocket per active session.

**Why not:**
- N TCP connections (battery drain, reconnect complexity)
- Permission requests only arrive on their session's WS — if that WS is disconnected, need push fallback
- More complex lifecycle management
- iOS background execution budget is per-process, not per-connection

### Option C: Hybrid (single WS + subscription tiers) — **enhanced Option A**

Single WS with explicit subscription levels:

```ts
type ClientMessage =
  | { type: "subscribe"; sessionId: string; level: "full" | "notifications" }
  | { type: "unsubscribe"; sessionId: string }
  // ...
```

- `full`: All events (text_delta, thinking_delta, tool_start, etc.) — only for the active chat
- `notifications`: Lightweight events only (permission_request, session_ended, error, agent_start, agent_end) — for background sessions

**This is the recommended approach.** It preserves bandwidth for the active session while keeping the user informed about background sessions.

---

## Concept Mapping

### WebSocket Messages → iOS Notification Constructs

| Server Event | Active Session (full) | Background Session (notifications) | App Backgrounded | iOS Construct |
|---|---|---|---|---|
| `text_delta` | → TimelineReducer | — (not sent) | — | DeltaCoalescer → SwiftUI |
| `thinking_delta` | → TimelineReducer | — | — | DeltaCoalescer → SwiftUI |
| `tool_start` | → TimelineReducer | → SessionStore status | — | Timeline row / badge |
| `tool_end` | → TimelineReducer | → SessionStore status | — | Timeline row / badge |
| `agent_start` | → TimelineReducer | → SessionStore status | — | Live Activity update |
| `agent_end` | → TimelineReducer | → SessionStore status | → APNs (if interesting) | Live Activity / push |
| `permission_request` | → PermissionStore + overlay | → PermissionStore + banner | → APNs time-sensitive | UNNotification (threadId=session) |
| `permission_expired` | → PermissionStore | → PermissionStore | — | Cancel notification |
| `session_ended` | → TimelineReducer | → SessionStore | → APNs passive | UNNotification (threadId=workspace) |
| `error` | → TimelineReducer | → SessionStore badge | → APNs (non-retry) | UNNotification (threadId=session) |
| `compaction_start` | → TimelineReducer | — | — | — |
| `compaction_end` | → TimelineReducer | — | — | — |
| `rpc_result` | → handleRPCResult | — | — | — |
| **New events** | | | | |
| `workspace_sessions_changed` | → WorkspaceStore | → WorkspaceStore | — | Badge count update |
| `scheduled_execution_finished` | → AutomationStore | → AutomationStore | → APNs digest | UNNotification (threadId=workspace) |

### iOS Notification Threading (UNNotification.threadIdentifier)

iOS groups notifications by `threadIdentifier`. This maps perfectly to our hierarchy:

```
Thread ID Format              Groups Into
─────────────────────────────────────────────
workspace-{workspaceId}       All events for a workspace
session-{sessionId}           All events for a session
permission-{sessionId}        Permission requests for a session
automation-{workspaceId}      Scheduled run results
```

**Recommended threading:**

| Notification Type | threadIdentifier | Category | Interruption Level |
|---|---|---|---|
| Permission request (low/med) | `session-{sessionId}` | `PERMISSION_REQUEST` | `timeSensitive` |
| Permission request (high/crit) | `session-{sessionId}` | `PERMISSION_BIOMETRIC` | `timeSensitive` |
| Session ended | `workspace-{workspaceId}` | `SESSION_DONE` | `passive` |
| Session error | `session-{sessionId}` | `SESSION_ERROR` | `active` |
| Scheduled run success | `automation-{workspaceId}` | `AUTOMATION_DONE` | `passive` |
| Scheduled run failed | `automation-{workspaceId}` | `AUTOMATION_FAILED` | `active` |
| Scheduled run blocked | `automation-{workspaceId}` | `AUTOMATION_BLOCKED` | `timeSensitive` |

**Deduplication rules:**
1. Permission requests use `perm-{permissionId}` as notification identifier → replacing same ID cancels old
2. Session ended/error uses `session-event-{sessionId}` → latest event wins per session
3. Automation results use `auto-{executionId}` → unique per execution
4. When app returns to foreground → cancel all delivered notifications for the active session

### Live Activity Mapping (revised per Apple docs)

#### Current Implementation Audit

Our `LiveActivityManager.swift` + `PiSessionAttributes` have several gaps
against Apple's ActivityKit documentation and HIG:

| Issue | Severity | Detail |
|---|---|---|
| **`pushType: nil`** | Critical | We pass `nil` to `Activity.request()`. Without `.token`, the system never delivers push tokens. Server-side Live Activity updates are impossible when the app is backgrounded. Server has `sendLiveActivityUpdate()` / `endLiveActivity()` ready but iOS never obtains or sends push tokens. |
| **No `staleDate`** | High | We never set staleDate on `ActivityContent`. If the app loses WS connection, the Live Activity shows stale data with zero indication to the user. Apple recommends advancing staleDate with each update. |
| **No `alertConfiguration`** | High | Permission requests could trigger `alertConfiguration` on Live Activity update (lights up screen, shows expanded DI on non-DI devices as banner). Instead we fire separate local notifications — duplicating effort. |
| **No deep linking** | Medium | Tapping the Live Activity opens the app generically. Should deep-link to the specific session via `widgetURL()` or `Link`. |
| **No interactive elements** | Medium | Could add Allow/Deny `Button` (via App Intents `LiveActivityIntent`) directly on the expanded Live Activity. Killer UX for permission approval without opening the app. |
| **Manual elapsed timer** | Low | We poll elapsed every 30s. Should use SwiftUI `Text(startTime, style: .timer)` for automatic, system-rendered countdown with zero updates needed. |
| **No `relevanceScore`** | Low (v1) | Single activity doesn't need it. Required for multi-session (permission-pending sessions should score highest). |
| **No activity cleanup on launch** | Low | Apple says check `Activity.activities` on launch and end stale ones from previous crashes. We don't. |
| **No `frequentPushesEnabled` sync** | Low | We log it but don't send to server. Server should throttle push frequency based on this. |

**What's correct:**
- `areActivitiesEnabled` check before starting ✓
- Throttled updates (1/sec matches ActivityKit's own budget) ✓
- Coarse state only (no text_delta streaming — matches HIG) ✓
- All presentations implemented (Lock Screen, compact, minimal, expanded) ✓
- `endIfNeeded()` with dismissal policy ✓
- 5-min dismissal (within Apple's "15-30 min typical" range, reasonable for our use case) ✓

#### Apple's Key Constraints

From the official documentation:

| Constraint | Value | Impact |
|---|---|---|
| Max activity duration | **8 hours** (auto-ended by system) | Long agent sessions will lose their Live Activity. Must handle gracefully. |
| Lock Screen persistence after end | **Up to 4 hours** (12 total) | Good — user can glance at final status. |
| Push priority 10 budget | **System-imposed per hour** | Mix priority 5 (free) and 10 (budgeted). Only use 10 for permissions. |
| `NSSupportsLiveActivitiesFrequentUpdates` | Opt-in, user-disablable | We should add this Info.plist key for tool-change updates. |
| Push tokens | **Per-activity, can change** | Must track via `pushTokenUpdates` async sequence and re-send to server. |
| Push-to-start tokens (iOS 17.2+) | Start Live Activity from server push | Server could auto-start activity when scheduled run begins, even if app is backgrounded. |
| Multiple activities per app | **Up to 5** | System uses `relevanceScore` to pick Dynamic Island occupant. |
| Interactive elements | Button/Toggle via `LiveActivityIntent` | Can add Allow/Deny directly in expanded presentation. |
| Alert configuration | Lights up screen, shows expanded DI | Use for permission requests instead of separate local notification. |
| Animation duration | **Max 2 seconds** | Our status transitions are fine. |

#### HIG: "Track multiple events with a single Live Activity"

Apple HIG explicitly says:
> "Let people track multiple events efficiently with a single Live Activity.
> Instead of creating separate Live Activities people need to jump between
> to track different events, prefer a single Live Activity that uses a
> dynamic layout and rotates through events."

This changes our multi-session strategy. Instead of one-activity-per-session:

**Recommended: One "Control Tower" Live Activity for all sessions**

```
┌─────────────────────────────────────────────────┐
│ Lock Screen                                      │
│                                                  │
│  ┌─────────────────────────────────────────────┐│
│  │ 🖥 Pi Remote           2 busy · 1 pending  ││
│  │                                             ││
│  │  coding: editing auth.ts         ● Working  ││
│  │  research: [PENDING] bash: rm    ⚠ Approve  ││
│  │  ops: idle                       ○ Ready    ││
│  │                                             ││
│  │  ⏱ 12:34                    Tap to approve  ││
│  └─────────────────────────────────────────────┘│
└─────────────────────────────────────────────────┘
```

Compact presentation:
- Leading: `🖥` (or workspace icon of most-critical session)
- Trailing: `⚠ 1` (pending permission count) or `● 2` (active sessions)

Minimal presentation:
- Permission pending: orange exclamation badge
- All idle: green dot
- Working: yellow dot

Expanded presentation:
- Per-session rows (max 3-4 visible) sorted by criticality
- Permission-pending sessions at top with Allow/Deny buttons (App Intents)
- Active tools shown inline
- Deep-link per row to that session's chat

#### Revised Attributes (multi-session aware)

```swift
struct PiAgentAttributes: ActivityAttributes {
    // Static: set once
    let userId: String

    struct ContentState: Codable, Hashable {
        var sessions: [SessionSummary]    // all active sessions
        var totalPending: Int             // total pending permissions
        var mostCriticalSessionId: String? // for deep-link on tap
    }

    struct SessionSummary: Codable, Hashable {
        let sessionId: String
        let workspaceName: String
        let workspaceIcon: String?        // SF Symbol or emoji
        var status: String                // busy, ready, stopped, error
        var activeTool: String?
        var pendingPermissions: Int
        var lastEvent: String?
    }
}
```

#### Push Integration (fixing the `pushType: nil` gap)

```swift
// Start with pushType: .token
let activity = try Activity.request(
    attributes: attributes,
    content: .init(state: initialState, staleDate: Date.now + 60),
    pushType: .token  // CRITICAL: enables server-side updates
)

// Forward push token to server
Task {
    for await pushToken in activity.pushTokenUpdates {
        let tokenString = pushToken.reduce("") { $0 + String(format: "%02x", $1) }
        try? await api.registerDeviceToken(tokenString, tokenType: "liveactivity")
    }
}
```

Server uses push token for:
- **Priority 5** (free): tool_start, agent_start/end, status changes
- **Priority 10** (budgeted): permission_request (with `alertConfiguration`), errors
- **Push-to-start** (iOS 17.2+): scheduled run begins → auto-start Live Activity

#### staleDate Strategy

```swift
// Set staleDate to 60s from now on each update.
// If no update arrives within 60s, system marks activity stale.
// Widget extension checks context.isStale and shows "Reconnecting..." overlay.
let content = ActivityContent(
    state: newState,
    staleDate: Date.now + 60,
    relevanceScore: newState.totalPending > 0 ? 100 : 50
)
await activity.update(content)
```

#### Interactive Allow/Deny (App Intents)

```swift
// In the widget extension:
struct AllowPermissionIntent: LiveActivityIntent {
    @Parameter(title: "Permission ID")
    var permissionId: String

    func perform() async throws -> some IntentResult {
        // Send allow to server via shared URLSession
        try await PermissionActionService.shared.allow(permissionId)
        return .result()
    }
}

// In expanded presentation:
if session.pendingPermissions > 0 {
    HStack {
        Button(intent: AllowPermissionIntent(permissionId: pendingId)) {
            Label("Allow", systemImage: "checkmark.circle")
        }
        Button(intent: DenyPermissionIntent(permissionId: pendingId)) {
            Label("Deny", systemImage: "xmark.circle")
        }
    }
}
```

**Note:** Interactive elements require careful design. Apple HIG says "prefer
limiting it to a single element." For permissions, two buttons (Allow/Deny)
is acceptable since it's the core supervisory action.

#### Migration from v1

| Step | Change |
|---|---|
| 1. Fix `pushType` | Change `nil` → `.token`, forward token to server |
| 2. Add `staleDate` | Set 60s ahead on each update |
| 3. Add `alertConfiguration` | For permission_request updates only |
| 4. Add deep linking | `widgetURL` → session-specific URL scheme |
| 5. Use `Text(.., style: .timer)` | Replace manual elapsed timer |
| 6. Activity cleanup on launch | Check `Activity.activities`, end stale ones |
| 7. Multi-session attributes | Redesign `PiSessionAttributes` → `PiAgentAttributes` |
| 8. Interactive Allow/Deny | Add `LiveActivityIntent` for permission actions |
| 9. Push-to-start | For scheduled run auto-start |

---

## Server Protocol Changes

### New Endpoint

Replace per-session WS with per-user WS:

```
GET /stream                  # New: multiplexed user stream
GET <historical session-scoped stream endpoint>  # Deprecated during migration
```

### New Client Messages

```ts
// Subscribe to a session's event stream
| { type: "subscribe"; sessionId: string; level: "full" | "notifications" }

// Unsubscribe from a session
| { type: "unsubscribe"; sessionId: string }

// All existing commands gain mandatory sessionId
| { type: "prompt"; sessionId: string; message: string; ... }
| { type: "steer"; sessionId: string; message: string; ... }
| { type: "permission_response"; sessionId: string; id: string; ... }
// etc.
```

### New Server Messages

```ts
// All existing messages gain sessionId (already present on permission_request)
| { type: "text_delta"; sessionId: string; delta: string }
| { type: "agent_start"; sessionId: string }
// etc.

// New workspace-level events
| { type: "workspace_sessions_changed"; workspaceId: string; sessions: SessionSummary[] }
| { type: "scheduled_execution_started"; workspaceId: string; runId: string; executionId: string }
| { type: "scheduled_execution_finished"; workspaceId: string; runId: string; executionId: string; status: string; silent: boolean }
```

### Auto-Subscribe Behavior

On WS connect, server auto-subscribes client to `notifications` level for ALL active sessions. Client explicitly upgrades ONE session to `full` when entering chat.

```
1. WS opens → server sends workspace_sessions_changed for each workspace
2. Client sends subscribe(sessionId=X, level="full") → enters chat
3. Background sessions continue sending permission_request, agent_end, error
4. Client sends subscribe(sessionId=Y, level="full") → old X downgrades to notifications
5. Only ONE full subscription at a time (enforced server-side)
```

---

## iOS Architecture Changes

### Connection Layer

```swift
// Before (v1)
ServerConnection → WebSocketClient → one session stream

// After (v2)
ServerConnection → WebSocketClient → multiplexed user stream
                 → SessionRouter (demux by sessionId)
                   → ActiveSessionPipeline (full: coalescer → reducer → timeline)
                   → BackgroundSessionMonitor (notifications: store updates + badges)
                   → PermissionStore (all sessions)
```

### SessionRouter (new)

```swift
@MainActor @Observable
final class SessionRouter {
    /// The session receiving full streaming events.
    private(set) var activeSessionId: String?

    /// Per-session lightweight state for background sessions.
    private(set) var sessionStates: [String: BackgroundSessionState] = [:]

    /// Route incoming server message to appropriate handler.
    func route(_ message: ServerMessage) {
        guard let sessionId = message.sessionId else { return }

        if sessionId == activeSessionId {
            // Full pipeline: coalescer → reducer → timeline
            activePipeline.receive(message)
        } else {
            // Lightweight: update status, handle permissions, fire notifications
            backgroundMonitor.receive(message, sessionId: sessionId)
        }
    }

    func setActive(_ sessionId: String) {
        // Downgrade old active → notifications
        // Upgrade new → full
    }
}
```

### BackgroundSessionState (new)

```swift
struct BackgroundSessionState {
    let sessionId: String
    let workspaceId: String
    var status: String          // ready, busy, stopped, error
    var pendingPermissions: Int
    var lastEvent: String?
    var lastActivity: Date
}
```

This powers:
- Tab bar badges (total pending permissions across all sessions)
- Session list status indicators
- Workspace summary cards

### Push Notification Integration

Server-side `broadcastToUser` already handles the WS-connected case. For backgrounded app:

```ts
// server.ts - enhanced pushFallback
private pushFallback(userId: string, msg: ServerMessage): void {
    // ... existing logic ...

    // NEW: include threadIdentifier in APNs payload
    if (msg.type === "permission_request") {
        payload.aps["thread-id"] = `session-${msg.sessionId}`;
    }
    if (msg.type === "session_ended") {
        payload.aps["thread-id"] = `workspace-${session?.workspaceId || "default"}`;
    }
    if (msg.type === "scheduled_execution_finished") {
        payload.aps["thread-id"] = `automation-${msg.workspaceId}`;
    }
}
```

iOS-side local notifications also get threading:

```swift
// PermissionNotificationService.swift
content.threadIdentifier = "session-\(request.sessionId)"
```

---

## WebSocket Best Practices Applied

### 1. Compression: OFF (correct — already done)
`perMessageDeflate: false` in server. For our payloads (JSON, typically <1KB text deltas), compression CPU cost exceeds bandwidth savings. The Tailscale tunnel already compresses at the transport layer.

### 2. Nagle's Algorithm: OFF (correct — already done)
`socket.setNoDelay(true)` on upgrade. Critical for real-time streaming — prevents buffering small frames.

### 3. Ping/Pong Keepalive
- **Server:** `ws` library auto-responds to pings
- **Client:** 30s ping interval, 2 consecutive failures → reconnect
- **Enhancement:** Server should also ping clients (detect zombie connections from server side)

```ts
// server.ts — add server-initiated pings
const PING_INTERVAL = 30_000;
const interval = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
        ws.ping();
    }
}, PING_INTERVAL);
ws.on("close", () => clearInterval(interval));
ws.on("pong", () => { /* reset timeout if tracking */ });
```

### 4. Backpressure / Flow Control
Currently no backpressure. If server produces events faster than the WS can send (slow network), messages queue in memory.

**Enhancement:** Monitor `ws.bufferedAmount`. If it exceeds a threshold, drop `text_delta`/`thinking_delta` (recoverable via history reload) but never drop `permission_request` or `session_ended`.

```ts
const MAX_BUFFER = 64 * 1024; // 64KB

function safeSend(ws: WebSocket, msg: ServerMessage): boolean {
    if (ws.bufferedAmount > MAX_BUFFER) {
        // Drop streaming deltas, keep critical events
        if (msg.type === "text_delta" || msg.type === "thinking_delta") {
            return false; // dropped
        }
    }
    ws.send(JSON.stringify(msg), { compress: false });
    return true;
}
```

### 5. Reconnection Strategy
Current: exponential backoff 2^(n-1) capped at 30s, ±25% jitter. This is correct.

**Enhancement for multiplexed WS:** On reconnect, server replays last N events per subscribed session (since the client's last-seen sequence number). This closes the gap without a full history reload.

```ts
// Client sends on reconnect:
| { type: "reconnect"; lastSeenSeq: Record<string, number> }
// e.g. { "session-abc": 1542, "session-def": 87 }

// Server replays missed events per session
```

### 6. Message Ordering
WebSocket guarantees in-order delivery per connection. With a single multiplexed WS, all messages for all sessions are ordered. This is simpler than multiple connections where cross-session ordering is undefined.

### 7. Binary vs Text Frames
Current: text frames (JSON). For text_delta streaming, this is fine.

**Future consideration:** If adding file push (attach tool), use binary frames for large payloads with a small JSON header. Not needed for v2.

---

## Migration Path

### Phase 1: Add `sessionId` to all ServerMessages (backward compatible)
- Server adds `sessionId` to every outgoing message
- iOS ignores it (still uses v1 single-session routing)
- No protocol break

### Phase 2: Add `/stream` endpoint (new, parallel to historical session-scoped stream endpoint)
- Server supports both endpoints simultaneously
- New iOS build uses `/stream` with subscribe/unsubscribe
- Old iOS builds continue working on the historical session-scoped stream endpoint

### Phase 3: iOS multi-session UI
- `SessionRouter` demuxes events
- Session list shows live status for all sessions
- Tab badge shows total pending permissions
- Notification threading enabled

### Phase 4: Deprecate historical session-scoped stream endpoint
- After all clients migrate to `/stream`
- Remove per-session WS endpoint

---

## Notification Deduplication Summary

| Source | Identifier | Thread | Dedup Strategy |
|---|---|---|---|
| Permission (WS connected) | `perm-{permissionId}` | `session-{sessionId}` | Same ID replaces; cancel on resolve/expire |
| Permission (APNs push) | `perm-{permissionId}` | `session-{sessionId}` | APNs collapse-id = permissionId |
| Session ended (WS) | `session-event-{sessionId}` | `workspace-{workspaceId}` | Latest wins per session |
| Session error (WS) | `session-error-{sessionId}` | `session-{sessionId}` | Latest wins per session |
| Automation done (APNs) | `auto-{executionId}` | `automation-{workspaceId}` | Unique per execution |
| Automation blocked (APNs) | `auto-{executionId}` | `automation-{workspaceId}` | Unique, time-sensitive |
| App foregrounded | — | — | Cancel all delivered for active session |

**iOS Notification Summary Grouping (automatic):**

When 3+ notifications share a `threadIdentifier`, iOS automatically shows a summary:
- "3 more notifications from coding session" (session thread)
- "2 automation results in research" (automation thread)

Custom summaries via `UNNotificationCategory.categorySummaryFormat`:
```swift
// e.g. "%u permission requests from %@"
let category = UNNotificationCategory(
    identifier: "PERMISSION_REQUEST",
    actions: [allow, deny],
    intentIdentifiers: [],
    options: [],
    categorySummaryFormat: "%u permission requests"
)
```

---

## Open Questions

1. Should `subscribe(level: "full")` automatically downgrade the previous full session, or require explicit `unsubscribe` + `subscribe`?
   **Recommendation:** Auto-downgrade. Only one full stream at a time, enforced server-side.

2. Should server buffer and replay missed events on reconnect, or always require history reload?
   **Recommendation:** History reload for v2. Sequence-based replay is a v3 optimization.

3. ~~Should background sessions with pending permissions get their own Live Activity?~~
   **Resolved:** No. Apple HIG explicitly recommends one Live Activity that tracks multiple events with a dynamic layout. Use a "control tower" activity summarizing all sessions. See Live Activity Mapping section.

4. How to handle the transition when user switches active session mid-stream?
   **Recommendation:** Server-side: unsubscribe old full → subscribe new full (atomic). Client-side: new `TimelineReducer` instance, load history, then stream.

5. Should interactive Allow/Deny on Live Activity use `allowSession` scope or `allowOnce`?
   **Recommendation:** `allowOnce` from Live Activity (safe default). Full scope options require the app's permission detail sheet.

6. How to handle the 8-hour Live Activity limit for long agent sessions?
   **Recommendation:** On `ActivityState.ended` (system-forced), auto-restart if session is still active. Gap is brief (~1s).
