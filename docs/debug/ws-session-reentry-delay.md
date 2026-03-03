# WebSocket Session Re-Entry Delay

**Status:** Active tracker
**Severity:** High
**Opened:** 2026-03-02
**Last updated:** 2026-03-02

## Current conclusion

The dominant 8s reconnect symptom is **application-side scheduling delay**, not server subscribe time.

Latest confirmed chain:
1. Server emits `.connected` quickly (0-1ms subscribe path on server).
2. iOS WebSocket receives/decode happens quickly.
3. Main thread is intermittently blocked by timeline layout/cell configuration.
4. `.connected` handling in the session loop is delayed until main-thread work drains.

So `ws_connect_ms` can look like "network delay" while most time is actually spent waiting for main-thread availability.

## LAN-direct status

**Working as of 2026-03-02** (commit `4579d91`).

- iOS discovers `_oppi._tcp` via `NetServiceBrowser` and selects LAN endpoint when fingerprint trust checks pass.
- Connection transport path is tracked as `paired` or `lan`.
- Telemetry confirmed: `transport=lan` with connections to `192.168.68.66:7749`.

### NWBrowser TXT resolution bug (fixed)

`NWBrowser` (Network framework) does not resolve TXT records for services registered via `dns-sd -R`. The `browseResultsChangedHandler` fires once with `.none` metadata and never updates. This prevented LAN discovery from parsing the `sid`/`tfp`/`ip`/`p` fields needed for endpoint selection.

**Fix:** Replaced `NWBrowser` with `NetServiceBrowser` + `NetService.startMonitoring()`. TXT record arrives via `didUpdateTXTRecord` delegate before `netServiceDidResolveAddress` completes. See `docs/debug/lan-transport-activation.md` for full investigation notes.

### TLS pinning on LAN

The server is paired through a Tailscale hostname but LAN connects via raw IP. TLS works because `PinnedServerTrustDelegate` pins the leaf cert fingerprint and calls `.useCredential(trust:)` — bypassing hostname validation entirely. The Tailscale cert is accepted on LAN because the fingerprint matches, regardless of hostname mismatch.

### Re-pairing requirement

Paired credentials must include `tlsCertFingerprint` for LAN to activate. Servers paired before TLS was configured (or after cert rotation) need a fresh `oppi pair` + re-scan.

## Tracker

### A. Path attribution (LAN vs tailscale/paired)
- [x] Emit transport path in stream-session diagnostics logs (`transport`, `endpointHost`)
- [x] Tag `chat.ws_connect_ms` with `transport`
- [x] Tag `chat.fresh_content_lag_ms` with `transport`

### B. Main-thread starvation attribution
- [x] Extend WS decode telemetry with `stage` and `transport` tags
- [x] Emit `chat.ws_decode_ms` stage=`main_actor_hop` for `.connected` and large hop delays
- [x] Emit `chat.ws_decode_ms` stage=`session_loop_dispatch` for `.connected`

### C. LAN activation
- [x] Fix NWBrowser TXT resolution bug (replaced with NetServiceBrowser)
- [x] Confirm LAN transport working on-device via telemetry (`transport=lan`)
- [x] Verify TLS pinning bypasses hostname validation for LAN IP connections

### D. Rendering bottleneck follow-up
- [ ] Keep reducing timeline main-thread cost in large sessions (cell config/layout)
- [ ] Re-test on device with large traces and compare `main_actor_hop` vs `ws_connect_ms`
- [ ] Compare `ws_connect_ms` on `lan` vs `paired` to isolate network vs app delay

## How to rule app vs infrastructure quickly

Use the same workload and compare these metric slices:

1. `chat.ws_connect_ms` grouped by `transport`
2. `chat.ws_decode_ms` where `stage in (main_actor_hop, session_loop_dispatch)`
3. `chat.fresh_content_lag_ms` grouped by `transport`

Interpretation:
- **App bottleneck:** high `ws_connect_ms` + high `main_actor_hop/session_loop_dispatch` on both `lan` and `paired`
- **Network bottleneck:** high `ws_connect_ms` on `paired` with low dispatch-hop metrics, but low `ws_connect_ms` on `lan`

## Files involved

- `ios/Oppi/Core/Networking/WebSocketClient.swift`
- `ios/Oppi/Features/Chat/Session/ChatSessionManager.swift`
- `ios/Oppi/Core/Networking/ServerConnection.swift`
- `ios/Oppi/Core/Networking/LANEndpointSelection.swift`
- `ios/Oppi/Core/Services/LANDiscovery.swift`
- `ios/Oppi/Core/Services/ConnectionCoordinator.swift`
- `docs/telemetry-catalog.md`
