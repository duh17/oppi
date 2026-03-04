# Networking / Transport Review (since `testflight/19`)

## Connection Lifecycle Assessment (connect, reconnect, backoff, cleanup)

### What looks solid

- **Session-entry latency fixes are real and well-targeted.**
  - `ServerConnection` now avoids tearing down a healthy socket in `connectStream()` (`ios/Oppi/Core/Networking/ServerConnection.swift:277-307`, guard at `:295`).
  - Eager resolution for setup commands (`subscribe`, `unsubscribe`, `get_queue`) is in place (`ServerConnection.swift:369-383`), which removes the `streamSession()` bootstrap deadlock window.
  - `WebSocketClient.waitForConnection()` moved to continuation-based signaling instead of polling (`ios/Oppi/Core/Networking/WebSocketClient.swift:350-379`), with explicit waiter resolution on connect/disconnect transitions (`:372-377`, `:619-623`, `:437`).
  - Reconnect delay curve is now mobile-friendly (`WebSocketClient.reconnectDelay`, `:752-763`).

- **Instrumentation quality improved meaningfully.**
  - Session bootstrap phases are separated (`stream_open_ms`, `subscribe_ack_ms`, `queue_sync_ms`) in `ServerConnection.streamSession()` (`ServerConnection.swift:774-892`).
  - Server-side subscribe timing is logged (`server/src/stream.ts:262-275`).

### Risks / correctness gaps

1. **Resubscribe success currently means “send succeeded”, not “server accepted subscription”.**
   - `resubscribeWithRetry` returns `true` after a successful WebSocket send (`ServerConnection.swift:445-471`) but does not await `command_result` for `subscribe`.
   - If the server rejects subscribe (session missing/invalid), client still treats recovery as successful.

2. **`cancelReconnectBackoff()` does not resolve pending connection waiters.**
   - It sets `.disconnected` but does not call `resolveConnectionWaiters()` (`WebSocketClient.swift:391-402`), unlike `disconnect()` (`:437`).
   - Any in-flight `send()` blocked in `waitForConnection()` can still sit until timeout.

3. **`waitForConnectedStream()` in `ServerConnection` is still polling-based.**
   - `ServerConnection.waitForConnectedStream` uses 50ms sleep polling (`ServerConnection.swift:897-915`) despite event-driven status wait already existing in `WebSocketClient`.

## LAN Discovery (Bonjour approach, the NWBrowser workaround, reliability)

### What looks solid

- **The NWBrowser TXT workaround is correctly implemented.**
  - `LANDiscovery` uses `NetServiceBrowser` + `NetService.startMonitoring()` (`ios/Oppi/Core/Services/LANDiscovery.swift:28-36`, `:85-86`, `:237-240`).
  - TXT parsing and endpoint extraction are isolated and test-covered (`LANDiscovery.swift:112-181`; tests in `ios/OppiTests/Network/LANDiscoveryTests.swift:6-87`).

- **Trust gates for LAN direct mode are conservative (good).**
  - Requires server fingerprint prefix match + pinned TLS fingerprint in credentials (`ios/Oppi/Core/Networking/LANEndpointSelection.swift:57-73`).
  - Falls back to paired transport by default (`:40-52`, `:90-101`).

- **Server-side Bonjour publication is pragmatic and clean.**
  - Host selection avoids loopback/link-local (`server/src/server.ts:121-149`, `:500-552`).
  - TXT record includes protocol/version/server identity (+ TLS prefix when available) via `buildBonjourTxtRecord` (`server/src/bonjour-advertiser.ts:66-101`).

### Risks / correctness gaps

1. **Discovery candidate dedupe may throw away useful alternatives.**
   - `LANDiscovery.rebuildEndpoints()` dedupes by `serverFingerprintPrefix` only (`LANDiscovery.swift:58-66`).
   - This can collapse multiple candidates before `ConnectionCoordinator.bestLANEndpoint()` ranking runs (`ConnectionCoordinator.swift:136-178`).

2. **Transport path can change without reconnecting the active WebSocket.**
   - `setDiscoveredLANEndpoint()` updates `transportPath`, `apiClient`, and preferred endpoint (`ServerConnection.swift:225-261`), but does **not** re-open an already-connected WS.
   - Result: REST can move to LAN while WS may still be on paired host; telemetry tag can report LAN before WS actually migrates.

