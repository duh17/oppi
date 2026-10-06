# Testing Guide

Use these canonical test commands for the Oppi monorepo.

## Pick a command

| You changed | Run first | Details |
| --- | --- | --- |
| Server code | `cd server && npm run check && npm test` | [Server](#server) |
| Wire protocol | Both sides' protocol tests and `protocol/*.json` snapshots | [Protocol checks](#protocol-checks) |
| iOS code, unit-level | `clients/apple/scripts/sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests` (add `--root <worktree>` for a worktree) | [Apple: iOS unit tests](apple.md#ios-unit-tests), [Swift Testing filters](apple.md#swift-testing-filters) |
| iOS build only | `sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build` | [Apple: Simulator build](apple.md#simulator-build) |
| iOS user journey | The E2E lane | [Apple: iOS E2E tests](apple.md#ios-e2e-tests) |
| iOS coverage gate, privacy manifest, project file | Coverage gate, archive report, `xcodegen generate` | [Apple](apple.md) |
| Mac app (only when the work names Mac) | Mac checks | [Mac](mac.md) |

Never pipe `sim-pool.sh` output through `grep`, `tail`, or `head`; read its summary and log paths. Long runs go through `background_job`.

## Policy as code

- Gate policy: `server/testing-policy.json`
- Change-aware local gate: `.githooks/pre-push`
- Explicit full non-coverage gate: `cd server && npm run test:gate:pr-fast`
- Full threshold-enforced coverage: local `cd server && npm run test:gate:ci-coverage` (`test:coverage` on the server) and `oppi-workflow.sh release-all`
- Coverage thresholds live in `server/vitest.config.ts` and `clients/apple/scripts/check-coverage.sh`.

The local hook reads the refs Git pushes, classifies changed paths, and runs platform checks concurrently. Server changes run static checks plus Vitest's affected tests; server configuration and protocol changes run the full non-coverage suite. Apple changes compile affected test bundles with the repository simulator pool. Each lane requires its relevant worktree paths to match the pushed commit. Successful lanes are cached by commit, pushed range, lane mode, path set, and toolchain so retries do not repeat completed work.

Full server and Apple unit coverage run on the local workstation. Pre-push keeps compile, static-analysis, architecture, and affected-test failures on the push path. Use `cd server && npm run test:gate:ci-coverage` and `clients/apple/scripts/check-coverage.sh` for threshold-enforced coverage, or `oppi-workflow.sh release-all` for a release cut. `.github/workflows/hygiene.yml` still runs secret, file-size, and tracked-private-path checks for every push and pull request. `.gitignore` does not protect a path after `git add -f`; the private-path check rejects that.

## Detail map

This page keeps the rules that always apply. Read only the detail page for the area you are changing.

| Page | Covers |
| --- | --- |
| [Apple](apple.md) | Apple |
| [Mac](mac.md) | Mac |

## Server

From `server/`:

```bash
npm run check
npm test
```

The server Vitest configuration caps file workers at four. CLI tests launch
child processes, so allowing worker count to scale with host cores can starve
nested subprocesses and contend with the concurrent Apple pre-push lane.

### One-shot Linux validation on macOS

Use Apple `container` copy-in mode for a clean Linux check without exposing the checkout through a host bind mount. The command streams the working tree into the container, including uncommitted files but excluding local build products.

```bash
container system start

./scripts/apple-container-copy-run.sh \
  --source . \
  --workdir /work/server \
  --exclude .git \
  --exclude .pi \
  --exclude .internal \
  --exclude clients \
  --exclude server/node_modules \
  --exclude server/dist \
  --exclude server/coverage \
  -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates git openssl
    rm -rf /var/lib/apt/lists/*
    npm install -g bun@1.3.11
    npm ci --no-audit --no-fund
    npm run check
    npm test
  '
```

For Apple `container` installations without the `container cp` plugin, including 0.9, the helper uses `tar` over `container exec -i` for copy-in and optional copy-out, then deletes the ephemeral container. It does not pass `--volume` or `--mount`.

Writable host bind mounts in compose files and scripted container runs are rejected by `server/scripts/check-compose-mounts.ts`, which runs as part of `npm run check` (`npm run mounts:check` standalone).

Isolated reverse-proxy Docker proof is `cd server && npm run test:proxy-review` (`server/proxy-review/`). It does not reuse `server/e2e/docker-compose.e2e.yml`.

Server E2E coverage is documented in `server/e2e/README.md`. Prefer native mode for local work; `E2E_NATIVE=1` also suppresses Docker cleanup:

```bash
cd server
E2E_NATIVE=1 npm run test:e2e
npm run test:e2e # Docker Compose mode when that environment is explicitly needed
```

## Protocol checks

Protocol changes must update and test both sides:

- Server contracts: `server/src/types.ts` and related `server/src/types/*`
- Apple models: `clients/apple/OppiCore/Models/*Message.swift`
- Protocol snapshots: `protocol/*.json` when the wire shape changes
- Protocol/model tests in both `server/tests` and `clients/apple/OppiTests`

The canonical protocol-change checklist lives in [Server architecture](../architecture-server.md#protocol-boundary).

## Failure investigation

- Do not pipe `sim-pool.sh` output through `grep`, `tail`, or `head`; the summary includes the log and artifact paths.
- When a wrapper prints a `.summary.json` or full log path, inspect that path before rerunning.
- E2E native failures preserve the temporary data dir for debugging.
- For failed XCUITests, inspect the `.xcresult` and the app UI hierarchy attachment when element visibility is unclear.
