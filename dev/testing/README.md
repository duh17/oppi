# Testing Guide

## Pick a command

| You changed | Run first | Details |
| --- | --- | --- |
| Server code | `cd server && npm run check && npm test` | [Server](#server) |
| Wire protocol | Both sides' protocol tests and `protocol/*.json` snapshots | [Protocol checks](#protocol-checks) |
| iOS code, unit-level | `clients/apple/scripts/sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests` (add `--root <worktree>` for a worktree) | [iOS unit tests](apple.md#ios-unit-tests), [Swift Testing filters](apple.md#swift-testing-filters) |
| iOS build only | `sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build` | [Simulator build](apple.md#simulator-build) |
| iOS user journey | The E2E lane | [iOS E2E tests](apple.md#ios-e2e-tests) |
| Coverage, privacy manifest, project file | Coverage gate, archive report, `xcodegen generate` | [Apple](apple.md) |
| Mac app (only when the work names Mac) | Mac checks | [Mac](mac.md) |
| `dev/**/*.md` | `bun scripts/dev-docs-guard.ts` | [dev/README.md](../README.md#what-belongs-in-dev) |
| A red pre-push or land gate | Read the summary lines | [Gate reports](#gate-reports) |

- Never pipe `sim-pool.sh` output through `grep`, `tail`, or `head`; read its summary and log paths. Long runs go through `background_job`.
- Identifiers and semantic controls: [iOS accessibility and agent testability](ios-accessibility-testability.md); strict QA receipts: [qa-verification.md](qa-verification.md).

## Policy as code

- Gate policy: `server/testing-policy.json`. Local gate: `.githooks/pre-push` (install with `install -m 755 .githooks/pre-push "$(git rev-parse --git-path hooks)/pre-push"`; `--self-test`, lane fixtures only `--self-test --lanes-only`).
- Full non-coverage gate: `cd server && npm run test:gate:pr-fast`. Coverage thresholds (no CI runs them): `cd server && npm run test:gate:ci-coverage` (`test:coverage`; thresholds in `server/vitest.config.ts`) and `clients/apple/scripts/check-coverage.sh`. Release cuts: [`scripts/release/README.md`](../../scripts/release/README.md).
- `.github/workflows/hygiene.yml` runs secret, file-size, and tracked-private-path checks on every push; `.gitignore` does not protect a path after `git add -f`.

## The pre-push gate

- The hook classifies changed paths (`scripts/pre-push-plan.ts`) and runs lanes concurrently: `server` (static checks, the `bun test` suites of `server/plugins/{background-jobs,subagents}`, plus affected Vitest; configuration, protocol, and `server/plugins/` changes run the full suite, because the plugin host loads plugins outside Vitest's import graph), `apple` (build-for-testing, the whole OppiUnitTests suite in 3 slots via `unit-shards.ts`, the Mac compile, `ios-release`), `mac`, `harness` (the hook's self-test), and a docs check for `dev/**/*.md`. Each lane requires its relevant worktree paths to match the pushed commit; passes are cached by commit, range, lane mode, path set, and toolchain.
- A planned server or harness lane first runs `server/scripts/ensure-installed-deps.mjs` (`npm ci` when `server/node_modules` is missing or differs from the lockfile). Never symlink or copy main's `node_modules` (a symlink counts as not installed).
- `ios-release` compiles Release for the device SDK, because Debug never sees `#if DEBUG` code and a Release-only break would otherwise fail the first archive: `xcodebuild -project Oppi.xcodeproj -scheme Oppi -configuration Release -sdk iphoneos -destination generic/platform=iOS -derivedDataPath .build/pre-push-release CODE_SIGNING_ALLOWED=NO build` under the pinned Xcode. It takes its slot only after the Debug build holds one. A red run prints compiler errors and `.git/oppi/pre-push-logs/ios-release-*.log`.
- The Apple lane builds `-scheme Oppi` when UI or E2E code changed (or `OPPI_PRE_PUSH_UI_LANES=1`), else `OppiUnitTests`; the unit shards reuse that build.
- Gates export `OPPI_SIM_POOL_GATE=1`: a sim-pool call that finds every slot busy queues up to 30 minutes instead of failing after 60 s (an explicit `OPPI_SIM_POOL_WAIT` wins).
- A run whose Swift Testing summary says it failed never passes, even when xcodebuild exits 0 (sim-pool exits 65; see `«unknown»` below).

## Heavy-job slots

`scripts/heavy.sh <class> -- <command...>` is a machine-wide counting semaphore (BSD `lockf`): `xcode-build` 2, `server-full` 1, `ui-suite` 2, `sim-first-boot` 1 (overrides `OPPI_HEAVY_XCODE_BUILD` and the like; `OPPI_HEAVY_DIR`, `OPPI_HEAVY_POLL`). Run a hand-started full server suite as `scripts/heavy.sh server-full -- npm test` from `server/`.

- Ordinary jobs get no queue or fairness. A waiting land-gate job (`LAND_QUEUE_BATCH` set) leaves a `<class>.<pid>` marker under `$OPPI_HEAVY_DIR/gate-waiting`, and no non-gate newcomer for that class takes a slot while a live marker exists; gate jobs never defer to each other.
- A waiter exits 143 once `OPPI_HEAVY_PARENT_PID` dies or it is orphaned; nested use of a held class runs directly.
- `sim-pool run` takes an `xcode-build` slot around its build only, never while holding a simulator, and honours `OPPI_HEAVY_HELD`.

## Batch gate (land queue)

A queue gates a batch with two repo-owned commands from a checkout of the batch:

1. `.githooks/pre-push` (refs on stdin), or under `bun scripts/batch-gate.ts --with-pre-push '<push row>'` when `--supports-pre-push` prints `batch-gate: runs-pre-push`. UI lanes start once the hook's `apple` lane passed; the first failed hook lane stops the rest (`CANCELLED`, `NOT RUN`) and the gate exits 3 even if the hook then exits 0. The gate deletes every `swiftlint.stamp` and `architecture-boundaries.stamp` first, so both build phases run. `--build-cache` lists the paths a queue may keep between batches and their Xcode key.
2. `bun scripts/batch-gate.ts --worktree <path> [--target <branch>] [--test <selector>[@<p>[,<p>]]]... [--profile <p>]...`. With `--target` and an Apple lane in the replayed plan, unit selectors are checked against the unit shards' record (`clients/apple/.build/unit-shards-last.json`) instead of rerun. UI selectors run per profile (`iphone`, `ipad`, `duo`), sharded; `@<profile>` scopes one (probe `--supports-profile-scope` first).

Selectors: `OppiTests/<Suite>[/<test>]`; `OppiUITests/<Suite>[/<test>]`; `OppiE2ETests/<Suite>[/<test>]` (suites that call `TwoServerFixture.<member>` run through `bun server/scripts/e2e-two-server.ts`; `e2e.sh` groups skip them, so name them); bare `<Suite>Tests[/<test>]` resolves to its one declaring target (ambiguity is an error); `e2e-group:<name>`; `server/tests/<file>.test.ts`.

Exit codes: `0` pass or nothing named; `1` a lane failed (every lane runs) or a quarantine entry expired or lacks a field; `2` unknown or ambiguous selector, unknown profile, undeclared suite, bad argument, not an Oppi checkout; `143` signal; the deps-sync exit code. A named selector that executes zero tests fails as `zero tests ran for ...`.

## Gate reports

`scripts/gate-report.ts` writes these for the unit shards, UI shards, `batch-gate.ts`, and the pre-push server lane.

- **Rerun once.** Unit shards (≤20 failed tests), UI shards and E2E (≤5, only when the run reached its XCTest summary) rerun failures once in the same lane. A pass on rerun is `FLAKY` and the lane passes. Failed UI/E2E runs hold their slot 15–35 s longer collecting diagnostics.
- **Rerun ledger:** `$(git rev-parse --git-common-dir)/oppi/test-flakes.jsonl`, one line per rerun; a test that flaked in 2 distinct heads gets quarantined. Every passing lane prints `N flakes hidden by rerun: ...` or `no flakes hidden by rerun`.
- **Red-lane ledger:** in a land-queue batch (`LAND_QUEUE_BATCH`), each failed lane appends to `$(git rev-parse --git-common-dir)/oppi/land-queue/red-lanes.jsonl` with a `cause_guess`, its evidence, and `cause_confirmed: null` for a person to correct. The pre-push Apple build, Mac, Release, and harness lanes do not write it yet.
- **Quarantine:** `dev/testing/quarantine.json`, entries `{id, owner, reason, addedAt, expires, backlog}` with ids under `OppiTests/`, `OppiUITests/`, or `OppiE2ETests/`, expiring at most 30 days out. The blocking run skips entries and a non-blocking run reports them; an expired or incomplete entry fails the gate before anything runs. Two-server suites cannot skip, so their entries still block.
- **Lane budgets:** `dev/testing/lane-budgets.json`; over budget prints `WARNING <lane> over budget` and never fails. Set one with `bun scripts/gate-report.ts budget <lane> <seconds>`.

Reading the summary lines (each sim-pool run also writes a log and `*.summary.json` under `clients/apple/.build/logs/` and prints `Artifact: <path>`; read them before rerunning a red lane):

- `INFRASTRUCTURE FAIL` (shard) / `INFRASTRUCTURE failure, no tests ran in shard-N` (summary): the shard ran no tests (no slot, a simulator that would not boot, a runner that never started). Not a test failure, and nothing reruns; sim-pool's own error line follows. Test failures read `FAIL` / `test failures in shard-N`.
- `«unknown»` in a Swift Testing summary: an issue recorded with no test to blame (often a request that outlived its test). It fails the run with no failed test to rerun.
- `red lane <lane>: cause guess <cause> (<evidence>); recorded in <path>` in a land-queue batch, or `not recorded (no LAND_QUEUE_BATCH)` outside one.
- `quarantined (non-blocking): passed|failed <ids>`: the separate run of quarantined tests; it never fails the lane.
- `ios-unit: not run; the pre-push gate already ran every OppiUnitTests test in its unit shards, including …`: the unit selectors are covered by this HEAD's shards, not skipped.
- `pre-push: FAIL (its <lane> lane failed; the hook exited 0)`: a hook lane failed under `--with-pre-push`, so the gate failed even though the hook itself exited 0.

### UI and E2E launch state

- Every UI/E2E launch builds its app through `OppiTestLaunch.makeApp(...)` (`clients/apple/QAVerificationSupport/OppiTestLaunch.swift`), never `XCUIApplication()`. It adds a reset token; the app owns the reset (`TestLaunchContract`, Debug only, first in `didFinishLaunching`), clearing app and app-group defaults and draft directories for a new token and pinning What's New as seen.
- UI tests use one token per test; E2E uses one per process (`OppiTestLaunch.processToken`), because a mixed token would clear a pairing whose single-use invite a later case needs.
- `-dev.chenda.Oppi.test.animations NO` turns animations off (`E2ETestCase` passes it).
- The reset leaves the Keychain (the pool resets it per slot), `TimelineCache`, `FileBrowserCache`, `LocalHTTPCache`, and Tailnet state alone; a test that needs those empty clears them.
- Harness and preview classes may reuse one launch (`UIHarnessTestCase.reusesLaunch`, `PreviewUITestCase.reusesLaunch`; owner `ReusedHarnessLaunch` in `QAVerificationSupport`). A test gets the running app when its arguments and non-`SCREENSHOT_*` environment match; its `SCREENSHOT_*` keys (screen, page, site, theme) reach the app through the in-process reset (`HarnessLaunchReset`, only with `OPPI_TEST_REUSE_LAUNCH=1`).
- A reset restores the launch's argument domain, re-applies the launch contract, empties `HarnessLaunchReset.resetProcessCaches` and `resetHarnessFixtures` (the one entry point per process-wide cache owner), ends editing, dismisses what is presented, and swaps in a fresh root. The test fails if `harness.reset.generation` does not appear within 10 s, or on `harness.reset.failure`. A failed test or the end of the class ends the launch; a relaunch inside one test keeps what the test wrote.
- A reused process keeps singletons no reset clears, system-service state, and allocator warmth, so first-use, cold-start, and relaunch tests never reuse. A preview value that changes between tests comes from `SCREENSHOT_*` when the root is built, never a `static let`. `freshProcess: true` opts one harness test out; `TEST_RUNNER_OPPI_UI_REUSE_LAUNCH=0` turns reuse off. `RouterSettingsModalsUITests/testReusedLaunchStartsClean{First,Second}` fail on a leaked write record, sheet, or keyboard; whichever runs second also asserts it came through a reset.
- An E2E launch configuration that fails its first-surface check fails the rest of that configuration at once (`E2ELaunchFailureLedger`).

## Server

From `server/`: `npm run check` and `npm test`.

- Vitest caps file workers at 8 because CLI tests spawn children. Lower with `OPPI_VITEST_MAX_WORKERS` (1–8); never use `VITEST_MAX_WORKERS`, which bypasses the bound.
- Each test file gets its own `TMPDIR` under `/tmp/ovt<pid>` (`vitest.global-setup.ts`, `vitest.temp-guard.ts`), short so `<dataDir>/run/oppi.sock` stays under the 100-byte socket limit. A file that leaves an entry in its `TMPDIR` fails; use `makeTempDir(prefix)` from `server/tests/harness/temp-dir.ts`.
- Clean Linux check without a host bind mount: `./scripts/apple-container-copy-run.sh --source . --workdir /work/server --exclude .git --exclude .pi --exclude .internal --exclude clients --exclude server/node_modules --exclude server/dist --exclude server/coverage -- bash -lc 'set -euo pipefail; apt-get update && apt-get install -y --no-install-recommends ca-certificates git openssl && npm install -g bun@1.3.11 && npm ci --no-audit --no-fund && npm run check && npm test'` (after `container system start`). Writable host bind mounts are rejected by `server/scripts/check-compose-mounts.ts` (in `npm run check`).
- Reverse-proxy proof: `npm run test:proxy-review`. Server E2E: `server/e2e/README.md`; prefer `E2E_NATIVE=1 npm run test:e2e`.

## Protocol checks

Run server protocol tests, then Apple Codable tests, per the [protocol boundary checklist](../architecture-server.md#protocol-boundary).

## Failure investigation

Native E2E failures keep the temporary data dir; for XCUITest failures, inspect the `.xcresult` and its UI hierarchy attachment.
