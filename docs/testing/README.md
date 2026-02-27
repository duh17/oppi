# Oppi Testing Strategy (Unified)

Last updated: 2026-02-27

This directory defines the testing strategy for the Oppi monorepo (`ios/` + `server/`).

## Canonical gate policy

Use this as the source of truth for what must run on PRs vs nightly/release-deep runs:

- **[`docs/testing/pr-vs-nightly-gates.md`](./pr-vs-nightly-gates.md)**

Do not duplicate or override gate definitions in other docs.

## Testing docs map

- PR vs nightly/release gates: [`./pr-vs-nightly-gates.md`](./pr-vs-nightly-gates.md)
- Server testing details: [`./server.md`](./server.md)
- iOS testing details: [`./ios.md`](./ios.md)
- Requirements/invariant traceability: [`./requirements-matrix.md`](./requirements-matrix.md)
- Bug-bash workflow and regression capture: [`./bug-bash-playbook.md`](./bug-bash-playbook.md)

## Gate layers (mental model)

| Layer | Goal | Representative command(s) |
|---|---|---|
| L0 Static/build | Compile + lint + format sanity | `cd server && npm run check`; `cd ios && xcodebuild ... build` |
| L1 Unit/component | Deterministic behavior checks | `cd server && npm test`; `cd ios && xcodebuild ... test` |
| L2 Cross-protocol | iOS/server message compatibility | `./scripts/check-protocol.sh` |
| L3 Deterministic integration | WS/session integration without external model variance | `cd server && npm run test:e2e:linux` |
| L4 Runtime contract | Real-model end-to-end behavior | `cd server && npm run test:e2e:lmstudio:contract` |
| L5 Reliability/perf/stress | Hang/load/adversarial hardening | `ios/scripts/test-ui.sh`; `cd server && npm run test:load:ws`; `cd server && npm run test:security:adversarial` |

## Standard command packs

### Fast local loop

```bash
cd server && npm run check && npm test
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

### Protocol-touching changes

```bash
./scripts/check-protocol.sh
```

### Deep runtime/reliability pack

```bash
cd server && npm run test:e2e:linux:full
cd server && npm run test:e2e:lmstudio:contract
cd server && npm run test:load:ws
cd server && npm run test:security:adversarial
ios/scripts/test-ui.sh
```
