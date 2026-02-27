# Oppi Testing Strategy (Unified)

Last updated: 2026-02-19

This is the combined testing strategy for the Oppi monorepo (`ios` + `server`).

- iOS detail: [`docs/testing/ios.md`](./ios.md)
- Server detail: [`docs/testing/server.md`](./server.md)
- Requirements/invariants matrix: [`docs/testing/requirements-matrix.md`](./requirements-matrix.md)
- Bug-bash playbook + replay fixture flow: [`docs/testing/bug-bash-playbook.md`](./bug-bash-playbook.md)

## Requirements Matrix

Use the requirements matrix as the traceability source for test planning and bug-bash follow-up:
- Requirement/invariant ID (`RQ-*`) -> current iOS/server test coverage
- Coverage status (`covered`/`partial`/`gap`) with notes on missing assertions
- Bug-bash mapping (`Bug ID -> invariant -> repro artifact -> regression test path`)

---

## 1) Audit Snapshot (current state)

### Coverage of test surfaces

- **iOS unit test files:** 53 (`ios/OppiTests/*Tests.swift`)
- **iOS UI test files:** 2 (`ios/OppiUITests/*Tests.swift`)
- **iOS test declarations:**
  - Swift Testing `@Test`: 1095
  - XCTest-style `func test...`: 22
- **Server Vitest files:** 63 (`server/tests/*.test.ts`)
- **Server Vitest test cases (current run):** 1035
- **Cross-protocol snapshot assets:**
  - `protocol/server-messages.json`
  - `protocol/pi-events.json`

### Existing automated lanes

- **iOS**
  - `xcodebuild ... build`
  - `xcodebuild ... test` (scheme `Oppi`)
  - UI reliability harness: `ios/scripts/test-ui-reliability.sh`
- **Server**
  - `npm test` (Vitest)
  - `npm run check` (tsc + eslint + prettier)
  - `npm run test:e2e:linux` / `:full`
  - `npm run test:e2e:lmstudio:contract`
- **Cross-contract**
  - `scripts/check-protocol.sh` (server snapshots + iOS protocol decode)

### Important observation

No in-repo CI workflow config is present (`.github/workflows` not found). Current gates are local/script-driven.

---

## 2) Unified Test Pyramid

| Layer | Goal | Primary Lanes |
|---|---|---|
| L0 Static | Type/lint/format/build sanity | `server: npm run check`, `ios: xcodebuild build` |
| L1 Unit/Component | Deterministic logic correctness | `server: npm test`, `ios: xcodebuild test (OppiTests)` |
| L2 Contract | iOS/server protocol compatibility | `scripts/check-protocol.sh` |
| L3 Deterministic Integration | Runtime wiring without external model variance | `server: test:e2e:linux` |
| L4 Real Runtime Contract | Pairing/auth/ws/tool/permission/reconnect correctness with real model | `server: test:e2e:lmstudio:contract` |
| L5 Reliability/Perf Harness | Hang/stall/regression and load behavior | `ios/scripts/test-ui-reliability.sh`, `server: npm run test:load:ws` |

---

## 3) Required Gates by Change Type

| Change Type | Required Gates |
|---|---|
| iOS UI-only | iOS build + iOS unit tests; UI reliability harness for timeline/chat interaction changes |
| iOS networking / decode / protocol | `scripts/check-protocol.sh` + iOS unit tests + server protocol snapshots |
| Server route/storage/policy | `npm run check` + `npm test` + targeted integration tests |
| Server WS/session/turn flow | `npm test` + `test:e2e:linux` + `test:e2e:lmstudio:contract` |
| Security/auth/pairing changes | `npm test` + security/adversarial tests + LM Studio contract lane |
| Protocol schema/message changes | **Mandatory**: `scripts/check-protocol.sh` + both sides’ protocol tests |
| Release candidate | Full iOS tests, full server tests, Linux E2E, LM Studio contract, UI reliability harness |

---

## 4) Recommended Standard Command Packs

## Fast local (developer loop)

```bash
# Server
cd server && npm run check && npm test

# iOS
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

## Protocol-safe change

```bash
./scripts/check-protocol.sh
```

## Runtime/contract-heavy change

```bash
cd server && npm run test:e2e:linux
cd server && npm run test:e2e:lmstudio:contract
```

## Release gate

```bash
./scripts/check-protocol.sh
cd server && npm run check && npm test && npm run test:e2e:linux && npm run test:e2e:lmstudio:contract
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
ios/scripts/test-ui-reliability.sh
```

---

## 5) Gaps Found in Audit (priority)

1. **No in-repo CI orchestration** for the above gate sequence.
2. **Server coverage report is stale** (`server/coverage/coverage-summary.json` timestamp 2026-02-16).
3. **Lower server line/branch coverage areas** include `server.ts`, `routes.ts`, `push.ts`, `cli.ts`.
4. **iOS UI tests are reliability-focused harness tests**, not full onboarding/pairing/workspace user-flow automation.
5. Manual harnesses exist but are optional by nature (`npm run test:load:ws`, `npm run test:security:adversarial`) and not yet wired into a standard CI cadence.

---

## 6) Next 2-Week Plan (practical)

1. Add a single scripted **monorepo test gate** (shell script) that runs protocol + server + iOS command packs.
2. Define when to run manual harnesses (`test:load:ws`, `test:security:adversarial`) and whether to add a nightly cadence.
3. Add one iOS UI end-to-end flow test for: connect server -> open workspace -> send prompt -> approve permission.
4. Refresh coverage output after latest server changes and set target floor for critical modules.
5. Keep `test:e2e:lmstudio:contract` as the canonical WS/protocol gate.
