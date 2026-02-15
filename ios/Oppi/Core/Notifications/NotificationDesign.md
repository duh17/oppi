# Permission Notifications Design

## Problem
When the app is backgrounded or the user is in another app, permission
requests expire silently. The agent stalls or auto-denies.

## Solution: Two-tier notification system

### Tier 1: Local Push Notification (no server changes)
When the WebSocket delivers a `permission_request` and the app is in the
background (or inactive), fire a local `UNNotification` with actionable
buttons.

**How it works:**
1. App registers `UNNotificationCategory` "PERMISSION" with actions "Allow" and "Deny"
2. `ServerConnection.handleServerMessage` checks `UIApplication.shared.applicationState`
3. If `.background` or `.inactive`, schedule a `UNNotificationRequest` immediately
4. User sees banner/lock screen notification with "Allow" / "Deny" buttons
5. `UNUserNotificationCenterDelegate.didReceive` routes the response back
   through the WebSocket (which may still be alive briefly in background)

**Limitation:** iOS suspends WebSocket ~30s after backgrounding. If the
permission arrives after suspension, it's lost until foreground.

### Tier 2: Remote Push via APNs (requires server changes)
Server detects no active WebSocket client → sends APNs push via the
device token registered at connection time.

**Server changes:**
1. Client sends `{ type: "register_push", deviceToken: "..." }` on connect
2. Server stores device tokens per user
3. On `permission_request` from gate, if no WS subscribers → send APNs push
4. APNs payload includes permission ID, tool name, risk level

**iOS changes:**
1. Register for remote notifications on launch
2. Send device token to server via new ClientMessage type
3. Handle remote notification → open app → scroll to permission

### Tier 3: Live Activity (iOS 16.1+)
For when the user is on another app but phone is unlocked.
Shows a persistent banner on the Dynamic Island / Lock Screen.

**How it works:**
1. On `permission_request`, start a `LiveActivity<PermissionAttributes>`
2. Shows tool name, risk level, countdown timer on Dynamic Island
3. User taps → opens app → scrolls to permission card
4. On resolve/expire, end the Live Activity

## Implementation Priority
1. **Tier 1 (local notifications)** — zero infrastructure, ~50 lines of code
2. **Tier 3 (Live Activity)** — no server changes, good UX for active phone use
3. **Tier 2 (APNs)** — requires server APNs integration, most complete solution

## Tier 1 Implementation

Register category at app launch:
```swift
let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [])
let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
let category = UNNotificationCategory(
    identifier: "PERMISSION",
    actions: [allow, deny],
    intentIdentifiers: []
)
UNUserNotificationCenter.current().setNotificationCategories([category])
```

Fire on permission_request when backgrounded:
```swift
let content = UNMutableNotificationContent()
content.title = "Permission Required"
content.body = "\(request.tool): \(request.displaySummary)"
content.categoryIdentifier = "PERMISSION"
content.userInfo = ["permissionId": request.id, "sessionId": request.sessionId]
content.sound = .default
content.interruptionLevel = .timeSensitive

let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
let request = UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)
try await UNUserNotificationCenter.current().add(request)
```
