# iOS Lifecycle Test Matrix

Manual QA checklist for background/foreground transitions.
Run through these scenarios after changes to `PiRemoteApp`, `ServerConnection`,
`ChatSessionManager`, or `WebSocketClient`.

## Scenarios

### A. Quick background + foreground (< 10 seconds)

| Step | Expected |
|------|----------|
| 1. Open a session, agent is responding | Chat streaming visible |
| 2. Swipe home (background) | `flushAndSuspend` fires, WS stays open |
| 3. Return within ~5s | Timeline continues from where it was. No flash, no duplicate messages. No "reconnecting" system event |
| 4. Verify scroll position | Same position as before backgrounding |

### B. Long background (> 30 seconds, WS dies)

| Step | Expected |
|------|----------|
| 1. Open a session, agent finishes a turn | Chat shows completed turn |
| 2. Background for > 30 seconds | iOS kills the WS |
| 3. Return to foreground | "Connection dropped — reconnecting..." system event appears briefly. Timeline catches up via sequenced replay. No double-load flash |
| 4. Send a new message | Works normally — agent responds |
| 5. Check session list | All sessions refreshed (metadata current) |

### C. Background with agent working server-side

| Step | Expected |
|------|----------|
| 1. Send a long task, background immediately | Agent continues on server |
| 2. Wait 1-2 minutes | Agent finishes server-side |
| 3. Return to foreground | Catch-up replays all missed events. Session shows as ready. All tool calls and responses visible |

### D. Rapid cycling (background -> foreground -> background -> foreground)

| Step | Expected |
|------|----------|
| 1. Open a session | Normal chat |
| 2. Quick home press + return, 3 times in 5 seconds | Each cycle: reentrancy guard prevents concurrent `reconnectIfNeeded`. Only one session list refresh runs at a time. No duplicate "reconnecting" events. No crash |
| 3. Timeline stable | Same items, no duplication, no missing content |

### E. Tab switching during background

| Step | Expected |
|------|----------|
| 1. Open session, background | WS may die |
| 2. Return, immediately switch to Settings tab | No crash. Session list refreshes in background |
| 3. Switch back to Sessions tab, tap same session | ChatView mounts, loads cached trace, reconnects WS. Timeline shows full history |

### F. Permission prompt during background

| Step | Expected |
|------|----------|
| 1. Agent requests permission (tool approval) | Push notification appears |
| 2. While backgrounded, tap "Approve" on notification | WS may be dead — approval may fail silently |
| 3. Return to foreground | Permission sweep clears expired requests. If approval failed, permission shows as expired in timeline |

### G. Memory warning during background

| Step | Expected |
|------|----------|
| 1. Open a session with long history | Large timeline |
| 2. Simulate memory warning (Xcode: Debug > Simulate Memory Warning) | MarkdownSegmentCache cleared, tool output truncated, expanded items collapsed, image data stripped |
| 3. Return to foreground | Timeline still visible (degraded but functional). No crash. History reload restores full data |

### H. Session stopped during background

| Step | Expected |
|------|----------|
| 1. Session is stopped server-side while app is backgrounded | Session status changes server-side |
| 2. Return to foreground | Session list shows stopped status. ChatView shows "Session ended" footer. No auto-reconnect loop (stopped sessions don't reconnect) |

## Invariants (must hold for ALL scenarios)

- [ ] `reducer.loadSession()` is called at most once per foreground transition
- [ ] No "Connection dropped" → immediate "Connection dropped" loops (double-fire)
- [ ] `foregroundRecoveryInFlight` flag resets after completion (no stuck state)
- [ ] Scroll position restored correctly (if user was scrolled up, stays there)
- [ ] Composer draft preserved across background cycles
- [ ] Extension dialog cleared when WS is dead (server re-sends on reconnect)
- [ ] No unbounded task accumulation from rapid cycling

## Architecture Notes

### Separation of Concerns

| Component | Responsibility |
|-----------|---------------|
| `PiRemoteApp.handleScenePhase` | Triggers `flushAndSuspend` / `reconnectIfNeeded` |
| `ServerConnection.reconnectIfNeeded` | Session list, workspace, metadata refresh. Does NOT touch timeline |
| `ChatSessionManager.connect` | WS stream, trace loading, catch-up, auto-reconnect. Owns the timeline |
| `ChatView.onChange(scenePhase)` | Saves scroll state on background |
| `RestorationState` | Persists tab, session, draft, scroll position |

### Key Design Decision

`reconnectIfNeeded` does NOT call `reducer.loadSession()`. Timeline recovery is
exclusively owned by `ChatSessionManager` (via auto-reconnect + sequenced catch-up).
This prevents double-load races where both paths rebuild the timeline simultaneously.

## Offline v0 Reliability Gate (T4)

Current gate status: **IN PROGRESS** (simulator evidence complete, device matrix pending).

### Automated evidence (simulator)

Run on 2026-02-10:

```bash
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test \
  -only-testing:PiRemoteTests/TimelineCacheTests \
  -only-testing:PiRemoteTests/WorkspaceStoreOfflineTests \
  -only-testing:PiRemoteTests/FreshnessStateTests \
  -only-testing:PiRemoteTests/ChatSessionManagerTests \
  -only-testing:PiRemoteTests/TimelineReducerTests
```

Result: **pass (98 tests, 5 suites)**.

### Offline matrix for v0 ship gate

| ID | Scenario | Coverage | Status |
|----|----------|----------|--------|
| O1 | Cold launch in airplane mode with prior cache | `TimelineCacheTests`, `WorkspaceStoreOfflineTests`; manual device run required | ⏳ Device pending |
| O2 | Foreground/background with network flap | `ChatSessionManagerTests` reconnect/catch-up tests; manual device run required | ⏳ Device pending |
| O3 | Session switch while disconnected | `ChatSessionManagerTests` cleanup/ownership tests; manual device run required | ⏳ Device pending |
| O4 | Reconnect catch-up without full reload flicker | `ChatSessionManagerTests` catch-up + `TimelineReducerTests` duplicate suppression | ⏳ Device pending |
| O5 | Offline session/workspace list continuity | `WorkspaceStoreOfflineTests`, freshness metadata + chips; manual device run required | ⏳ Device pending |

### Device execution checklist (required to close T4)

Device target: **Duh Ifone** (iPhone 16 Pro, `00000000-0000-0000-0000-000000000000`)

Current blocker: local `xcodebuild` destination resolution does not currently list the physical iPhone (only simulator + `Any iOS Device` placeholder). Resolve pairing/visibility before running D1–D5.

| Step | Procedure | Expected |
|------|-----------|----------|
| D1 | Prime cache while online (launch app, open Sessions + Workspaces + one active Chat session) | Cached data present for all three surfaces |
| D2 | Enable Airplane Mode and cold-launch app | Sessions/Workspaces render from cache; Chat opens with cached timeline |
| D3 | Background app, toggle network on/off, foreground | No blank screen; state transitions show `syncing/offline/stale` correctly |
| D4 | While offline, switch sessions and re-open previous session | No crashes; cached timeline continuity preserved |
| D5 | Re-enable network and foreground | Sequenced catch-up resumes; no full-reload flicker or duplicate final assistant bubble |

Log capture command after each run window:

```bash
ios/scripts/collect-device-logs.sh --last 10m --include-debug --no-sudo
```

### Ship decision rule

- [x] Targeted offline/reconnect unit suites pass.
- [ ] Device matrix O1–O5 all pass on physical device.
- [ ] Device logs + short notes attached to this document or linked TODO.

**Gate is fail-closed until device matrix is complete.**
