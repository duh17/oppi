# Oppi — Agent Guide

Oppi monorepo — iOS/macOS app + self-hosted server for mobile-supervised [pi](https://github.com/badlogic/pi-mono) sessions.

## Structure

```
clients/apple/ Apple clients (iOS + macOS, SwiftUI + UIKit, iOS 26+)
server/        Server runtime (TypeScript, runs under Bun or Node.js)
```

## Commands

```bash
# Server
cd server && npm install        # also builds via prepare script
cd server && npm test
cd server && npm run check      # typecheck + lint + format — fix ALL errors before committing
cd server && npm start

# Apple — project generation
cd clients/apple && xcodegen generate

# Apple — builds MUST use sim-pool (isolates DerivedData per build slot)
cd clients/apple && bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
cd clients/apple && bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi test -only-testing:OppiTests
```

The Xcode project file is generated — never edit `Oppi.xcodeproj` directly. Change `project.yml` and run `xcodegen generate`.

After code changes: run `npm run check` (server) and/or build + test (Apple). Fix all errors before committing.

## Parallel Build Safety

Multiple agents may build concurrently. Xcode's build system uses a SQLite database that locks when two builds share the same DerivedData path. This causes `unable to attach DB: database is locked` errors.

Rules:
1. **Always use `sim-pool.sh`** for simulator builds — it auto-injects isolated `-derivedDataPath` per slot
2. If sim-pool isn't available, pass `-derivedDataPath /tmp/oppi-dd-$$` to avoid the shared default path
3. **Never use bare `xcodebuild`** without one of the above — the default DerivedData path will collide with Xcode or other agents
4. Do not pipe sim-pool output through `grep`/`tail`/`head` — it prints a self-contained summary with the log path
5. To investigate build failures, use `read(path=...)` on the log file printed in the summary

## Complexity Guardrails

Before writing new code, search for existing implementations:
```bash
# Server utilities
rg 'export function' server/src/metric-utils.ts server/src/log-utils.ts
# iOS formatting
rg 'static func\|func format' -t swift clients/apple/Oppi/Core/Formatting/
# Type/interface names — check for collisions
rg 'export (type|interface) YourName' server/src/types.ts server/src/policy-types.ts
```

When adding files: if the directory already has 10+ files with the same prefix (e.g. `session-*.ts`), pause and check whether the new code belongs in an existing file.

## Protocol Discipline

When changing client/server message contracts:
1. Update server types in `server/src/types.ts`
2. Update iOS models (`ServerMessage.swift`, `ClientMessage.swift`)
3. Update protocol tests on both sides

No partial protocol updates.

## Code Quality

### TypeScript (server)
- No `any` types unless absolutely necessary
- Check `node_modules` for external API type definitions instead of guessing
- Validate at boundaries — parse incoming external data before internal use
- Keep behavior observable — structured logs, deterministic error messages
- No new coordinator class for less than ~100 lines of logic — use a function
- No new Deps interface for a single method — inline the dependency
- No `as SomeType` casts in session coordinator wiring — narrow the method signature instead

### Swift (Apple clients)
- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All `@Observable` classes must be `@MainActor`
- Prefer `if let x` over `if let x = x`
- No force unwraps in production code
- Liquid Glass for navigation chrome only. Never for scrollable content.

### Testing (Apple clients)
- Use Swift Testing (`import Testing`, `@Test`, `#expect`) for all unit tests. No XCTest for unit tests.
- XCTest is only allowed for UI tests (`XCUIApplication` requires it — Swift Testing has no UI testing support).
- Use `@Suite("Name")` to group related tests in a struct.
- Use `@MainActor` on the struct (not individual tests) when all tests need main actor isolation.
- Use `Issue.record()` instead of `XCTFail()`. Use `#expect()` instead of `XCTAssert*`.
- **xcodebuild `-only-testing` with Swift Testing**: xcodebuild strips one trailing `()` from identifiers. Add double parentheses `()()` for function-level filters:
  - Suite: `-only-testing:OppiTests/MySuiteStruct` (use struct name, not `@Suite` display name)
  - Function: `-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'`
  - Multiple: repeat `-only-testing:` for each test

## Apple Client Architecture

### Performance Philosophy

For hot paths (chat timeline, streaming rendering, scroll containers), use the most performant native API Apple provides — not the highest-level abstraction. Concretely:

- **iOS timeline**: `UICollectionView` + `UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout` + `UIContentConfiguration`
- **macOS timeline**: `NSCollectionView` + `NSDiffableDataSourceSnapshot` + `NSCollectionViewCompositionalLayout` + `NSView`-based items
- **Both**: bridged to SwiftUI via `UIViewRepresentable` / `NSViewRepresentable`

SwiftUI is the right choice for forms, settings, navigation shells, session lists, workspace views — anything that isn't the streaming hot path.

Before choosing an API for a performance-sensitive surface, check Apple's current documentation for the recommended approach. Use the lowest-level stable API that's actively maintained. Avoid wrapping performance-critical rendering in SwiftUI when AppKit/UIKit gives direct control over layout, diffing, and scroll position.

### Key Principles

- **Many small stores on purpose.** Each `@Observable` store is separate to prevent cross-store re-renders. Do not merge stores. To list them: `rg 'final class .*(Store|Reducer|Coalescer)\b' -t swift clients/apple/Oppi/ | sort`
- **Prefer focused dependencies.** Views should use the narrowest environment object that works (`\.apiClient` > `ChatSessionState` > `ServerConnection`).
- **iOS/Mac sharing.** Shared types and helpers go in `Shared/`. Do not duplicate logic between `Oppi/` and `OppiMac/`. If you're writing a view that exists in one target, check the other target first.
- **Share state, fork views.** Models, networking, stores, reducers — share aggressively in `Shared/`. Views — share when pure SwiftUI (settings, lists, forms), fork when platform-specific rendering is needed (timeline cells, text input).
- **Forward-compatible decoding.** `ServerMessage` has `.unknown(type:)`. Unknown server types are logged and skipped.

## Style

- No emojis in commits or code
- Technical prose, direct

## Definition of Done

1. `npm run check` passes (server) and/or xcodebuild build + test pass (Apple)
2. Protocol changes are mirrored on both sides with tests
3. `xcodegen generate` was run if Apple client file structure changed