## Race Conditions (WS subscription timing, meta tracking, message ordering)

### What looks solid

- **Subscription/meta race fix is correct.**
  - Subscription state is pre-tracked before send (`WebSocketClient.swift:189-255`), with rollback on failure (`:240-248`).
  - This aligns with receive-loop guard at `activeSubscriptions[sessionId] == .full` (`WebSocketClient.swift:562`).

- **Setup command deadlock fix is correct.**
  - Eager command result resolution in stream router (`ServerConnection.swift:349-383`).
  - Verified by tests (`ios/OppiTests/Network/ServerConnectionStreamTests.swift:242-308`).

- **Duplicate `message_end` suppression improved for replay interleavings.**
  - Latest assistant is now found by reverse-scan, not strict tail check (`ios/Oppi/Core/Runtime/TimelineReducer.swift:832-842`; helper in `TimelineTurnAssembler.swift:17-30`).
  - Regression tests cover trailing system/tool rows (`ios/OppiTests/Timeline/TimelineReducerEdgeCaseTests.swift:98-205`).

### Risks / correctness gaps

1. **Full-subscription recovery trigger is string-fragile.**
   - Detection uses substring match on server error text (`ServerConnection+MessageRouter.swift:165-166`).
   - Any wording change can silently break auto-recovery.

2. **File-suggestions protocol path lacks ws-handler coverage.**
   - Added command in protocol (`server/src/types.ts:704`) and iOS encoder tests (`ios/OppiTests/Protocol/ClientMessageTests.swift:214-225`), but no `ws-message-handler` tests for `get_file_suggestions` branch (`server/src/ws-message-handler.ts:195-196`, `:404-449`; existing tests in `server/tests/ws-message-handler.test.ts` do not cover it).

## Error Recovery (offline, timeout, server restart scenarios)

### What looks solid

- **Multiple recovery layers exist and are coherent:**
  - Ping watchdog reconnect (`WebSocketClient.swift:654-687`).
  - Silence watchdog probe/escalation (`ios/Oppi/Core/Networking/SilenceWatchdog.swift:43-57`) wired by `ChatSessionManager`.
  - Foreground stale-backoff reset (`ServerConnection+Refresh.swift:245-250`).
  - Offline replay semantics are strongly covered server-side (`server/tests/offline-recovery.test.ts`).

### Risks / correctness gaps

1. **Background keep-alive scope is only active server connection.**
   - `OppiApp` checks `connection.sessionStore` (active connection only) before starting keep-alive (`ios/Oppi/App/OppiApp.swift:355-360`).
   - Busy sessions on inactive servers can still be suspended.

2. **New recovery paths are under-tested.**
   - No explicit tests found for:
     - `cancelReconnectBackoff()` behavior,
     - `BackgroundKeepAlive` lifecycle,
     - `triggerFullSubscriptionRecovery()` cooldown/in-flight guards.

## Suggestions (ordered by impact)

1. **Make resubscribe recovery ack-validated (highest impact).**
   - For active-session recovery, use `sendCommandAwaitingResult("subscribe")` semantics (or equivalent ack waiter), not send-only success.

2. **Reconcile WS transport on endpoint flips.**
   - When `transportPath` changes (`paired`↔`lan`), either reconnect WS immediately (with debounce/cooldown) or mark “pending transport switch” and reconnect at safe boundary. Avoid mixed API/WS endpoints.

3. **Preserve multiple LAN candidates until selection stage.**
   - In `LANDiscovery`, avoid deduping solely by `sid`; keep candidates keyed by service identity (name/host/port), then let `ConnectionCoordinator.bestLANEndpoint()` rank them.

4. **Resolve connection waiters in `cancelReconnectBackoff()`.**
   - Mirror `disconnect()` behavior by calling `resolveConnectionWaiters()` after status changes to `.disconnected`.

5. **Harden protocol contracts and recovery signaling.**
   - Replace string match (`"is not subscribed at level=full"`) with typed server error code.
   - Consider making `get_file_suggestions.requestId` required in `types.ts` to match actual handler expectations.

6. **Add focused tests for newly added recovery codepaths.**
   - iOS: `BackgroundKeepAlive`, `cancelReconnectBackoff`, full-subscription recovery cooldown/retry.
   - Server: `ws-message-handler` tests for `get_file_suggestions` success/failure/missing-workspace paths.
