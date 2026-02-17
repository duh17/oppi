# App Intents — Design Document

> **Goal:** Expose oppi's core action — firing a prompt into a workspace — to Siri, Shortcuts automations, Spotlight, and the iPhone Action button.

## Motivation

Oppi is a mobile supervisor for pi CLI sessions. Today, every interaction requires opening the app. App Intents make the agent accessible from:

- **Siri**: "Hey Siri, ask Oppi to run the test suite"
- **Action button**: Long-press → open a new session + composer (iPhone 16 Pro)
- **Shortcuts automations**: Time-of-day, NFC tap, Focus mode, location, Wi-Fi connect, etc.
- **Spotlight**: Type "Ask Oppi" from home screen search

The user builds the intents (verbs); Apple provides triggers and orchestration via the Shortcuts app. No custom scheduler needed.

---

## Intents

### 1. `AskPiIntent` — Primary

Fire-and-forget: sends a prompt to a workspace and returns immediately. The agent runs server-side; push notifications handle permission approvals.

**Parameters:**

| Parameter | Swift Type | Required | Default | Notes |
|-----------|-----------|----------|---------|-------|
| `prompt` | `String` | ✅ | — | The message to send |
| `workspace` | `ServerWorkspaceEntity` | ✅ | — | Composite entity: "ServerName → WorkspaceName" |
| `model` | `String?` | Optional | Workspace's `defaultModel` | Free text, e.g. "sonnet", "opus" |
| `thinking` | `ThinkingLevelAppEnum?` | Optional | `medium` | off / low / medium / high |

**Parameter Summary (Shortcuts editor):**
```
Ask \(\.$workspace) \(\.$prompt)
```
With optional `When` clauses revealing model/thinking when non-default.

**App Shortcut phrases:**
```swift
"Ask \(.applicationName) \(\.$prompt)"
"Tell \(.applicationName) \(\.$prompt)"
"\(.applicationName) \(\.$prompt)"
```

### 2. `OpenNewSessionIntent` — Action Button Target

Opens the app to a new session in a chosen workspace with the composer focused. No prompt parameter — the user types after the app opens.

**Parameters:**

| Parameter | Swift Type | Required | Default |
|-----------|-----------|----------|---------|
| `workspace` | `ServerWorkspaceEntity?` | Optional | Last-used workspace |

**Behavior:**
- `openAppWhenRun = true`
- Creates a new session via REST API
- Sets `sessionStore.activeSessionId`
- Navigates to the chat view with the composer keyboard up

**App Shortcut phrases:**
```swift
"New session in \(.applicationName)"
"Open \(.applicationName)"
```

This is the one users assign to the Action button — quick physical access to start a conversation.

---

## Entities

### `ServerWorkspaceEntity` — Composite Entity

Avoids `IntentParameterDependency` bugs (workspace depending on server selection fails at runtime — documented SO issue). Instead, encodes both server + workspace into a single entity.

```swift
struct ServerWorkspaceEntity: AppEntity {
    /// Stable ID encoding: "serverFingerprint:workspaceId"
    var id: String

    /// Display: "Mac Studio → oppi-dev"
    var serverName: String
    var workspaceName: String
    var workspaceIcon: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Workspace"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(workspaceName)",
            subtitle: "\(serverName)"
        )
    }

    static var defaultQuery = ServerWorkspaceEntityQuery()
}
```

**ID format:** `"sha256:abc123...:ws_xyz789"` — split on first `:` after the fingerprint prefix to recover `serverId` and `workspaceId`.

Wait — fingerprints contain colons (`sha256:...`). Better format:

**ID format:** `"<serverFingerprint>|<workspaceId>"` — split on `|` delimiter.

### `ServerWorkspaceEntityQuery`

Fetches workspaces from ALL paired servers in parallel (reuses the pattern from `WorkspaceStore.loadAll`).

