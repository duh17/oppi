# Oppi - Agent Guide

Oppi brings [Pi](https://github.com/badlogic/pi-mono) coding sessions to iPhone, iPad, and Mac through a server you run yourself.

## Rules

- Read files in full before editing code or proposing solutions. Do not rely on search snippets for broad changes.
- Do not use the word `legacy`. Add compatibility layers only when asked. Before making a breaking change, explain what may stop working. Ask first when the impact might surprise the user.
- Use a small function or local type instead of a new layer. Keep important context in comments next to the code.
- Before changing server or Apple client structure, network connections, state stores, or extension UI, read `dev/architecture.md`, then `dev/architecture-server.md` or `dev/architecture-client.md`. `server/scripts/check-architecture-boundaries.ts` (`--scope server`, `--scope ios`, `--scope mac`) and local ESLint rules enforce these boundaries.
- Include Mac (`OppiMac`) when work names Mac, macOS, desktop, or OppiMac, or changes `OppiCore` or other shared Apple code. `OppiCore` changes need relevant proof on both Apple clients. Canonical Mac validation is `dev/testing/README.md`; do not duplicate its commands here.
- Protocol changes: follow the "Protocol boundary" checklist in `dev/architecture-server.md`. Update these files and add tests on both sides:
  - `server/src/types/protocol.ts`
  - matching Apple models in `clients/apple/OppiCore/Models/`
  - directly decoded server type modules required by the changed fixture (for this bundle, `server/src/types/session.ts`, `server/src/types/icon.ts`, `server/src/types/git.ts`, `server/src/types/shared.ts`, and `server/src/thinking-levels.ts`; do not mechanically include every `server/src/types/*` file)
  - the `protocol/*.json` snapshots
  - ordinary protocol tests, which compare canonical bytes without writing tracked fixtures
  - the explicit `cd server && npm run protocol:fixtures:update` command when regeneration is intended
- Generic extension UI must work for every extension. Read display behavior from protocol metadata; never branch on specific tool, extension, status, widget, or display names.
- Keep agentic-loop evidence inspectable: goal evaluations, claims, continuation decisions, blockers, and their reasons. Do not hide or over-truncate that output.
- Store files by purpose:
  - `.internal/` lasting private work (reports, research, diagrams)
  - `.pi/` session state, todos, attachments, prompts, worktrees, temporary caches
  - `docs/` public documentation (daily use and extension authoring only)
  - `dev/` contributor architecture, leftover transport notes, telemetry, testing docs
- Keep unrelated changes from other sessions. If overlapping edits cannot be separated safely, stop and ask.
- Commit only with authority from the current request. An explicitly agreed end-to-end delivery request includes scoped local commit and ff-only landing after required validation and review; an ordinary fix request does not. Stage only paths or hunks changed in this session unless the user asks for more. Never `git add .` or `git add -A`. After committing, run `npm run check` in `server/` and the relevant tests, then ask before pushing. Prefer one push per finished change; small pushes make CI failures easier to find.

### TypeScript

- Use `any` only when no reasonable typed alternative exists.
- Check installed type definitions before guessing external API shapes.
- Validate external input at the system boundary. Log failures clearly and return predictable errors.

### Swift

- Swift 6 strict concurrency is on. All `@Observable` classes must use `@MainActor`.
- Prefer `if let x` over `if let x = x`. Handle optionals safely in production code; never force-unwrap them.

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Edit `project.yml`, put plist keys under `info.properties`, and run `xcodegen generate`.
- Run simulator builds and tests through `clients/apple/scripts/sim-pool.sh`. Bare `xcodebuild` needs a unique `-derivedDataPath`. No video for builds, unit tests, or networking/backend changes; use `oppi_simulator_recording` only for UI appearance, animation, or interaction. Read the `sim-pool.sh` summary and printed log path; do not pipe it through `grep`, `tail`, or `head`. If an Apple build fails or stalls, read that log and check for active `xcodebuild` or sim-pool processes before retrying.
- Use `-scheme OppiUnitTests` for `OppiTests`. The full `Oppi` scheme also builds UI, E2E, and performance bundles.
- Swift Testing removes one trailing `()` from `xcodebuild -only-testing` filters. Use double parentheses for a function:
  - Suite: `-only-testing:OppiTests/MySuiteStruct`
  - Function: `-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'`
- Use `dev/testing/README.md` for server, Apple, E2E, coverage, and test-gate commands. Run the smallest documented check that proves the change.

## Cursor Cloud specific instructions

Cloud Agent VM is Linux: only `server/` runs here; Apple clients need macOS and Xcode. Server requires Node 24+ (`engines.node >=24`). `node`, `npm`, `npx`, and `bun` already resolve correctly in every shell (Node 24 shadows the platform Node 22 shim), so plain `node`/`npm` and built `oppi` CLI need no source step.

Two injected settings break the suite unless cleared per invocation:

- `NO_COLOR=1` / `TERM=dumb` disable ANSI, so CLI tests that assert on color escapes fail.
- Managed git `commit.gpgsign=true` with an SSH signer can stall 20+ seconds, so git-heavy tests (worktrees, workspace git diff) miss the 10s timeout.

Run checks and tests like this (leaves the managed git config untouched for your signed commits):

```bash
cd server
env -u NO_COLOR -u FORCE_COLOR GIT_CONFIG_GLOBAL=/dev/null npm run check
env -u NO_COLOR -u FORCE_COLOR GIT_CONFIG_GLOBAL=/dev/null npm test
```
