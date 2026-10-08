# Oppi - Agent Guide

Oppi brings [Pi](https://github.com/badlogic/pi-mono) coding sessions to iPhone, iPad, and Mac through a server you run yourself.

## Rules

- Inspect the affected code and contracts; expand the search when dependencies require it.
- Avoid unrequested compatibility layers. Explain breaking impacts and confirm surprises outside the agreed scope.
- Use a small function or local type instead of a new layer. Keep important context in comments next to the code.
- Architecture boundaries: `dev/architecture.md`, with server/client details in `dev/architecture-server.md` and `dev/architecture-client.md`. Consult the affected boundary; `server/scripts/check-architecture-boundaries.ts` (`--scope server|ios|mac`) and ESLint enforce it.
- Do not change the Mac app for a feature unless the request explicitly names Mac, macOS, desktop, or OppiMac. Mac is outside feature-implementation scope. Shared code that iOS uses, and that Mac may use later, belongs in `OppiCore`. Do not add Mac UI, Mac tests, or a Mac release only because `OppiCore` changed.
- Protocol changes follow the "Protocol boundary" checklist in `dev/architecture-server.md`: keep affected server types, Apple models, snapshots, and tests on both sides aligned. Ordinary tests must not rewrite tracked fixtures; regenerate deliberately.
- Generic extension UI must work for every extension. Read display behavior from protocol metadata; never branch on specific tool, extension, status, widget, or display names.
- iOS agent-facing controls keep native accessibility semantics: stable scoped identifiers, the same owner action for touch and accessibility activation, and reset semantics on reuse. See `dev/testing/ios-accessibility-testability.md`.
- Keep agentic-loop evidence inspectable: claims, continuation decisions, blockers, and their reasons. Do not hide or over-truncate that output.
- Store files by purpose:
  - `.internal/` lasting private work (reports, research, diagrams)
  - `.pi/` session state, todos, attachments, prompts, worktrees, temporary caches
  - `docs/` public documentation (daily use and extension authoring only)
  - `dev/` contributor architecture, leftover transport notes, telemetry, testing docs
- Keep unrelated changes from other sessions. If overlapping edits cannot be separated safely, stop and ask.
- Commit and push only with authority. Stage only this session's paths or hunks unless asked for more; never `git add .` or `git add -A`.

## Build and Test Rules

- `Oppi.xcodeproj` is generated. Edit `project.yml`, put plist keys under `info.properties`, and run `xcodegen generate`.
- Use `dev/testing/README.md` for commands, schemes, and Swift Testing filters. Run the smallest documented check that proves the change; record video only for UI appearance, animation, or interaction.
- Simulator builds use `clients/apple/scripts/sim-pool.sh`; bare `xcodebuild` needs a unique `-derivedDataPath`. Preserve the runner's summary and log paths. On failure or a stall, inspect the log and active build processes before retrying.
