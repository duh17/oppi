# Oppi iOS Testing Strategy

Last updated: 2026-02-27

Scope: `ios/` app target (`Oppi`), unit tests (`OppiTests`), UI tests (`OppiUITests`).

Canonical gate policy lives in:
- [`docs/testing/pr-vs-nightly-gates.md`](./pr-vs-nightly-gates.md)

Related docs:
- Unified overview: [`docs/testing/README.md`](./README.md)
- Server strategy: [`docs/testing/server.md`](./server.md)
- Requirements traceability: [`docs/testing/requirements-matrix.md`](./requirements-matrix.md)

## iOS command lanes

### PR-baseline lanes

```bash
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

When iOS project structure/files change:

```bash
cd ios && xcodegen generate
```

### PR-required for protocol/message shape changes

```bash
./scripts/check-protocol.sh
```

### Nightly/release-deep iOS lane

```bash
ios/scripts/test-ui.sh
```

## iOS-specific gate mapping (quick reference)

| iOS change type | PR-required gates | Nightly/release-deep gates |
|---|---|---|
| UI/presentation only (no protocol/network) | `xcodebuild ... build`; `xcodebuild ... test` | `ios/scripts/test-ui.sh` |
| Networking/session handling (no schema change) | `xcodebuild ... build`; `xcodebuild ... test` | `ios/scripts/test-ui.sh`; `cd server && npm run test:e2e:lmstudio:contract` |
| Protocol/message schema change | iOS build/test + `./scripts/check-protocol.sh` + server `npm run check` + `npm test` | `cd server && npm run test:e2e:lmstudio:contract` |

For cross-platform changes, apply the union of this table and [`docs/testing/server.md`](./server.md).
