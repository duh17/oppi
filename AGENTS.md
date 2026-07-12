# Oppi - Agent Guide

Oppi is an iPhone/iPad client and self-hosted server for [Pi](https://github.com/badlogic/pi-mono) coding agent sessions. The goal is to bring Pi's transparency and extensibility to native iOS.

## Rules

- Read files in full before editing code or proposing solutions. Do not rely on search snippets for broad changes.
- Do not default to backward compatibility or add the prefix "legacy". If a change may break behavior, ask first.
- Do not add a new abstraction when a small function or local type will do.
- Keep contextual knowledge in comments close to the code.
- Before changing server or Apple client structure, transports, stores, or extension UI surfaces, read `docs/architecture.md` and the relevant split page (`docs/architecture-server.md`, `docs/architecture-client.md`). The boundary rules there are enforced by `server/scripts/check-architecture-boundaries.ts` and ESLint local rules.
- Protocol changes must update `server/src/types/protocol.ts`, the Apple mirrors in `clients/apple/OppiCore/Models/`, and `protocol/*.json` snapshots together, with tests on both sides; partial updates are invalid. See "Protocol boundary" in `docs/architecture-server.md` for the checklist.
- Extension UI translation, dedupe, and rendering must stay extension-agnostic. Never branch on concrete tool, extension, status, widget, or display names in generic extension-surface code; add or consume semantic protocol metadata instead.
- Keep durable repo-private working artifacts in `.internal/` (`reports/`, `research/`, `diagrams/`). Keep `.pi/` for runtime/session state and reusable local agent inputs such as todos, attachments, prompts, worktrees, and temporary caches. Reserve `docs/` for curated public docs.
- Preserve unrelated changes from other sessions. If overlapping edits cannot be safely separated, stop and ask the user.
- Do not commit unless explicitly asked. Stage only paths/hunks changed in this session unless the user explicitly asks for broader scope; never use `git add .` or `git add -A`.

### TypeScript

- Avoid `any` unless there is no reasonable alternative.
- Check installed type definitions before guessing external API shapes.
- Validate external input at boundaries and keep failures observable with structured logs and deterministic errors.

### Swift

- Swift 6 strict concurrency is on.
- All `@Observable` classes must be `@MainActor`.
- Prefer `if let x` over `if let x = x`.
- No force unwraps in production code.

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Change `project.yml`, put plist keys under `info.properties`, and run `xcodegen generate`.
- Always use `sim-pool.sh` for simulator builds and tests. Do not run bare `xcodebuild` unless you also set a unique `-derivedDataPath`. The pool wrapper is a maintainer-local skill; when unavailable, the public fallback is a unique `-derivedDataPath` per `docs/testing/README.md`.
- Do not pipe `sim-pool.sh` output through `grep`, `tail`, or `head`. Read the summary and inspect the printed log path.
- Investigate Apple build failures or apparent hangs by reading the `sim-pool.sh` log path and checking for active `xcodebuild`/sim-pool processes before rerunning.
- Use `-scheme OppiUnitTests` for `OppiTests`. The full `Oppi` scheme also builds UI, E2E, and perf bundles.
- With Swift Testing, `xcodebuild -only-testing` strips one trailing `()`. Use double parentheses for function-level filters:
  - Suite: `-only-testing:OppiTests/MySuiteStruct`
  - Function: `-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'`
- Use `docs/testing/README.md` for server, Apple, simulator, E2E, coverage, and test-gate commands. Run the smallest documented check that proves the change.

### Commands

```bash
# Server
cd server && npm test
cd server && npm run check
cd server && npm run test:gate:pr-fast

# Apple
cd clients/apple && xcodegen generate
cd clients/apple && bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
cd clients/apple && bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
```
