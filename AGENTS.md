# Oppi — Agent Principles

Oppi monorepo — iOS app + server for mobile-supervised pi CLI.

## First Message

If no concrete task given, read this file and the relevant sub-AGENTS.md, then ask what to work on.
- iOS app: see `ios/AGENTS.md`
- Server: see `server/AGENTS.md`

## Structure

```
ios/        iOS app (SwiftUI, iOS 26+)
server/     Server runtime (Node.js/TypeScript)
skills/     Agent skills (oppi-dev)
```

## Protocol Discipline

When changing client/server message contracts:
1. Update server types in `server/src/types.ts`
2. Update iOS models (`ServerMessage.swift`, `ClientMessage.swift`)
3. Update protocol tests on both sides

No partial protocol updates.

## Commands

```bash
# iOS
cd ios && xcodegen generate
cd ios && xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
ios/scripts/build-install.sh --launch --device B726F6B5-ED68-58A3-A434-1EC27090E2F9

# Server
cd server && npm test
cd server && npm start
```

## Git

- Never `git add .` / `git add -A`
- Never destructive reset/clean/stash
- Never commit unless user asks
- Always ask before removing functionality that appears intentional
