# Oppi Server Testing Strategy

Last updated: 2026-02-27

Scope: `server/` runtime (Node/TypeScript), plus protocol artifacts shared with iOS.

Canonical gate policy lives in:
- [`docs/testing/pr-vs-nightly-gates.md`](./pr-vs-nightly-gates.md)

Related docs:
- Unified overview: [`docs/testing/README.md`](./README.md)
- iOS strategy: [`docs/testing/ios.md`](./ios.md)
- Requirements traceability: [`docs/testing/requirements-matrix.md`](./requirements-matrix.md)

## Server command lanes

### PR-baseline lanes

```bash
cd server && npm run check
cd server && npm test
```

### PR-required for WS/session/turn flow changes

```bash
cd server && npm run test:e2e:linux
```

### PR-required for protocol/message shape changes

```bash
./scripts/check-protocol.sh
```

### Nightly/release-deep lanes

```bash
cd server && npm run test:e2e:linux:full
cd server && npm run test:e2e:lmstudio:contract
cd server && npm run test:load:ws
cd server && npm run test:security:adversarial
```

## Server-specific gate mapping (quick reference)

| Server change type | PR-required gates | Nightly/release-deep gates |
|---|---|---|
| Route/storage/policy (non-WS flow) | `npm run check`; `npm test` | `npm run test:security:adversarial` |
| WS/session/turn/reconnect flow | `npm run check`; `npm test`; `npm run test:e2e:linux` | `npm run test:e2e:linux:full`; `npm run test:e2e:lmstudio:contract`; `npm run test:load:ws` |
| Security/auth/pairing | `npm run check`; `npm test`; `npm run test:e2e:linux` | `npm run test:security:adversarial`; `npm run test:e2e:lmstudio:contract` |
| Protocol/message schema change | `npm run check`; `npm test`; `./scripts/check-protocol.sh` | `npm run test:e2e:lmstudio:contract` |

For cross-platform changes, apply the union of this table and [`docs/testing/ios.md`](./ios.md).
