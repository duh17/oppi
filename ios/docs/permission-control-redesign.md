# Permission Control — Redesign Spec

> Replaces the inline-card approach from DESIGN.md Section 4.
> Permission requests move from heavy timeline cards to a floating overlay
> system that is always reachable, gesture-driven, and Liquid Glass native.

## Problem Statement

The current implementation has three components:

| Component | Location | Issue |
|-----------|----------|-------|
| `PermissionCardView` | `Permissions/PermissionCardView.swift` | Full-width inline card (risk badge + monospace command + reason + 2 buttons). Dominates the timeline when 2-3 permissions arrive in a row. Uses `tokyoBgHighlight` with colored border -- visually disconnected from the terminal-style chat. |
| `PermissionPillBanner` | `ChatView.swift` (private) | Orange bar with text "N pending -- tap to review". Plain bg, no Liquid Glass, no urgency, no gesture. Just scrolls to the inline card. |
| `PermissionResolvedBadge` | `ChatItemRow.swift` (private) | Green/red capsule. Jarring weight change from full card -> tiny pill. |

Core UX failure: the most time-critical action in the app (approve a command
before the 30s timeout) requires scrolling to find a card buried in the
timeline, then tapping a button. Too many steps. If the user is typing when
the permission arrives, the card appears below the fold behind the keyboard.

## Design Principles

1. **Zero scroll to act.** The permission UI is always visible when pending.
2. **One gesture to resolve.** Swipe or tap -- not scroll-then-find-then-tap.
3. **Glass for controls, solid for content.** Buttons get Liquid Glass.
   Command text stays monospace on solid dark bg for readability.
4. **Risk communicates through color, not words.** Tint the glass, not the text.
5. **Timeline stays clean.** Pending permissions live in the overlay, not inline.
   Only resolved markers appear in the chat flow.

## Architecture Overview

```
                          PermissionStore (source of truth)
                                   |
                    +--------------+--------------+
                    |                             |
           PermissionOverlay              ChatItemRow
           (floating, always visible)     (inline resolved markers only)
                    |
          +---------+---------+
          |                   |
    PermissionPill      PermissionSheet
    (compact bar)       (detail, from pill tap)
```

Pending permissions never appear as `ChatItem.permission` in the timeline.
The reducer emits `.permissionResolved` markers inline after resolution.
All pending UI lives in `PermissionOverlay`, which floats above the scroll
view and input bar.

## Types

### PermissionOutcome

`PermissionAction` is the wire type (`.allow`/`.deny`) sent to the server.
`PermissionOutcome` is the local display type for resolved markers:

```swift
enum PermissionOutcome: Sendable, Equatable {
    case allowed
    case denied
    case expired
    case cancelled
}
```

This avoids polluting the `Codable` wire type with client-only states.

### ChatItem.permissionResolved (fattened)

The resolved timeline marker needs tool + summary for display:

```swift
case permissionResolved(
    id: String,
    outcome: PermissionOutcome,
    tool: String,
    summary: String
)
```

`TimelineReducer.resolvePermission()` must receive tool/summary from the
caller. `PermissionStore` preserves request data until after the reducer
records the resolved marker.

### ChatItem.permission (kept for trace compat)

The `.permission(PermissionRequest)` case stays in the enum for backward
compatibility with `loadFromTrace`. When encountered during trace replay,
the reducer auto-resolves it (the permission is historical, not actionable).
`ChatItemRow` renders it as a resolved marker, never as an interactive card.

## Components

### 1. PermissionOverlay

Container view overlaid on `ChatView`. Manages the floating pill and
the detail sheet. Positioned between the scroll view and the input bar.

```
+-----------------------------------+
|          ScrollView (chat)        |
|                                   |
|                                   |
+-----------------------------------+
|  [PermissionOverlay / pill area]  |  <-- safeAreaInset zone
+-----------------------------------+
|          ChatInputBar             |
+-----------------------------------+
```

**Placement:** `.safeAreaInset(edge: .bottom)` on the ScrollView, inside
the existing `VStack { SessionToolbar; ScrollView; InputBar }`. This pushes
scroll content up so the pill never covers chat messages. When no permissions
are pending, the view is `EmptyView` — zero height, no inset.

**State:**
- `pendingRequests: [PermissionRequest]` from `PermissionStore`
- `showDetail: Bool` -- whether the sheet is presented
- `swipeOffset: CGFloat` -- drag gesture tracking

### 2. PermissionPill

Compact floating bar. Always visible when permissions are pending.

**Single pending:**

```
+-----------------------------------------------------+
|  [icon]  $ git push origin main              0:28   |
+-----------------------------------------------------+
         ^                                       ^
     risk icon                               countdown
     (tinted)
```

