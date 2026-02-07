# Pi Remote Checklist (NetNewsWire-Inspired)

This is a practical, prioritized checklist for applying the strongest NetNewsWire patterns to Pi Remote.

Legend:
- `[x]` done
- `[ ]` pending
- `[~]` in progress

Status discipline:
- Mark `[x]` only when behavior is implemented and verifiable in code/tests.
- Use `[~]` when implementation exists but scope/documentation/coverage is partial.
- Prefer adding file-path evidence inline for every `[x]` item.

---

## 0) Reliability Values (adopt explicitly)

Mirror NetNewsWire's priority order in team docs and code review:

- [ ] No data loss
- [ ] No crashes
- [ ] No other bugs
- [ ] Fast performance
- [ ] Developer productivity

Implementation steps:
- [ ] Add this priority order to `ios/DESIGN.md` and top-level `DESIGN.md`
- [ ] Add PR checklist item: "Does this improve/maintain reliability ladder?"

---

## 1) iOS App Hardening (highest ROI)

### 1.1 Stream lifecycle, reconnect, state sync
- [x] Chat stream ownership moved to `ChatView.task(id:)` (view owns `for await` loop) (`Features/Chat/ChatView.swift`)
- [x] `ServerConnection` no longer owns hidden long-lived stream task (`Core/Networking/ServerConnection.swift`)
- [x] Disconnect on `ChatView` disappear (`Features/Chat/ChatView.swift`)
- [x] `isConnected` derived from actual socket status (`Core/Networking/ServerConnection.swift`)
- [ ] Add serialized operation queue for session transitions (`load history` -> `connect stream` -> `request state`)
- [ ] Add reconnect backoff policy + cap + jitter docs
- [x] Add explicit stale-stream guard (ignore events for non-active session) (`Core/Networking/ServerConnection.swift`)

### 1.2 Timeline rendering performance
- [x] Auto-scroll now keyed off mutation version (`renderVersion`), not just item count (`Core/Runtime/TimelineReducer.swift`, `Features/Chat/ChatView.swift`)
- [ ] Cap total rendered timeline rows in-memory (windowing policy)
- [x] Cap per-tool stored output bytes with truncation metadata (`Core/Runtime/ChatItem.swift`, `PiRemoteTests/ToolOutputStoreTests.swift`)
- [ ] Add "reconfigure visible rows only" optimization pass (avoid broad updates)
- [ ] Add frame-drop / render-latency instrumentation in debug builds

### 1.3 Extension UI and interaction completeness
- [x] Root-level sheet wired for `activeExtensionDialog` (`App/ContentView.swift`)
- [x] Extension notification/toast surfaced (`App/ContentView.swift`)
- [ ] Add richer extension dialog variants (editor multiline, confirm destructive style)
- [ ] Add timeout UX for stale extension requests
- [ ] Persist pending extension request IDs across foreground/background

### 1.4 Stop / force-stop robustness
- [x] Stop sends explicit protocol `stop` (`Core/Models/ClientMessage.swift`, `Core/Networking/ServerConnection.swift`)
- [x] Force-stop task cancellation cleanup added (`Features/Chat/ChatView.swift`)
- [x] Force-stop failure surfaced to timeline (`Features/Chat/ChatView.swift`)
- [ ] Disable duplicate stop taps while in-flight (idempotent UI lock)
- [ ] Add server-state reconciliation after stop timeout (auto `get_state`)
- [ ] Add explicit terminal-state banner after forced stop

### 1.5 Safety + input correctness
- [x] Use `SecureField` for manual token entry (`Features/Onboarding/OnboardingView.swift`)
- [~] Remove production force unwraps in app layer (remaining crash paths in `Core/Models/User.swift` via `fatalError`)
- [x] VisionKit availability checks (`isSupported`, `isAvailable`) before scanner presentation (`Features/Onboarding/OnboardingView.swift`)
- [x] Add graceful fallback for scan-unavailable devices (`Features/Onboarding/OnboardingView.swift`)

### 1.6 Accessibility + ergonomics
- [ ] Audit all custom controls for VoiceOver labels/hints
- [ ] Add Dynamic Type checks for chat rows / permission cards
- [ ] Ensure 44x44pt minimum targets everywhere; 48x48 for destructive/primary actions
- [ ] Add hardware keyboard shortcuts for key actions (stop, approve/deny, focus input)

### 1.7 Lifecycle discipline (foreground/background)
- [~] Foreground policy implemented in code (`PiRemoteApp.handleScenePhase`, `ServerConnection.reconnectIfNeeded`) but not fully documented in design docs
- [~] Background policy implemented in code (`PiRemoteApp.handleScenePhase`, `ServerConnection.flushAndSuspend`, `RestorationState.save`) but not fully documented in design docs
- [ ] Ensure all background->foreground resume paths are idempotent

### 1.8 State restoration (NetNewsWire-style)
- [~] Create typed `RestorationState` (implemented: active session, tab, composer draft; pending: scroll anchor, pending permission IDs) (`Core/Services/RestorationState.swift`)
- [~] Save on background and significant transitions (implemented on `.background`; additional transition hooks pending) (`App/PiRemoteApp.swift`)
- [~] Restore on launch/foreground with migration strategy for schema changes (implemented: versioned schema + freshness window; foreground restoration still partial) (`Core/Services/RestorationState.swift`, `App/PiRemoteApp.swift`)
- [ ] Add manual restoration matrix doc and QA checklist

