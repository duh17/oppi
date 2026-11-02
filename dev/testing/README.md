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

Semantic iOS controls follow [iOS accessibility and agent testability](ios-accessibility-testability.md), which also holds the identifier naming rule. `scripts/ax-id-guard.ts` (the iOS architecture check, and the first step of the pre-push Apple lane) fails when a UI or E2E test references an identifier the app does not define. The QA driver already refuses `firstMatch` and coordinate fallbacks; see [qa-verification.md](qa-verification.md).

## Policy as code

- Gate policy: `server/testing-policy.json`
- Change-aware local gate: `.githooks/pre-push`
- Explicit full non-coverage gate: `cd server && npm run test:gate:pr-fast`
- Full threshold-enforced coverage: local `cd server && npm run test:gate:ci-coverage` (`test:coverage` on the server) and `clients/apple/scripts/check-coverage.sh`
- Coverage thresholds live in `server/vitest.config.ts` and `clients/apple/scripts/check-coverage.sh`.

The hook and `scripts/batch-gate.ts` export `OPPI_SIM_POOL_GATE=1` for everything they start, so every sim-pool call of a gate (the Apple build, the unit shards, UI and E2E lanes) that finds every simulator slot of its profile busy queues for one for up to 30 minutes (`GATE_POOL_WAIT_SECONDS` in `clients/apple/scripts/sim-pool-ops.ts`, the only place the number lives) instead of failing after 60 seconds: a gate has no caller to retry it, and a busy pool is not a test failure. The same wait bounds the first-boot slot and booted-simulator capacity waits. An explicit `OPPI_SIM_POOL_WAIT` still wins; a plain developer run of `sim-pool.sh` keeps the 60-second default. A unit shard that ran no tests is reported as `INFRASTRUCTURE FAIL` (with sim-pool's own error line) and the unit-shards summary says `INFRASTRUCTURE failure, no tests ran in shard-N`, apart from `test failures in shard-N`; nothing is rerun for it. A run whose own Swift Testing summary says it failed never passes a lane, even when xcodebuild exits 0: an issue recorded with no test to blame (Swift Testing prints it as `«unknown»`, as a request that outlived its test does) fails the summary while every test case passed, so sim-pool exits 65 and the lane reports `FAIL` (with no failed test to rerun, no rerun happens).

The local hook reads the refs Git pushes, classifies changed paths, and runs platform checks concurrently. If a server or harness lane is planned, the hook first runs `server/scripts/ensure-installed-deps.mjs` once, before any lane starts, and fails without starting lanes if that fails. The same script runs at the start of `npm run check`, `npm run check:server`, and `npm test` (inline in each script, because npm skips `pre*` scripts when `ignore-scripts` is set): when `server/node_modules` is missing or differs from the worktree's own `package-lock.json` (including transitive packages), it runs `npm ci` in `server/` at first need, so fresh and rebased worktrees need no manual install. Agents must not symlink or copy main's `node_modules`; a symlinked `server/node_modules` counts as not installed and is replaced by a real install. Vitest's global setup only verifies (`--check`) and never installs. Server changes run static checks plus Vitest's affected tests; server configuration and protocol changes run the full non-coverage suite. Apple changes build the affected test bundles without a simulator, then run the whole OppiUnitTests suite in 3 pool slots at once (`clients/apple/scripts/unit-shards.ts`) and compile the app for Release (below). Each lane requires its relevant worktree paths to match the pushed commit. Successful lanes are cached by commit, pushed range, lane mode, path set, and toolchain so retries do not repeat completed work.

The Debug build never compiles code behind `#if DEBUG`, so a Release-only break (a DEBUG-only member used from shared code) passes every other lane and fails the first archive. The `ios-release` lane closes that: after the Apple build, it runs `xcodebuild -project Oppi.xcodeproj -scheme Oppi -configuration Release -sdk iphoneos -destination generic/platform=iOS -derivedDataPath .build/pre-push-release CODE_SIGNING_ALLOWED=NO build` under the Xcode named in `clients/apple/scripts/xcode-toolchain.txt` (an explicit `DEVELOPER_DIR` wins), in an `xcode-build` slot. It needs only the sources, so it starts during the Apple lane's Debug build and keeps running beside the unit shards and the Mac compile that follow it. It asks for its slot only once the Debug build holds one (the Apple lane takes its slot through `heavy.sh`, and sim-pool, seeing `OPPI_HEAVY_HELD`, takes no second), so on a busy machine it never takes the last free slot from the build every other lane waits for (the unit shards build the scheme the Apple lane just built, so sim-pool skips their build and they need no slot). A failed Debug build still waits for it and fails with the Debug build's status. The lane keeps the newest 10 `ios-release-*.log` files. It shares sim-pool's SwiftPM clone and compilation cache for that Xcode (`clients/apple/scripts/xcode-cache-args.ts` prints the arguments; the package clone is used once a `sim-pool run` build resolved it), so a fresh worktree compiles from the cache and clones nothing. The Mac compile runs under the same pinned Xcode and its cache key includes the version. It runs whenever the Apple lane runs, caches like every other lane (commit, pushed range, Apple mode, pinned Xcode version), and keeps its own incremental DerivedData, so a rebuild after a small change recompiles only what changed. A red run prints the compiler errors and the build log path (`.git/oppi/pre-push-logs/ios-release-*.log` of the checkout). Reproduce it by hand with the command above from `clients/apple/`.

`scripts/heavy.sh <class> -- <command...>` is a machine-wide counting semaphore (BSD `lockf`, macOS) that keeps concurrent heavy jobs from oversubscribing the host. Classes and default slots: `xcode-build` 2 (build and build-for-testing, including the pre-push Apple, Mac, and Release compiles), `server-full` 1 (full Vitest suite, including pre-push `server=full`), `ui-suite` 2, `sim-first-boot` 1 (sim-pool's first boot of a new or erased simulator). Override with `OPPI_HEAVY_XCODE_BUILD`, `OPPI_HEAVY_SERVER_FULL`, `OPPI_HEAVY_UI_SUITE`, `OPPI_HEAVY_SIM_FIRST_BOOT`; `OPPI_HEAVY_DIR` moves the slot files and `OPPI_HEAVY_POLL` sets the retry interval (default 5 s). A job that finds every slot busy prints `[heavy] ... waiting` on stderr and starts when a slot frees. Between ordinary jobs there is no queue and no fairness guarantee: waiters retry every poll interval and a newcomer tries immediately, so a newcomer can take a slot that freed between polls. The land gate comes first: a waiting job with `LAND_QUEUE_BATCH` set (the pre-push hook exports it for a `refs/heads/land-queue/<batch>` push, `batch-gate.ts` for its lanes) leaves a `<class>.<pid>` marker under `$OPPI_HEAVY_DIR/gate-waiting` while it waits, and a non-gate newcomer for that class takes no slot while a live marker is there, so the gate gets the next free one; a stale marker (dead pid) is ignored and removed, and gate jobs never defer to each other. A waiting job exits 143 without running once `OPPI_HEAVY_PARENT_PID` (the pre-push hook sets it to its own pid) is no longer alive, or once it is orphaned to init, so a killed hook leaves no queued work behind. The command's exit status is passed through, and nested use of a class already held runs directly. `sim-pool run` takes an `xcode-build` slot itself (same slot files, `flock`, the same gate priority) around its build only (and a `sim-first-boot` slot around a new or erased simulator's first boot), never while holding a simulator slot, and honors `OPPI_HEAVY_HELD` and, like heavy.sh, `OPPI_HEAVY_PARENT_PID`/orphaning while it waits. Run a hand-started full suite as `scripts/heavy.sh server-full -- npm test` from `server/`. The pre-push Apple lane builds (no simulator), then runs the Mac compile and the full OppiUnitTests suite in `OPPI_UNIT_SHARDS` (3) pool slots (`clients/apple/scripts/unit-shards.ts`) at the same time, overlapping the server lane. It builds `-scheme Oppi` when UI or E2E code changed, or when `OPPI_PRE_PUSH_UI_LANES=1` (set by `batch-gate.ts --with-pre-push` for a batch with UI or E2E lanes), and `-scheme OppiUnitTests` otherwise; the unit shards run `--scheme` of that same build, so `.build/dd` holds one scheme's build and no later build in it re-links.

### Automation contract

A merge queue or CI that lands batches of commits can gate a batch with two repo-owned commands, run from a checkout of the batch (no queue-specific tooling):

1. `.githooks/pre-push`, which reads the refs Git pushes on stdin. A non-zero exit fails the batch. A queue that sees `batch-gate: runs-pre-push` from `bun scripts/batch-gate.ts --supports-pre-push` leaves the hook to the gate instead: `--with-pre-push '<push row>'` runs it alongside the gate's lanes (output prefixed `[pre-push]`). The UI lanes start once the hook's `apple` lane passed (or with the hook when its plan has no Apple lane); every other lane starts after the hook passed. The hook reports each lane's outcome to `OPPI_PRE_PUSH_EVENTS`; the first failed lane, or a failed hook, stops the running lanes at once (summary `CANCELLED`, not a red lane of the ledger), starts no other (summary `NOT RUN`), and the gate exits 3 after the hook ended, even when the hook itself then exits 0 (`FAIL (its <lane> lane failed; the hook exited 0)`). The hook's own self-test (the harness lane) unsets `OPPI_PRE_PUSH_EVENTS`, so its deliberately failing fixtures never report into a gate; `.githooks/pre-push --self-test --lanes-only` runs just those fixtures. The summary leads with a `pre-push: PASS|FAIL` row. Before the hook starts, the gate deletes every `swiftlint.stamp` and `architecture-boundaries.stamp` under `clients/apple/.build/*/Build/Intermediates.noindex`, so both build phases run in every gate even when the queue kept the DerivedData. `bun scripts/batch-gate.ts --build-cache` lists the ignored paths a queue may keep in a reused batch worktree (the `dd` and `pre-push-mac` DerivedData under `clients/apple/.build`, and `clients/apple/Vendor`; not `pre-push-release`, whose whole-module compile rebuilds the app module anyway) and a key naming the pinned Xcode; the queue recreates the worktree when the key changes.
2. `bun scripts/batch-gate.ts --worktree <path> [--target <branch>] [--test <selector>[@<p>[,<p>]]]... [--profile <p>]...`, for the suites the batch's commits asked for. `--worktree` defaults to the current directory. `--target` is the branch the batch lands on: the gate replays the pre-push plan (`scripts/pre-push-plan.ts`) for `merge-base(HEAD, target)..HEAD`, and when that plan has an Apple lane, pre-push already ran every OppiUnitTests test on this HEAD (`unit-shards.ts`), so the gate still checks each `OppiTests/...` selector against the target's declarations but runs no `ios-unit` lane (it prints `ios-unit: not run; the pre-push gate already ran every OppiUnitTests test in its unit shards, including ...`, and names quarantined selectors apart). Each selector must still name a test that ran: `unit-shards.ts` records its HEAD and shard summaries in `clients/apple/.build/unit-shards-last.json`, and the gate reads the test ids of those shards' xcresults (`Suite/test()`; the `()` are ignored on both sides). A selector that matched none of them (a helper function, a disabled or compiled-out test) fails the `ios-unit` lane as `zero tests ran for ...: no test matches the selector`. Without a readable record at this HEAD the gate runs the `ios-unit` lane after all and says why. Without `--target`, or when the plan has no Apple lane, the `ios-unit` lane runs. UI tests run one `ui-<profile>` lane per profile (`iphone`, `ipad`, `duo`), in parallel, and a lane holds only the filters scoped to its profile; each lane builds once and splits its filters over several pool slots of that profile (`clients/apple/scripts/ui-shards.ts`, see [Apple](apple.md)). A `--test` value may end in `@<profile>[,<profile>]` to scope its UI tests (`OppiUITests/FooUITests@ipad`): a merge queue scopes each entry's suites to that entry's own profiles, so one entry's iPhone-only suite does not run on another entry's iPad lane. An unscoped UI selector runs on every `--profile` (default `iphone`). The scope is ignored for every other selector kind, and repeated selectors collapse. `bun scripts/batch-gate.ts --supports-profile-scope` prints `batch-gate: profile-scope` and exits 0 without running anything; a queue probes it before passing `@<profile>` selectors, since a gate without the suffix exits 2 on the flag. Every step it starts runs with `OPPI_SIM_POOL_GATE=1` (see the gate wait below). `--test` selectors:
   - `OppiTests/<Suite>[/<test>]`: one OppiUnitTests run on the iPhone pool.
   - `OppiUITests/<Suite>[/<test>]`: UI tests, per scoped profile or else per `--profile`, sharded across that profile's pool slots (iPhone up to 3 shards, iPad 3, Duo 1; `OPPI_UI_SHARDS` overrides, never above the profile's slots). A shard that ran no tests fails the lane as `INFRASTRUCTURE FAIL`, apart from `FAIL` test failures. A shard whose run finished with failed tests reruns them once (see [Gate reports](#gate-reports)).
   - `OppiE2ETests/<Suite>[/<test>]`: paired-server E2E through `clients/apple/scripts/e2e.sh --native`. A suite that needs a second server (its Swift file calls `TwoServerFixture.<member>`, today `OfflinePairedServerE2ETests` and `ServerSettingsSwitchE2ETests`) runs through `bun server/scripts/e2e-two-server.ts` instead, which starts the second server, pairs it, and then runs `e2e.sh` for that suite. Each run gets its own fixture file and ports, so concurrent gates do not collide, and the test asks the wrapper for the second server's invite when it pairs, so a long build-slot wait cannot expire it. `TWO_SERVER_TEST=<Suite>[/<test>]` picks the suite when you run the wrapper by hand. Name it like any other E2E selector; the gate chooses the runner. `e2e.sh --group all|regression|full-regression` skips these two suites (`TWO_SERVER_SUITES` in `e2e.sh`); name them as selectors to run them.
   - `<Suite>Tests[/<test>]` (bare, no target prefix; the suite name ends in `Tests`): runs as the prefixed form for the one test target that declares `<Suite>Tests`, and the gate logs `--test '<Suite>Tests' resolved to <Target>/<Suite>Tests`. A suite no target declares is an error; a suite several targets declare (types in `QAVerificationSupport` are compiled into both UI and E2E) is an ambiguity error listing the prefixed forms to pick from.
   - `e2e-group:<name>`: an E2E group through `clients/apple/scripts/e2e.sh --group <name>`.
   - `server/tests/<file>.test.ts`: a server Vitest file (the `server/` prefix is optional).

   Exit codes: `0` every lane passed or no suites were named; `1` a lane failed (every lane runs, so one gate reports every red suite), or an entry of `dev/testing/quarantine.json` expired or lacks a field; `2` an unknown or ambiguous selector, an unknown profile, a suite the test target does not declare, an unknown argument, or a worktree that is not an Oppi checkout; `143` stopped by SIGTERM or SIGINT; the failing exit code of the `server/scripts/ensure-installed-deps.mjs` sync that runs before any lane. A named iOS or E2E run that executes zero tests fails the lane, and the lane names the selectors: `zero tests ran for OppiTests/FooTests/bar: no test matches the selector` when the run finished (exit 0, or a summary that counted zero), plain `zero tests ran for ...` when it stopped before any test. sim-pool itself fails such a run: a `test` run with `-only-testing` selectors whose finished Swift Testing (`Test run with 0 tests`) or XCTest (`Executed 0 tests`) summary counted zero tests exits 65 with `error: zero tests ran for <selectors>: no test matches the selector`, whoever called it.

### Gate reports

What a gate prints and keeps besides pass and fail. The code is `scripts/gate-report.ts`; the unit shards, the UI shards, `batch-gate.ts`, and the pre-push server lane write through it.

- **Rerun once.** The unit shards (`unit-shards.ts`, at most 20 failed tests, read from the xcresult), the UI shards (`ui-shards.ts`), and the E2E lane of `batch-gate.ts` rerun a red run's failed tests once, in the same lane (UI and E2E at most 5, read from the run's sim-pool log, and only when the run reached its XCTest summary: a runner that died midway may have left tests unrun). An E2E rerun keeps the step's mode (`--native`, a group's Docker mode) and runs `--only-testing` of each failed test; a two-server suite reruns through its wrapper, once per test. A test that passes on the rerun is `FLAKY`: the lane passes. A failed UI or E2E run collects xcodebuild's failure diagnostics first, so its slot is held 15–35 s longer before the rerun starts.
- **Rerun ledger.** Every rerun outcome is one line of `$(git rev-parse --git-common-dir)/oppi/test-flakes.jsonl`: `{"id", "lane", "profile", "head", "at", "outcome"}`, where `lane` is `unit-full` (the pre-push unit shards), `ui-<profile>`, or `e2e`, and `outcome` is `flaky` (passed on the rerun) or `failed` (failed again). Older rows have only `id`, `head`, `at`; they are unit-shard flakes. A test's "flaked in N gates" counts the distinct heads of its `flaky` rows; at 2, quarantine it.
- **Hidden flakes.** Every passing lane's summary says what a rerun hid (a red lane hid nothing, so its runner prints no such line, and `batch-gate.ts` leaves red lanes' flakes out): `2 flakes hidden by rerun: OppiTests/S/a() (unit-full), OppiUITests/C/testB (ui-ipad)`, or `no flakes hidden by rerun`. `batch-gate.ts` reads the ledger for the checkout's HEAD, so its line also lists what the pre-push unit shards hid for the same commit.
- **Red-lane ledger.** In a land-queue batch (`LAND_QUEUE_BATCH`, set by the queue for `batch-gate.ts`; the pre-push hook takes it from the `refs/heads/land-queue/<batch>` it is pushed), every lane that fails appends one line to `$(git rev-parse --git-common-dir)/oppi/land-queue/red-lanes.jsonl`: `{"at", "batch", "branches", "head", "lane", "profile", "exit", "seconds", "tests", "cause_guess", "cause_evidence", "cause_confirmed"}`. Writers: every `batch-gate.ts` lane, its planning (`lane: "plan"`) and quarantine (`lane: "quarantine"`) failures, the pre-push unit shards (`unit-full`), and the pre-push server lane. Not yet written: the pre-push Apple build, Mac, Release, and harness lanes. `tests` are the failing test ids (after the rerun). `cause_guess` is a guess from the lane's output, `cause_evidence` the line that suggested it: `selector` (unknown selector, undeclared suite, a run that matched no test), `compile`, `quarantine`, `test-failure` (a failing test is named; it outranks infrastructure noise), `infra` (slots busy, a hang or stall, a simulator that would not boot, a run that never started), or `unknown`. `cause_confirmed` starts as `null`: a person or the night triage corrects the guess by setting it to a cause class or a short note. The summary prints each red lane as `red lane <lane>: cause guess <cause> (<evidence>); recorded in <path>`, or `not recorded (no LAND_QUEUE_BATCH)` outside a batch.
- **Quarantine.** `dev/testing/quarantine.json` holds `[{"id": "OppiUITests/Class/testName", "owner": "...", "reason": "...", "addedAt": "YYYY-MM-DD", "expires": "YYYY-MM-DD", "backlog": "<factory backlog key>"}]`; the id starts with `OppiTests/`, `OppiUITests/`, or `OppiE2ETests/`. An `expires` more than 30 days after today is refused (`QUARANTINE_MAX_DAYS` in `unit-shards.ts`): a quarantine is a decision date, not parking. Each lane honours its own bundle's entries (unit: the unit shards and the `ios-unit` lane; UI: the UI shards; E2E: the `e2e` lane): the blocking run skips them (a selector an entry covers leaves the blocking run), and a separate non-blocking run reports them (`quarantined (non-blocking): passed|failed ...`). E2E groups skip every quarantined E2E test without running it, and the two-server wrapper cannot skip, so an entry inside a two-server suite still blocks (the gate says so). An entry past `expires`, or one missing a field, fails the unit shards, the UI shards, and `batch-gate.ts` before they run anything, until its owner fixes the test, extends the entry, or deletes it.
- **Lane budgets.** `dev/testing/lane-budgets.json` is the one place budgets live. Each lane prints its wall time against its budget, `budget <lane>: ...`; over budget adds `WARNING <lane> over budget: ...` to the summary and never fails the lane.

  | Lane | Measure | Budget | Printed by |
  | --- | --- | --- | --- |
  | `unit-full` | longest shard | 240 s | `unit-shards.ts` (pre-push) |
  | `ui-iphone`, `ui-ipad` | median seconds of one test in the lane's first run | 45 s | `ui-shards.ts`, repeated in the `batch-gate.ts` summary |
  | `server` | lane wall time | 180 s | the pre-push server lane and the `batch-gate.ts` server lane |

  Other lanes print `no budget`. To change one, edit its entry: `{"<lane>": {"measure": "longest-shard" | "median-test" | "wall", "seconds": <n>}}`; a new lane name gets a budget as soon as it has an entry. A file that is not JSON, or an entry with an unknown measure or no `seconds`, prints a `WARNING lane budget...` line and the lane goes on without that budget: budgets never fail a lane. `bun scripts/gate-report.ts budget <lane> <seconds>` prints a lane's verdict by hand.

Each sim-pool run writes its log and a `*.summary.json` under `clients/apple/.build/logs/` of the checkout it ran in (`pool-<slot>-<stamp>.summary.json`) and prints `Artifact: <path>`. Read the summary and log before rerunning a red lane. The queue's own landing, bisecting, and cleanup are outside this repository.

Full server and Apple unit coverage run on the local workstation. Pre-push keeps compile, static-analysis, architecture, and affected-test failures on the push path. Use `cd server && npm run test:gate:ci-coverage` and `clients/apple/scripts/check-coverage.sh` for threshold-enforced coverage, or the tracked release commands in [`scripts/release/README.md`](../../scripts/release/README.md) for a release cut. `.github/workflows/hygiene.yml` still runs secret, file-size, and tracked-private-path checks for every push and pull request. `.gitignore` does not protect a path after `git add -f`; the private-path check rejects that.

### UI and E2E launch state

Every UI/E2E launch builds its `XCUIApplication` through `OppiTestLaunch.makeApp(...)` (`clients/apple/QAVerificationSupport/OppiTestLaunch.swift`, compiled into both test targets). Do not call `XCUIApplication()` for the Oppi app. The helper adds the existing common arguments (`-ApplePersistenceIgnoreState YES`) and a reset token (`-dev.chenda.Oppi.test.resetToken <token>`). The app, not the harness, owns the reset: `TestLaunchContract` (`Oppi/App/TestLaunchContract.swift`, Debug builds only) runs first in `didFinishLaunching`, before any scene or store exists. When the token differs from the last one the app applied, it clears its own persistent defaults (app and app-group domains) and the Composer-draft (Quick Session included) and workspace-file-draft directories, then pins What's New as seen for the bundle's own version. The same token on a later launch keeps all state. A site that needs more passes its own arguments and environment through the helper.

- UI tests get one token per test (every `makeApp` inside a test shares it), so each test starts clean and a relaunch inside a test keeps what the test wrote.
- The E2E target uses one token per test process (`OppiTestLaunch.processToken`) for every launch, plain `XCTestCase` previews included, so only the first launch resets and relaunches keep the pairing and drafts that the relaunch cases prove. Mixing tokens in one process would clear a pairing a later `E2ETestCase` launch still needs, and its invite is single-use.
- `-dev.chenda.Oppi.test.animations NO` turns UIKit animations off for the launch. `makeApp(animations:)` defaults to on, and `E2ETestCase` passes off; a case that proves a transition opts back in.
- The reset leaves the Keychain alone. Clearing the app's server index means a launch no longer sees servers an earlier run left paired; the per-slot uninstall and keychain reset belong to the pool.
- The reset also leaves the app's caches and device state: `TimelineCache` and `FileBrowserCache` (under Caches, in per-server directories), `LocalHTTPCache` (the app already purges it at every launch), and the Tailnet node state under Application Support. A test that needs one of them empty clears it itself.

Debug-harness classes can opt in to one launch for all their tests (`UIHarnessTestCase.reusesLaunch`, and `AudioScriptReaderUITests`; `ReusedHarnessLaunch` in `OppiUITests`). A launch is the expensive part of a UI test (about 11.5 s of Xcode harness overhead before the app runs, even for an empty app), so these classes launch once per launch configuration (the app's launch arguments and environment, minus the per-test reset token) and between tests run the same reset contract inside the live app. The test posts the Darwin notification `dev.chenda.Oppi.test.reset` with a new generation as its state (`OppiTestLaunch.requestInProcessReset`). The app listens only when launched with `OPPI_TEST_REUSE_LAUNCH=1` and a reset token (`HarnessLaunchReset`). It then re-applies the reset contract with a token for that generation (`TestLaunchContract.applyInProcessReset`), empties the process-wide render and decode caches (one `DEBUG` entry point per cache owner, listed in `HarnessLaunchReset.resetProcessCaches`), puts the persisted theme back, dismisses what is presented, swaps the window root for a fresh harness root, and publishes the generation as `harness.reset.generation` only once the previous root and its content controller have been released. If they are still alive after about a second it publishes `harness.reset.failure` with the reason instead. A test fails with the failure reason, or with "the in-process reset did not take" naming the stale marker when no generation shows within 10 s. A failed test, a different launch configuration, or the end of the class ends the launch, so one failure does not cascade. A test that cannot start from a reset passes `freshProcess: true` to `launchHarness`. `TEST_RUNNER_OPPI_UI_REUSE_LAUNCH=0` turns reuse off for a run (every test launches fresh) to tell a reuse problem from a test problem.

What a reused launch keeps, because it is the same process: singletons and statics that no cache owner clears (for example the audio session, the simulator's orientation, keyboard and pasteboard, and permission decisions), anything an earlier test left in a system service, and the allocator and OS page-cache state a long-lived process builds up. A test about first-use cost, a cold start, or a relaunch is not a reuse candidate. Route and E2E classes keep a fresh launch per test: they need the real app root, and the E2E pairing.

When an E2E launch fails its first-surface check, `E2ETestCase` records the reason under that launch configuration (class, launch flags, arguments, environment) and fails the same configuration at once for the rest of the run, instead of relaunching and timing out each test (`E2ELaunchFailureLedger`). A sibling that launches differently still runs, and a failure after a successful launch of the configuration is not recorded.

## Detail map

This page keeps the rules that always apply. Read only the detail page for the area you are changing.

| Page | Covers |
| --- | --- |
| [Apple](apple.md) | Apple |
| [iOS accessibility](ios-accessibility-testability.md) | Agent-facing control identity and activation |
| [Mac](mac.md) | Mac |

## Server

From `server/`:

```bash
npm run check
npm test
```

The server Vitest configuration caps file workers at eight. CLI tests launch
child processes, so allowing worker count to scale with host cores can starve
nested subprocesses and contend with the concurrent Apple pre-push lane.
Set `OPPI_VITEST_MAX_WORKERS` (an integer 1 to 8; anything else is an error) to
lower the cap on a busy host. Vitest's own `VITEST_MAX_WORKERS` overrides the
config and bypasses that bound, so do not use it.

Every test file runs with its own `TMPDIR` inside a run-private root,
`/tmp/ovt<pid>` (`server/vitest.global-setup.ts`, `server/vitest.temp-guard.ts`). The
root is short on purpose: a test's `<dataDir>/run/oppi.sock` must stay under the
100-byte socket cap, and macOS's default `$TMPDIR` alone takes 49 bytes. Concurrent
runs never share entries, a run leaves nothing in the shared temp dir, and a run
killed before teardown is swept by the next one. A file fails if it leaves an entry
in its `TMPDIR` after its own hooks, and the error names the entries. Create fixture
directories with `makeTempDir(prefix)` from `server/tests/harness/temp-dir.ts`
(removed when the file finishes) or remove them yourself in `afterEach`/`afterAll`;
code under test that creates a temp dir must remove it on dispose.

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
