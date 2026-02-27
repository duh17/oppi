# PR vs Nightly/Release Testing Gates

Last updated: 2026-02-27

This is the canonical gate policy for Oppi testing.

- PR gates = required before merge for the matching change type.
- Nightly/release-deep gates = heavier coverage run on cadence or before release cut.

Related docs:
- Overview: [`docs/testing/README.md`](./README.md)
- Server detail: [`docs/testing/server.md`](./server.md)
- iOS detail: [`docs/testing/ios.md`](./ios.md)
- Requirements mapping: [`docs/testing/requirements-matrix.md`](./requirements-matrix.md)
- Bug-bash workflow: [`docs/testing/bug-bash-playbook.md`](./bug-bash-playbook.md)

## Gate catalog (commands)

### PR-required gates (base)

```bash
# Server baseline
cd server && npm run check
cd server && npm test

# iOS baseline
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test

# Cross-protocol validation (required when protocol/messages change)
./scripts/check-protocol.sh

# Deterministic WS/session integration (required for WS/session flow changes)
cd server && npm run test:e2e:linux
```

### Nightly/release-deep gates

```bash
# Real-model runtime contract
cd server && npm run test:e2e:lmstudio:contract

# Extended deterministic integration
cd server && npm run test:e2e:linux:full

# Server stress/security harnesses
cd server && npm run test:load:ws
cd server && npm run test:security:adversarial

# iOS UI reliability/hang harness
ios/scripts/test-ui.sh
```

## Decision table (change type -> required gates)

| Change type | PR-required gates | Nightly/release-deep gates |
|---|---|---|
| Docs/testing-only changes | None | None |
| iOS UI/presentation only (no protocol/network changes) | iOS build + iOS test | `ios/scripts/test-ui.sh` |
| iOS networking/session handling (no schema change) | iOS build + iOS test | `ios/scripts/test-ui.sh`; `cd server && npm run test:e2e:lmstudio:contract` |
| iOS or server protocol/message schema change | `./scripts/check-protocol.sh` + iOS build/test + server `npm run check` + `npm test` | `cd server && npm run test:e2e:lmstudio:contract` |
| Server route/storage/policy (non-WS-flow) | `cd server && npm run check` + `npm test` | `cd server && npm run test:security:adversarial` |
| Server WS/session/turn/reconnect flow | server `npm run check` + `npm test` + `npm run test:e2e:linux` | `cd server && npm run test:e2e:linux:full`; `cd server && npm run test:e2e:lmstudio:contract`; `cd server && npm run test:load:ws` |
| Security/auth/pairing | server `npm run check` + `npm test` + `npm run test:e2e:linux` | `cd server && npm run test:security:adversarial`; `cd server && npm run test:e2e:lmstudio:contract` |
| Release candidate | All applicable PR gates above | Run all nightly/release-deep gates |

## Notes

- If a change spans iOS + server, apply the union of both rows.
- If uncertain, choose the stricter row.
- Keep this file as the source of truth. Other testing docs should reference this table, not redefine conflicting gate rules.
