# Oppi iOS Testing Strategy

Last updated: 2026-02-19

Scope: `ios/` app target (`Oppi`), unit tests (`OppiTests`), UI tests (`OppiUITests`).

---

## 1) Current Audit

## Inventory

- **Unit test files:** 53
- **UI test files:** 2
- **Framework split:**
  - Swift Testing: 52 files (`import Testing`)
  - XCTest: 3 files (`ProtocolSnapshotTests` + 2 UI test files)

## Main suites by concern (filename-based grouping)

- **Protocol & Codable contract** (5)
  - `ProtocolSnapshotTests`, `ServerMessageTests`, `ClientMessageTests`, `ServerConnectionTypesTests`, `ModelCodableTests`
- **Networking & connection lifecycle** (10)
  - `APIClientTests`, `ServerConnectionTests`, `ConnectionCoordinatorTests`, `StreamRecoveryTests`, `ForegroundReconnectGateTests`, etc.
- **Timeline/rendering/parser stack** (20)
  - `TimelineReducerTests`, `TimelineStressTests`, `Tool*Tests`, `TraceRenderingTests`, `CommonMarkTests`, `SyntaxHighlighterTests`, etc.
- **State/store/caching/restoration** (9)
  - `WorkspaceStoreTests`, `StoreTests`, `TimelineCacheTests`, `FreshnessStateTests`, etc.
- **Chat/composer/interaction** (9)
  - `Chat*Tests`, `ComposerAutocompleteTests`, `PastableTextViewTests`, `ReliabilityTests`, etc.
- **Security/platform services** (6)
  - `KeychainServiceTests`, `PermissionNotificationServiceTests`, `ConnectionSecurityPolicyTests`, etc.
- **UI tests** (2)
  - `UIHangHarnessUITests` (simulator reliability harness)
  - `ManualScreenshotUITests` (manual screenshot state prep)

---

## 2) Existing iOS Lanes

## Standard build/test

```bash
cd ios && xcodegen generate
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

## UI reliability harness

```bash
ios/scripts/test-ui-reliability.sh
```

Uses scheme `OppiUIReliability` and currently focuses on chat timeline/hang regressions.

---

## 3) iOS Gate Policy

## Required for all iOS changes

1. `xcodebuild ... build` succeeds.
2. `xcodebuild ... test` succeeds for impacted suites.
3. `xcodegen generate` run when project structure/files change.

## Required for protocol-touching iOS changes

- Run monorepo protocol gate:

```bash
./scripts/check-protocol.sh
```

## Required for timeline/chat performance-sensitive changes

- Run UI reliability harness:

```bash
ios/scripts/test-ui-reliability.sh
```

---

## 4) Gaps and Risks (iOS)

1. **UI tests are narrow** (reliability harness + screenshot prep), not full user workflows.
2. Limited automated **real server interaction** tests from iOS side (pair/connect/send/approve).
3. XCTest + Swift Testing split is manageable, but consistency/documented conventions should be explicit.

---

## 5) Recommended iOS Additions

## Near term (high ROI)

1. Add one UI integration flow:
   - connect server -> open workspace -> send prompt -> approve permission -> verify response row.
2. Add negative flow UI test:
   - reconnect after transient disconnect, verify no duplicate sends / no stuck composer.
3. Add targeted test bundle for release toggles:
   - push/live activity/dictation gate behavior.

## Medium term

4. Add explicit “protocol encode” tests (not just decode snapshots) for client outbound messages.
5. Add performance budget assertions for timeline update latency in stress suites.

---

## 6) Suggested Daily/Release Command Packs

## Daily loop

```bash
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

## Release gate (iOS slice)

```bash
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
ios/scripts/test-ui-reliability.sh
./scripts/check-protocol.sh
```