---

## 2) Server + Protocol Hardening (keep Node baseline strong)

### 2.1 Already completed
- [x] Assistant turn persistence on `message_end`
- [x] Debounced session metadata persistence
- [x] WS latency tuning (`perMessageDeflate: false`, no delay)
- [x] Orphan container cleanup on start/stop
- [x] REST stop endpoint + abort fallback timer
- [x] E2E latency metrics + mid-stream stop regression test

### 2.2 Next backend checks
- [ ] Add WS backpressure telemetry (queue depth / send lag)
- [ ] Add activity replay endpoint (`GET /activity?since=<ts>`) for Live tab recovery
- [ ] Add bounded memory policy for active session event buffers
- [ ] Add server conformance tests for unknown message types + reconnect order
- [ ] Add structured health endpoint with container/image status

---

## 3) macOS App Checklist (new target)

## 3.1 Product scope (decide before coding)
- [ ] Decide v1 Mac role:
  - client-only supervisor UI (recommended first)
  - or includes local server management
- [ ] Confirm single-user vs multi-user assumptions for desktop use
- [ ] Define iOS/Mac parity boundaries (what is intentionally different)

### 3.2 Architecture
- [ ] Extract shared Swift domain package (`PiRemoteCore`) used by iOS + macOS
  - models
  - protocol decode
  - reducer/coalescer
  - API/WS clients
- [ ] Keep platform-specific UI/navigation shells thin
- [ ] Keep server protocol source-of-truth in one place (shared fixtures + decode tests)

### 3.3 macOS UX
- [ ] Multi-column layout (sessions / timeline / detail) with keyboard-first flow
- [ ] Menu commands + keyboard shortcuts for frequent actions
- [ ] Better live activity console (wider, denser, searchable)
- [ ] Drag/drop and copy ergonomics for tool output and logs
- [ ] Notification center integration for permission prompts

### 3.4 Reliability
- [ ] Full state restoration on relaunch (selected session, scroll, draft)
- [ ] Offline/resume behavior parity with iOS
- [ ] Explicit crash-safe persistence points for user-visible state

### 3.5 QA and release
- [ ] Platform-specific test matrix (window lifecycle, menu actions, keyboard)
- [ ] Dogfood checklist for full-day usage without memory growth
- [ ] Package and signing flow (direct distribution / TestFlight for Mac if needed)

---

## 4) "Should we build the server in Swift with Apple container?"

Short answer: **viable, but not required to ship a good macOS app**.

### Recommendation
- **Near term:** keep current Node server as source of truth; ship macOS app against existing protocol.
- **Parallel exploration:** run a Swift server spike behind the same protocol contract.
- **Decision gate:** migrate only if Swift backend demonstrates clear wins on operability + performance + maintainability.

### Why this is the best path
- You already have a working TS server + E2E suite.
- macOS app does not require server rewrite.
- Rewriting backend and adding macOS client at the same time multiplies risk.

### Swift server viability checklist
- [ ] Can we manage Apple containers from Swift reliably (CLI wrapper or native API) with equivalent lifecycle guarantees?
- [ ] Can we match protocol behavior exactly (message order, reconnect semantics, stop semantics)?
- [ ] Can we preserve all existing E2E tests (or port them) as a conformance gate?
- [ ] Do we get measurable wins (startup time, memory, crash handling, deploy simplicity)?
- [ ] Is local packaging materially better (single Swift binary vs Node runtime bundle)?

### Migration strategy (if pursued)
1. [ ] Freeze protocol contract in fixtures.
2. [ ] Build Swift `ContainerRuntime` adapter first (no API changes).
3. [ ] Run dual-backend conformance tests (TS vs Swift outputs).
4. [ ] Shadow mode in dev for at least 2 weeks.
5. [ ] Cut over only after parity + reliability pass.

---

## 5) Concrete next 10 tasks (execution order)

1. [~] Add `RestorationState` + persistence hooks (core hooks done; scope incomplete)
2. [ ] Implement serialized session-stream operation queue
3. [x] Add VisionKit availability checks + fallback
4. [x] Replace token `TextField` with `SecureField`
5. [~] Remove production force unwraps / crashy URL construction in iOS target
6. [x] Add tool-output memory caps and truncation markers
7. [ ] Add duplicate-stop tap suppression and final-state banner
8. [ ] Add activity replay backend endpoint for Live recovery
9. [ ] Extract shared Swift core package for iOS/macOS
10. [ ] Scaffold macOS app shell using shared core + same wire protocol

---

## 6) Definition of Done for this checklist

- [ ] iOS reconnect/stream/stop flows are deterministic under repeated foreground/background cycles
- [ ] No unbounded growth paths in chat/tool runtime memory
- [ ] Extension/permission requests always have a visible UX path
- [ ] State restoration passes documented manual matrix
- [ ] macOS client reaches functional parity for supervision loop
- [ ] Backend choice (TS vs Swift) decided via measured conformance + ops data, not preference