**Multiple pending:**

```
+-----------------------------------------------------+
|  [icon]  $ git push origin main     0:28    3 more  |
+-----------------------------------------------------+
                                                  ^
                                            badge count
```

**Visual spec:**
- Height: 52pt
- Background: `.glassEffect(.regular.tint(riskColor).interactive())`
- Shape: `.capsule(style: .continuous)`
- Content: risk SF Symbol + command summary (monospace, truncated) + countdown
- Shadow: standard glass shadow (system-provided by `.glassEffect`)
- When multiple: trailing badge with "+N more"

**Gestures (single pending only):**

| Gesture | Action | Feedback |
|---------|--------|----------|
| Swipe right (> 80pt) | Allow | Green flash + `.light` haptic + pill slides off right |
| Swipe left (> 80pt) | Deny | Red flash + `.heavy` haptic + pill slides off left |
| Tap | Present detail sheet | Standard iOS 26 sheet presentation |
| Horizontal drag (< 80pt) | Peek allow/deny state | Pill translates, bg tints green/red |

**Gestures (multiple pending):**

| Gesture | Action | Feedback |
|---------|--------|----------|
| Tap | Present detail sheet (with paging) | Standard sheet presentation |

When 2+ permissions are pending, swipe-to-resolve is disabled on the pill.
The user must tap into the sheet to act on individual requests. This avoids
gesture ambiguity between allow/deny swipe and paging.

**Swipe mechanics (single pending):**

The pill tracks the user's horizontal drag. As the drag passes thresholds,
visual feedback intensifies:

| Offset | Visual |
|--------|--------|
| 0-40pt right | Pill translates. Green tint fades in on trailing edge. |
| 40-80pt right | "Allow" label appears. Haptic `.soft`. |
| >80pt right | Snap to allow. Green flash. `.light` impact. |
| 0-40pt left | Pill translates. Red tint fades in on leading edge. |
| 40-80pt left | "Deny" label appears. Haptic `.soft`. |
| >80pt left | Snap to deny. Red flash. `.heavy` impact. |
| Release < 80pt | Spring back to center. |

For **critical risk** requests, swipe-right-to-allow is disabled even when
single. The user must tap into the detail sheet and use the deliberate allow
button. The pill shows a lock icon on the right edge to signal this.

**Countdown behavior:**

The pill shows `Text(request.timeoutAt, style: .timer)` for the first
pending request. When < 10s remaining, the countdown pulses (opacity
animation). When the server sends `permission_expired`, the pill updates
to the next request or dismisses.

### 3. PermissionSheet

Detail view presented as a bottom sheet when the user taps the pill.
Uses standard iOS 26 sheet presentation (glass bg is automatic at partial
detent).

**Detent:** `.presentationDetents([.height(340), .medium])` -- compact by
default, expandable for long commands.

**Layout (single, compact detent, ~340pt):**

```
+-------------------------------------------+
|                                           |
|   [risk icon]  Permission Request   0:28  |
|                                           |
|   +-------------------------------------+ |
|   |  $ git push origin main --force     | |  <-- monospace, solid dark bg
|   +-------------------------------------+ |
|                                           |
|   Pushes to remote repository.            |  <-- reason (secondary text)
|                                           |
|   +-------+  +--------------------------+|
|   | Deny  |  |         Allow            ||  <-- glass buttons
|   +-------+  +--------------------------+|
|                                           |
+-------------------------------------------+
```

**Layout (multiple pending):**

When 2+ pending, the sheet content is a `TabView(.page)` so the user can
swipe horizontally between requests. A page indicator shows position. Each
page has the same layout as the single-request view. A "Deny All" button
appears at the bottom when 3+ requests are pending.

**Visual spec:**
- Background: Liquid Glass (automatic on iOS 26 sheets at partial detent)
- Command box: `Color.tokyoBgDark`, `RoundedRectangle(cornerRadius: 10)`,
  monospace font, `.textSelection(.enabled)`
- Risk icon: same tinted SF Symbol from the pill, larger (`.title2`)
- Countdown: `Text(timeoutAt, style: .timer)` with `.monospacedDigit()`
- Buttons: full width, stacked or side-by-side depending on risk level

**Button layout by risk:**

| Risk | Allow | Deny |
|------|-------|------|
| Low | `.glassProminent` `.tint(.green)` -- 2/3 width | `.glass` -- 1/3 width |
| Medium | `.glassProminent` `.tint(.blue)` -- 1/2 width | `.glass` `.tint(.red)` -- 1/2 width |
| High | `.glass` `.tint(.orange)` -- 1/2 width | `.glass` `.tint(.red)` -- 1/2 width |
| Critical | `.bordered` `.tint(.primary)` red border -- 1/2 width | `.glassProminent` `.tint(.red)` -- 1/2 width |

