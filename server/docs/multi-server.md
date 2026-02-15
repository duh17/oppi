# Multi-Server Support

> The iOS app can pair with multiple oppi servers and display workspaces grouped by server.

## Problem

Currently the iOS app supports exactly one server connection. Credentials are stored as a single Keychain item, `ServerConnection` owns one `APIClient`, and `WorkspaceHomeView` shows a flat workspace list. Adding a second server (e.g. Mac Mini alongside Mac Studio) requires re-pairing, which destroys the first connection.

## Naming

The entity is called **Server** — it's deployment-agnostic (bare metal Mac, Docker container, Apple container, VPS, cloud). Each server has a unique Ed25519 identity fingerprint.

## Core Principles

1. **No "active server" restriction.** Browse all servers' workspaces on one screen. Connect on demand when you drill into a workspace.
2. **No health checks or heartbeats.** The workspace fetch IS the health signal. If a server is unreachable, cached workspaces show with per-server `FreshnessState`. The user discovers failure when they tap in — instant, obvious, no wasted requests.
3. **Replay handles everything.** Switch freely between servers. Trace replay catches you up when you return to a session.

## Design

### Server Model (iOS)

```swift
/// A paired oppi server that the app can connect to.
struct PairedServer: Identifiable, Codable, Sendable, Hashable {
    /// Server fingerprint (sha256:...) — unique, stable identity.
    let id: String
    var name: String          // "mac-studio", "mac-mini" (from invite, editable)
    var host: String          // "my-server.tail00000.ts.net"
    var port: Int             // 7749
    var token: String         // sk_...
    var fingerprint: String   // sha256:rHLw... (== id)

    // Invite metadata
    var securityProfile: String?
    var inviteVersion: Int?
    var inviteKeyId: String?
    var requireTlsOutsideTailnet: Bool?
    var allowInsecureHttpInTailnet: Bool?
    var requirePinnedServerIdentity: Bool?

    // Local state (not from server)
    var addedAt: Date         // when first paired
    var sortOrder: Int        // manual ordering

    /// Derive ServerCredentials for connection.
    var credentials: ServerCredentials { ... }
}
```

The fingerprint IS the server ID — it survives hostname changes, port changes, re-installs (as long as the identity key is preserved).

### Server Store

```swift
/// Manages the list of paired servers. Persists to Keychain.
/// Pure data store — no networking, no health checks.
@MainActor @Observable
final class ServerStore {
    private(set) var servers: [PairedServer] = []

    func add(_ server: PairedServer) throws { ... }
    func update(_ server: PairedServer) { ... }
    func remove(id: String) { ... }
    func server(for id: String) -> PairedServer? { ... }
}
```

### Keychain Storage

Current: single item under account `"server-credentials"`.

New: keyed by server fingerprint.

```swift
enum KeychainService {
    private static let service = "dev.chenda.PiRemote"

    // Multi-server
    static func saveServer(_ server: PairedServer) throws { ... }
    static func loadServers() -> [PairedServer] { ... }
    static func deleteServer(id: String) { ... }

    // Migration: single legacy credential → first PairedServer entry.
    // Called once on app launch. No-op if already migrated.
    static func migrateIfNeeded() -> PairedServer? { ... }
}
```

