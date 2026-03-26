# Oppi — Agent Guide

Oppi monorepo — iOS/macOS app + self-hosted server for mobile-supervised [pi](https://github.com/badlogic/pi-mono) sessions.

## First Message

If no concrete task given, read this file and `README.md`, then ask what to work on.
For context on specific areas, read the relevant docs:
- Root: `README.md`
- Architecture map: `.internal/ARCHITECTURE.md`
- Server: `server/README.md`

## Structure

```
clients/apple/ Apple clients (iOS + macOS, SwiftUI + UIKit, iOS 26+)
server/        Server runtime (Node.js/TypeScript)
```

## Commands

```bash
# Server
cd server && npm install        # also builds via prepare script
cd server && npm test
cd server && npm run check    # typecheck + lint + format — fix ALL errors before committing
cd server && npm start

# Apple — use sim-pool.sh for simulator commands (avoids collisions between agents)
cd clients/apple && xcodegen generate
cd clients/apple && ./scripts/sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
cd clients/apple && ./scripts/sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi test -only-testing:OppiTests

# iOS device deploy (ALWAYS use this script — never call devicectl directly)
# Single canonical install script lives in the oppi-dev skill.
bash ~/.pi/agent/skills/oppi-dev/scripts/install.sh -d DEVICE_UDID --launch
```

**sim-pool.sh** wraps xcodebuild with slot-based simulator locking for parallel agents. It auto-injects `-destination` and `-derivedDataPath` — do NOT pass your own. On failure it prints a `BUILD FAILED` summary with the full log path. Do not pipe build output through `grep`/`tail` — use `read(path=...)` on the log path from the summary.

After code changes: run `npm run check` (server) or `sim-pool.sh run -- xcodebuild ... build` + `test -only-testing:OppiTests` (iOS unit tests). UI tests run in the nightly gate only. Get full output. Fix all errors, warnings, and infos before committing.

See [`.internal/testing/`](.internal/testing/) for full test strategy, pyramid, and required gates by change type.

The Xcode project file is generated — never edit `Oppi.xcodeproj` directly. Change `project.yml` and run `xcodegen generate`.

## Git Rules

- **ONLY commit files YOU changed in THIS session**
- ALWAYS use `git add <specific-file-paths>` — list only files you modified
- Before committing, run `git status` and verify you are only staging your files
- NEVER push unless user asks
- Always ask before removing functionality that appears intentional

### Forbidden Operations
- `git add -A` / `git add .` — stages everything, including other agents' work
- `git reset --hard` — destroys uncommitted changes
- `git checkout .` — destroys uncommitted changes
- `git clean -fd` — deletes untracked files
- `git stash` — stashes ALL changes
- `git push --force`
- `xcrun devicectl device uninstall` — never uninstall the iOS app
- Raw `devicectl device install` — use `~/.pi/agent/skills/oppi-dev/scripts/install.sh -d DEVICE_UDID` instead

### GitHub Issues
```bash
gh issue view <number> --json title,body,comments,labels,state
```
When closing via commit: include `fixes #<number>` or `closes #<number>`.

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

### Rendering Performance (iOS)
- See [`.internal/golden-principles.md`](.internal/golden-principles.md) (Rendering section) for enforced invariants.

### Testing (Apple clients)
- Use Swift Testing (`import Testing`, `@Test`, `#expect`) for all unit tests. No XCTest for unit tests.
- XCTest is only allowed for UI tests (`XCUIApplication` requires it — Swift Testing has no UI testing support).
- Use `@Suite("Name")` to group related tests in a struct.
- Use `@MainActor` on the struct (not individual tests) when all tests need main actor isolation.
- Use `Issue.record()` instead of `XCTFail()`. Use `#expect()` instead of `XCTAssert*`.
- `#filePath` works in Swift Testing for bundle-free fixture resolution — no need for `Bundle(for:)`.
- **xcodebuild `-only-testing` with Swift Testing**: xcodebuild strips one trailing `()` from identifiers. Add double parentheses `()()` for function-level filters:
  - Suite: `-only-testing:OppiTests/MySuiteStruct` (use struct name, not `@Suite` display name)
  - Function: `-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'`
  - Multiple: repeat `-only-testing:` for each test

## iOS Architecture

See `.internal/ARCHITECTURE.md` for the full data flow, environment injection table, and store inventory.

Key principles:
- **Many small stores on purpose.** Each `@Observable` store is separate to prevent cross-store re-renders. Do not merge stores. To list them: `rg 'final class .*(Store|Reducer|Coalescer)\b' -t swift clients/apple/Oppi/ | sort`
- **Prefer focused dependencies.** Views should use the narrowest environment object that works (`\.apiClient` > `ChatSessionState` > `ServerConnection`).
- **iOS/Mac sharing.** Shared types and helpers go in `Shared/`. Do not duplicate logic between `Oppi/` and `OppiMac/`. If you're writing a view that exists in one target, check the other target first.
- **Forward-compatible decoding.** `ServerMessage` has `.unknown(type:)`. Unknown server types are logged and skipped.

## Style

- No emojis in commits or code
- Keep answers short and concise
- Technical prose, direct

## Tool Usage

- Always read a file in full before editing it
- Never use `sed`/`cat` to read files — use the read tool

## Definition of Done

A task is done when:
1. `npm run check` passes (server) and/or `sim-pool.sh run -- xcodebuild ... build` + `test -only-testing:OppiTests` pass (Apple)
2. Protocol changes are mirrored on both sides with tests
3. `xcodegen generate` was run if Apple client file structure changed