For critical: Deny is the prominent (easy) action. Allow requires deliberate
tap on a non-prominent button. This inverts the default emphasis.

**Auto-dismiss:** When the active request is resolved (by this device, another
device, or expiry), the sheet auto-advances to the next pending request. If
none remain, the sheet dismisses after a brief "All clear" flash (300ms).

### 4. PermissionResolvedRow (inline timeline marker)

Replaces both `PermissionCardView` (inline) and `PermissionResolvedBadge`.
A single compact row in the chat timeline, matching the visual weight of
tool call rows.

```
[checkmark.shield.fill]  Allowed: bash "git push origin main"
[xmark.shield.fill]      Denied: bash "rm -rf /"
[clock.badge.xmark]      Expired: bash "sudo apt install"
```

**Visual spec:**
- Single line, left-aligned
- Icon: green checkmark.shield / red xmark.shield / gray clock.badge.xmark
- Text: `outcome: tool "summary"` in `.caption.monospaced()`
- Background: subtle tinted strip (green/red/gray at 0.08 opacity)
- Shape: `RoundedRectangle(cornerRadius: 8)`
- Padding: 8pt horizontal, 6pt vertical
- No expand/collapse, no buttons, no interaction beyond context menu (Copy)

This is the only permission element in the chat timeline. Pending permissions
do not appear inline at all.

### 5. Permission Expiry in Overlay

When a permission expires (server sends `permission_expired`), the pill
shows a brief "Expired" state:
- Pill bg desaturates (gray tint)
- Command text strikes through
- Auto-dismisses after 1.5 seconds (or immediately advances if others pending)
- Timeline gets a `.permissionResolved(id, .expired, tool, summary)` marker

## Data Flow

### PermissionStore changes

The store must preserve request data long enough for the reducer to record
a fattened resolved marker. New API:

```swift
@MainActor @Observable
final class PermissionStore {
    var pending: [PermissionRequest] = []

    var count: Int { pending.count }

    func add(_ request: PermissionRequest) {
        guard !pending.contains(where: { $0.id == request.id }) else { return }
        pending.append(request)
    }

    /// Remove and return the request (caller needs tool/summary for resolved marker).
    func take(id: String) -> PermissionRequest? {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: idx)
    }

    /// Remove without returning (fire-and-forget).
    func remove(id: String) {
        pending.removeAll { $0.id == id }
    }

    func pending(for sessionId: String) -> [PermissionRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    func sweepExpired() -> [PermissionRequest] {
        let now = Date()
        let expired = pending.filter { $0.timeoutAt < now }
        pending.removeAll { $0.timeoutAt < now }
        return expired
    }
}
```

Key change: `take(id:)` returns the full request before removing, and
`sweepExpired()` returns full requests (not just IDs) so the reducer can
record tool/summary in the resolved marker.

### TimelineReducer changes

```swift
func resolvePermission(id: String, outcome: PermissionOutcome, tool: String, summary: String) {
    if let idx = items.firstIndex(where: { $0.id == id }) {
        items[idx] = .permissionResolved(id: id, outcome: outcome, tool: tool, summary: summary)
    } else {
        items.append(.permissionResolved(id: id, outcome: outcome, tool: tool, summary: summary))
    }
    bumpRenderVersion()
}
```

If the permission was never in the timeline (new flow: pending permissions
skip the timeline), we append instead of replace. This handles both old
(inline card) and new (overlay-only) flows.

### ServerConnection changes

Permission resolution call sites update to use `take()` and pass data through:

```swift
func respondToPermission(id: String, action: PermissionAction) async throws {
    try await wsClient.send(.permissionResponse(id: id, action: action))
    let outcome: PermissionOutcome = action == .allow ? .allowed : .denied
    if let request = permissionStore.take(id: id) {
        reducer.resolvePermission(
            id: id, outcome: outcome,
            tool: request.tool, summary: request.displaySummary
        )
    }
}
```

Permission cancelled/expired:
```swift
case .permissionCancelled(let id):
    if let request = permissionStore.take(id: id) {
        reducer.resolvePermission(
            id: id, outcome: .cancelled,
            tool: request.tool, summary: request.displaySummary
        )
    }

case .permissionExpired(let id, _):
    if let request = permissionStore.take(id: id) {
        reducer.resolvePermission(
            id: id, outcome: .expired,
            tool: request.tool, summary: request.displaySummary
        )
    }
```

### Timeline: no more inline pending

The reducer stops appending `ChatItem.permission` for live events.
`handleServerMessage` routes `.permissionRequest` to `PermissionStore`
and `DeltaCoalescer` only — NOT to the reducer timeline.

