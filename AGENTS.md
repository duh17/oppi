# Oppi — Agent Guide

Oppi is a monorepo for the Apple clients and self-hosted server behind mobile-supervised [pi](https://github.com/badlogic/pi-mono) sessions.

The Apple clients need to keep pi sessions observable, steerable, and safe from a phone or Mac.

For simulator/device loops, release workflows, incident triage, telemetry, config checks, and other operational runbooks, load the `oppi-dev` skill.

## Structure

```text
clients/apple/  Apple clients (iOS + macOS)
server/         Server runtime (TypeScript, Node.js 22+)
```

## Architecture Map

- `server/src/types.ts` defines the client/server protocol unions.
- `server/src/session-*.ts` owns session lifecycle, input, queueing, broadcasts, turns, state, summaries, and UI event shaping.
- `server/src/policy-*.ts` owns command policy, approvals, allowlists, and bash/git heuristics.
- `server/src/routes/workspaces.ts` owns workspace CRUD plus workspace-home summaries.
- `server/src/routes/sessions.ts` owns focused-session REST plus unified workspace session-list, archive bucket, attention, and local-session import APIs.
- `server/src/storage/session-sqlite-store.ts` owns the SQLite read model for recent session snapshots, workspace summaries, and stopped-history buckets.
- `server/src/local-sessions.ts` owns the cached importable TUI session catalog; hot paths must use the catalog, not reread JSONL files.
- `clients/apple/Oppi/Core/Models/ClientMessage.swift` and `ServerMessage.swift` mirror the wire protocol.
- `clients/apple/Oppi/Core/Networking` owns focused-session WebSocket, audio stream, HTTP refresh, and server-message effects.
- `clients/apple/Oppi/Core/Services/SessionStore.swift` owns full session state plus the cold list projection and authoritative workspace snapshot merge rules.
- `clients/apple/Oppi/Features/Workspaces/WorkspaceHomeView.swift` and `WorkspaceDetailView.swift` own the HTTP-first workspace navigation path.
- `clients/apple/Oppi/Features/Chat/Timeline` owns iOS chat timeline rendering and scroll anchoring.
- `clients/apple/Shared/Renderers` contains reusable Mermaid, LaTeX, and Org renderers.
- `clients/apple/OppiMac` owns the macOS client shell and Mac-specific server integration.

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

## Sharp Edges

- `Oppi.xcodeproj` is generated. Do not repair build issues by editing it directly.
- Simulator logs are part of the signal. Do not pipe `sim-pool.sh` through filters that hide the summary or log path.
- Swift 6 strict concurrency is enabled. UI-observable state must stay main-actor isolated.
- Unknown server messages must be logged and skipped, not treated as fatal decode failures.
- Server and Apple protocol updates are one change. Do not land one side without the other.
- Do not reintroduce workspace-scoped WebSocket list fanout for normal navigation without proving it beats the current HTTP snapshot path.
- Do not read `~/.pi/agent/sessions/*.jsonl` on workspace navigation hot paths; use the local-session catalog and SQLite projections.
- Keep repo-private working artifacts in `.pi/` (`reports/`, `research/`, `diagrams/`). Reserve `docs/` for curated public docs.

## Complexity Guardrails

- Before adding code, search for existing implementations, helpers, and type names.
- Prefer extending an existing file over adding another sibling when a directory already has many similarly named files.
- Do not add a new abstraction when a small function or local type will do.

## Protocol Discipline

Protocol changes must stay forward-compatible and mirrored across server and Apple models.

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

The chat timeline is a hot path: streaming text, tool output, approvals, diffs, and lifecycle events must render without scroll jumps or excessive SwiftUI invalidation.

For hot paths such as the chat timeline, streaming rendering, and scroll containers, use the lowest-level stable native API Apple provides rather than the highest-level abstraction.

Do not wrap performance-critical rendering in SwiftUI when UIKit or AppKit gives direct control over layout, diffing, and scroll position.

### Boundary

- UIKit or AppKit owns content rendering chrome.
- SwiftUI owns navigation shells and forms.
- Do not duplicate logic across frameworks.

Run `bash clients/apple/scripts/check-duplication.sh` before finishing Apple UI changes.

### Shared structure

Workspace navigation is HTTP-first and time-bounded: workspace home uses summary snapshots, workspace detail uses a recent session-list window plus lazy archive buckets, and hot paths must stay off raw JSONL reads.

- Many small stores are intentional. Do not merge them to “simplify” the architecture.
- Prefer the narrowest dependency that works.
- Share models, networking, stores, reducers, and helpers in `Shared/`.
- Share views when they are pure SwiftUI. Fork views when rendering is platform-specific.
- `ServerMessage` decoding is forward-compatible. Unknown server message types must be logged and skipped.

## When Ambiguous

1. Search for an existing implementation, test, helper, or naming pattern first.
2. Follow the local pattern unless it conflicts with this guide or the user asked for a redesign.
3. Keep diffs minimal when fixing bugs. Save broad refactors for explicit refactor tasks.
4. If a protocol, rendering, or session-lifecycle change has multiple plausible designs, present options and pick the safest default before coding.
5. Do not remove behavior that looks intentional without asking or proving it is dead.

## Style

- No emojis in commits or code.
- Keep technical prose direct.

## Verification Checklist

- Server-only changes: run `cd server && npm run check`.
- Server tests: run the relevant `npm test` target or focused test file when behavior changes.
- Coverage/release gates: follow `docs/testing/README.md` and the `oppi-dev` skill; do not invent ad hoc coverage commands.
- Apple file structure changes: run `cd clients/apple && xcodegen generate`.
- Apple code changes: run the relevant `sim-pool.sh` build or targeted test from the Core Commands section.
- Apple UI or rendering changes: also run `bash clients/apple/scripts/check-duplication.sh`.
- Protocol changes: update server types, Apple models, and protocol tests on both sides before finishing.

Fix all errors before handing work back. If a check cannot run, say exactly why and name the next best validation.
