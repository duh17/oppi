# Oppi Server Testing Strategy

Last updated: 2026-02-19

Scope: `server/` runtime (Node/TypeScript), plus protocol artifacts shared with iOS.

---

## 1) Current Audit

## Inventory

- **Vitest files:** 63 (`server/tests/*.test.ts`)
- **Vitest test cases (current run):** 1035
- **Manual harness scripts in `server/scripts/manual/`:**
  - `load-ws.ts`
  - `security-adversarial.ts`
  - `gate-client.ts`
- **Test helper module:**
  - `server/tests/session-spawn.helpers.ts`

## Area grouping (filename-based)

- **Policy / rules / gate**
- **Workspace / lifecycle limits**
- **Session / stream / turn / stop / event flow**
- **Auth / pairing / network allowlist / startup security**
- **Storage / config / lifecycle locks**
- **API and misc subsystems (skills, graph, trace, cli, qr, diff)**

## Coverage snapshot (available file)

`server/coverage/coverage-summary.json` exists, but timestamp is **2026-02-16** (stale relative to recent changes).

Known low-coverage areas from the last snapshot include core server modules (`src/server.ts`, `src/routes.ts`, `src/push.ts`, `src/cli.ts`). Refresh coverage after the latest cleanup before setting hard thresholds.

---

## 2) Existing Server Lanes

## Core

```bash
cd server && npm run check
cd server && npm test
```

## Deterministic E2E (containerized server environment)

```bash
cd server && npm run test:e2e:linux
cd server && npm run test:e2e:linux:full
```

## Real-model WS contract gate

```bash
cd server && npm run test:e2e:lmstudio:contract
```

This gate now validates:
- pairing + auth negatives
- session stream contract
- `/stream` reconnect/catch-up + miss behavior
- turn idempotency (`clientTurnId`) semantics
- stop lifecycle semantics

## Protocol cross-check with iOS

```bash
./scripts/check-protocol.sh
```

---

## 3) Server Gate Policy

## Required for all server changes

1. `npm run check`
2. `npm test`

## Required for WS/session flow changes

3. `npm run test:e2e:linux`
4. `npm run test:e2e:lmstudio:contract`

## Required for protocol/message shape changes

5. `./scripts/check-protocol.sh` (server + iOS compatibility)

## Required for release candidates

- Full stack:
  - `npm run check`
  - `npm test`
  - `npm run test:e2e:linux`
  - `npm run test:e2e:linux:full` (when environment permits)
  - `npm run test:e2e:lmstudio:contract`

---

## 4) Gaps and Risks (server)

1. No in-repo CI workflow orchestrating all required gates.
2. Coverage reporting is stale and not tied to a required threshold gate.
3. Manual harnesses are now scriptable (`test:load:ws`, `test:security:adversarial`) but not yet scheduled in CI/nightly cadence.
4. Known flaky area to isolate further: raw `/stream` `bash` command path behavior under certain sequencing.

---

## 5) Recommended Server Additions

## Near term (high ROI)

1. Add explicit contract checks for:
   - raw `/stream` `bash` path (success/error bounded response)
   - permission timeout + late response rejection
2. Define cadence/ownership for manual harness execution:
   - `npm run test:security:adversarial`
   - `npm run test:load:ws`
3. Refresh coverage and set module-level target floors for critical paths (`server.ts`, `routes.ts`, `sessions.ts`).

## Medium term

4. Add a single monorepo gate script that runs server + iOS + protocol in one command.
5. Add CI execution of at least:
   - `npm run check`
   - `npm test`
   - `./scripts/check-protocol.sh`

---

## 6) Suggested Daily/Release Command Packs

## Daily server loop

```bash
cd server && npm run check && npm test
```

## Runtime contract loop

```bash
cd server && npm run test:e2e:linux
cd server && npm run test:e2e:lmstudio:contract
```

## Release server slice

```bash
cd server && npm run check && npm test && npm run test:e2e:linux && npm run test:e2e:lmstudio:contract
```