For **trace replay** (`loadFromTrace`), if a `.permissionRequest` trace event
is encountered, auto-resolve it as expired (historical, not actionable).

### Wire protocol (no changes)

Server protocol unchanged. `permission_request`, `permission_expired`, and
`permission_response` messages stay the same. `PermissionOutcome` is
client-only.

## Gesture Implementation Notes

### Swipe-to-resolve on pill (single pending only)

```swift
@GestureState private var dragOffset: CGFloat = 0

var swipeGesture: some Gesture {
    DragGesture(minimumDistance: 20)
        .updating($dragOffset) { value, state, _ in
            if request.risk == .critical && value.translation.width > 0 {
                state = 0  // block right-swipe for critical
            } else {
                state = value.translation.width
            }
        }
        .onEnded { value in
            let threshold: CGFloat = 80
            if value.translation.width > threshold && request.risk != .critical {
                resolve(.allow)
            } else if value.translation.width < -threshold {
                resolve(.deny)
            }
        }
}
```

### Haptic feedback schedule

| Event | Haptic |
|-------|--------|
| Drag crosses 40pt threshold | `.sensoryFeedback(.impact(flexibility: .soft))` |
| Swipe completes (allow) | `.sensoryFeedback(.impact(weight: .light))` |
| Swipe completes (deny) | `.sensoryFeedback(.impact(weight: .heavy))` |
| Tap pill | `.sensoryFeedback(.selection)` |
| Permission expired | `.sensoryFeedback(.warning)` |

## iOS 26 API Usage

| API | Where | Purpose |
|-----|-------|---------|
| `.glassEffect(.regular.tint(color).interactive())` | PermissionPill | Risk-tinted floating glass bar |
| `.buttonStyle(.glassProminent)` | Allow button (non-critical) | Native glass button |
| `.buttonStyle(.glass)` | Deny button, secondary actions | Subtle glass button |
| `.presentationDetents([.height(340)])` | PermissionSheet | Compact glass sheet, auto-glass bg |
| `Text(date, style: .timer)` | Countdown in pill + sheet | System countdown, auto-updating |
| `.safeAreaInset(edge: .bottom)` | ChatView ScrollView | Pill pushes chat content up, zero when empty |
| `.sensoryFeedback()` | Swipe gestures | SwiftUI-native haptics (no UIKit generators) |
| `TabView(.page)` | Multi-permission sheet | Horizontal paging between requests |

## Migration Path

### Files to create
- `Features/Permissions/PermissionOverlay.swift` -- container (pill + sheet)
- `Features/Permissions/PermissionPill.swift` -- floating glass pill with swipe
- `Features/Permissions/PermissionSheet.swift` -- detail sheet with buttons

### Files to modify
- `Core/Models/Permission.swift` -- add `PermissionOutcome`
- `Core/Runtime/ChatItem.swift` -- fatten `.permissionResolved` with outcome/tool/summary
- `Core/Runtime/TimelineReducer.swift` -- stop emitting `.permission` for live events; update `resolvePermission` signature
- `Core/Services/PermissionStore.swift` -- add `take(id:)`, return full requests from `sweepExpired()`
- `Core/Networking/ServerConnection.swift` -- use `take()` in resolution paths, stop routing to reducer for pending
- `Features/Chat/ChatView.swift` -- remove `PermissionPillBanner`, add `PermissionOverlay` via `.safeAreaInset`
- `Features/Chat/ChatItemRow.swift` -- replace `PermissionResolvedBadge` with `PermissionResolvedRow`; render `.permission` case as resolved (trace compat)

### Files to delete
- `Features/Permissions/PermissionCardView.swift` -- no longer needed (inline card removed)

### Test updates
- `BugBashTests` -- update `permissionCancelledResolvesInTimeline` and related tests for new `.permissionResolved` shape and `PermissionOutcome`

## Accessibility

- **VoiceOver:** Pill announces "Permission request: [tool] [summary]. Double tap for details." When single: "Swipe right to allow, left to deny."
- **Dynamic Type:** Pill truncates command summary; sheet shows full text.
- **Reduce Motion:** Disable swipe-to-resolve. Pill shows Allow/Deny buttons inline instead. No morph transitions.
- **Reduce Transparency:** Glass falls back to opaque tinted bg (system behavior).
- **Switch Control:** Pill and sheet buttons are standard focusable controls.

## Open Questions

1. **Should swipe-to-allow be disabled for high risk too, or only critical?**
   Current spec: only critical blocks swipe-allow. High risk allows it but
   with orange warning tint. Could tighten this if users report accidental
   approvals.

2. **Batch "Allow All" for low-risk groups** -- worth building in v1 or defer?
   The server sends individual requests; batching is client-side grouping.
   Defer unless permission volume is high in practice.