```swift
struct ServerWorkspaceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ServerWorkspaceEntity] {
        // Parse IDs, look up from ServerStore + APIClient
    }

    func suggestedEntities() async throws -> [ServerWorkspaceEntity] {
        // Load all paired servers from ServerStore
        // For each reachable server, fetch workspaces via APIClient
        // Return combined list sorted by server name → workspace name
    }

    func entities(matching string: String) async throws -> [ServerWorkspaceEntity] {
        // Filter suggestedEntities by workspace name match
    }
}
```

**Data access pattern:** The entity query runs out-of-process (in the Shortcuts/Siri process). It cannot use `@Environment` or the app's `@Observable` stores. It must:

1. Read `PairedServer` list from `KeychainService.loadServers()` directly
2. Create ephemeral `APIClient` instances per server
3. Fetch workspaces via `GET /workspaces`

This is the same pattern used by `WorkspaceStore.loadAll` — create a throwaway `APIClient(baseURL:token:)` per server, fan out requests, merge results.

### `ThinkingLevelAppEnum`

Static enum — no network needed.

```swift
enum ThinkingLevelAppEnum: String, AppEnum {
    case off, low, medium, high

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Thinking Level" }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .off: "Off",
            .low: "Low",
            .medium: "Medium",
            .high: "High",
        ]
    }
}
```

Maps directly to existing `ThinkingLevel` enum (which also has `minimal` and `xhigh` — we expose only the 4 user-facing levels in the Shortcuts UI).

---

## Execution Flow — `AskPiIntent.perform()`

```
1. Parse workspace entity ID → (serverId, workspaceId)
2. Load PairedServer from KeychainService
3. Create APIClient from server credentials
4. POST /workspaces/{workspaceId}/sessions → Session
   (pass model if specified, otherwise workspace defaultModel)
5. Open lightweight WebSocket to session
6. Wait for .connected message (with timeout)
7. If thinking != .medium → send .setThinkingLevel
8. Send .prompt(message: prompt)
9. Disconnect WebSocket
10. Return .result(dialog: "Pi is working on it in {workspaceName}")
```

**Error cases:**
- Server unreachable → return error dialog "Can't reach {serverName}"
- Session creation fails → return error dialog with message
- WebSocket connect timeout (5s) → return error "Connection timed out"

**Timeout budget:** Intent should complete within ~10 seconds. Session creation is ~1-2s, WS connect ~1s, send is instant. Comfortable margin.

**Background execution:** Shortcuts automations run intents in the background. The `perform()` method does network I/O (REST + brief WS), which is allowed. No need for `openAppWhenRun` on `AskPiIntent`.

---

## Execution Flow — `OpenNewSessionIntent.perform()`

```
1. Resolve workspace:
   - If workspace parameter set → parse entity ID → (serverId, workspaceId)
   - If nil → use last-used workspace from RestorationState
   - If still nil → use first workspace from first server
2. Validate server reachable (quick health check or skip — app will handle)
3. Set navigation state:
   - Store target (serverId, workspaceId) in a shared UserDefaults key
     that the app reads on launch/foreground
4. Return .result() — app opens via openAppWhenRun = true
```

The app's `OppiApp.swift` reads the "intent launch target" from UserDefaults on `scenePhase == .active`, creates the session, and navigates to chat. This avoids the intent needing to do complex app-internal navigation from the Shortcuts process.

**Alternative considered:** Creating the session in the intent's `perform()` and passing the session ID to the app. Rejected because the intent runs in a different process — it can't drive `ServerConnection`/`SessionStore`/`TimelineReducer` state. Better to let the app own the full lifecycle.

---

## File Structure

```
ios/Oppi/Features/Intents/
├── AskPiIntent.swift              # Primary intent
├── OpenNewSessionIntent.swift     # Action button / quick launch
├── ServerWorkspaceEntity.swift    # Composite entity + query
├── ThinkingLevelAppEnum.swift     # Static thinking level enum
├── OppiShortcuts.swift            # AppShortcutsProvider
└── IntentAPIClient.swift          # Lightweight API helper for out-of-process use
```

### `IntentAPIClient`

