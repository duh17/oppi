# Pi Remote — iOS App Design

> **Review status:** Incorporates round-5 feedback from REVIEW.md (auto-scroll
> mechanics, server reconnect alignment, and stream-path performance constraints
> from container → WebSocket → iOS).

## Overview

Pi Remote for iOS is the mobile workshop for pi coding agents running on a
home server. Two roles: **permission authority** (approve dangerous actions)
and **skill workshop** (build, refine, and curate what your agent can do).

**Target:** iOS 26+ (Liquid Glass), SwiftUI, iPhone-only (portrait locked)

**Core loops:**

Permission (safety):
```
Notification: "pi wants to run `git push origin main`"
→ Glance at your phone → Tap Allow or Deny → Back to life
```

Skills (growth):
```
"I need my agent to analyze Strava exports"
→ Describe on phone → Agent builds skill → Test → Refine → Save
→ Future sessions have it pre-loaded
```

Sessions, skills, and permissions are the three pillars of the app.

---

## Design Philosophy

### Liquid Glass: Navigation Layer Only

Apple's Liquid Glass is for controls that float above content. We follow this
strictly:

**Use Liquid Glass for:**
- Tab bar (sessions / activity / settings)
- Toolbars and navigation bars
- Floating action button (new session)
- Permission card action buttons (allow/deny)
- Sheet presentations

**Never use Liquid Glass for:**
- Chat message bubbles
- Session list rows
- Activity feed entries
- Any scrollable content

This keeps content readable and avoids the legibility problems NN/g identified
with iOS 26. Glass is functional chrome; content is content.

### Respect the Criticism

iOS 26 Liquid Glass drew legitimate criticism for:
- **Readability**: Translucent text over busy backgrounds
- **Crowded targets**: Shrunken tab bar touch targets
- **Excessive animation**: Motion for motion's sake

Our response:
- High-contrast text on all glass surfaces (white bold text, vibrant treatment)
- Generous touch targets (minimum 44×44pt, 48×48pt for primary actions)
- Animation only where it communicates state change (permission morphing, session
  transitions) — never decorative
- Content backgrounds are solid or subtly gradient, never photos under glass

### Content-First, Glass-Second

The phone is grabbed for 5 seconds to approve a command. Every pixel serves
that goal:
- What does the agent want to do? (clear, readable summary)
- How dangerous is it? (color-coded risk)
- Approve or deny? (two big buttons)

Everything else is secondary.

---

## App Architecture

```
PiRemote/
├── App/
│   ├── PiRemoteApp.swift          # @main entry, scene setup, scenePhase
│   ├── Router.swift               # Navigation state machine
│   └── Info.plist                 # Portrait-locked, notification categories
│
├── Core/
│   ├── Networking/
│   │   ├── APIClient.swift        # REST client (sessions, auth, image upload)
│   │   ├── WebSocketClient.swift  # WS streaming + permissions + keepalive
│   │   └── ServerConnection.swift # Connection state, reconnect, scenePhase
│   │
│   ├── Models/
│   │   ├── Session.swift          # Session, SessionMessage, SessionPurpose
│   │   ├── Skill.swift            # Skill, SkillVersion, SkillState
│   │   ├── Permission.swift       # PermissionRequest, risk levels
│   │   ├── User.swift             # User, auth token
│   │   ├── ServerConfig.swift     # Host, port, connection info
│   │   ├── JSONValue.swift        # Recursive Codable JSON type
│   │   └── ServerMessage.swift    # Manual Decodable with type discriminator
│   │
│   ├── Runtime/
│   │   ├── AgentEvent.swift       # Transport-agnostic domain events
│   │   ├── ChatItem.swift         # Unified mixed timeline model
│   │   ├── TimelineReducer.swift  # Server events -> ChatItem state machine
│   │   └── DeltaCoalescer.swift   # Batches high-frequency deltas for UI
│   │
│   ├── Surfaces/
│   │   ├── SurfaceSink.swift      # Protocol for output primitives
│   │   ├── SurfaceCoordinator.swift # Fan-out to registered surfaces
│   │   ├── InAppTimelineSurface.swift # Chat/session UI projection
│   │   ├── NotificationSurface.swift # APNs/local notifications
│   │   └── LiveActivitySurface.swift  # Dynamic Island / Live Activity (v2)
│   │
│   ├── Services/
│   │   ├── SessionService.swift   # Session lifecycle management
│   │   ├── PermissionService.swift # Permission queue + resolution
│   │   ├── SkillService.swift     # Skill CRUD + version management
│   │   ├── NotificationService.swift # APNs registration + handling
│   │   └── KeychainService.swift  # Secure token storage
│   │
│   └── Extensions/
│       ├── Color+Risk.swift       # Risk-tier color palette
│       └── Date+Relative.swift    # "2m ago" formatting
│
├── Features/
│   ├── Onboarding/
│   │   ├── OnboardingView.swift   # Welcome → QR scan → connection test
│   │   ├── QRScannerView.swift    # DataScannerViewController wrapper
│   │   └── ConnectionTestView.swift # Verify server reachable
│   │
│   ├── Sessions/
│   │   ├── SessionListView.swift  # All sessions for this user
│   │   ├── SessionRowView.swift   # Single session in list
│   │   └── NewSessionView.swift   # Create session sheet + model picker
│   │
│   ├── Chat/
│   │   ├── ChatView.swift         # Main chat + live stream
│   │   ├── MessageBubble.swift    # User/assistant message
│   │   ├── ToolCallView.swift     # Collapsible tool execution + copy
│   │   ├── ThinkingView.swift     # Thinking indicator
│   │   └── ChatInputBar.swift     # Text input + send (rounded rect)
│   │
│   ├── Permissions/
│   │   ├── PermissionCardView.swift    # The money feature
│   │   ├── PermissionBannerView.swift  # Floating pill when typing
│   │   ├── PermissionQueueView.swift   # Multiple pending + batch actions
│   │   └── RiskBadge.swift             # Risk level indicator
│   │
│   ├── ExtensionUI/
│   │   ├── ExtensionDialogView.swift   # select/confirm/input dialogs
│   │   └── ExtensionStatusView.swift   # Notification/status forwarding
│   │
│   ├── Skills/
│   │   ├── SkillListView.swift         # Main Skills tab — grouped by state
│   │   ├── SkillRowView.swift          # Skill card in list
│   │   ├── SkillDetailView.swift       # Skill detail + files + versions
│   │   ├── SkillCreationSheet.swift    # "+" flow → describe → start session
│   │   ├── SkillSaveBanner.swift       # "Save as Skill" banner in chat
│   │   └── VersionHistoryView.swift    # Version list + restore
│   │
│   ├── Files/
│   │   ├── FileListView.swift          # Directory browser (session + skill)
│   │   ├── FileRowView.swift           # Single file row
│   │   ├── FilePreviewView.swift       # Router to type-specific previews
│   │   ├── MarkdownPreviewView.swift   # Markdown rendering
│   │   ├── HTMLPreviewView.swift       # WKWebView for HTML
│   │   ├── ImagePreviewView.swift      # AsyncImage viewer
│   │   └── CodePreviewView.swift       # Monospace text
│   │
│   └── Settings/
│       ├── SettingsView.swift     # Server info, policy, about
│       └── ServerStatusView.swift # Connection health + offline banner
│
└── Resources/
    ├── Assets.xcassets
    └── Info.plist
```

### State Management

Separate observable stores to scope re-renders. Permission timer ticks
(every second) don't re-render the session list.

```swift
// MARK: — Separate stores, not one god object

@MainActor @Observable
final class ConnectionState {
    var status: ConnectionStatus = .disconnected
    var lastConnected: Date?
    var serverHost: String = ""
    var serverPort: Int = 7749
}

@MainActor @Observable
final class SessionStore {
    var sessions: [Session] = []
    var activeSessionId: String?
}

@MainActor @Observable
final class PermissionStore {
    var pending: [PermissionRequest] = []
    var history: [PermissionRequest] = []
}

@MainActor @Observable
final class SkillStore {
    var skills: [Skill] = []            // All skills (built-in + user)
    var drafts: [SkillDraft] = []       // In-progress from sessions

    var active: [Skill] { skills.filter { $0.state == .active || $0.state == .builtIn } }
    var archived: [Skill] { skills.filter { $0.state == .archived } }
}

@MainActor @Observable
final class AppNavigation {
    var selectedTab: Tab = .sessions
    var showOnboarding: Bool = true
}

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

enum Tab: Hashable {
    case sessions
    case skills
    case settings
}
```

Inject via `@Environment` so views only observe what they need:

```swift
@main
struct PiRemoteApp: App {
    @State private var connectionState = ConnectionState()
    @State private var sessionStore = SessionStore()
    @State private var permissionStore = PermissionStore()
    @State private var navigation = AppNavigation()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionState)
                .environment(sessionStore)
                .environment(permissionStore)
                .environment(navigation)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                .task { await reconnectOnLaunch() }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // App foregrounded — reconnect WebSocket, refresh state
            Task { await serverConnection.reconnectIfNeeded() }
        case .background:
            // Let WebSocket die — rely on push for permissions
            break
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func reconnectOnLaunch() async {
        // 1. Load token from Keychain
        // 2. GET /workspaces + /workspaces/:wid/sessions → refresh session list
        // 3. Restore last-open session and connect ONE WebSocket (v1)
        // 4. Send get_state to sync pending permissions
    }
}
```

