# WebSocket Session Re-Entry Delay

**Status:** In Progress
**Severity:** High — P50 = 8.6s, every session switch affected
**Opened:** 2026-03-02

## Why Disconnects Happen

676 abnormal TCP deaths (code 1006) today — the dominant pattern. Root cause is the transport layer: Tailscale WireGuard over mobile networking.

| Trigger | Code | Frequency |
|---------|------|-----------|
| iOS suspends process (background) | 1006 | ~92% of all disconnects |
| WiFi↔cellular handoff | 1006 | Included above |
| Tailscale re-key / path change | 1006 | Included above |
| `connectStream()` restarting | 1000 | 22 events |
| `cancelReconnectBackoff` / cleanup | 1001 | 9 events |

**We cannot prevent the 1006 disconnects.** iOS will suspend the process and Tailscale will change paths. The fix is fast recovery: P50 reconnect should be <1s, not the current 67s.

Current reconnect gap after 1006: P50=67.5s, P90=644.8s, 78% take >10s.

## Symptom

Entering a chat session takes 8-10 seconds consistently. The user sees cached content immediately but the "syncing" state persists for the full duration. All 41 collected `ws_connect_ms` samples fall in 8-19 second range.

## Root Cause Chain

The delay is a cascade of five interacting problems:

### 1. `connectStream()` is fire-and-forget

`connectStream()` creates the WS and returns synchronously. `streamSession()` then immediately calls `sendCommandAwaitingResult("subscribe")`, but the WS isn't `.connected` yet.

**Location:** `ServerConnection.swift:196` → `WebSocketClient.swift:96`

### 2. `waitForConnection` timeout too short (3s)

`send()` calls `waitForConnection(timeout: 3s)`. If the WS isn't connected within 3 seconds, the subscribe send throws `notConnected`. The error is caught and swallowed — `streamSession` returns the stream without a successful subscribe.

**Location:** `WebSocketClient.swift:64` (default timeout), `WebSocketClient.swift:262`

### 3. Double-disconnect on fresh connection

When `connectStream()` calls `wsClient.connect()`, it first calls `disconnect()` (code 1000), opens a new WS (connects in ~84ms), but then the new connection immediately dies (code 1006, sent=1 recv=0). This forces the first reconnect attempt.

Server log pattern:
```
Connected              ← new WS up in 84ms
Disconnected (1006)    ← killed 87ms later (sent=1 recv=0)
Connected              ← reconnect attempt succeeds 1-4s later
```

Possible causes: Tailscale dropping the first connection, stale `onTermination` handler, or iOS networking race. Diagnostic logging added but not yet deployed successfully.

**Location:** `WebSocketClient.swift:110` (onTermination handler), server WS logs

### 4. Reconnect backoff accumulates during suspension

When the app backgrounds, iOS suspends the process. Reconnect attempts fire during brief wake-ups but can't complete TLS before re-suspension. Each failed attempt increments the backoff counter: 1s → 2s → 4s → 8s.

When the user foregrounds, `reconnectIfNeeded()` now resets the backoff (fix deployed), but if `streamSession()` races ahead of the foreground handler, the stale backoff is still active.

**Location:** `WebSocketClient.swift:541` (attemptReconnect), `ServerConnection+Refresh.swift:244` (backoff reset)

### 5. Fallback resubscribe adds full round-trip

After the 3s `waitForConnection` timeout and failed subscribe, the WS eventually reconnects. `handleStreamReconnected()` → `resubscribeTrackedSessions()` sends a new subscribe. Only then does `.connected` arrive in the ChatSessionManager stream loop, ending the `ws_connect_ms` measurement.

**Location:** `ServerConnection.swift:299` (handleStreamReconnected)

## Fixes Applied

| Fix | Commit | Effect |
|-----|--------|--------|
| Background keep-alive (beginBackgroundTask) | `7065521` | Prevents WS death when agents are busy |
| Foreground backoff reset (cancelReconnectBackoff) | `7065521` | Resets stale backoff on foreground |
| BackgroundKeepAlive crash fix (Int overflow) | uncommitted | Prevents crash on every background transition |
| Diagnostic logging (streamSession timing, onTermination) | uncommitted | Will reveal which phase takes the time |

## Fixes Needed

### A. Retune reconnect backoff curve

The current exponential backoff (1s, 2s, 4s, 8s, 16s...) is front-loaded with the slowest retries when failures are most likely transient. Mobile networking hiccups (background suspension, Tailscale handoff, cellular→wifi) resolve quickly but get punished hardest.

**Current:** `2^(attempt-1)` seconds, capped at 30s, ±25% jitter
**Proposed:**
- Attempts 1-3: 500ms fixed (transient — suspension wake, network handoff)
- Attempts 4-6: 2s, 4s, 8s (moderate — server restarting)
- Attempts 7-10: 15s cap (real problems — server down)

This works for both self-hosted (1 client, Mac Studio) and future hosted containers. Fast retries handle mobile transients; backoff still ramps for sustained failures.

**Location:** `WebSocketClient.reconnectDelay(attempt:)`

### B. Increase waitForConnectionTimeout (3s → 8s)

The 3-second timeout in `waitForConnection` expires before the fast-retry window completes. When `streamSession()` sends subscribe, the WS might still be in its first 500ms retry. The subscribe fails silently and the system falls back to the deferred resubscribe path (adding the full backoff delay).

With 500ms retries × 3 attempts = 1.5s for transient failures. 8s covers the moderate window too.

**Location:** `WebSocketClient.swift:64` (default parameter)

### C. Investigate double-disconnect

The code 1006 disconnect 87ms after a fresh connection is suspicious. The `connectionID` guard in `onTermination` should prevent stale handlers from killing new connections. Diagnostic logging added but not yet deployed — need data to confirm whether it's the stale handler or something else (Tailscale, iOS networking race).

**Location:** `WebSocketClient.swift:110` (onTermination handler)

## Metrics

```
Pre-fix baseline (41 samples):
  ws_connect_ms:      P50=8905ms  range=8053-19463ms
  fresh_content_lag:  P50=8552ms  range=169-19472ms

Pipeline (not bottleneck):
  cache_load_ms:      P50=7ms     range=0-91ms
  reducer_load_ms:    P50=8ms     range=0-87ms
  Server subscribe:   0-1ms (sessions already warm)
  TLS handshake:      ~84ms (when not blocked by backoff)
```

## Files Involved

- `ios/Oppi/Core/Networking/WebSocketClient.swift` — WS connection, backoff, status
- `ios/Oppi/Core/Networking/ServerConnection.swift` — connectStream, streamSession
- `ios/Oppi/Core/Networking/ServerConnection+Refresh.swift` — reconnectIfNeeded, backoff reset
- `ios/Oppi/Core/Services/BackgroundKeepAlive.swift` — background task for WS persistence
- `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift` — ws_connect_ms metric, stream loop
- `server/src/stream.ts` — subscribe timing logs