The entity query and `AskPiIntent` both need to make REST calls from outside the main app process. They can't use the app's `APIClient` (which is an `actor` that may be holding state).

`IntentAPIClient` is a minimal, stateless struct:

```swift
/// Minimal REST client for App Intents (runs in Shortcuts/Siri process).
/// No state, no caching — just authenticated HTTP calls.
struct IntentAPIClient: Sendable {
    let baseURL: URL
    let token: String

    func listWorkspaces() async throws -> [Workspace]
    func createSession(workspaceId: String, model: String?) async throws -> Session

    /// WebSocket URL for a session.
    func webSocketURL(sessionId: String, workspaceId: String) -> URL?
}
```

**Why not reuse `APIClient`?** It's an `actor` with `URLSession` lifecycle tied to the app process. The intent process needs a clean, self-contained client. The duplication is minimal (~30 lines of REST helpers) and avoids any process-boundary issues.

### Shared Code

The intent needs access to:
- `PairedServer` model (for `KeychainService.loadServers()`)
- `Workspace` model (for decoding API responses)
- `Session` model (for decoding session creation response)
- `ServerCredentials` model (for URL/auth construction)
- `KeychainService` (for reading paired servers)
- `ThinkingLevel` enum (for mapping)
- `ClientMessage` (for WebSocket prompt send)
- `ServerMessage` (for WebSocket `.connected` detection)

These are all in `Core/Models/` and `Core/Services/` — currently compiled only into the main `Oppi` target. Options:

**Option A: Add source files to the Oppi target only.**
App Intents defined in the main app target work for Siri, Shortcuts, Spotlight, and Action button. They run in-process when the app is foregrounded, and iOS launches the app in the background for background intent execution.

This is the simplest approach and how Apple's sample code works. No framework target needed.

**Option B: Shared framework target.**
A `OppiCore` framework that both the main app and a hypothetical widget extension can link. More complexity, only needed if we add WidgetKit later.

**Decision: Option A.** All intent code lives in the main `Oppi` target. If we add widgets later, we refactor into a shared framework at that point.

---

## `project.yml` Changes

Minimal:
- Add `Oppi/Features/Intents/` source directory (auto-discovered by XcodeGen glob)
- No new targets, frameworks, or entitlements needed
- No Info.plist changes (App Intents discovered via compiler metadata extraction, not plist)

---

## AppShortcutsProvider

```swift
struct OppiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Primary: fire a prompt
        AppShortcut(
            intent: AskPiIntent(),
            phrases: [
                "Ask \(.applicationName) \(\.$prompt)",
                "Tell \(.applicationName) \(\.$prompt)",
                "\(.applicationName) \(\.$prompt)",
            ],
            shortTitle: "Ask Pi",
            systemImageName: "terminal"
        )

        // Quick launch: open new session
        AppShortcut(
            intent: OpenNewSessionIntent(),
            phrases: [
                "New session in \(.applicationName)",
                "Open \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "New Session",
            systemImageName: "plus.message"
        )
    }
}
```

---

## Integration with Existing App

### Navigation from `OpenNewSessionIntent`

The intent writes a launch target to UserDefaults:

```swift
struct IntentLaunchTarget: Codable {
    let serverId: String
    let workspaceId: String
    let timestamp: Date
}
```

`OppiApp.swift` checks for this on `scenePhase == .active`:

```swift
if let target = IntentLaunchTarget.load(), target.isRecent {
    IntentLaunchTarget.clear()
    // Switch to server
    coordinator.switchToServer(target.serverId)
    // Create session + navigate
    Task {
        let session = try await connection.apiClient?.createWorkspaceSession(
            workspaceId: target.workspaceId
        )
        if let session {
            connection.sessionStore.upsert(session)
            connection.sessionStore.activeSessionId = session.id
            navigation.selectedTab = .workspaces
        }
    }
}
```

### WebSocket for `AskPiIntent`

The intent needs a lightweight, one-shot WebSocket:

