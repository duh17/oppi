# Oppi iOS — Agent Instructions

This file provides guidance to coding agents working with the Oppi iOS app.

## Build and Development Commands

### Building

```bash
# Generate Xcode project from project.yml (required after adding/removing files)
xcodegen generate

# Build for simulator
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Build for device (requires signing)
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'generic/platform=iOS' build
```

### Testing

```bash
# Run all tests
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

### Setup

The Xcode project file (`Oppi.xcodeproj/`) is gitignored. Always regenerate from `project.yml` via XcodeGen before building.

```bash
brew install xcodegen  # if not installed
xcodegen generate
```

### Repeatable local deploy flow (from repo root)

```bash
ios/scripts/build-install.sh --launch --device <iphone-udid>
```

## Project Architecture

### High-Level Structure

Oppi is an iPhone app (portrait-locked, iOS 26+) that supervises pi coding agents running on a home server. The phone is the **permission authority** — not a terminal. The agent works autonomously; you approve or deny dangerous actions.

The server (`../server/`) handles pi process management, policy evaluation, and WebSocket streaming. The app connects over the local network or VPN.

### App Structure

```
Oppi/
├── App/                        App entry, navigation, delegates
│   ├── OppiApp.swift           @main, scene setup, scenePhase
│   ├── AppNavigation.swift     Tab-based navigation state
│   ├── AppDelegate.swift       Push notification registration
│   └── ContentView.swift       Root view with tab bar
│
├── Core/
│   ├── Networking/
│   │   ├── APIClient.swift              REST client (sessions, workspaces, skills)
│   │   ├── WebSocketClient.swift        WS streaming, keepalive pings
│   │   ├── ServerConnection.swift       Top-level coordinator: stores + pipeline
│   │   ├── ServerConnection+MessageRouter.swift  Event dispatch
│   │   ├── ServerConnection+Refresh.swift        Single-flight metadata refresh
│   │   ├── ServerConnection+ModelCommands.swift   Model/thinking commands
│   │   └── ServerConnection+Fork.swift           Session forking
│   │
│   ├── Models/
│   │   ├── Session.swift          Session, SessionMessage, ModelInfo
│   │   ├── Workspace.swift        Workspace model
│   │   ├── Permission.swift       PermissionRequest, RiskLevel, PermissionAction
│   │   ├── PairedServer.swift     Multi-server credentials
│   │   ├── ClientMessage.swift    Client → Server (Encodable)
│   │   ├── ServerMessage.swift    Server → Client (manual Decodable)
│   │   ├── JSONValue.swift        Recursive Codable JSON type
│   │   └── ...                    SkillInfo, SlashCommand, TraceEvent, etc.
│   │
│   ├── Runtime/
│   │   ├── AgentEvent.swift       Transport-agnostic domain events
│   │   ├── ChatItem.swift         Unified timeline model
│   │   ├── TimelineReducer.swift  ServerMessage → ChatItem state machine
│   │   ├── ToolEventMapper.swift  Correlates tool_start/output/end
│   │   ├── DeltaCoalescer.swift   Batches text/thinking deltas at 33ms
│   │   ├── ToolOutputStore.swift  Memory-bounded output (256KB/item, 2MB total)
│   │   └── ToolArgsStore.swift    Tool call arguments storage
│   │
│   ├── Services/
│   │   ├── ServerStore.swift          Multi-server management
│   │   ├── SessionStore.swift         Observable session list
│   │   ├── WorkspaceStore.swift       Workspace list + cache
│   │   ├── PermissionStore.swift      Pending permission queue
│   │   ├── ConnectionCoordinator.swift  Multi-server connection lifecycle
│   │   ├── KeychainService.swift      Secure credential storage
│   │   ├── TimelineCache.swift        Durable offline timeline cache
│   │   ├── LiveActivityManager.swift  ActivityKit integration
│   │   ├── RestorationState.swift     Foreground/background persistence
│   │   └── ...                        Biometric, dictation, Sentry, audio
│   │
│   ├── Formatting/         Text formatting + parsing utilities
│   ├── Theme/              Colors, dynamic themes
│   ├── Views/              Reusable view components
│   ├── Extensions/         Swift extensions
│   ├── Push/               APNs push registration
│   ├── Notifications/      Local notification service
│   └── Security/           Certificate pinning
│
├── Features/
│   ├── Chat/
│   │   ├── Timeline/       UIKit collection view + cells
│   │   ├── Composer/       Text input bar + expanded composer
│   │   ├── Output/         Tool output rendering (bash, file, diff, etc.)
│   │   ├── Session/        Chat session manager + action handler
│   │   └── Support/        Toolbar, subviews, model picker
│   │
│   ├── Workspaces/         Workspace list, create, edit
│   ├── Sessions/           Session list per workspace
│   ├── Permissions/        Approve/deny with risk tiers
│   ├── Skills/             Skill browser + editor
│   ├── Servers/            Multi-server management
│   ├── Onboarding/         QR scanner + pairing
│   └── Settings/           App settings
│
├── Resources/              Assets, Info.plist, entitlements
│
OppiActivityExtension/      Live Activity widget extension
Shared/                     Shared between app and extension
│   └── PiSessionAttributes.swift
OppiTests/                  Unit tests (Swift Testing)
```

### Key Architectural Patterns

**Event Pipeline (core data flow):**
```
ServerMessage (WebSocket)
  → ServerConnection.handleServerMessage()
  → DeltaCoalescer (batches text/thinking at 33ms)
  → TimelineReducer (state machine → [ChatItem])
  → ChatTimelineCollectionView (UIKit)
