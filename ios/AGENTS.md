# Pi Remote iOS — Claude Code Instructions

This file provides guidance to Claude Code when working with the iOS app in this directory.

## Build and Development Commands

### Building

```bash
# Generate Xcode project from project.yml (required after adding/removing files)
xcodegen generate

# Build for simulator
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Build for device (requires signing)
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'generic/platform=iOS' build
```

### Testing

```bash
# Run all tests
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Test files in `PiRemoteTests/`:
- `ServerMessageTests.swift` — wire format decoding (manual `Decodable`)
- `ClientMessageTests.swift` — client message encoding
- `JSONValueTests.swift` — recursive JSON type
- `TimelineReducerTests.swift` — event pipeline state machine
- `ToolOutputStoreTests.swift` — memory-bounded output storage

### Setup

The Xcode project file (`PiRemote.xcodeproj/`) is gitignored. Always regenerate from `project.yml` via XcodeGen before building.

```bash
brew install xcodegen  # if not installed
xcodegen generate
```

### Repeatable local deploy flow (from repo root)

```bash
./scripts/ios-dev-up.sh -- --device <iphone-udid>
```

This runs a combined loop:
- starts/restarts `pi-remote` in background tmux window `pi-remote-server`
- waits for server port `7749`
- runs `ios/scripts/build-install.sh` (adds `--launch` by default)

Useful variants:

```bash
# keep existing server window
./scripts/ios-dev-up.sh --no-restart-server -- --device <iphone-udid>

# install without auto-launch
./scripts/ios-dev-up.sh --no-launch -- --device <iphone-udid>
```

## Project Architecture

### High-Level Structure

Pi Remote is an iPhone app (portrait-locked, iOS 26+) that supervises pi coding agents running on a home server. The phone is the **permission authority** — not a terminal. The agent works autonomously; you approve or deny dangerous actions.

The server (`../pi-remote/`) handles pi process management, policy evaluation, and WebSocket streaming. This app connects over Tailscale.

### App Structure

```
PiRemote/
├── App/                    # App entry, navigation, delegates
│   ├── PiRemoteApp.swift   # @main, scene setup, scenePhase
│   ├── AppNavigation.swift  # Tab-based navigation state
│   ├── AppDelegate.swift    # Push notification registration
│   └── ContentView.swift    # Root view with tab bar
│
├── Core/
│   ├── Networking/
│   │   ├── APIClient.swift        # REST (sessions, auth, device tokens)
│   │   ├── WebSocketClient.swift  # WS streaming, keepalive pings
│   │   └── ServerConnection.swift # Top-level coordinator: stores + pipeline
│   │
│   ├── Models/
│   │   ├── Session.swift          # Session, SessionMessage
│   │   ├── Permission.swift       # PermissionRequest, RiskLevel, PermissionAction
│   │   ├── User.swift             # ServerCredentials, Keychain token
│   │   ├── ClientMessage.swift    # Client → Server (Encodable)
│   │   ├── ServerMessage.swift    # Server → Client (manual Decodable)
│   │   ├── JSONValue.swift        # Recursive Codable JSON type
│   │   └── TraceEvent.swift       # Pi session JSONL format
│   │
│   ├── Runtime/
│   │   ├── AgentEvent.swift       # Transport-agnostic domain events
│   │   ├── ChatItem.swift         # Unified timeline model + ToolOutputStore
│   │   ├── TimelineReducer.swift  # ServerMessage → ChatItem state machine
│   │   ├── ToolEventMapper.swift  # Correlates tool_start/output/end (client-side IDs)
│   │   └── DeltaCoalescer.swift   # Batches text/thinking deltas at 33ms for 30fps
│   │
│   ├── Services/
│   │   ├── SessionStore.swift     # Observable session list
│   │   ├── PermissionStore.swift  # Pending permission queue
│   │   ├── KeychainService.swift  # Secure token storage
│   │   ├── LiveActivityManager.swift  # ActivityKit integration
│   │   └── RestorationState.swift # Foreground/background state persistence
│   │
│   ├── Views/                     # Reusable view components
│   │   ├── MarkdownText.swift
│   │   └── ImageBlobView.swift
│   │
│   ├── Extensions/
│   │   ├── Color+Risk.swift       # Risk-tier color palette
│   │   └── Date+Relative.swift    # "2m ago" formatting
│   │
│   ├── Push/
│   │   └── PushRegistration.swift
│   │
│   └── Notifications/
│       └── PermissionNotificationService.swift
│
├── Features/
│   ├── Chat/
│   │   ├── ChatView.swift         # Main chat + live stream
│   │   ├── ChatInputBar.swift     # Text input + send
│   │   └── ChatItemRow.swift      # Renders one ChatItem
│   │
│   ├── Sessions/
│   │   ├── SessionListView.swift  # All sessions for this user
│   │   └── NewSessionView.swift   # Create session sheet + model picker
│   │
│   ├── Permissions/
│   │   └── PermissionCardView.swift  # Approve/deny with risk tiers
│   │
│   ├── Live/
│   │   └── LiveFeedView.swift     # Cross-session activity feed
│   │
│   ├── Onboarding/
│   │   └── QRScannerView.swift    # DataScannerViewController wrapper
│   │
│   └── Settings/
│       └── SettingsView.swift
│
├── Resources/
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── PiRemote.entitlements
│
PiRemoteActivityExtension/        # Live Activity widget extension
Shared/                            # Shared between app and extension
│   └── PiSessionAttributes.swift  # ActivityKit attributes
PiRemoteTests/                     # Unit tests
```

### Key Architectural Patterns

**Event Pipeline (the core data flow):**
```
ServerMessage (WebSocket)
  → ServerConnection.handleServerMessage()
  → DeltaCoalescer (batches text/thinking at 33ms)
  → TimelineReducer (state machine → [ChatItem])
  → ChatView (LazyVStack)
