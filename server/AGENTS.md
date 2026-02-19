# Oppi Server

Node.js/TypeScript server that manages pi CLI sessions, policy decisions, and iOS push notifications.

## Commands

```bash
npm install     # Install dependencies
npm test        # Run all tests (vitest)
npm start       # Start server
npm run build   # TypeScript compile
npm run check   # typecheck + lint + format check
```

## Structure (map)

```
src/            Source code
tests/          Test files (vitest)
extensions/     Built-in extensions (permission-gate)
sandbox/        Container sandbox config
docs/           Server design docs
scripts/        Server ops scripts
```

Start navigation from these files:
- `src/types.ts` — client/server protocol contract
- `src/server.ts` — app wiring and runtime startup
- `src/policy.ts` + `config/policy-modes/` — policy engine + presets
- `config/schemas/` — config/runtime schema boundaries

## Non-negotiable invariants

- **Protocol changes must be end-to-end.** If you change server message types, update iOS models/tests too (see monorepo `../AGENTS.md`).
- **No partial contract updates.** Never ship a server-only protocol shape change.
- **Validate at boundaries.** Parse/validate incoming external data before internal use.
- **Keep behavior observable.** Prefer structured logs and deterministic error messages over ad-hoc prints.

## Definition of Done

A server task is done when all are true:

1. Relevant code + tests are updated.
2. `npm run check` passes.
3. `npm test` passes.
4. Protocol change (if any) is mirrored in iOS and protocol tests.
5. Docs are updated when behavior/contracts change.
