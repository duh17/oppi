# Oppi iOS

SwiftUI app (iOS 26+) that supervises pi CLI sessions on a home server. The phone is the permission authority — not a terminal.

## Commands

```bash
xcodegen generate    # Required after adding/removing files

# Build
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build

# Test
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

The Xcode project file is generated — never edit `Oppi.xcodeproj` directly. Change `project.yml` and run `xcodegen generate`.

## Key Architectural Patterns

**Event Pipeline (core data flow):**
```
ServerMessage (WebSocket)
  → ServerConnection.handleServerMessage()
  → DeltaCoalescer (batches text/thinking at 33ms)
  → TimelineReducer (state machine → [ChatItem])
  → ChatTimelineCollectionView (UIKit)
```

Direct state updates (session metadata, extension UI) bypass the pipeline and update stores directly.

**Observable Stores:** `SessionStore`, `WorkspaceStore`, `PermissionStore`, `TimelineReducer`, `ToolOutputStore`, `ToolArgsStore` are separate `@Observable` objects to prevent cross-store re-renders.

**ServerConnection** is the top-level coordinator per server. Owns API client, WebSocket, all stores, and the event pipeline. Multi-server via `ConnectionCoordinator`.

**Forward-compatible decoding.** `ServerMessage` has `.unknown(type:)`. Unknown server types are logged and skipped.

## Code Style

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All `@Observable` classes must be `@MainActor`
- Prefer `if let x` over `if let x = x`
- No force unwraps in production code
- Guard statements: `return` on a separate line
- No `...` or `…` in Logger messages
- Use `AppIdentifiers.subsystem` for all os.log subsystem strings
- Liquid Glass for navigation chrome only (tab bar, toolbars, nav bars). Never for scrollable content.

## Definition of Done

An iOS task is done when all are true:

1. `xcodebuild ... build` passes for the target simulator.
2. `xcodebuild ... test` passes for impacted tests.
3. `xcodegen generate` was run if file/project structure changed.
4. Protocol change (if any) is mirrored in `server/src/types.ts` + protocol tests (see `../AGENTS.md`).
5. User-visible behavior changes are documented when needed.


