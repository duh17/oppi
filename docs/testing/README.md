# Oppi Testing Policy (Canonical)

Last updated: 2026-02-27

This is the single source-of-truth document for testing strategy and gate policy.

## Policy as code

Canonical policy file:

- `server/testing-policy.json`

Canonical gate runner:

- `server/scripts/testing-gates.mjs`

Coherence enforcement:

- `server/scripts/check-testing-policy.mjs`
- `cd server && npm run check:testing-policy`

## Required gate commands

PR fast gate:

```bash
cd server && npm run test:gate:pr-fast
```

Nightly deep gate:

```bash
cd server && npm run test:gate:nightly-deep
```

## Gate definitions

Current policy (`server/testing-policy.json`):

- `pr-fast`: `check -> test`
- `nightly-deep`: `check -> test -> test:e2e:linux -> test:e2e:linux:https -> test:e2e:lmstudio:contract`

`testing-gates.mjs` supports:

- `TEST_GATE_ONLY=<step>`
- `TEST_GATE_FROM=<step>`

## Coherence strategy

Coherence means policy, CI, and docs cannot drift.

Required invariants:

1. `server/testing-policy.json` defines canonical gates and CI command targets.
2. `server/package.json` gate scripts call `server/scripts/testing-gates.mjs`.
3. `.github/workflows/pr-fast-gate.yml` runs `cd server && npm run test:gate:pr-fast`.
4. `.github/workflows/nightly-deep-gate.yml` runs `cd server && npm run test:gate:nightly-deep`.
5. This README references the same commands and policy path.

These invariants are validated by:

```bash
cd server && npm run check:testing-policy
```

## CI model (single self-hosted Mac)

- PR workflow: `.github/workflows/pr-fast-gate.yml`
- Nightly workflow: `.github/workflows/nightly-deep-gate.yml`
- Shared single-runner lock: `mac-studio-single-runner`
- Stale PR cancellation enabled in PR workflow.

## Supporting references

- `docs/testing/requirements-matrix.md`
- `docs/testing/bug-bash-playbook.md`

These files are supporting context only. If they conflict with this README or policy file, fix them.