```

Direct state updates (session metadata, extension UI) bypass the pipeline and update stores directly.

**Observable Stores (scoped re-renders):**
- `SessionStore` — session list
- `WorkspaceStore` — workspace list + cache
- `PermissionStore` — pending permission queue
- `TimelineReducer` — `[ChatItem]` timeline
- `ToolOutputStore` / `ToolArgsStore` — tool data (memory-bounded)

These are separate `@Observable` objects to prevent permission timer ticks from re-rendering the session list.

**ServerConnection** is the top-level coordinator per server. It owns the API client, WebSocket client, all stores, and the event pipeline. Multi-server support via `ConnectionCoordinator`.

**Forward-compatible decoding.** `ServerMessage` has an `.unknown(type:)` case. Unknown server message types are logged and skipped.

### Wire Protocol

Client-server messages defined in `../server/src/types.ts`. The Swift models must stay in sync:

| Server type (TypeScript) | Swift model |
|--------------------------|-------------|
| `ServerMessage` | `ServerMessage.swift` (manual `Decodable`) |
| `ClientMessage` | `ClientMessage.swift` (manual `Encodable`) |
| `PermissionRequest` fields | `Permission.swift` |
| `Session`, `SessionMessage` | `Session.swift` |

When the server adds new message types, add a new case to `ServerMessage` and handle it in `ServerConnection+MessageRouter`. The `default → .unknown` case in the decoder ensures the app won't crash on unrecognized types.

Timestamps are Unix milliseconds from the server. Convert via `Date(timeIntervalSince1970: ms / 1000)`.

## Code Style

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All `@Observable` classes must be `@MainActor`
- Prefer `if let x` and `guard let x` over `if let x = x`
- No force unwraps in production code
- Guard statements: `return` on a separate line
- Manual `Decodable` for `ServerMessage` (discriminated union on `type` field)
- Prefer value types (`struct`, `enum`) over classes where possible
- Mark `Sendable` conformance explicitly
- No `...` or `…` in Logger messages
- Use `AppIdentifiers.subsystem` for all os.log subsystem strings

### Liquid Glass Rules (iOS 26)

Use Liquid Glass for navigation chrome only (tab bar, toolbars, navigation bars, floating action buttons, sheet presentations). Never for scrollable content. High-contrast text on all glass surfaces. Minimum touch target 44×44pt.

## Things to Know

- `ToolEventMapper` generates client-side tool event IDs because the server's streaming events don't carry them. If the server adds IDs later, the mapper becomes a passthrough.
- `DeltaCoalescer` batches at 33ms but delivers tool/permission/error events immediately.
- `ToolOutputStore` is separate from `ChatItem` to keep `Equatable` diffs cheap. Full output fetched on-demand when user expands a tool call.
- Image upload uses workspace-scoped REST routes (`POST /workspaces/:wid/sessions/:sid/attachments`), not base64 over WebSocket.
- On background → foreground, the app calls REST to rebuild chat state. The server does not replay missed streaming events.
- The Xcode project file is generated — never edit `Oppi.xcodeproj` directly. Change `project.yml` and run `xcodegen generate`.
- Fork setup: update `bundleIdPrefix` and `DEVELOPMENT_TEAM` in `project.yml`.