### Networking

`@MainActor @Observable` class — NOT an actor (actor + ObservableObject
won't compile, actor-isolated properties can't be directly observed by views).

```swift
@MainActor @Observable
final class ServerConnection {
    private(set) var status: ConnectionStatus = .disconnected
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTimer: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

    private let baseURL: URL
    private let token: String

    // REST — session management
    func listSessions() async throws -> [Session] { ... }
    func createSession(name: String?, model: String?) async throws -> Session { ... }
    func deleteSession(id: String) async throws { ... }

    // REST — image upload (NOT over WebSocket — base64 over WS blocks the frame)
    func uploadImage(sessionId: String, data: Data, mimeType: String) async throws -> String { ... }

    // WebSocket — connects to a specific session
    // v1 policy: one active WebSocket at a time
    func connect(sessionId: String) -> AsyncStream<ServerMessage> {
        // Disconnect existing connection first (if any)
        // Create URLSessionWebSocketTask with bearer auth header
        // Start receive loop
        // Start keepalive ping timer (every 30s)
        // Return AsyncStream with onTermination cleanup
    }

    func send(_ message: ClientMessage) async throws { ... }
    func disconnect() { ... }

    // Permission response (can be sent from any screen)
    func respondToPermission(id: String, action: PermissionAction) async throws { ... }

    // Reconnect after background/disconnect
    func reconnectIfNeeded() async { ... }

    // MARK: — Internal

    // Keepalive pings — URLSessionWebSocketTask doesn't send pings by default
    private func startPingTimer() {
        pingTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                webSocket?.sendPing { error in
                    if error != nil { /* trigger reconnect */ }
                }
            }
        }
    }

    // Receive loop — pull-based, must call receive() in loop
    private func startReceiveLoop(
        continuation: AsyncStream<ServerMessage>.Continuation
    ) {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    guard let wsMessage = try await webSocket?.receive() else {
                        break
                    }

                    let serverMessage = try decodeServerMessage(wsMessage)
                    if case .unknown(let type) = serverMessage {
                        logger.debug("Skipping unknown server message type: \(type)")
                        continue
                    }

                    continuation.yield(serverMessage)
                } catch {
                    // WebSocket died OR payload decode failed
                    // (unknown message types should decode to .unknown, not throw)
                    break
                }
            }
        }
    }

    // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
    private var reconnectDelay: TimeInterval {
        min(pow(2, Double(reconnectAttempts)), 30)
    }
}
```

**Key networking decisions:**
- **One WebSocket at a time in v1.** Opening a new session connection first
  calls `disconnect()` on the existing one.
- Image upload via `POST /workspaces/:workspaceId/sessions/:id/attachments` (REST), not base64 over
  WebSocket. A 4MB base64 image blocks the WS frame and prevents permission
  responses from being sent.
- Client sends WebSocket pings every 30s (URLSessionWebSocketTask has no
  automatic ping).
- `ServerMessage` has an `.unknown(type:)` case. Unknown server message types
  are logged and skipped, not treated as fatal decode errors.
