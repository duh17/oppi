# iOS Implementation Review — Phase 1

**Reviewer**: Claude  
**Date**: 2026-02-06  
**Scope**: All 32 Swift files + project.yml (commit `7f9ad27`)  
**Build**: ✅ (0 errors, 0 warnings) — Xcode 26.2, iPhone 17 Pro simulator  
**Tests**: ✅ 34/34 passing  

---

## Verdict: Solid foundation, ~12 issues to fix before first device test

The architecture is clean and well-structured. The event pipeline (ServerMessage → AgentEvent → DeltaCoalescer → TimelineReducer → ChatItem) is the right design. Models match the server wire format correctly. Stores are properly separated.

The issues below are mostly "will crash at runtime" or "will silently break" — not architectural problems.

---

## 🔴 High Severity (will crash or silently break)

### 1. `stopSession` decodes wrong response shape

**File**: `APIClient.swift:75-81`  
**Server response**: `{ ok: true, session: Session }`  
**Client code**:
```swift
struct Response: Decodable { let session: Session? }
let response = try JSONDecoder().decode(Response.self, from: data)
```
This works because `session` is optional, but the *next line* falls back to `getSession()` if session is nil. The issue: the server always returns `session`, so the fallback is dead code and harmless. BUT the response also has `ok: true` which would fail decoding if `Decodable` was strict about unknown keys. Swift's `JSONDecoder` ignores unknown keys by default, so this actually works fine.

**Severity**: Low (works by accident) — but the `Response` struct should include `ok` for correctness.

### 2. `ChatView.connectToSession` — stream task never cancelled on re-navigation

**File**: `ChatView.swift:118-140`  
The `for await message in stream` loop is inside `.task(id: sessionId)`, which cancels when `sessionId` changes or the view disappears. Good. BUT `onDisappear` also calls `connection.disconnectSession()`, and the Task.isCancelled check inside the loop only fires on the *next* iteration. When the WebSocket disconnects, `ws.receive()` should throw, breaking the loop. This is fine.

**Actual issue**: If the user quickly navigates back and forward to the same session, `.task(id: sessionId)` won't re-fire because the id didn't change. The stream will be gone (disconnected in `onDisappear`) but the task won't restart.

**Fix**: Use a incrementing `@State var connectionGeneration` as the task id, bumped in `onAppear`.

### 3. `PermissionCardView.resolve` swallows errors silently

**File**: `PermissionCardView.swift:97-101`  
```swift
Task {
    try? await connection.respondToPermission(id: request.id, action: action)
}
```
If the WebSocket is disconnected when the user taps Allow/Deny, the error is silently swallowed. The button shows as "resolving" forever (isResolving=true, never reset).

**Fix**: Catch the error, reset `isResolving`, show inline error or toast.

### 4. `DeltaCoalescer.scheduleFlushIfNeeded` — `self?.flushInterval` captures optional

**File**: `DeltaCoalescer.swift:50-55`  
```swift
flushTask = Task { @MainActor [weak self] in
    try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(33))
```
This captures `[weak self]` but immediately uses `self?.flushInterval`. If self is deallocated before the sleep, it falls back to 33ms — which is fine. But the `Task` is `@MainActor` and `DeltaCoalescer` is already `@MainActor`, so `self` can't be deallocated while the task runs on the same actor. The `[weak self]` is unnecessary here but not harmful.

**Severity**: Cosmetic — no real issue.

### 5. `WebSocketClient` reconnect reuses stale `continuation`

**File**: `WebSocketClient.swift:171-188`  
On reconnect, `attemptReconnect()` calls `openWebSocket(sessionId:, continuation:)` reusing `self.continuation`. This is correct — the original `AsyncStream.Continuation` is still valid and the consumer is still iterating. ✅

But there's a timing issue: if `disconnect()` is called between the reconnect delay and the `openWebSocket` call, `self.continuation` will be `nil` (set to nil in `disconnect()`). The `guard let self, let cont = self.continuation` handles this. ✅

### 6. `TimelineReducer.process(.toolOutput)` — O(n) scan on every output chunk

**File**: `TimelineReducer.swift:96-97`  
```swift
func updateToolCallPreview(id: String, isError: Bool) {
    guard let idx = items.firstIndex(where: { $0.id == id }),
```
For large sessions (hundreds of items), this linear scan runs on every tool output chunk. With the DeltaCoalescer batching tool output at 0ms (immediate), this fires for every chunk.

**Fix (v2)**: Keep a `[String: Int]` index of item IDs to positions. For v1, this is acceptable — sessions rarely exceed ~100 items, and `firstIndex` on a small array is fast.

**Severity**: Low (v1 acceptable, note for v2).

---

## 🟡 Medium Severity (UX bugs, edge cases)

### 7. `ChatView` — `isNearBottom` sentinel is unreliable for auto-scroll

**File**: `ChatView.swift:44-46, 58-63`  
```swift
Color.clear.frame(height: 1)
    .id("bottom-sentinel")
    .onAppear { isNearBottom = true }
    .onDisappear { isNearBottom = false }
```
The sentinel is 1pt tall inside `LazyVStack`. When the ScrollView hasn't rendered it yet (initial load, or user scrolled up), `onDisappear` fires setting `isNearBottom = false`, which disables auto-scroll. The `onChange(of: reducer.renderVersion)` then won't scroll.

**Real scenario**: User opens a busy session → messages load → sentinel was never visible → auto-scroll is disabled → user sees the top of the conversation, not the bottom.

**Fix**: Initialize `isNearBottom = true` (already done ✅) and also scroll to bottom on initial load in `connectToSession()` after `loadFromREST`.

### 8. Permission pill banner is not tappable

