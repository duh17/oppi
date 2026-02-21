# Oppi — Agent Guide

Oppi monorepo — iOS app + self-hosted server for mobile-supervised [pi](https://github.com/badlogic/pi-mono) sessions.

## First Message

If no concrete task given, read this file and `README.md`, then ask what to work on.
For context on specific areas, read the relevant README:
- Root: `README.md` 
- Server: `server/README.md`

## Structure

```
ios/           iOS app (SwiftUI + UIKit, iOS 26+)
server/        Server runtime (Node.js/TypeScript)
```

## Commands

```bash
# Server
cd server && npm install
cd server && npm test
cd server && npm run build
cd server && npm run check    # typecheck + lint + format — fix ALL errors before committing
cd server && npm start

# iOS
cd ios && xcodegen generate
cd ios && xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test

# iOS device deploy (ALWAYS use this script — never call devicectl directly)
# Auto-discovers first connected paired iPhone. Pass -d <name|udid> to override.
cd ios && bash scripts/build-install.sh --launch
```

After code changes: run `npm run check` (server) or `xcodebuild build` + `test` (iOS). Get full output. Fix all errors, warnings, and infos before committing.

See [`docs/testing/`](docs/testing/) for full test strategy, pyramid, and required gates by change type.

The Xcode project file is generated — never edit `Oppi.xcodeproj` directly. Change `project.yml` and run `xcodegen generate`.

## Git Rules

- **ONLY commit files YOU changed in THIS session**
- ALWAYS use `git add <specific-file-paths>` — list only files you modified
- Before committing, run `git status` and verify you are only staging your files
- NEVER commit unless user asks
- Always ask before removing functionality that appears intentional

### Forbidden Operations
- `git add -A` / `git add .` — stages everything, including other agents' work
- `git reset --hard` — destroys uncommitted changes
- `git checkout .` — destroys uncommitted changes
- `git clean -fd` — deletes untracked files
- `git stash` — stashes ALL changes
- `git push --force`
- `xcrun devicectl device uninstall` — never uninstall the iOS app
- Raw `devicectl device install` — use `ios/scripts/build-install.sh` instead

### GitHub Issues
```bash
gh issue view <number> --json title,body,comments,labels,state
```
When closing via commit: include `fixes #<number>` or `closes #<number>`.

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

### Swift (iOS)
- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All `@Observable` classes must be `@MainActor`
- Prefer `if let x` over `if let x = x`
- No force unwraps in production code
- Liquid Glass for navigation chrome only. Never for scrollable content.

## iOS Architecture

**Event pipeline (core data flow):**
```
ServerMessage (WebSocket)
  → ServerConnection.handleServerMessage()
  → DeltaCoalescer (batches text/thinking at 33ms)
  → TimelineReducer (state machine → [ChatItem])
  → ChatTimelineCollectionView (UIKit)
```

**Observable stores:** `SessionStore`, `WorkspaceStore`, `PermissionStore`, `TimelineReducer`, `ToolOutputStore`, `ToolArgsStore` — separate `@Observable` objects to prevent cross-store re-renders.

**ServerConnection** is the top-level coordinator per server. Owns API client, WebSocket, all stores, event pipeline. Multi-server via `ConnectionCoordinator`.

**Forward-compatible decoding.** `ServerMessage` has `.unknown(type:)`. Unknown server types are logged and skipped.

## Server Navigation

- `src/types.ts` — client/server protocol contract
- `src/server.ts` — app wiring and runtime startup
- `src/policy.ts` + `config/policy-modes/` — policy engine + presets

## Style

- No emojis in commits or code
- Keep answers short and concise
- Technical prose, direct

## Tool Usage

- Always read a file in full before editing it
- Never use `sed`/`cat` to read files — use the read tool

## Definition of Done

A task is done when:
1. `npm run check` passes (server) and/or `xcodebuild build` + `test` pass (iOS)
2. Protocol changes are mirrored on both sides with tests
3. `xcodegen generate` was run if iOS file structure changed