- On reconnect after background, fetch `GET /workspaces/:workspaceId/sessions/:id` to rebuild chat
  state (server doesn't replay missed streaming events).
- AsyncStream `onTermination` cancels the WebSocket task to prevent leaks
  when the view pops.

### Event Pipeline & Surface Model (Extensible to Dynamic Island)

To support streaming thinking/tool traces now and additional iOS primitives
later (Live Activities / Dynamic Island), the data flow is split into layers:

```
ServerMessage (transport)
  -> AgentEvent (domain event)
  -> TimelineReducer (session state machine)
  -> SurfaceCoordinator (fan-out)
  -> Surface sinks (in-app, push, live activity, etc.)
```

**Dynamic Island note:** Dynamic Island is a presentation of a Live Activity
(ActivityKit). We design for a `LiveActivitySurface` sink now, but keep it
behind v2 scope.

```swift
enum AgentEvent: Sendable {
    case agentStart(sessionId: String)
    case agentEnd(sessionId: String)

    case textDelta(sessionId: String, delta: String)
    case thinkingDelta(sessionId: String, delta: String)

    // v1 server tool messages have no ID.
    // Client generates toolEventId on tool_start and reuses it for output/end.
    case toolStart(
        sessionId: String,
        toolEventId: String,
        tool: String,
        args: [String: JSONValue]
    )
    case toolOutput(
        sessionId: String,
        toolEventId: String,
        output: String,
        isError: Bool
    )
    case toolEnd(sessionId: String, toolEventId: String)

    case permissionRequest(PermissionRequest)
    case permissionExpired(id: String)
    case sessionEnded(sessionId: String, reason: String)
    case error(sessionId: String, message: String)
}

protocol SurfaceSink {
    var id: SurfaceID { get }
    @MainActor func consume(_ event: AgentEvent)
}

enum SurfaceID {
    case inAppTimeline
    case notification
    case liveActivity
}
```

Routing split (transport -> direct state updates vs pipeline):

```swift
@MainActor
func handleServerMessage(_ message: ServerMessage, sessionId: String) {
    switch message {
    // Direct state/UI updates (not timeline events)
    case .connected(let session), .state(let session):
        sessionStore.upsert(session)

    case .extensionUIRequest(let request):
        activeExtensionDialog = request

    case .extensionUINotification(_, let message, _, _, _):
        extensionToast = message

    case .unknown(let type):
        logger.debug("Ignoring unknown server message: \(type)")

    // Pipeline events
    case .agentStart:
        pipeline.receive(.agentStart(sessionId: sessionId))
    case .agentEnd:
        pipeline.receive(.agentEnd(sessionId: sessionId))
    case .textDelta(let delta):
        pipeline.receive(.textDelta(sessionId: sessionId, delta: delta))
    case .thinkingDelta(let delta):
        pipeline.receive(.thinkingDelta(sessionId: sessionId, delta: delta))
    case .toolStart(tool: let tool, args: let args):
        pipeline.receive(toolMapper.start(sessionId: sessionId, tool: tool, args: args))
    case .toolOutput(output: let output, isError: let isError):
        pipeline.receive(toolMapper.output(sessionId: sessionId, output: output, isError: isError))
    case .toolEnd(tool: let _):
        pipeline.receive(toolMapper.end(sessionId: sessionId))
    case .permissionRequest(let request):
        pipeline.receive(.permissionRequest(request))
    case .permissionExpired(id: let id, reason: let _):
        pipeline.receive(.permissionExpired(id: id))
    case .sessionEnded(reason: let reason):
        pipeline.receive(.sessionEnded(sessionId: sessionId, reason: reason))
    case .error(let message):
        pipeline.receive(.error(sessionId: sessionId, message: message))
    case .permissionCancelled(id: let id):
        // remove card immediately from PermissionStore (direct update)
        permissionStore.remove(id: id)
    }
}
```

Tool-event correlation helper (v1):

```swift
@MainActor
final class ToolEventMapper {
    private var currentToolEventID: String?

    func start(sessionId: String, tool: String, args: [String: JSONValue]) -> AgentEvent {
        let id = UUID().uuidString
        currentToolEventID = id
        return .toolStart(sessionId: sessionId, toolEventId: id, tool: tool, args: args)
    }

    func output(sessionId: String, output: String, isError: Bool) -> AgentEvent {
        let id = currentToolEventID ?? UUID().uuidString
        return .toolOutput(sessionId: sessionId, toolEventId: id, output: output, isError: isError)
    }

    func end(sessionId: String) -> AgentEvent {
        let id = currentToolEventID ?? UUID().uuidString
        currentToolEventID = nil
        return .toolEnd(sessionId: sessionId, toolEventId: id)
    }
}
```

Assumption: tool events are sequential (one open tool at a time). If server
adds parallel/interleaved tools, protocol must include server-side tool IDs.

**v1 sinks:**
- `InAppTimelineSurface` (full-fidelity chat/timeline, expandable sections)
- `NotificationSurface` (permission + session alerts)

**v2 sink:**
- `LiveActivitySurface` (compact session state + pending permissions for Lock
  Screen / Dynamic Island)

Performance rules by surface:

| Surface | Fidelity | Update Policy |
|--------|----------|---------------|
| In-app timeline | Full (thinking/tool/output) | Coalesce text/thinking (33-50ms), immediate tool/permission/error |
| Notification | Event-driven only | Only on permission/error/session-end |
| Live Activity (v2) | Summary only | Throttle to coarse updates (≈1s+) |

Container -> iOS streaming performance contract:
- Hot path must avoid synchronous disk I/O per event.
- Parse once (`JSON.parse` line from container), translate, broadcast.
- Persist session metadata on debounce (~1s) and flush immediately on
  `agent_end` / `session_ended`.
- Persist finalized assistant messages on `message_end` so reconnect rebuilds
  conversation text correctly.
- If WebSocket backpressure appears (`bufferedAmount` growth), prioritize
  permission/error/lifecycle delivery over best-effort deltas.

`DeltaCoalescer` rules (critical for terminal-like smoothness):

```swift
@MainActor
func receive(_ event: AgentEvent) {
    switch event {
    // High-frequency events (batch)
    case .textDelta(_, _), .thinkingDelta(_, _):
        buffer.append(event)
        scheduleFlushIfNeeded(interval: .milliseconds(33))

    // Non-delta events (must be immediate)
    case .permissionRequest(_),
         .permissionExpired(_),
         .toolStart(_, _, _, _),
         .toolOutput(_, _, _, _),
         .toolEnd(_, _),
         .agentStart(_),
         .agentEnd(_),
         .sessionEnded(_, _),
         .error(_, _):
        flushBufferedDeltasNow()
        deliverImmediately(event)
    }
}
```

Why `toolOutput` bypasses batching: users perceive tool output as command
feedback (terminal feel). 33-50ms for text/thinking is fine; tool feedback
should render as soon as frames arrive.

Live Activity must **not** receive raw token-by-token thinking/tool output.
It gets summarized state only (agent busy/ready, active tool name, pending
permission count, countdown). This keeps battery/network cost predictable.

---

## Screens

### 1. Onboarding

**Flow:** Welcome → QR Scan → Connection Test → Done

```
┌─────────────────────────────┐
│                             │
│      ┌──────────────┐      │
│      │   Pi Remote   │      │
│      │     ◉ ◉ ◉     │      │
│      └──────────────┘      │
│                             │
│   Control your pi agents    │
│   from your phone.          │
│                             │
│   Scan the QR code from     │
│   your server to connect.   │
│                             │
│  ┌───────────────────────┐  │
│  │                       │  │
│  │    [Scan QR Code]     │  │  ← .buttonStyle(.glassProminent)
│  │                       │  │    .tint(.blue)
│  └───────────────────────┘  │
│                             │
│   Enter manually ›          │  ← text link
│                             │
└─────────────────────────────┘
```

QR code contains JSON:
```json
{
  "host": "myhost.tail12345.ts.net",
  "port": 7749,
  "token": "nr_abc123...",
  "name": "Chen"
}
```

After scan:
1. Test connection: `GET /health` then `GET /me`
2. Store token in Keychain
3. Transition to session list
4. **Request notification permission AFTER connection succeeds** — with a
   pre-prompt explaining why ("Pi Remote sends notifications when your agent
   needs approval for dangerous actions"). iOS shows the system dialog only
   once; maximizing grant rate matters.

**QR Scanner implementation:** No native SwiftUI QR scanner exists. Use
`DataScannerViewController` (VisionKit, iOS 16+) wrapped in
`UIViewControllerRepresentable`. Requires camera permission. ~50-80 lines
of bridging boilerplate — handle camera lifecycle and permission prompts
properly.

**Liquid Glass usage:** Only the primary CTA button gets `.glassProminent`.
The rest is solid background with clean typography.

---

### 2. Session List (Home Tab)

```
┌─────────────────────────────┐
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │  ← glass nav bar
│  ┃  Sessions        ● 🔔  ┃  │     (connection dot + notifications)
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
│                             │
│  ┌───────────────────────┐  │
│  │ 🟢 Feature: auth flow │  │  ← solid card, no glass
│  │ ready • claude-sonnet  │  │
│  │ "I've implemented the  │  │
│  │  login endpoint..."    │  │
│  │ 3m ago                 │  │
│  └───────────────────────┘  │
│                             │
│  ┌───────────────────────┐  │
│  │ 🟡 Debug: memory leak │  │  ← yellow = busy
│  │ busy • 2 pending ⚠️    │  │     pending permissions badge
│  │ "Analyzing heap dump..."│  │
│  │ 12s ago                │  │
│  └───────────────────────┘  │
│                             │
│  ┌───────────────────────┐  │
│  │ ⚫ Refactor: types    │  │
│  │ stopped • 47 messages  │  │
│  │ "Done! All types..."   │  │
│  │ 2h ago                 │  │
│  └───────────────────────┘  │
│                             │
│                        ┌──┐ │
│                        │＋│ │  ← floating glass action button
│                        └──┘ │     positioned above tab bar safe area
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │  ← glass tab bar
│  ┃ Sessions   Live     ⚙️ ┃  │
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
└─────────────────────────────┘
```

**Session row design:**
- Status dot: 🟢 ready, 🟡 busy, 🔴 error, ⚫ stopped
- Session name (user-provided or auto-generated)
- Model name, small text
- Last message preview, 2 lines max
- Relative timestamp
- Permission badge if pending approvals exist

**New session sheet:** Includes a model text field. The server has no
`GET /models` endpoint yet — v1 uses a text field with commonly used models
as suggestions. Server endpoint added to API plan for v2.

**Offline state:** When REST endpoints are unreachable, show a pinned banner:
"Last updated 5 minutes ago • Offline". Keep the cached session list from
the last successful fetch (in-memory, not persisted). Render it with
`.safeAreaInset(edge: .top)` so it sits below the nav bar and does not
push/shift list content.

**Liquid Glass usage:**
- Tab bar: automatic with `TabView`
- Nav bar: automatic with `NavigationStack`
- Floating "+" button: `.glassEffect(.regular.tint(.blue).interactive())`
  — positioned with `.safeAreaInset` to sit above the tab bar
- Session cards: **NO glass** — solid `secondarySystemBackground` cards

```swift
TabView(selection: $navigation.selectedTab) {
    Tab("Sessions", systemImage: "terminal", value: .sessions) {
        NavigationStack {
            SessionListView()
        }
    }
    Tab("Skills", systemImage: "wrench.and.screwdriver", value: .skills) {
        NavigationStack {
            SkillListView()
        }
    }
    Tab("Settings", systemImage: "gear", value: .settings) {
        NavigationStack {
            SettingsView()
        }
    }
}
.tabBarMinimizeBehavior(.onScrollDown)
```

```swift
NavigationStack {
    SessionListView()
        .safeAreaInset(edge: .top) {
            if connectionState.status == .disconnected {
                OfflineBanner(lastUpdated: connectionState.lastConnected)
            }
        }
}
```

---

### 3. Chat View (Session Detail)

Entered by tapping a session row. This is a conversation + activity feed hybrid.

```
┌─────────────────────────────┐
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │  ← glass nav bar
│  ┃ ‹  Feature: auth  🟢  ┃  │     back button + status dot
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
│                             │
│  ┌ ⚠️ 1 pending ──────── ┐  │  ← floating permission pill
│  └───────────── tap to ▼ ┘  │     (shows when typing + perm arrives)
│                             │
│  ┌─ You ────────────────┐   │
│  │ Add login endpoint   │   │  ← right-aligned, tinted bubble
│  │ with JWT tokens      │   │     solid color, no glass
│  └──────────────────────┘   │
│                             │
│  ┌─ Agent ──────────────┐   │
│  │ I'll implement the   │   │  ← left-aligned, subtle bg
│  │ JWT auth flow...     │   │
│  │                      │   │
│  │ ▶ bash: npm install  │   │  ← collapsible tool call
│  │   jsonwebtoken       │   │     tap to expand, long-press to copy
│  │   ✓ exit 0           │   │
│  │                      │   │
│  │ ▶ edit: src/auth.ts  │   │  ← another tool call
│  │   +45 -2 lines       │   │
│  │   ✓ saved            │   │
│  │                      │   │
│  │ I've created the     │   │
│  │ auth middleware...    │   │
│  └──────────────────────┘   │
│                             │
│  ┌─── ⚠️ Permission ────┐   │
│  │                      │   │  ← INLINE permission card
│  │  bash: git push      │   │     (appears in chat flow)
│  │  origin main         │   │
│  │                      │   │
│  │  Risk: 🟡 medium     │   │
│  │  "Pushes to remote"  │   │
│  │                      │   │
│  │ ┏━━━━━━┓  ┏━━━━━━━┓  │   │  ← glass buttons
│  │ ┃ Deny ┃  ┃ Allow ┃  │   │
│  │ ┗━━━━━━┛  ┗━━━━━━━┛  │   │
│  └──────────────────────┘   │
│                             │
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │
│  ┃  Message...        ⬆️  ┃  │  ← input bar (rounded rect, not capsule)
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
└─────────────────────────────┘
```

**Message types in the feed:**

| Type | Visual |
|------|--------|
| User message | Right-aligned, tinted bubble |
| Assistant text | Left-aligned, subtle background |
| Tool call | Collapsible row with icon + summary + status |
| Tool output | Hidden by default, expand on tap. Long-press → copy. |
| Thinking | Pulsing "···" indicator |
| Permission request | Highlighted card with action buttons |
| Permission resolved | Compact "✓ Allowed" or "✗ Denied" badge |
| Extension UI dialog | Presents queued modal sheet (forwarded from server) |
| Error | Red-tinted card |

**Unified timeline model (required for streaming + collapse):**

```swift
enum ChatItem: Identifiable, Equatable {
    case userMessage(id: String, text: String, timestamp: Date)
    case assistantMessage(id: String, text: String, timestamp: Date)

    case thinking(
        id: String,
        preview: String,
        hasMore: Bool
    )

    case toolCall(
        id: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        outputByteCount: Int,
        isError: Bool,
        isDone: Bool
    )

    case permission(PermissionRequest)
    case permissionResolved(id: String, action: PermissionAction)
    case sessionEnded(id: String, reason: String)
    case error(id: String, message: String)

    var id: String {
        switch self {
        case .userMessage(let id, _, _): return id
        case .assistantMessage(let id, _, _): return id
        case .thinking(let id, _, _): return id
        case .toolCall(let id, _, _, _, _, _, _): return id
        case .permission(let request): return request.id
        case .permissionResolved(let id, _): return id
        case .sessionEnded(let id, _): return id
        case .error(let id, _): return id
        }
    }
}

@MainActor @Observable
final class ToolOutputStore {
    private(set) var fullOutputByItemID: [String: String] = [:]

    func append(_ chunk: String, to itemID: String) {
        fullOutputByItemID[itemID, default: ""] += chunk
    }

    func fullOutput(for itemID: String) -> String {
        fullOutputByItemID[itemID, default: ""]
    }
}
```

Reducer state machine (must be explicit before coding):

```swift
@MainActor @Observable
final class TimelineReducer {
    private(set) var items: [ChatItem] = []

    // Turn-local buffers (reset on agentStart / finalized on agentEnd)
    private var currentAssistantID: String?
    private var assistantBuffer: String = ""

    private var currentThinkingID: String?
    private var thinkingBuffer: String = ""

    // Tool correlation (v1 assumes sequential tool execution)
    private var currentToolEventID: String?

    // Expansion state is separate UI state, not part of ChatItem payload
    var expandedItemIDs: Set<String> = []

    func loadFromREST(_ messages: [SessionMessage]) { ... }
    func process(_ event: AgentEvent) { ... }
}
```

Transition rules:
- `agentStart`:
  - mark session busy
  - clear stale turn buffers
  - create new assistant turn context
- `thinkingDelta`:
  - append to `thinkingBuffer`
  - materialize/refresh a `ChatItem.thinking` preview item
- first `textDelta` after thinking:
  - keep thinking item collapsed
  - start/continue assistant text accumulation
- `toolStart`:
  - generate client `toolEventId` (UUID)
  - append `toolCall` item with empty preview
  - set `currentToolEventID`
- `toolOutput`:
  - append full chunk to `ToolOutputStore`
  - update only preview fields in `ChatItem.toolCall`
- `toolEnd`:
  - set `isDone = true`
  - clear `currentToolEventID`
- `agentEnd`:
  - flush assistant buffer into final `assistantMessage`
  - close orphaned tool item if needed (`isDone = false`)
  - mark session ready
- `error` / `sessionEnded`:
  - flush buffers, append terminal item, end turn

Tool correlation assumption (v1): server tool events are sequential (no
interleaving). If parallel tools ship later, server must include tool IDs.

Performance rules for this timeline (terminal-like smoothness):
- Coalesce text/thinking deltas and flush to UI every 33-50ms (not every token)
- Deliver tool output, permissions, errors, and lifecycle events immediately
- Keep `ChatItem` lightweight (preview + metadata only)
- Store large/full tool output outside `ChatItem` (`ToolOutputStore`)
- Default collapsed for thinking/tool output; expand only when tapped
- Keep expansion state in `Set<String>` to avoid rewriting large timeline items
- Disable implicit row animations for delta updates (`withAnimation(nil)` / transaction)
- Use `ScrollView` + `LazyVStack` with stable IDs; avoid invalidating whole list
- Auto-scroll only when user is near bottom; otherwise show "jump to latest"
- Trim old in-memory output for inactive sessions (bounded memory)

Auto-scroll implementation (required to avoid streaming jank):
- Place an invisible bottom sentinel row with stable id (`"bottom-sentinel"`)
- Track near-bottom using sentinel visibility
- On delta flush/new item:
  - if near-bottom: `proxy.scrollTo("bottom-sentinel", anchor: .bottom)` with `withAnimation(nil)`
  - if not near-bottom: do not move scroll; show "Jump to latest"
- Use animated scroll only for user-triggered jump button

```swift
.onChange(of: reducer.items.last?.id) { _, _ in
    guard isNearBottom else { return }
    withAnimation(nil) {
        proxy.scrollTo("bottom-sentinel", anchor: .bottom)
    }
}
```

Terminal-smooth rendering budget (targets):
- Maintain 60fps while streaming (main-thread frame budget ~16.7ms)
- Keep per-flush reducer + diff work under ~4ms on iPhone-class hardware
- Keep rendered row count bounded via `LazyVStack` and collapsed sections
- Keep per-item preview strings short (e.g., <= 500 chars in timeline cells)
- Avoid expensive markdown/text layout in hot path; plain monospaced `Text`
  for streaming content

**Tool call collapse behavior:**
- Default: collapsed to one line (`▶ bash: npm install jsonwebtoken ✓`)
- Tap to expand: shows full command + output
- Long output: truncated with "Show more" link
- Error output: auto-expanded, red tinted
- **Context menu** on all tool output: Copy Output, Copy Command
- Special-case pseudo tools from server:
  - `__compaction` → neutral system row ("Context compacted")
  - `__retry` or `error` message starting with `Retrying (` → info/notice row,
    not red failure card

**Input bar behavior when agent is busy:**
- Replace send affordance with a **Stop** button (`square.fill`, red tint)
- Stop action sends WebSocket `{ "type": "stop" }` (alias of `abort`)
- After tap, enter `stopping` UI state (button disabled + spinner)
- Exit `stopping` when `agent_end` or `session_ended` arrives
- If still busy after ~5s, show secondary action: "Force Stop Session"
  (REST `POST /workspaces/:workspaceId/sessions/:id/stop`)
- Placeholder while busy: "Agent is working..."
- v2: show mode picker ("Send as: Steer / Follow-up") in addition to Stop
- Busy-state race is still possible (tap send before `agent_start` arrives).
  If server rejects/returns an error, show an inline error row in chat
  (do not fail silently).

**Permission arrives while typing:**
- When input bar has focus AND a permission arrives, show a **floating pill
  banner at the top** of the chat (not inline at the bottom behind the keyboard)
- Pill text: "⚠️ 1 pending — tap to review ▼"
- Tapping pill scrolls to the inline permission card
- This avoids the chat scroll shifting under the user's fingers
- Pill dismissal rules:
  - Dismiss when tapped (after scroll)
  - Dismiss when permission resolves elsewhere (server update)
  - Dismiss when permission expires (`permission_expired`)
  - Dismiss when keyboard closes and the inline card is visible again

**Reconnect after background:** When app returns to foreground, fetch
`GET /workspaces/:workspaceId/sessions/:id` to rebuild chat state. Server does NOT replay missed
streaming events.

**Known v1 limitation:** `GET /workspaces/:workspaceId/sessions/:id` currently returns only
user/assistant/system messages, not tool-call stream events. After reconnect,
text history is accurate but tool rows that occurred while disconnected may be
missing. We accept this for v1 and track server-side tool-event persistence for
v2.

**Known v1 limitation:** non-text tool output (image/binary) may be dropped by
current server translation. Tool row can show start/end with no preview text.

**When `session_ended` arrives:**
- Append inline system card: "Session ended: <reason>"
- Update `SessionStore` status to `.stopped`
- Disable chat input bar permanently for that session
- Keep user on the chat screen (no auto-pop)

**Liquid Glass usage:**
- Nav bar: automatic glass
- Permission card action buttons: `.buttonStyle(.glass)` for deny,
  `.buttonStyle(.glassProminent)` for allow
- Tool call rows: NO glass — they're content
- Message bubbles: NO glass — solid backgrounds for readability
- Input bar: `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))`

**Chat input bar — rounded rectangle, NOT capsule:**

Capsule shape balloons into a pillow when TextField expands to multi-line.
Use `RoundedRectangle(cornerRadius: 20)` from the start — it looks good
at all heights.

```swift
struct ChatInputBar: View {
    @Binding var text: String
    let onSend: () -> Void
    let onStop: () -> Void
    let sessionStatus: SessionStatus
    let isStopping: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField(
                sessionStatus == .busy ? "Agent is working..." : "Message...",
                text: $text,
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.plain)

            if sessionStatus == .busy {
                Button(action: onStop) {
                    if isStopping {
                        ProgressView()
                    } else {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(isStopping)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
```

**Streaming lifecycle (`AsyncStream` + view cancellation):**

```swift
struct ChatView: View {
    let session: Session
    @Environment(ServerConnection.self) private var serverConnection

    var body: some View {
        ScrollView { ... }
            .task(id: session.id) {
                let stream = serverConnection.connect(sessionId: session.id)
                for await message in stream {
                    handleServerMessage(message)
                }
            }
    }
}
```

`.task(id:)` auto-cancels when `ChatView` disappears or session changes.
`connect()` must clean up in `onTermination` so `receive()` and ping tasks
stop immediately.

---

### 4. Permission Card (The Money Feature) 💰

This is the core UX. Three contexts where permission requests appear:

#### A. Inline in Chat

When you're actively watching a session, permissions appear in the chat flow
as highlighted cards (see chat view above).

#### B. Push Notification → Sheet

When you're not in the app, a push notification brings you to a **permission
sheet**:

```
┌─────────────────────────────┐
│                             │
│     (dimmed app content)    │
│                             │
│  ┌───────────────────────┐  │  ← sheet with glass inset
│  │                       │  │
│  │  ⚠️  Permission       │  │
│  │  Request              │  │
│  │                       │  │
│  │  Session: auth flow   │  │
│  │  Agent: claude-sonnet │  │
│  │                       │  │
│  │  ┌─────────────────┐  │  │
│  │  │  $ git push      │  │  │  ← monospace command display
│  │  │    origin main   │  │  │     dark bg, high contrast
│  │  └─────────────────┘  │  │
│  │                       │  │
│  │  Risk: 🟡 MEDIUM     │  │
│  │                       │  │
│  │  "Pushes code to     │  │
│  │   remote repository" │  │
│  │                       │  │
│  │  ⏱ Expires in 1:48   │  │  ← countdown timer
│  │                       │  │
│  │  ┏━━━━━━━━━━━━━━━━━┓  │  │
│  │  ┃     Allow       ┃  │  │  ← .glassProminent, risk-colored
│  │  ┗━━━━━━━━━━━━━━━━━┛  │  │
│  │                       │  │
│  │  ┏━━━━━━━━━━━━━━━━━┓  │  │
│  │  ┃      Deny       ┃  │  │  ← .glass, .tint(.red)
│  │  ┗━━━━━━━━━━━━━━━━━┛  │  │
│  │                       │  │
│  └───────────────────────┘  │
│                             │
└─────────────────────────────┘
```

#### C. Floating Permission Pill (while typing)

When input bar has focus, permissions show as a floating pill at the top
of the chat instead of scrolling the chat view under the user's fingers.

#### Permission Card Anatomy

```swift
struct PermissionCardView: View {
    let request: PermissionRequest
    let onRespond: (PermissionAction) -> Void

    @State private var isExpired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                RiskBadge(risk: request.risk)
                Text("Permission Request")
                    .font(.headline)
                Spacer()
                Text(request.sessionId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Command display — monospace, dark bg, NOT glass
            CommandView(summary: request.displaySummary, tool: request.tool)

            // Reason
            Text(request.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Timer (visual feedback only)
            // Server event `permission_expired` is the authority.
            Text(request.timeoutAt, style: .timer)
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Action buttons
            if isExpired {
                // Expired: gray out, disable buttons
                Label("Expired", systemImage: "clock.badge.xmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                PermissionActions(
                    request: request,
                    onRespond: { action in
                        // Haptic feedback
                        let generator = UIImpactFeedbackGenerator(
                            style: action == .allow ? .light : .heavy
                        )
                        generator.impactOccurred()
                        onRespond(action)
                    }
                )
            }
        }
        .padding(20)
        .opacity(isExpired ? 0.5 : 1.0)
    }

    // Server is the authority on expiration — don't rely on local timer.
    // Timer is visual only and may reach 0:00 before/after the server event.
    // When permission_expired arrives via WebSocket, set isExpired = true.
}
```

#### Risk Tiers — Color Palette

| Risk | Color | Icon | Examples |
|------|-------|------|----------|
| `low` | System green | `checkmark.shield` | Read file, list directory |
| `medium` | System yellow | `exclamationmark.triangle` | git push, npm install |
| `high` | System orange | `flame` | rm -rf, chmod, network calls |
| `critical` | System red | `xmark.octagon` | sudo, /etc writes, env secrets |

```swift
extension Color {
    static func forRisk(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}
```

**Allow button** tint shifts with risk:
- Low: green (safe, go ahead)
- Medium: blue (neutral, your call)
- High: orange (caution, think first)
- Critical: **white button with red border** — NOT red-tinted. Two red buttons
  (allow + deny) is confusing. Deny stays red. Allow for critical uses
  a stark white/high-contrast treatment with `.bordered` style and red
  `.overlay` border to signal danger without being mistaken for the deny button.

#### Command Display

The command summary is the most important element. It must be:
- **Monospace font** — looks like a terminal
- **Dark background** — high contrast, always readable
- **No glass effect** — this is content, not chrome
- **Trust server's `displaySummary`** — the server generates a human-readable
  summary. Don't re-parse `input` on the phone.

```swift
struct CommandView: View {
    let summary: String
    let tool: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconForTool(tool))
                    .font(.caption)
                Text(tool)
                    .font(.caption.bold())
            }
            .foregroundStyle(.secondary)

            Text(summary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemBackground))
                )
        }
    }
}
```

#### Permission Action Buttons (Morphing)

When a permission is resolved, the two buttons morph into a single
confirmation badge:

```swift
struct PermissionActions: View {
    let request: PermissionRequest
    let onRespond: (PermissionAction) -> Void

    @State private var resolved: PermissionAction?
    @Namespace private var morphNamespace

    var body: some View {
        HStack(spacing: 12) {
            if let resolved {
                Label(
                    resolved == .allow ? "Allowed" : "Denied",
                    systemImage: resolved == .allow ? "checkmark" : "xmark"
                )
                .font(.subheadline.bold())
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(
                    .regular.tint(resolved == .allow ? .green : .red),
                    in: .capsule
                )
                .matchedGeometryEffect(
                    id: resolved == .allow ? "allow-action" : "deny-action",
                    in: morphNamespace
                )
            } else {
                Button("Deny") { respond(.deny) }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .controlSize(.large)
                    .matchedGeometryEffect(id: "deny-action", in: morphNamespace)

                if request.risk == .critical {
                    Button("Allow") { respond(.allow) }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .controlSize(.large)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red, lineWidth: 2)
                        )
                        .matchedGeometryEffect(id: "allow-action", in: morphNamespace)
                } else {
                    Button("Allow") { respond(.allow) }
                        .buttonStyle(.glassProminent)
                        .tint(allowColor)
                        .controlSize(.large)
                        .matchedGeometryEffect(id: "allow-action", in: morphNamespace)
                }
            }
        }
        .animation(.bouncy(duration: 0.4), value: resolved)
    }

    private func respond(_ action: PermissionAction) {
        resolved = action
        onRespond(action)
    }

    private var allowColor: Color {
        switch request.risk {
        case .low: return .green
        case .medium: return .blue
        case .high: return .orange
        case .critical, .unknown: return .primary
        }
    }
}
```

> **API safety:** v1 implementation defaults to `HStack` + per-button
> `.glassEffect()` and `matchedGeometryEffect` (known APIs). If
> `GlassEffectContainer` is confirmed in the shipping iOS 26 SDK, we can swap
> it in later for tighter glass morph transitions.

#### Multiple Pending Permissions

When 2+ permissions are pending, show a **queue** with batch actions:

```
┌─────────────────────────────┐
│  3 Pending Permissions      │
│                             │
│  ┌──────────────────────┐   │
│  │ 🔴 bash: sudo apt    │   │  ← highest risk first
│  │    install nginx      │   │
│  │  [Allow]    [Deny]    │   │
│  └──────────────────────┘   │
│                             │
│  ┌──────────────────────┐   │
│  │ 🟡 bash: git push    │   │  ← collapsed, timer prominent
│  │  ⏱ 1:32  ⚡ expiring  │   │     flash when < 30s remaining
│  └──────────────────────┘   │
│                             │
│  ┌──────────────────────┐   │
│  │ 🟢 read: 5 files in  │   │  ← batched same-tool low-risk
│  │    /workspace/src/    │   │
│  │  [Allow All]          │   │
│  └──────────────────────┘   │
│                             │
│  [Deny All]                 │
│                             │
└─────────────────────────────┘
```

**Queue rules:**
- Sorted by risk (critical first), then by arrival time
- Only the top card is fully expanded with action buttons
- Others show compact one-line summary + timer
- "Deny All" at the bottom for quick batch rejection
- Each resolved card animates out, next card expands
- **Batch approval:** When 2+ requests share the same tool AND risk level,
  group them: "read: 5 files in /workspace/src/ — [Allow All]"
- **Expiry flash:** Collapsed items flash/pulse when < 30s remaining
- Items expire immediately when `permission_expired` arrives from server
  (don't trust local timer accuracy)

---

### 5. Extension UI Dialogs

The server forwards `extension_ui_request` messages for extension-generated
dialogs (select, confirm, input). These are a separate interaction model
from permissions.

| Method | iOS UI |
|--------|--------|
| `showSelect` | Modal sheet with option list |
| `showConfirm` | Modal sheet with confirm/cancel |
| `showInput` | Modal sheet with text field |
| `showNotification` | Toast/banner (no response needed) |
| `setStatus` | Status strip update (no response needed) |

v1 behavior: extension dialogs are **modal sheets**, one at a time. If multiple
requests arrive, queue them and present sequentially. Do not inline these in
chat bubbles for v1.

```swift
@State private var activeExtensionDialog: ExtensionUIRequest?

.sheet(item: $activeExtensionDialog) { request in
    ExtensionDialogView(request: request) { response in
        Task { try? await serverConnection.send(.extensionUIResponse(response)) }
        activeExtensionDialog = nil
    }
}
```

Non-interactive extension notifications (`showNotification`, `setStatus`) are
rendered as transient UI updates and never block chat interaction.

---

### 6. Live Tab (v1)

A reverse-chronological **live** feed of events the phone has witnessed across
sessions while connected. In v1 this is not a durable audit history.

v2: when server audit endpoints ship, this can become a true history view.

```
┌─────────────────────────────┐
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │
│  ┃  Live                  ┃  │
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
│                             │
│  Today                      │
│                             │
│  3:42 PM • auth flow        │
│  ✓ bash: npm test           │
│    All 47 tests passing     │
│                             │
│  3:41 PM • auth flow        │
│  ✓ Allowed: git push main   │  ← permission resolution
│    Approved by you          │
│                             │
│  3:38 PM • auth flow        │
│  ▶ edit: src/auth.ts        │
│    +45 -2 lines             │
│                             │
│  3:35 PM • debug: mem leak  │
│  ✗ Denied: rm -rf /tmp/     │  ← denied, red accent
│    Auto-denied (timeout)    │
│                             │
│  3:30 PM • auth flow        │
│  ◉ Session started          │
│    Model: claude-sonnet     │
│                             │
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │
│  ┃ Sessions   Live    ⚙️  ┃  │
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
└─────────────────────────────┘
```

**Live event types:**
- Tool execution (tool name + summary + status)
- Permission approved/denied (who approved, scope)
- Session started/stopped
- Errors

Each row is tappable → navigates to the session at that point in history.

No glass on content rows. Solid backgrounds, clear typography, timestamp +
session name for context.

---

### 7. Settings

```
┌─────────────────────────────┐
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │
│  ┃  Settings              ┃  │
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
│                             │
│  SERVER                     │
│  ┌──────────────────────┐   │
│  │ Host  myhost...  │   │
│  │ Port  7749           │   │
│  │ Status  🟢 Connected │   │
│  │ Latency  12ms        │   │
│  └──────────────────────┘   │
│                             │
│  NOTIFICATIONS              │
│  ┌──────────────────────┐   │
│  │ Push Notifications 🔘│   │
│  │ Permission Alerts  🔘│   │
│  │ Session Updates    🔘│   │
│  └──────────────────────┘   │
│                             │
│  ACCOUNT                    │
│  ┌──────────────────────┐   │
│  │ Name    Chen         │   │
│  │ Policy  Admin        │   │
│  │ Disconnect Server  › │   │
│  └──────────────────────┘   │
│                             │
│  Pi Remote v1.0             │
│                             │
│  ┏━━━━━━━━━━━━━━━━━━━━━━━┓  │
│  ┃ Sessions   Live    ⚙️  ┃  │
│  ┗━━━━━━━━━━━━━━━━━━━━━━━┛  │
└─────────────────────────────┘
```

Standard iOS settings pattern. `Form` with sections. No custom glass here —
let the system handle it. The glass nav bar and tab bar are automatic.

---

## Data Models (Swift)

### JSONValue — Recursive Codable JSON

`AnyCodable` doesn't exist in the Swift standard library. Use a custom
recursive enum:

```swift
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
```

### Session & Messages

```swift
struct Session: Identifiable, Decodable {
    let id: String
    let userId: String
    var name: String?
    var status: SessionStatus
    let createdAt: Date
    var lastActivity: Date
    var model: String?
    var messageCount: Int
    var tokens: TokenUsage
    var cost: Double
    var lastMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case userId
        case name
        case status
        case createdAt
        case lastActivity
        case model
        case messageCount
        case tokens
        case cost
        case lastMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decode(SessionStatus.self, forKey: .status)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        tokens = try container.decode(TokenUsage.self, forKey: .tokens)
        cost = try container.decode(Double.self, forKey: .cost)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)

        let createdAtMs = try container.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdAtMs / 1000.0)

        let lastActivityMs = try container.decode(Double.self, forKey: .lastActivity)
        lastActivity = Date(timeIntervalSince1970: lastActivityMs / 1000.0)
    }
}

enum SessionStatus: String, Codable {
    case starting, ready, busy, stopped, error
}

struct TokenUsage: Codable {
    var input: Int
    var output: Int
}

struct SessionMessage: Identifiable, Decodable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let content: String
    let timestamp: Date
    var model: String?
    var tokens: TokenUsage?
    var cost: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case role
        case content
        case timestamp
        case model
        case tokens
        case cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        tokens = try container.decodeIfPresent(TokenUsage.self, forKey: .tokens)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)

        let timestampMs = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: timestampMs / 1000.0)
    }
}

enum MessageRole: String, Codable {
    case user, assistant, system
}
```

### Permissions

```swift
struct PermissionRequest: Identifiable {
    let id: String
    let sessionId: String
    let tool: String
    let input: [String: JSONValue]
    let displaySummary: String
    let risk: RiskLevel
    let reason: String
    let timeoutAt: Date

    var isExpired: Bool { Date() > timeoutAt }
    var timeRemaining: TimeInterval { timeoutAt.timeIntervalSinceNow }
}

enum RiskLevel: String, Codable, Comparable {
    case low, medium, high, critical, unknown

    // Graceful fallback for unknown risk levels from server
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = RiskLevel(rawValue: value) ?? .unknown
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high, .critical, .unknown]
        return (order.firstIndex(of: lhs) ?? 4) < (order.firstIndex(of: rhs) ?? 4)
    }
}

enum PermissionAction: String, Codable {
    case allow, deny
    // Future: allowSession, allowWorkspace, allowAlways
}
```

### Extension UI

```swift
struct ExtensionUIRequest: Identifiable {
    let id: String
    let sessionId: String
    let method: String          // showSelect, showConfirm, showInput
    var title: String?
    var options: [String]?      // for showSelect
    var message: String?        // for showConfirm
    var placeholder: String?    // for showInput
    var prefill: String?        // for showInput
    var timeout: TimeInterval?
}

struct ExtensionUIResponse: Codable {
    let id: String
    var value: String?          // selected option or input text
    var confirmed: Bool?        // for showConfirm
    var cancelled: Bool?        // user dismissed
}
```

### ServerMessage — Manual Decodable

Swift enums with associated values don't auto-synthesize Codable. The server
sends flat JSON with a `type` discriminator and snake_case keys. Manual
decoding is required (~80-100 lines).

```swift
enum ServerMessage {
    // Session lifecycle
    case connected(Session)
    case state(Session)
    case agentStart
    case agentEnd
    case sessionEnded(reason: String)

    // Streaming
    case textDelta(String)
    case thinkingDelta(String)

    // Tool execution
    case toolStart(tool: String, args: [String: JSONValue])
    case toolOutput(output: String, isError: Bool)
    case toolEnd(tool: String)

    // Permissions
    case permissionRequest(PermissionRequest)
    case permissionExpired(id: String, reason: String)
    case permissionCancelled(id: String)

    // Extension UI
    case extensionUIRequest(ExtensionUIRequest)
    case extensionUINotification(
        method: String,
        message: String?,
        notifyType: String?,
        statusKey: String?,
        statusText: String?
    )

    // Errors
    case error(String)

    // Forward compatibility
    case unknown(type: String)
}

extension ServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, session, delta, tool, args, output, isError, error, reason, id
        case sessionId, input, displaySummary, risk, timeoutAt
        case method, title, options, message, placeholder, prefill, timeout
        case notifyType, statusKey, statusText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "connected":
            let session = try container.decode(Session.self, forKey: .session)
            self = .connected(session)
        case "state":
            let session = try container.decode(Session.self, forKey: .session)
            self = .state(session)
        case "agent_start":
            self = .agentStart
        case "agent_end":
            self = .agentEnd
        case "text_delta":
            let delta = try container.decode(String.self, forKey: .delta)
            self = .textDelta(delta)
        case "thinking_delta":
            let delta = try container.decode(String.self, forKey: .delta)
            self = .thinkingDelta(delta)
        case "tool_start":
            let tool = try container.decode(String.self, forKey: .tool)
            let args = try container.decode([String: JSONValue].self, forKey: .args)
            self = .toolStart(tool: tool, args: args)
        case "tool_output":
            let output = try container.decode(String.self, forKey: .output)
            let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self = .toolOutput(output: output, isError: isError)
        case "tool_end":
            let tool = try container.decode(String.self, forKey: .tool)
            self = .toolEnd(tool: tool)
        case "error":
            let error = try container.decode(String.self, forKey: .error)
            self = .error(error)
        case "session_ended":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .sessionEnded(reason: reason)
        case "permission_request":
            let req = PermissionRequest(
                id: try container.decode(String.self, forKey: .id),
                sessionId: try container.decode(String.self, forKey: .sessionId),
                tool: try container.decode(String.self, forKey: .tool),
                input: try container.decode([String: JSONValue].self, forKey: .input),
                displaySummary: try container.decode(String.self, forKey: .displaySummary),
                risk: try container.decode(RiskLevel.self, forKey: .risk),
                reason: try container.decode(String.self, forKey: .reason),
                timeoutAt: Date(timeIntervalSince1970:
                    try container.decode(Double.self, forKey: .timeoutAt) / 1000.0)
            )
            self = .permissionRequest(req)
        case "permission_expired":
            let id = try container.decode(String.self, forKey: .id)
            let reason = try container.decode(String.self, forKey: .reason)
            self = .permissionExpired(id: id, reason: reason)
        case "permission_cancelled":
            let id = try container.decode(String.self, forKey: .id)
            self = .permissionCancelled(id: id)
        case "extension_ui_request":
            let req = ExtensionUIRequest(
                id: try container.decode(String.self, forKey: .id),
                sessionId: try container.decode(String.self, forKey: .sessionId),
                method: try container.decode(String.self, forKey: .method),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                options: try container.decodeIfPresent([String].self, forKey: .options),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder),
                prefill: try container.decodeIfPresent(String.self, forKey: .prefill),
                timeout: try container.decodeIfPresent(Double.self, forKey: .timeout)
            )
            self = .extensionUIRequest(req)
        case "extension_ui_notification":
            let method = try container.decode(String.self, forKey: .method)
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            let notifyType = try container.decodeIfPresent(String.self, forKey: .notifyType)
            let statusKey = try container.decodeIfPresent(String.self, forKey: .statusKey)
            let statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
            self = .extensionUINotification(
                method: method,
                message: message,
                notifyType: notifyType,
                statusKey: statusKey,
                statusText: statusText
            )
        default:
            self = .unknown(type: type)
        }
    }
}
```

Receive-loop rule: `.unknown(type:)` messages are logged and skipped. They do
not terminate the stream.

### ClientMessage — Manual Encodable

Maps to server's snake_case `ClientMessage` types:

```swift
enum ClientMessage {
    case prompt(message: String, images: [ImageAttachment]?)
    case stop
    case abort // legacy alias
    case getState
    case permissionResponse(id: String, action: PermissionAction)
    case extensionUIResponse(ExtensionUIResponse)
    // v2: case steer(message: String)
    // v2: case followUp(message: String)
}

extension ClientMessage: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        switch self {
        case .prompt(let message, let images):
            try container.encode("prompt", forKey: "type")
            try container.encode(message, forKey: "message")
            try container.encodeIfPresent(images, forKey: "images")
        case .stop:
            try container.encode("stop", forKey: "type")
        case .abort:
            try container.encode("abort", forKey: "type")
        case .getState:
            try container.encode("get_state", forKey: "type")
        case .permissionResponse(let id, let action):
            try container.encode("permission_response", forKey: "type")
            try container.encode(id, forKey: "id")
            try container.encode(action.rawValue, forKey: "action")
        case .extensionUIResponse(let response):
            try container.encode("extension_ui_response", forKey: "type")
            try container.encode(response.id, forKey: "id")
            try container.encodeIfPresent(response.value, forKey: "value")
            try container.encodeIfPresent(response.confirmed, forKey: "confirmed")
            try container.encodeIfPresent(response.cancelled, forKey: "cancelled")
        }
    }
}

struct StringCodingKey: CodingKey {
    var stringValue: String
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

struct ImageAttachment: Codable {
    let data: String  // base64
    let mimeType: String
}
```

### Date Decoding

Server timestamps are Unix milliseconds. Core models decode ms → `Date`
manually (`Session`, `SessionMessage`, and `PermissionRequest.timeoutAt` in the
`ServerMessage` decoder). This avoids hidden dependency on `JSONDecoder`
configuration.

Optional convenience decoder for non-model date fields:

```swift
extension JSONDecoder {
    static var piRemote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let ms = try container.decode(Double.self)
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        return decoder
    }
}
```

### Invite

```swift
struct InviteData: Codable {
    let host: String
    let port: Int
    let token: String
    let name: String
}
```

---

## Push Notifications

### Registration Flow

Request notification permission **after successful server connection** — not
at app launch. iOS shows the system dialog once; if denied, you can't ask
again. Maximize grant rate with a pre-prompt.

```
Onboarding complete
  → Show pre-prompt: "Pi Remote sends notifications when your
    agent needs approval for dangerous actions."
  → User taps "Enable Notifications"
  → Request system notification permission
  → If granted: Register with APNs → send device token to server
  → If denied: Show settings link, continue without push
```

### Notification Types

| Type | Priority | Sound | Category |
|------|----------|-------|----------|
| Permission request (critical) | `.timeSensitive` | alert | `PERMISSION_CRITICAL` |
| Permission request (high) | `.timeSensitive` | default | `PERMISSION_HIGH` |
| Permission request (medium) | `.active` | default | `PERMISSION` |
| Permission request (low) | `.passive` | none | `PERMISSION` |
| Session error | `.active` | default | `SESSION_ERROR` |
| Session completed | `.passive` | none | `SESSION_DONE` |

### Actionable Notifications

```swift
let allowAction = UNNotificationAction(
    identifier: "ALLOW",
    title: "Allow",
    options: [.foreground]  // open app to confirm
)

let denyAction = UNNotificationAction(
    identifier: "DENY",
    title: "Deny",
    options: [.destructive]  // can execute in background
)

let permissionCategory = UNNotificationCategory(
    identifier: "PERMISSION",
    actions: [allowAction, denyAction],
    intentIdentifiers: []
)
```

**Critical/high risk:** Always opens the app for full card view.
**Medium/low risk:** Can deny from notification banner, allow opens app.

### Notification Payload

```json
{
  "aps": {
    "alert": {
      "title": "Permission Request",
      "subtitle": "Session: auth flow",
      "body": "bash: git push origin main"
    },
    "category": "PERMISSION",
    "interruption-level": "time-sensitive",
    "relevance-score": 0.9
  },
  "permissionId": "perm_abc123",
  "sessionId": "sess_xyz",
  "risk": "medium",
  "tool": "bash",
  "summary": "git push origin main",
  "timeoutAt": 1738900000000
}
```

---

## Connection & Reconnection

```swift
@MainActor @Observable
final class ServerConnection {
    private(set) var status: ConnectionStatus = .disconnected
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTimer: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

    // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
    private var reconnectDelay: TimeInterval {
        min(pow(2, Double(reconnectAttempts)), 30)
    }

    func connect(sessionId: String) -> AsyncStream<ServerMessage> {
        // 0. disconnect() existing socket first (v1: one active session stream)
        // 1. Create URLSessionWebSocketTask with bearer auth header
        // 2. Start receive loop (pull-based: must call receive() in loop)
        // 3. Start keepalive ping timer (every 30s)
        // 4. Return AsyncStream
        // 5. onTermination: cancel WebSocket task + ping timer
    }

    func reconnectIfNeeded() async {
        guard status != .connected else { return }
        status = .reconnecting

        // 1. Fetch GET /workspaces + /workspaces/:wid/sessions to refresh list + statuses
        // 2. Reconnect only the currently open session (v1)
        // 3. Send get_state to refresh pending permissions
        // 4. Clear stale permission cards that server no longer has
    }

    private func handleDisconnect() async {
        guard reconnectAttempts < maxReconnectAttempts else {
            status = .disconnected
            return
        }
        status = .reconnecting
        reconnectAttempts += 1
        try? await Task.sleep(for: .seconds(reconnectDelay))
        // Attempt reconnect...
    }
}
```

When decoding incoming frames, unknown server message types map to
`.unknown(type:)` and are skipped with a debug log.

**Connection states shown in UI:**
- 🟢 Connected (green dot in nav bar)
- 🟡 Reconnecting... (yellow, pulsing)
- 🔴 Disconnected (red, tap to retry)

The connection indicator is a small dot in the top nav bar — minimal,
always visible, never in the way.

**Stale state on reconnect:** When WebSocket reconnects after background:
1. Server sends `connected` with current state for the reopened session
2. Server resends any pending `permission_request` messages
3. Client clears local permission cards and replaces with server state
4. Fetch `GET /workspaces/:workspaceId/sessions/:id` for text history (missed tool stream events are
   a known v1 limitation)

---

## Implementation Plan

### Server alignment prerequisites (before iOS build)
- [x] Persist finalized assistant messages on `message_end` so
      `GET /workspaces/:workspaceId/sessions/:id` can rebuild conversation after reconnect.
- [x] Debounce session metadata disk writes (e.g., 1s) instead of syncing on
      every stream event to avoid event-loop stalls and uneven WebSocket pacing.
- [x] Keep `SessionManager` in-memory stats aligned with persisted writes to
      prevent stale `messageCount`/`lastMessage` regressions.

### Phase 1: Foundation (2-3 days)
- [ ] Xcode project setup (iOS 26 target, SwiftUI lifecycle, portrait lock)
- [ ] `JSONValue` recursive Codable type
- [ ] `ServerMessage` manual decoder with tests (build and test FIRST)
- [ ] `ServerMessage.unknown(type:)` fallback + test for unknown payloads
- [ ] `ClientMessage` manual encoder
- [ ] `AgentEvent` domain model (includes `agentStart`/`agentEnd`)
- [ ] Transport router: direct store updates vs pipeline events
- [ ] `ToolEventMapper` (client-generated toolEventId, sequential assumption)
- [ ] `TimelineReducer` state machine skeleton + transition tests
- [ ] `DeltaCoalescer` (33-50ms for text/thinking, bypass non-delta events)
- [ ] `SurfaceCoordinator` + main-actor `SurfaceSink` protocol
- [ ] `InAppTimelineSurface` and `NotificationSurface` skeletons
- [ ] `Session` + `SessionMessage` manual Unix-ms date decode
- [ ] `APIClient` (REST: health, me, list sessions, create session)
- [ ] `WebSocketClient` (connect, receive loop, ping timer, send)
- [ ] `connect(sessionId:)` disconnects old socket first (v1 one-stream policy)
- [ ] Swift harness test against real server before UI work
- [ ] `KeychainService` (store/retrieve auth token)
- [ ] `QRScannerView` (DataScannerViewController + UIViewControllerRepresentable)
- [ ] Onboarding flow (QR scan → store credentials → test connection)
- [ ] `scenePhase` handling (reconnect on foreground)
- [ ] Reconnect-on-launch flow

### Phase 2: Sessions + Chat (2-3 days)
- [ ] Separate observable stores (ConnectionState, SessionStore, PermissionStore)
- [ ] Session list view with live status updates
- [ ] Session creation sheet with model text field
- [ ] `ChatItem` unified mixed timeline model (preview-only payload)
- [ ] `ToolOutputStore` for full output chunks keyed by item id
- [ ] Chat view streaming via `.task(id: session.id)`
- [ ] Thinking + tool sections collapsed by default
- [ ] Expansion state in `Set<String>` (not inside content payload)
- [ ] Tool call collapsible rows with context menu (copy)
- [ ] Disable row animations on delta flush updates
- [ ] Add performance signposts + Instruments pass for scroll/stream jank
- [ ] Chat input bar (rounded rect, Stop action when busy, stopping state)
- [ ] Inline error rows for prompt/busy race failures
- [ ] Handle `session_ended` (inline card + disable input + keep screen open)
- [ ] Offline banner pinned with `.safeAreaInset(edge: .top)`
- [ ] Document/ship reconnect limitation: tool events may be missing post-reconnect

### Phase 3: Permission Cards (1-2 days)
- [ ] Permission card view (inline in chat)
- [ ] Permission sheet (from notification deep link)
- [ ] Permission queue view (multiple pending + batch actions)
- [ ] Batch approval "Allow All Low Risk" for same-tool groups
- [ ] Risk badge and color system
- [ ] Critical risk: white Allow button with red border
- [ ] Command display (monospace, trust server's displaySummary)
- [ ] Countdown UI via `Text(timeoutAt, style: .timer)`
- [ ] Gray out/disable only on server `permission_expired` event
- [ ] Action morph via `matchedGeometryEffect` (safe fallback APIs)
- [ ] Haptic feedback (.light for allow, .heavy for deny)
- [ ] Floating permission pill + explicit dismissal rules

### Phase 4: Push Notifications (1-2 days)
- [ ] Pre-prompt → APNs registration (after connection, not on launch)
- [ ] Server-side: `POST /me/device-token` endpoint
- [ ] Server-side: send push on permission_request
- [ ] Notification categories with Allow/Deny actions
- [ ] Deep link from notification → permission card
- [ ] Background deny handling

### Phase 5: Extension UI + Polish (1-2 days)
- [ ] Extension UI dialog handling as queued modal sheets (select, confirm, input)
- [ ] Extension notification/status forwarding
- [ ] Live feed tab (ephemeral, connected-session events only)
- [ ] Settings view
- [ ] Connection status indicator + reconnection
- [ ] Pull-to-refresh on session list
- [ ] Empty states
- [ ] Error handling and offline state
- [ ] App icon

### Post-v1: Additional iOS Surfaces
- [ ] `LiveActivitySurface` adapter (ActivityKit)
- [ ] Lock Screen / Dynamic Island compact layouts
- [ ] Surface-specific throttling policy for live updates

---

## Server-Side Changes Needed

| Endpoint | Phase | Status |
|----------|-------|--------|
| `GET /health` | 1 | ✅ Exists |
| `GET /me` | 1 | ✅ Exists |
| `GET /workspaces` | 1 | ✅ Exists |
| `GET /workspaces/:wid/sessions` | 1 | ✅ Exists |
| `POST /workspaces/:wid/sessions` | 1 | ✅ Exists |
| `GET /workspaces/:wid/sessions/:id` | 2 | ✅ Exists |
| `DELETE /workspaces/:wid/sessions/:id` | 2 | ✅ Exists |
| `POST /workspaces/:wid/sessions/:id/stop` | 2 | ✅ Exists |
| WebSocket streaming (`/workspaces/:wid/sessions/:id/stream`) | 2 | ✅ Exists |
| Permission protocol | 3 | ✅ Exists |
| `POST /workspaces/:wid/sessions/:id/attachments` | 2 | ❌ NEW — REST image upload |
| `POST /me/device-token` | 4 | ❌ NEW — APNs registration |
| APNs push sender | 4 | ❌ NEW — push on permission_request |
| `POST /me/live-activity-token` | v2 | ❌ NEW — register ActivityKit push token |
| APNs live activity sender | v2 | ❌ NEW — remote updates for Live Activities |
| `GET /activity?since=<ts>` | v2 | ❌ NEW — durable audit/history feed |
| `GET /models` | v2 | ❌ NEW — model list for session creation |
| `POST /me/rotate-token` | v2 | ❌ NEW — token rotation if compromised |

---

## Build Requirements

- Xcode 26.0+
- iOS 26.0+ deployment target
- Swift 6.0+
- No external dependencies for v1
- VisionKit framework (DataScannerViewController for QR)
- Keychain Services (secure token storage)
- ActivityKit framework (v2, Live Activities / Dynamic Island)
- `Info.plist`: `UISupportedInterfaceOrientations` = portrait only

---

## Key Design Decisions

### Why not a web app / PWA?
- No push notification reliability on iOS (PWAs still limited)
- No Keychain access for secure token storage
- Can't use Liquid Glass or native iOS controls
- Background WebSocket handling is unreliable
- The whole point is native UX for 5-second interactions

### Why `@MainActor @Observable` instead of actor?
- `actor` + `ObservableObject` won't compile (protocol requires class)
- Actor-isolated properties can't be directly observed by SwiftUI views
- For a single-connection phone app, main-actor class with background
  `Task` dispatching is simpler and correct

### Why separate observable stores?
- Single `AppState` causes full-app re-renders when any field changes
- Permission timer ticks (every second) would re-render session list
- Separate stores + `@Environment` injection scopes re-renders to the
  views that actually care about each state

### Why iPhone-first, no iPad?
- This is a phone-in-pocket permission tool
- iPad layout adds complexity with no clear benefit for v1
- Portrait lock via Info.plist prevents accidental landscape issues
- iPad support later: NavigationSplitView + size classes

### Why no voice input in v1?
- Text input works fine for quick prompts
- Voice adds Whisper/Speech framework complexity
- Can add in v2 with minimal UI changes (mic button in input bar)

### Why AsyncStream over Combine?
- Swift concurrency is the future, Combine is legacy
- AsyncStream maps naturally to WebSocket message flow
- `onTermination` handler ensures proper WebSocket cleanup
- No framework dependency, just Swift

### Why one active WebSocket session in v1?
- Simplifies lifecycle (connect/disconnect/ping/reconnect)
- Prevents orphaned `receiveTask`/`pingTimer` work when switching sessions
- Matches real usage: users supervise one active task at a time
- Multi-session concurrent streaming can be added in v2

### Why coalesced rendering instead of per-token updates?
- Per-token UI commits create layout/diff thrash and visible stutter
- 33-50ms coalescing preserves "live" feel while staying frame-budget friendly
- Immediate delivery for tool/permission/error events keeps interaction latency low
- Closer to terminal feel: smooth stream, no jumpy full-list recompute

### Why an event pipeline + surface sinks?
- One source of truth for agent events (`AgentEvent`)
- New iOS primitives plug in as sinks without rewriting networking/reducers
- Keeps transport concerns (WebSocket/APNs) separate from UI surfaces
- Lets each surface choose its own throttle/fidelity policy

### Why Live Activity/Dynamic Island is summary-only?
- Dynamic Island has tight space and update budget constraints
- Token-level thinking/tool streaming would waste battery and be unreadable
- Live Activity should show supervision state only (busy/ready, active tool,
  pending permission count, time remaining)

### Why accept missing tool rows after reconnect in v1?
- Server REST history currently stores text messages, not streamed tool events
- Reconnect can always rebuild text timeline and permission state
- Missing tool rows are documented honestly instead of hidden behind fragile
  client-side caching
- Proper fix is server-side tool-event persistence (v2)

### Why no SwiftData/CoreData?
- Session data lives on the server, not the phone
- The phone is a thin client — minimal local state
- Keychain for auth token, UserDefaults for preferences
- If we need offline history later, SwiftData is an easy add

### Why REST for image upload?
- Base64 over WebSocket blocks the frame (4-7MB per photo)
- Blocks permission responses from being sent during upload
- REST upload shows progress, supports cancellation
- Server returns attachment ID, referenced in WebSocket prompt

### Why trust server's displaySummary?
- Server already generates human-readable command summaries
- Duplicating parsing logic on the phone adds maintenance burden
- Phone shows `displaySummary` as-is — one source of truth
- If formatting needs change, only server code changes