Each `PairedServer` is stored as a separate Keychain generic-password item with account `"server-<fingerprint>"`. A UserDefaults key `"pairedServerIds"` stores the ordered list of fingerprints (fingerprints aren't secrets).

### Connection Model

**Connect on demand.** No persistent "active server." The connection follows the user's navigation.

```
WorkspaceHomeView (all servers, grouped)
  ├── tap workspace on Mac Studio → connect to Mac Studio
  │     └── ChatView (streaming from Mac Studio)
  │           └── navigate back → disconnect
  └── tap workspace on Mac Mini → connect to Mac Mini
        └── ChatView (streaming from Mac Mini)
              └── navigate back → disconnect
```

The existing `ServerConnection` manages ONE live connection. When the user navigates to a workspace on a different server, it tears down and reconfigures:

```swift
extension ServerConnection {
    /// Reconfigure to target a different server.
    func switchServer(to server: PairedServer) -> Bool {
        disconnectSession()
        return configure(credentials: server.credentials)
    }
}
```

`ChatSessionManager` already handles reconnection and trace replay on foreground. The same mechanism works when switching servers — you leave a session on Server A, browse workspaces, open a session on Server B, and when you return to Server A's session, replay catches you up.

### Workspace Data: Per-Server Isolation

Workspaces and sessions from different servers must not mix:

```swift
@MainActor @Observable
final class WorkspaceStore {
    /// Workspaces keyed by server ID for grouped display.
    var workspacesByServer: [String: [Workspace]] = [:]

    /// Per-server freshness tracking (replaces single FreshnessState).
    var freshness: [String: FreshnessState] = [:]

    /// Load workspaces for ALL paired servers (workspace home).
    func loadAll(servers: [PairedServer]) async { ... }
}
```

Similarly, `SessionStore` gets a server dimension. Sessions already have `workspaceId`; we add logical server association by tracking which server returned them.

### Workspace Home — Grouped by Server

```
┌─────────────────────────────────────┐
│  Workspaces                      +  │
├─────────────────────────────────────┤
│  Mac Studio             updated 2m  │  ← tappable → ServerDetailView
│  ┌─────────────────────────────┐    │
│  │ 🔧 coding     ● 1 active   │    │
│  │ 🔍 research   ○ stopped    │    │
│  │ 📝 writing    ● 2 active   │    │
│  └─────────────────────────────┘    │
│                                     │
│  Mac Mini             unreachable   │  ← FreshnessState from failed fetch
│  ┌─────────────────────────────┐    │
│  │ 🧪 testing    ○ stopped    │    │  ← cached, shown grayed
│  │ 🤖 automation  —           │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

- **Server section header**: name + per-server `FreshnessState` label (e.g. "updated 2m", "unreachable")
- **Tapping section header** → `ServerDetailView` (info, stats, security, actions)
- **Tapping workspace row** → connects to that server → `WorkspaceDetailView`
- **Unreachable servers**: workspaces shown from cache, grayed. Tapping shows connection error.
- **Pull to refresh**: re-fetches workspaces from all servers in parallel.

### Server Detail View

Reached by tapping a server section header:

```
┌─────────────────────────────────────┐
│ ← Mac Studio                       │
├─────────────────────────────────────┤
│ Host            mac-studio.ts.net   │
│ Port            7749                │
│ Uptime          2d 14h              │
│ OS              macOS arm64         │
│ Pi Version      0.8.0               │
│ Server Version  0.2.0               │
├─────────────────────────────────────┤
│ Stats                               │
│ Workspaces      4                   │
│ Active Sessions 2                   │
│ Total Sessions  15                  │
│ Skills          12                  │
│ Models          8                   │
├─────────────────────────────────────┤
│ Security                            │
│ Profile       tailscale-permissive  │
│ Fingerprint   sha256:rHLw...  📋    │
├─────────────────────────────────────┤
│ [ Rename ]  [ Re-pair ]  [ Remove ] │
└─────────────────────────────────────┘
```

Data comes from `GET /server/info` (new endpoint), fetched on-demand when the view appears.

### Server Info API (New Endpoint)

```
GET /server/info   (authenticated)

{
  "name": "mac-studio",
  "version": "0.2.0",
  "uptime": 86400,
  "os": "darwin",
  "arch": "arm64",
  "hostname": "mac-studio",
  "nodeVersion": "v22.0.0",
  "dataDir": "~/.config/oppi",
  "piVersion": "0.8.0",
  "configVersion": 2,
  "identity": {
    "fingerprint": "sha256:rHLw...",
    "keyId": "srv-default",
    "algorithm": "ed25519"
  },
  "stats": {
    "workspaceCount": 4,
    "activeSessionCount": 2,
    "totalSessionCount": 15,
    "skillCount": 12,
    "modelCount": 8
  }
}
```

### Onboarding / Add Server

- **First launch**: Same flow (scan QR → pair → navigate to workspaces)
- **Add another server**: Settings → "Add Server" → scan QR → validates → appends to server list
- **Fingerprint collision**: If scanned invite matches existing server, update credentials (host/port/token may change, fingerprint stable) — don't duplicate
- **Re-pair**: Settings per-server action. Opens QR scanner, updates that server's credentials.

### Push Notifications

Register device token with ALL paired servers:

```swift
func registerPushTokenWithAllServers(token: String, servers: [PairedServer]) async {
    await withTaskGroup(of: Void.self) { group in
        for server in servers {
            group.addTask {
                let api = APIClient(baseURL: server.baseURL, token: server.token)
                try? await api.registerDeviceToken(token)
            }
        }
    }
}
```

### Cache Namespacing

All caches get a server dimension to prevent cross-server collisions:

```swift
// TimelineCache
func loadSessionList(serverId: String) -> [Session]?
func saveSessionList(_ sessions: [Session], serverId: String)
func loadWorkspaces(serverId: String) -> [Workspace]?
func saveWorkspaces(_ workspaces: [Workspace], serverId: String)
```

## Implementation Phases

### P1: Foundation
- [ ] `PairedServer` model
- [ ] Multi-server `KeychainService` (save/load/delete by fingerprint)
- [ ] Single-credential migration
- [ ] `ServerStore` (pure data: list, add, remove, update)
- [ ] Wire `AppNavigation.showOnboarding` to `ServerStore.servers.isEmpty`

### P2: Server Info API
- [ ] `GET /server/info` on oppi-server (TypeScript)
- [ ] `ServerInfo` model + `APIClient.serverInfo()` on iOS
- [ ] `ServerDetailView` on iOS

### P3: Workspace + Session Store Per-Server
- [ ] `WorkspaceStore.workspacesByServer` keyed by server ID
- [ ] Per-server `FreshnessState` on workspace store
- [ ] `SessionStore` with server awareness
- [ ] Cache namespacing (`TimelineCache` by server ID)

### P4: Workspace Home UI
- [ ] `WorkspaceHomeView` → sectioned by server
- [ ] Server section header (name, freshness label, tappable)
- [ ] Tap workspace → `ServerConnection.switchServer()` → drill in
- [ ] Unreachable server graceful handling (cached workspaces, grayed)

### P5: Add Server Flow
- [ ] Settings → "Add Server" → QR scan → `ServerStore.add()`
- [ ] Fingerprint dedup (update existing on collision)
- [ ] Settings → "Servers" section (rename, re-pair, remove)
- [ ] First-launch onboarding unchanged (just adds first server)

### P6: Polish
- [ ] Push token registration with all servers
- [ ] Permission push → resolve server → connect
- [ ] Cross-server permission banner attribution
- [ ] Handle server removal gracefully (clean up cache, sessions)