```

Direct state updates (session metadata, extension UI) bypass the pipeline and update stores directly.

**Observable Stores (scoped re-renders):**
- `SessionStore` — session list, active session ID
- `PermissionStore` — pending permission queue
- `TimelineReducer` — `[ChatItem]` timeline, `renderVersion` counter
- `ToolOutputStore` — full tool output (memory-bounded: 256KB/item, 2MB total)

These are separate `@Observable` objects to prevent permission timer ticks from re-rendering the session list.

**ServerConnection** is the top-level coordinator. It owns the API client, WebSocket client, all stores, and the event pipeline. Injected via `@Environment`.

**One WebSocket at a time (v1).** Opening a new session stream disconnects the previous one.

**Forward-compatible decoding.** `ServerMessage` has an `.unknown(type:)` case. Unknown server message types are logged and skipped, not fatal decode errors.

### Wire Protocol

Client-server messages defined in `../pi-remote/src/types.ts`. The Swift models must stay in sync:

| Server type (TypeScript) | Swift model |
|--------------------------|-------------|
| `ServerMessage` | `ServerMessage.swift` (manual `Decodable`) |
| `ClientMessage` | `ClientMessage.swift` (manual `Encodable`) |
| `PermissionRequest` fields | `Permission.swift` |
| `Session`, `SessionMessage` | `Session.swift` |

When the server adds new message types, add a new case to `ServerMessage` and handle it in `ServerConnection.handleServerMessage()`. The `default → .unknown` case in the decoder ensures the app won't crash on unrecognized types.

Timestamps come from the server as Unix milliseconds. Convert to `Date` via `Date(timeIntervalSince1970: ms / 1000)`.

### Live Activity / Dynamic Island

`PiRemoteActivityExtension` uses `Shared/PiSessionAttributes.swift` for the ActivityKit `ActivityAttributes` definition. The main app updates Live Activities via `LiveActivityManager`.

## Code Formatting

Prefer idiomatic modern Swift.

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All `@Observable` classes must be `@MainActor`
- Prefer `if let x` and `guard let x` over `if let x = x` and `guard let x = x`
- No force unwraps in production code
- Guard statements: always put `return` on a separate line
- Use `Codable` with explicit `CodingKeys` for server types — never trust default synthesis for wire formats
- Manual `Decodable` for `ServerMessage` (discriminated union on `type` field)
- Prefer value types (`struct`, `enum`) over classes where possible
- Mark `Sendable` conformance explicitly
- No `...` or `…` in Logger messages

### Liquid Glass Rules (iOS 26)

Use Liquid Glass for navigation chrome only:
- Tab bar, toolbars, navigation bars
- Floating action buttons
- Permission card action buttons
- Sheet presentations

Never use Liquid Glass for scrollable content (chat bubbles, list rows, feed entries). High-contrast text on all glass surfaces. Minimum touch target 44x44pt (48x48pt for primary actions).

## Things to Know

- `ToolEventMapper` generates client-side tool event IDs because v1 server messages have no tool call ID. If server adds IDs later, the mapper becomes a passthrough.
- `DeltaCoalescer` batches `textDelta`/`thinkingDelta` at 33ms but delivers tool/permission/error events immediately (terminal-like feedback).
- `ToolOutputStore` is separate from `ChatItem` to keep `Equatable` diffs cheap. Full output fetched on-demand when user expands a tool call.
- Image upload uses REST (`POST /sessions/:id/attachments`), not base64 over WebSocket.
- On background → foreground, the app calls `GET /sessions/:id` to rebuild chat state. The server does not replay missed streaming events.
- Just because unit tests pass doesn't mean a given bug is fixed. It may not have a test. It may require manual testing on device.
- The Xcode project file is generated — never edit `PiRemote.xcodeproj` directly. Change `project.yml` and run `xcodegen generate`.
