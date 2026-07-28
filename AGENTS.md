# Oppi - Agent Guide

Oppi is an iPhone/iPad app and a server you run yourself for [Pi](https://github.com/badlogic/pi-mono) coding sessions. It brings Pi's transparent, customizable sessions to iOS.

## Rules

- Read files in full before editing code or proposing solutions. Do not rely on search snippets for broad changes.
- Ban the word `legacy`. Don't add backward-compatibility layers unless I ask. Tell me when a change may break compatibility; if I may not know about that break, ask before proceeding.
- Don't add a new layer when a small function or local type will do.
- Keep important context in comments next to the code.
- Before changing server or Apple client structure, network connections, state stores, or extension UI, read `docs/architecture.md` and the relevant split page (`docs/architecture-server.md`, `docs/architecture-client.md`). The rules there are checked by `server/scripts/check-architecture-boundaries.ts` and local ESLint rules.
- Protocol changes must update `server/src/types/protocol.ts`, the matching Apple models in `clients/apple/OppiCore/Models/`, and the `protocol/*.json` snapshots together, with tests on both sides. Updating only some of these is not valid. See "Protocol boundary" in `docs/architecture-server.md` for the checklist.
- Generic extension UI code must work for any extension. Don't check specific tool, extension, status, widget, or display names; use the meaning provided by protocol metadata instead.
- Put lasting private work files in `.internal/` (`reports/`, `research/`, `diagrams/`). Use `.pi/` for session state and reusable agent files such as todos, attachments, prompts, worktrees, and temporary caches. Use `docs/` for public docs.
- Keep unrelated changes from other sessions. If overlapping edits cannot be separated safely, stop and ask the user.
- Don't commit unless asked. Stage only paths or hunks changed in this session unless the user asks for more; never use `git add .` or `git add -A`.
- After a commit and passing local checks (`server npm run check` + relevant tests), ask before pushing. Prefer one push per finished change instead of multi-day batches; small pushes make CI failures easier to find.

### TypeScript

- Avoid `any` unless there is no reasonable alternative.
- Check installed type definitions before guessing external API shapes.
- Check outside input when it enters the system. Log failures clearly and return predictable errors.

### Swift

- Swift 6 strict concurrency is on.
- All `@Observable` classes must use `@MainActor`.
- Prefer `if let x` over `if let x = x`.
- Don't force-unwrap values in production code.

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Change `project.yml`, put plist keys under `info.properties`, and run `xcodegen generate`.
- Always use the repository-owned `clients/apple/scripts/sim-pool.sh` for simulator builds and tests. Do not run bare `xcodebuild` unless you also set a unique `-derivedDataPath`; see `docs/testing/README.md`.
- Use normal `sim-pool.sh` runs without video for builds, unit tests, and changes that don't affect the UI, such as networking or backend logic. Use `oppi_simulator_recording` only when a recording helps check the UI, animation, or interaction.
- Do not pipe `sim-pool.sh` output through `grep`, `tail`, or `head`. Read the summary and inspect the printed log path.
- If an Apple build fails or seems stuck, read the `sim-pool.sh` log and check for active `xcodebuild` or sim-pool processes before trying again.
- Use `-scheme OppiUnitTests` for `OppiTests`. The full `Oppi` scheme also builds UI, E2E, and perf bundles.
- With Swift Testing, `xcodebuild -only-testing` removes one trailing `()`. Use double parentheses for function-level filters:
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
cd clients/apple && ./scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
cd clients/apple && ./scripts/sim-pool.sh \
  run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
```
