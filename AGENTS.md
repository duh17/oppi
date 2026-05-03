# Oppi — Agent Guide

Oppi is a monorepo for the Apple clients and self-hosted server behind mobile-supervised [pi](https://github.com/badlogic/pi-mono) sessions.

For simulator/device loops, release workflows, incident triage, telemetry, config checks, and other operational runbooks, load the `oppi-dev` skill.

## Structure

```text
clients/apple/  Apple clients (iOS + macOS)
server/         Server runtime (TypeScript, Node.js 22+)
```

## Core Commands

```bash
# Server
cd server && npm install
cd server && npm test
cd server && npm run check
cd server && npm start

# Apple
cd clients/apple && xcodegen generate
cd clients/apple && bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
cd clients/apple && bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
```

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Never edit it directly. Change `project.yml` and run `xcodegen generate`.
- XcodeGen overwrites generated plist content. Put plist keys in `project.yml` under `info.properties`.
- Always use `sim-pool.sh` for simulator builds and tests. Do not run bare `xcodebuild` unless you also set a unique `-derivedDataPath`.
- Do not pipe `sim-pool.sh` output through `grep`, `tail`, or `head`. Read the summary and inspect the printed log path.
- Investigate Apple build failures by reading the log path from `sim-pool.sh`, not by blindly rerunning.
- Use `-scheme OppiUnitTests` for `OppiTests`. The full `Oppi` scheme also builds UI, E2E, and perf bundles.
- With Swift Testing, `xcodebuild -only-testing` strips one trailing `()`. Use double parentheses for function-level filters:
  - Suite: `-only-testing:OppiTests/MySuiteStruct`
  - Function: `-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'`

After code changes, run the relevant checks and fix all errors before finishing.

## Complexity Guardrails

- Before adding code, search for existing implementations, helpers, and type names.
- Prefer extending an existing file over adding another sibling when a directory already has many similarly named files.
- Do not add a new abstraction when a small function or local type will do.

## Protocol Discipline

When changing client/server message contracts:

1. Update server types in `server/src/types.ts`
2. Update Apple models such as `ServerMessage.swift` and `ClientMessage.swift`
3. Update protocol tests on both sides

No partial protocol updates.

## Code Quality

### TypeScript

- Avoid `any` unless there is no reasonable alternative.
- Check installed type definitions before guessing external API shapes.
- Validate at boundaries. Parse external input before internal use.
- Keep behavior observable with structured logs and deterministic error messages.
- Do not add a coordinator class for small logic that fits in a function.
- Do not add a `Deps` interface for a single dependency.
- Do not use `as SomeType` casts in session coordinator wiring when narrowing the signature would solve it.

### Swift

- Swift 6 strict concurrency is on.
- All `@Observable` classes must be `@MainActor`.
- Prefer `if let x` over `if let x = x`.
- No force unwraps in production code.
- Liquid Glass is for navigation chrome only, never scrollable content.

### Testing

- Use Swift Testing for unit tests: `import Testing`, `@Test`, `#expect`.
- Use XCTest only for UI tests that require `XCUIApplication`.
- Group related tests with `@Suite`.
- Put `@MainActor` on the suite when all tests need main actor isolation.
- Use `Issue.record()` instead of `XCTFail()`.

## Apple Architecture

### Hot paths

For hot paths such as the chat timeline, streaming rendering, and scroll containers, use the lowest-level stable native API Apple provides rather than the highest-level abstraction.

Do not wrap performance-critical rendering in SwiftUI when UIKit or AppKit gives direct control over layout, diffing, and scroll position.

### Boundary

- UIKit or AppKit owns content rendering chrome.
- SwiftUI owns navigation shells and forms.
- Do not duplicate logic across frameworks.

Run `bash clients/apple/scripts/check-duplication.sh` before finishing Apple UI changes.

### Shared structure

- Many small stores are intentional. Do not merge them to “simplify” the architecture.
- Prefer the narrowest dependency that works.
- Share models, networking, stores, reducers, and helpers in `Shared/`.
- Share views when they are pure SwiftUI. Fork views when rendering is platform-specific.
- `ServerMessage` decoding is forward-compatible. Unknown server message types must be logged and skipped.

- Keep repo-private working artifacts in `.pi/` (`reports/`, `research/`, `diagrams/`) and reserve `docs/` for curated public docs.

## Style

- No emojis in commits or code.
- Keep technical prose direct.

## Definition of Done

1. `npm run check` passes for server changes
2. Apple build and relevant tests pass for Apple changes
3. Protocol changes are mirrored on both sides with tests
4. `xcodegen generate` was run if Apple file structure changed