```swift
/// One-shot WebSocket: connect, send messages, disconnect.
/// Used by AskPiIntent to fire a prompt without the full
/// ServerConnection machinery.
actor IntentWebSocket {
    func sendPrompt(
        url: URL,
        token: String,
        thinkingLevel: ThinkingLevel?,
        prompt: String
    ) async throws {
        // 1. Open URLSessionWebSocketTask
        // 2. Wait for first message (.connected) with 5s timeout
        // 3. If thinkingLevel != nil && != .medium → send setThinkingLevel
        // 4. Send prompt message
        // 5. Close WebSocket
    }
}
```

This is ~50 lines of `URLSessionWebSocketTask` code. No reconnection logic, no ping timers, no DeltaCoalescer — just open, send, close.

---

## Testing Strategy

### Unit Tests

1. **`ServerWorkspaceEntity` ID encoding/decoding** — round-trip `serverId|workspaceId`
2. **`ThinkingLevelAppEnum` ↔ `ThinkingLevel` mapping** — all cases
3. **`IntentLaunchTarget` UserDefaults persistence** — write/read/clear/expiry
4. **`IntentAPIClient` request formation** — correct paths, headers, body encoding

### Integration Tests

5. **`AskPiIntent.perform()` with mock API** — verify session creation + WS message sequence
6. **`ServerWorkspaceEntityQuery.suggestedEntities()`** — multi-server merge, unreachable server handling
7. **`OpenNewSessionIntent.perform()`** — launch target written correctly

### Manual Testing

8. **Shortcuts app**: Create a shortcut with "Ask Pi" action, configure parameters, run
9. **Siri**: "Hey Siri, ask Oppi to check server health"
10. **Action button**: Settings → Action Button → select "New Session", press button
11. **Automation**: Create time-of-day automation → Ask Pi, verify it fires
12. **Spotlight**: Search "Ask Oppi" → verify App Shortcut appears

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Entity query makes network calls from Shortcuts process — may be slow | Cache workspace list in UserDefaults (quick read), refresh lazily. Timeout after 5s with stale data. |
| Server credentials in Keychain may not be accessible from background intent | Keychain items are accessible when device is unlocked (default). App Intents run after unlock. Test on device. |
| WebSocket connect in `AskPiIntent` may hang | Hard 5s timeout on connect. If timeout, return error dialog and don't leak the task. |
| `openAppWhenRun` for `OpenNewSessionIntent` may not focus composer | Use `UIApplication.sendAction` to becomeFirstResponder, or set a flag that ChatInputBar reads. |
| App Intents compile-time metadata extraction may fail silently | Build + check Shortcuts app after adding intents. Xcode shows warnings if metadata generation fails. |
| Multi-server entity list may be confusing with only one server | If only one server, omit server name from subtitle in `displayRepresentation`. |

---

## Scope

### v1 (this PR)
- `AskPiIntent` + `OpenNewSessionIntent`
- `ServerWorkspaceEntity` with query
- `ThinkingLevelAppEnum`
- `OppiShortcuts` provider
- `IntentAPIClient` + `IntentWebSocket`
- `IntentLaunchTarget` for app navigation
- Unit tests for entities, enums, persistence
- Integration test for intent perform with mock

### Future
- `SessionStatusIntent` — "What's pi working on?"
- `ApprovePermissionIntent` — approve/deny from Siri
- WidgetKit integration (reuses same entities)
- Spotlight indexing of past sessions
- Intent donation for prediction ("you usually ask pi about X at this time")

---

## Open Questions

1. **Keychain access group**: Do App Intents running in the Shortcuts process have access to the app's Keychain items? Likely yes (same app group), but needs device testing.

2. **Background WebSocket duration**: Does iOS kill the intent process if the WebSocket takes >10s? The budget should be fine (5s connect timeout + instant send), but worth testing with a slow server.

3. **Entity query caching**: Should `ServerWorkspaceEntityQuery.suggestedEntities()` cache results in UserDefaults for faster subsequent loads? The Shortcuts editor calls this every time the user taps the parameter, and hitting the network each time may feel slow.
