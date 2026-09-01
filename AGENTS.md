# Oppi - Agent Guide

Oppi brings [Pi](https://github.com/badlogic/pi-mono) coding sessions to iPhone, iPad, and Mac through a server you run yourself.

## Rules

- Read files in full before editing code or proposing solutions. Do not rely on search snippets for broad changes.
- Do not use the word `legacy`. Add compatibility layers only when asked. Before making a breaking change, explain what may stop working. Ask first when the impact might surprise the user.
- Use a small function or local type instead of adding a new layer.
- Keep important context in comments next to the code.
- Before changing server or Apple client structure, network connections, state stores, or extension UI, read `dev/architecture.md`. Then read the relevant split page: `dev/architecture-server.md` or `dev/architecture-client.md`. `server/scripts/check-architecture-boundaries.ts` (`--scope server`, `--scope ios`, `--scope mac`) and local ESLint rules enforce these boundaries.
- Mac is an Apple client target (`OppiMac`). Include it when the work names Mac, macOS, desktop, or OppiMac, or when it changes `OppiCore` or other shared Apple code.
- `OppiCore` changes need relevant proof on both Apple clients. Canonical Mac validation is `dev/testing/README.md`; do not duplicate those commands here.
- For protocol changes, follow the "Protocol boundary" checklist in `dev/architecture-server.md`. Update these files and add tests on both sides:
  - `server/src/types/protocol.ts`
  - the matching Apple models in `clients/apple/OppiCore/Models/`
  - directly decoded server type modules required by the changed fixture (for this bundle, `server/src/types/session.ts`, `server/src/types/icon.ts`, `server/src/types/git.ts`, `server/src/types/shared.ts`, and `server/src/thinking-levels.ts`; do not mechanically include every `server/src/types/*` file)
  - the `protocol/*.json` snapshots
  - ordinary protocol tests, which compare canonical bytes without writing tracked fixtures
  - the explicit `cd server && npm run protocol:fixtures:update` command when regeneration is intended
- Generic extension UI must work for every extension. Read display behavior from protocol metadata; never branch on specific tool, extension, status, widget, or display names.
- Keep agentic-loop evidence inspectable: goal evaluations, claims, continuation decisions, blockers, and their reasons. Do not hide or over-truncate that output.
- Store files by purpose:
  - `.internal/` for lasting private work such as reports, research, and diagrams
  - `.pi/` for session state, todos, attachments, prompts, worktrees, and temporary caches
  - `docs/` for public documentation (daily use and extension authoring only)
  - `dev/` for contributor architecture, leftover transport notes, telemetry, and testing docs
- Keep unrelated changes from other sessions. If you cannot separate overlapping edits safely, stop and ask the user.
- Commit only when asked. Stage only paths or hunks changed in this session unless the user asks for more. Never use `git add .` or `git add -A`.
- After committing, run `npm run check` in `server/` and the relevant tests, then ask before pushing. Prefer one push per finished change; small pushes make CI failures easier to find.

### TypeScript

- Use `any` only when no reasonable typed alternative exists.
- Check installed type definitions before guessing external API shapes.
- Validate external input at the system boundary. Log failures clearly and return predictable errors.

### Swift

- Swift 6 strict concurrency is on.
- All `@Observable` classes must use `@MainActor`.
- Prefer `if let x` over `if let x = x`.
- Handle optionals safely in production code; never force-unwrap them.

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Edit `project.yml`, put plist keys under `info.properties`, and run `xcodegen generate`.
- Run simulator builds and tests through `clients/apple/scripts/sim-pool.sh`. Bare `xcodebuild` requires a unique `-derivedDataPath`; see `dev/testing/README.md`.
- Use normal `sim-pool.sh` runs without video for builds, unit tests, and changes to networking or backend logic. Use `oppi_simulator_recording` only when a recording helps check UI appearance, animation, or interaction.
- Read the `sim-pool.sh` summary and its printed log path. Do not pipe its output through `grep`, `tail`, or `head`.
- If an Apple build fails or stalls, read the `sim-pool.sh` log and check for active `xcodebuild` or sim-pool processes before trying again.
- Use `-scheme OppiUnitTests` for `OppiTests`. The full `Oppi` scheme also builds UI, E2E, and performance bundles.
- Swift Testing removes one trailing `()` from `xcodebuild -only-testing` filters. Use double parentheses for a function:
  - Suite: `-only-testing:OppiTests/MySuiteStruct`
  - Function: `-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'`
- Use `dev/testing/README.md` for server, Apple, simulator, E2E, coverage, and test-gate commands. Run the smallest documented check that proves the change.

### Commands

```bash
# Server
cd server && npm test
cd server && npm run check
cd server && npm run test:gate:pr-fast

# Apple
cd clients/apple && xcodegen generate
./scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme Oppi build
./scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
```

## Cursor Cloud specific instructions

The Cloud Agent VM is Linux, so only the `server/` workspace runs here; the Apple client needs macOS and Xcode. The server requires Node 24+ (`engines.node >=24`). The environment makes `node`, `npm`, `npx`, and `bun` resolve to the correct versions in every shell (Node 24 shadows the platform's Node 22 shim), so plain `node`/`npm` commands and the built `oppi` CLI work without sourcing anything.

Two platform-injected settings make the server suite fail unless neutralized per invocation:

- `NO_COLOR=1` / `TERM=dumb` disable ANSI output, breaking CLI tests that assert on color escapes.
- The managed global git config forces `commit.gpgsign=true` with an SSH signer that intermittently stalls for 20+ seconds, so git-heavy tests (worktrees, workspace git diff) exceed the 10s test timeout.

Run the server checks and tests like this (leaves the managed git config untouched for your own signed commits):

```bash
cd server
env -u NO_COLOR -u FORCE_COLOR GIT_CONFIG_GLOBAL=/dev/null npm run check
env -u NO_COLOR -u FORCE_COLOR GIT_CONFIG_GLOBAL=/dev/null npm test
```