**File**: `ChatView.swift:67-69`  
```swift
if !permissionStore.pending(for: sessionId).isEmpty {
    PermissionPillBanner(count: permissionStore.pending(for: sessionId).count)
}
```
The banner says "tap to review" but there's no tap gesture or scroll action. The permission cards are inline in the timeline, so the banner should scroll to the first pending permission.

**Fix**: Add `onTapGesture` that scrolls to the first `.permission` item in `reducer.items` via `ScrollViewReader`.

### 9. `OnboardingView.testConnection` — `APIClient` actor method called from MainActor

**File**: `OnboardingView.swift:106-131`  
`testConnection` creates a local `APIClient` actor and calls `await api.health()` and `await api.me()`. This crosses actor boundaries correctly. ✅

But the local `APIClient` is never stored — it gets created, used, and discarded. The `URLSession` inside it will be deallocated, potentially cancelling in-flight requests. In practice, `await` ensures the requests complete before the function returns, so the URLSession stays alive for the duration. This is fine.

### 10. `SessionStore.upsert` inserts at index 0 — doesn't maintain sort order

**File**: `SessionStore.swift:23-27`  
```swift
func upsert(_ session: Session) {
    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
        sessions[idx] = session
    } else {
        sessions.insert(session, at: 0)
    }
}
```
New sessions go to index 0, but `sort()` is only called explicitly. The session list from `listSessions()` replaces the whole array (sorted by server). But `state` messages via WebSocket update individual sessions without re-sorting.

**Effect**: A session that goes busy will stay in its current position instead of moving to the top.

**Fix**: Call `sort()` after upsert, or accept the behavior (most session lists are short).

### 11. `NewSessionView` — hardcoded model list will go stale

**File**: `NewSessionView.swift:15-19`  
```swift
private let suggestedModels = [
    "anthropic/claude-sonnet-4-0",
    "anthropic/claude-opus-4-0",
    "anthropic/claude-haiku-3-5",
]
```
These model strings are hardcoded. The server's `defaultModel` from config isn't exposed in any API. When new models ship, the app needs an update.

**Fix (v2)**: Add `GET /models` endpoint on server, or at minimum fetch `defaultModel` from server config.

### 12. `ServerCredentials.baseURL` — force-unwrap on malformed host

**File**: `User.swift:22-23`  
```swift
var baseURL: URL {
    URL(string: "http://\(host):\(port)")!
}
```
If `host` contains spaces or special characters (from a corrupted QR code), this will crash.

**Fix**: Guard with optional or validate host during QR parse.

---

## 🟢 Low Severity (cosmetic, minor)

### 13. `ContentView` uses `SwiftUI.Tab` fully-qualified to avoid `AppTab` collision

**File**: `ContentView.swift:11-24`  
The rename from `Tab` → `AppTab` was correct, but the `SwiftUI.Tab` qualification is a bit unusual. An alternative is `typealias PiTab = Tab` but `AppTab` is cleaner. Fine as-is.

### 14. `RiskLevel` extension in `Color+Risk.swift` — feature extension in wrong file

**File**: `Color+Risk.swift:14-35`  
The `RiskLevel` extensions (`label`, `systemImage`) are model logic, not color extensions. They should live in `Permission.swift` or a separate `RiskLevel+Display.swift`.

**Severity**: File organization only.

### 15. `LiveFeedView` shares `reducer.items` with `ChatView`

**File**: `LiveFeedView.swift:9`  
The Live tab shows the same items as the active chat session. If no session is connected, it's empty. If a session is connected, it shows the same timeline. This isn't really a "live cross-session feed" — it's a mirror.

**v2 note**: This needs its own data source (activity log API) to be useful.

### 16. Tests don't test `DeltaCoalescer` directly

The DeltaCoalescer is tested indirectly through TimelineReducer tests (which feed events without coalescing). A direct test of batching behavior (verify that 10 rapid textDeltas produce fewer onFlush calls) would catch regressions.

### 17. `SessionMessage.stub()` test helper uses raw JSON string interpolation

**File**: `TimelineReducerTests.swift:147-155`  
```swift
let json = """
{"id":"\(id)","sessionId":"\(sessionId)","role":"\(role.rawValue)","content":"\(content)","timestamp":\(tsMs)}
"""
```
If `content` contains quotes or backslashes, the JSON is invalid. For test stubs this is fine (controlled inputs), but fragile.

---

## ✅ What's Good

1. **ServerMessage decoder with `.unknown` fallback** — exactly right for forward-compat
2. **Manual Codable implementations** — avoids the pitfalls of synthesized Codable with type discriminators
3. **Unix-ms timestamp handling** — consistent across Session, SessionMessage, PermissionRequest
4. **DeltaCoalescer design** — 33ms batch for text, immediate for everything else. Clean separation
5. **ToolOutputStore** — full output separated from ChatItem keeps Equatable diffs cheap
6. **ToolEventMapper** — client-generated UUIDs for sequential tools is the right v1 approach
7. **WebSocket reconnect** with exponential backoff and max attempts
8. **Permission card UX** — risk-differentiated button styles, haptics, countdown timer
9. **Separate @Observable stores** — SessionStore/PermissionStore won't thrash each other
10. **Test coverage** on the critical decoder paths — 34 tests covering all wire message types

---

## Recommended Fix Priority

1. **#2** (re-navigation same session) — Will hit this in real use immediately  
2. **#3** (permission resolve error) — Permission approval is the money feature  
3. **#8** (permission pill not tappable) — UX promise not delivered  
4. **#7** (auto-scroll on initial load) — First thing user sees  
5. **#12** (force-unwrap URL) — Crash on bad QR  
6. Rest: v2 backlog  
