# Oppi — Agent Principles

Monorepo for the Oppi mobile-supervised coding agent platform.

## Structure

```
ios/        iOS app (SwiftUI, iOS 26+)
server/     Server runtime (Node.js/TypeScript)
skills/     Agent skills (oppi-dev)
```

## Working Model

- iOS app: see `ios/AGENTS.md`
- Server: see `server/AGENTS.md`
- If no concrete task given, ask what to work on.

## Protocol Discipline

When changing client/server message contracts:
1. Update server types in `server/src/types.ts`
2. Update iOS models (`ServerMessage.swift`, `ClientMessage.swift`)
3. Update protocol tests on both sides

No partial protocol updates.

## Change Discipline

- Do not remove intentional behavior without confirming.
- Prefer backward-compatible changes.
- Keep changes scoped; avoid opportunistic refactors unless requested.
- Surface risks, trade-offs, and verification steps clearly.

## Testing Expectations

- For user-reported bugs, prefer adding a regression test with the fix.
- If a regression test is trivial and low-risk, include it in the same change.
- If not practical, document why and provide manual verification steps.

## Commands

```bash
# iOS
cd ios && xcodegen generate
cd ios && xcodebuild -scheme Oppi build
cd ios && xcodebuild -scheme Oppi test
ios/scripts/build-install.sh --launch --device 00000000-0000-0000-0000-000000000000

# Server
cd server && npm test
cd server && npm start
```

## Git / Commit Rules

- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
- Keep subject under 72 chars
- Never `git add .` / `git add -A`
- Never destructive reset/clean/stash shortcuts
- Never commit unless user asks
- Track files you changed
