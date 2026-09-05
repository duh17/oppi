# Oppi - Agent Guide

Oppi brings [Pi](https://github.com/badlogic/pi-mono) coding sessions to iPhone, iPad, and Mac through a server you run yourself.

## Rules

- Inspect the affected code and contracts; expand the search when dependencies require it.
- Avoid unrequested compatibility layers. Explain breaking impacts and confirm surprises outside the agreed scope.
- Use a small function or local type instead of a new layer. Keep important context in comments next to the code.
- Architecture boundaries: `dev/architecture.md`, with server/client details in `dev/architecture-server.md` and `dev/architecture-client.md`. Consult the affected boundary; `server/scripts/check-architecture-boundaries.ts` (`--scope server|ios|mac`) and ESLint enforce it.
- Include Mac (`OppiMac`) when work names Mac, macOS, desktop, or OppiMac, or changes `OppiCore` or other shared Apple code. `OppiCore` changes need relevant proof on both Apple clients. Canonical Mac validation is `dev/testing/README.md`; do not duplicate its commands here.
- Protocol changes follow the "Protocol boundary" checklist in `dev/architecture-server.md`: keep affected server types, Apple models, snapshots, and tests on both sides aligned. Ordinary tests must not rewrite tracked fixtures; regenerate deliberately.
- Generic extension UI must work for every extension. Read display behavior from protocol metadata; never branch on specific tool, extension, status, widget, or display names.
- Keep agentic-loop evidence inspectable: goal evaluations, claims, continuation decisions, blockers, and their reasons. Do not hide or over-truncate that output.
- Store files by purpose:
  - `.internal/` lasting private work (reports, research, diagrams)
  - `.pi/` session state, todos, attachments, prompts, worktrees, temporary caches
  - `docs/` public documentation (daily use and extension authoring only)
  - `dev/` contributor architecture, leftover transport notes, telemetry, testing docs
- Keep unrelated changes from other sessions. If overlapping edits cannot be separated safely, stop and ask.
- Commit and push only with authority. Stage only this session's paths or hunks unless asked for more; never `git add .` or `git add -A`.

### TypeScript

- Use `any` only when no reasonable typed alternative exists.
- Check installed type definitions before guessing external API shapes.
- Validate external input at the system boundary. Log failures clearly and return predictable errors.

### Swift

- Swift 6 strict concurrency is on. All `@Observable` classes must use `@MainActor`.
- Prefer `if let x` over `if let x = x`. Handle optionals safely in production code; never force-unwrap them.

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Edit `project.yml`, put plist keys under `info.properties`, and run `xcodegen generate`.
- Use `dev/testing/README.md` for commands, schemes, and Swift Testing filters. Run the smallest documented check that proves the change; record video only for UI appearance, animation, or interaction.
- Simulator builds use `clients/apple/scripts/sim-pool.sh`; bare `xcodebuild` needs a unique `-derivedDataPath`. Preserve the runner's summary and log paths. On failure or a stall, inspect the log and active build processes before retrying.

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
