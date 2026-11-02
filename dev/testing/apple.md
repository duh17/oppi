# Testing Guide: Apple

Part of [Testing Guide](README.md); same standard (commands, schemes, selectors, gotchas, reading gate output). Commands run from `clients/apple/` unless noted.

## Prebuilt frameworks

- The Oppi target links two untracked XCFrameworks under `clients/apple/Vendor/` (TailscaleKit, libghostty-vt). Xcode checks them while planning, before any Run Script phase, so a fresh worktree fails with `There is no XCFramework found at …/Vendor/…`. `sim-pool.sh run` and Xcode Cloud run `clients/apple/scripts/ensure-prebuilt-frameworks.sh` first; run it yourself before a bare `xcodebuild` or Xcode GUI build. It copies from `~/Library/Caches/oppi-*/<build-id>/` when the cache matches and builds only on a miss.
- Xcode caches a failed build plan: after filling `Vendor/`, delete `<DerivedData>/Build/Intermediates.noindex/XCBuildData/*.xcbuilddata` or use a fresh `-derivedDataPath` (sim-pool does this for `.build/dd`).
- The architecture-check build phase and the E2E server need `server/node_modules`; `sim-pool.sh run` and `e2e.sh` run `node server/scripts/ensure-installed-deps.mjs` first, a bare `xcodebuild` does not.
- TailscaleKit: `./scripts/build-tailscalekit.sh` (cache miss needs Go with cgo).
- Terminal engine: `clients/apple/scripts/build-ghostty-vt.sh` (exactly Zig 0.17.0, fetched and SHA-checked if absent). Its revision is the one Rex encodes pane snapshots with: older than ghostty `781c58e96` fails a whole snapshot on an unknown record kind, so after a bump check a Rex pane showing an image. Only iOS links it.
- `Oppi.xcodeproj` is generated: edit `project.yml`, then `xcodegen generate`.

## Privacy manifests

```bash
./scripts/check-privacy-manifests.sh             # manifest contents and project.yml membership
./scripts/check-privacy-manifests.sh self-test
xcodebuild -project Oppi.xcodeproj -scheme Oppi -configuration Release \
  -destination 'generic/platform=iOS' -archivePath .build/privacy/Oppi.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
./scripts/check-privacy-manifests.sh --archive .build/privacy/Oppi.xcarchive
```

These prove placement and contents, not that every required-reason API is declared. Before distribution an authorized maintainer makes a normally signed archive (no export or upload), runs Xcode Organizer's **Generate Privacy Report**, saves it under `.internal/reports/privacy/`, and reviews every declaration; that review is a mandatory manual gate, and `-exportArchive` is not a substitute.

## Simulator build

```bash
./scripts/sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi build
```

Without the pool, use a unique `-derivedDataPath` and `-destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.

- **Xcode toolchain:** every lane builds with Xcode 27.1 through `DEVELOPER_DIR`, never `xcode-select`; the pin is `clients/apple/scripts/xcode-toolchain.txt` (applied by `xcode-toolchain.sh`/`.ts`; an explicit `DEVELOPER_DIR` wins; a missing app fails rather than falling back). A bare `xcodebuild` uses your shell's `DEVELOPER_DIR`. Check `plutil -p <Oppi.app>/Info.plist` for `DTSDKName` `iphonesimulator27.1`. Xcode Cloud: `ci_scripts/ci_post_clone.sh` exports `DEVELOPER_DIR` from `xcode-select -p` when `CI_XCODE_CLOUD` is set and fails unless it reports 27.1.
- **Profiles:** `iphone` (iPhone 16 Pro, run slots 0–5, default), `ipad` (iPad Pro 13-inch (M5), slots 6–9), `duo` (`--device-profile duo` or `OPPI_SIM_DEVICE_PROFILE=duo`, slot 10, iOS 27.1). Duo screenshots: `xcrun simctl io <udid> screenshot --display=1` (outer) or `--display=3` (inner). A dedicated lane of your own starts at slot 11+ (`OPPI_SIM_POOL_SLOT_START`).
- **Claimed simulators:** never `simctl create`. `U=$(./scripts/sim-pool.sh claim --device-profile duo)` leases a slot runs never use (iPhone 20–27, Duo 30–37, iPad 40–47) owned by your session; call `claim` before each use instead of caching a booted state; `./scripts/sim-pool.sh release "$U"` when done. Another session cannot release yours.
- **Idle reaping:** every run, `claim`, and `release` reaps simulators idle over `OPPI_SIM_POOL_IDLE_MINUTES` (30) beyond the `OPPI_SIM_POOL_KEEP_WARM` (2) newest, and claims of stopped owners. There is no background reaper (a detached one could outlive its lock dir and reap against an empty ledger); `sim-pool.sh reap` runs one pass. At most `OPPI_SIM_POOL_MAX_BOOTED` (12) simulators boot; a run waits for capacity, then fails `none is idle in the pool`. Unmanaged simulators are never touched.

## iOS unit tests

```bash
./scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
./scripts/sim-pool.sh run --root /path/to/worktree -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
bun clients/apple/scripts/unit-shards.ts     # whole suite, OPPI_UNIT_SHARDS (3) slots, what pre-push runs
```

- Use `OppiUnitTests` for `OppiTests`; an OppiTests-only `-scheme Oppi` run is rewritten to it. `run` executes in the resolved checkout (`--root`, `OPPI_ROOT`, or this git root) wherever it was launched. Run baselines in a separate worktree, never a checkout Xcode.app has open.
- `unit-shards.ts`: shards 1..N-1 take type lists balanced by `unit-shard-seconds.json`; the last shard runs `-skip-testing` of the rest, so a type the scan misses still runs. A zero-test shard fails the run. `--strict` (release gates) ignores quarantine and reruns. Refresh timings with `--record <pool log>`.
- UI shards: `bun clients/apple/scripts/ui-shards.ts --profile iphone -- OppiUITests/<Suite> ...` (`--plan` prints the shards). One shard per 120 s of tests, at most `OPPI_UI_SHARDS` (iPhone 3, iPad 3, Duo 1) and the profile's slots; `--shards N` forces. A heavy class splits into methods with a catch-all shard, so a method the scan missed still runs once. A shard fails when a planned test has no `Test Case` line. xcresults are best effort (sim-pool stops xcodebuild after the summary); the shard output and sim-pool log are the record. Refresh with `--record <pool log>...`. Gate formats: [Gate reports](README.md#gate-reports).

## Swift Testing filters

With Xcode 27 a function filter takes its single `()`; the old doubled `()()` matches nothing.

```bash
-only-testing:OppiTests/MySuiteStruct
-only-testing:'OppiTests/MySuiteStruct/myTestFunc()'
```

Conventions: Swift Testing (`import Testing`, `@Test`, `#expect`, `@Suite`, `Issue.record()`) for unit tests; XCTest only for `XCUIApplication`. Put `@MainActor` on the suite when every test needs it. Take a test window down with `hideTestWindow(_:)` (`Support/TestFactories.swift`), and close an inline review-comment composer with `closeInlineComposer(in:)` first: hiding a window does not resign its first responder, and an orphaned software keyboard stays up for the rest of the run.

## Gotchas

Each of these has cost a worker a false red or a false green.

- **A filter that matches nothing passes in raw xcodebuild** ("0 tests passed"). sim-pool and every gate lane fail it as `zero tests ran for ...`, but a run with several selectors passes when only some match, so name declared types in land-queue `--tests`.
- **A removed cell lingers** one run-loop turn on iOS 27: assert on the data source, not on walking `subviews`.
- **A first-responder ask lands on a turn, not a deadline:** the SSH terminal asks for the grid's keyboard from a block it dispatches, and UIKit can refuse an ask that arrives while the chat bar's text view is still resigning. Await the turn (`nextRunLoopPass()`) or the responder state; a fixed sleep races both.
- **An anchored confirmation has no Cancel** (iOS 26+ popover action sheets drop `.cancel`): dismiss by tapping outside.
- **Sheet and alert buttons can appear twice** on iOS 27: query by identifier and take `firstMatch`.
- **A `UIAction`/`UIAlertAction` handler can't run in a unit test:** test the owner method it calls and prove the menu item in a UI test; never add a test-only property to reach the closure.
- **Experiments are on in unit tests** (`OppiTestExperimentsAtLoad.m`): test the off state with an explicit `SSHTerminalExperimentAccess`; UI tests use `OppiTestLaunch.experimentArguments`.
- **Launch arguments are strings:** `-key YES` reads as `"YES"`; use `bool(forKey:)`.
- **A popover menu's actions are buttons** on iOS 26/27, not `app.menuItems`: query enabled buttons whose whole `label` is the title and assert `isHittable` in Swift (`hittable` is not a predicate key). A broad `descendants(matching: .any)[title]` can match a same-text list row.
- **A row array can't prove a row works:** mount the page and activate the row through its owner (the Terminal tab's Retry row was dead three ways while every row-array test passed).
- **Prove a new test can fail:** when the fix predates its test, put the old code back once and watch it go red.

## sim-pool behaviour that bites

- **Builds:** `run` builds outside simulator slots into one DerivedData per checkout (`clients/apple/.build/dd`) under a checkout lock and an `xcode-build` heavy slot. A `test` run then clones the products (APFS) and leases a slot only for `test-without-building`. A UI/E2E-only run strips hosted unit-test bundles from its clone.
- **Build skip:** `.build/dd/oppi-build-stamp.json` keys HEAD, `git diff HEAD`, untracked files, reachable `.xcconfig`s (including the gitignored `Local.xcconfig`), `Vendor/*/BUILD_ID`, Xcode version, `DEVELOPER_DIR`/`TOOLCHAINS`/`SDKROOT`/`OPPI_REPO_ROOT`/`OPPI_TELEMETRY_MODE`, and the full invocation; the log then says `Build skipped`. One stamp per DerivedData, so another scheme, branch, commit, edit, revert, or raw `xcodebuild` into `.build/dd` rebuilds. Not keyed: other env vars and tool versions (`bun`, `node`); a checkout with an untracked nested repo is never skipped.
- **Compilation cache:** shared per Xcode in `~/Library/Caches/oppi-xcode/<Xcode>/` with prefix mapping, which compiles `#filePath` to `/^src/...`: tests load files from their bundle or `TEST_RUNNER_OPPI_SOURCE_ROOT` (`ios-test-no-source-paths`). `OPPI_SIM_POOL_COMPILATION_CACHE=0` disables it.
- **Slot reset:** each run uninstalls `dev.chenda.Oppi`, resets the keychain, and revokes microphone before `xcodebuild` (~1–2 s), so no run leaks a pairing or preference into the next.
- **E2E contamination:** `simctl boot` turns `SIMCTL_CHILD_*` into device environment until shutdown, so a slot an E2E lane booted would start every later app in E2E mode. The pool probes reused slots (`simctl spawn <udid> /usr/bin/env`) and recycles contaminated ones; a raw `xcodebuild` on a pool device bypasses this (check `xcrun simctl getenv <udid> PI_E2E_INVITE_URL`).
- **Interrupted runs:** a canceled, hung, or dead-holder run marks its slot `interrupted`, and the next run boots it clean.
- **Slimming:** background daemons are disabled after boot unless `OPPI_SIM_SLIM=0`; Maps navigation (`com.apple.navd`) stays enabled because a missing navigationService floods diagnostics on iOS 27.2.
- **Hang detection:** `OPPI_SIM_POOL_SILENCE_TIMEOUT` (180 s) counts log growth, DerivedData mtime, and the xcodebuild tree's CPU; CPU alone extends at most five windows (`alive-on-cpu-only=`). A Swift runtime crash (`Fatal error:`) fails at once without retry. A stall before `Resolve Package Graph` samples xcodebuild and fails without retry (usually Xcode.app holding the project).
- **Finished runs:** after a Swift Testing or single-bundle XCTest summary, sim-pool waits at most `OPPI_SIM_POOL_COMPLETION_TIMEOUT` (30 s; 5 s after Swift Testing) and keeps the result (`completion_hang_detected`); result bundles and coverage may then be incomplete. `OppiUnitTests` runs pass `-collect-test-diagnostics never`.
- **Slot ownership:** exclusion is `flock(2)` on `$OPPI_SIM_POOL_LOCK_DIR/slot-N.lock`; a dead wrapper pid alone never authorizes reuse, and a surviving orphan (other than a leftover `simctl io`) keeps the slot. First boots take the `sim-first-boot` heavy slot.
- **Cache pruning:** `./scripts/sim-pool.sh prune-cache` (dry run), `--apply`, `--keep-slots 0-5`. Never copy `.build` between checkouts.

## iOS coverage gate

```bash
./clients/apple/scripts/sim-pool.sh self-test
./clients/apple/scripts/ci-simulator.sh self-test
./clients/apple/scripts/check-coverage.sh self-test
./scripts/check-coverage.sh                                   # full local gate
OPPI_SIMULATOR_RUNNER=ci ./scripts/check-coverage.sh          # single-device runner; never concurrently
```

Exit codes: `2` only for coverage below an enforced threshold; `7` package resolution failed twice; `8` invalid runner configuration; anything else nonzero is a collection failure, not a shortfall. Boot waits: two 120 s readiness waits (`OPPI_SIM_POOL_BOOT_TIMEOUT`, `OPPI_SIM_POOL_BOOT_RETRIES`).

## iOS E2E tests

`clients/apple/scripts/e2e.sh` starts a paired E2E server (Docker by default, `--native` for a local process), launches XCUITests, and cleans up. Artifacts: `.internal/reports/e2e-runs/<timestamp>/` (`E2E_ARTIFACT_DIR`).

```bash
clients/apple/scripts/e2e.sh --native
clients/apple/scripts/e2e.sh --native --only-testing OppiE2ETests/<Suite>/<test>
clients/apple/scripts/e2e.sh --group gate         # preferred release gate (ReleaseGateE2ETests)
clients/apple/scripts/e2e.sh --group extended     # gate + recovery, history, quick-session, extension-attention
clients/apple/scripts/e2e.sh --group regression   # also media, screenshot; all, full-regression
```

- The app's invite outlives the 90 s short-invite window, so the server requires approval; `server/scripts/e2e-pairing-approver.mjs` approves as the bootstrap device (`pairing-approver.log`), keeping the shipped policy.
- Prerequisite: an OpenCode Go credential in `~/.pi/agent/auth.json` or `OPENCODE_API_KEY`; sessions run `opencode-go/deepseek-v4.1-flash`, and the server gets only that key (`server/e2e/model-lane.ts`).
- Strict parent-facing verification: `bun clients/apple/scripts/qa-verify.ts` ([qa-verification.md](qa-verification.md)).
- **Order independence:** all cases share one app, server, and simulator. `E2ETestCase` resets orientation and relaunches after a failure. The case finds fixtures by id (`session.nav.<id>`), never title; restores screen-local state; sets `e2eRequiresFreshLaunch` when it needs rows seeded after launch; and overrides `e2eAutoOpenWorkspaceName` rather than setting `OPPI_E2E_AUTO_OPEN_WORKSPACE`.
- **Durable and faux model:** `--durable` (`OPPI_E2E_DURABLE=1`) creates test sessions with `engine: "durable"`; `--faux-model` (needs `--durable`) uses `server/src/e2e-faux-provider.ts`, which echoes the last user text at 4 tokens/s (~17 s) ending `End of faux reply.`. The server registers it only with both `OPPI_E2E_UI_HARNESS=1` and `OPPI_E2E_FAUX_PROVIDER=1`, and only durable sessions can select it. `DurableSessionE2ETests` skips without `--durable`; `POST /e2e/ui/sessions/:id/disconnect` drops the focused socket with 1011.
- **Labs:** use paired-server labs (`E2ELabFixtures.swift`, `E2ELabWorkspaceFixture`) when the UI depends on real server state; screenshots land in `/tmp/oppi-screenshots/`. A lab test asserts what the screen shows; a screenshot-only test rots unseen.

## Debug harnesses

Harnesses, `--screenshot-preview` screens, and fixtures live in `clients/apple/OppiDebugHarness/` and compile only in Debug: the Release configuration sets `EXCLUDED_SOURCE_FILE_NAMES` to `$(SRCROOT)/OppiDebugHarness/*` and `*/*`. Xcode's `*` does not match `/`, so files stay at most one folder deep (`ios-debug-harness-depth`), each still wrapped in `#if DEBUG`. The app's one hook is `OppiApp.makeRootViewController()` → `DebugHarnessLaunch.rootViewController(root:)`. It is the same target (not a module or host app) because tests launch the Debug app with arguments and harnesses use internal types. Route a new harness in `DebugHarnessLaunch` or `ScreenshotPreviewView`; fixture seams that set private state stay in the type's file under `#if DEBUG`.

## Screenshot previews

- `--screenshot-preview` is for isolated visuals, not paired-server behaviour. Add a fixture to an existing named preview instead of a new test method.
- `OppiUITests/UIValidateTests/testDumpNamedPreview` is the one generic dump (tree, PNG, manifest; audit with `OPPI_UI_VALIDATE_AUDIT=1`, automation types only):

```bash
TEST_RUNNER_SCREENSHOT_SCREEN=session-timeline \
TEST_RUNNER_OPPI_UI_VALIDATE_DIR=/tmp/oppi-ui-validate/session-timeline \
  ./scripts/sim-pool.sh run -- xcodebuild -project Oppi.xcodeproj -scheme Oppi test \
  -only-testing:OppiUITests/UIValidateTests/testDumpNamedPreview
```

  Inputs (`TEST_RUNNER_`-prefixed): `SCREENSHOT_SCREEN` (required), `OPPI_UI_VALIDATE_DIR`, `OPPI_UI_VALIDATE_AUDIT`, `OPPI_UI_VALIDATE_READY` (default `screenshot.ready`; the dump waits for nothing else), `OPPI_UI_VALIDATE_ORIENTATION`, `OPPI_UI_VALIDATE_CONTENT_SIZE` (an unknown category silently renders default size), `OPPI_UI_VALIDATE_TAPS` (`doubletap:`, `swipeup:`, `scrollto:`, `x:y`), and every other `SCREENSHOT_*` variable.
- `scripts/screenshot-screen-guard.ts` sees only literal screen names: grep the tests for sub-page keys (`SCREENSHOT_SWEEP_PAGE`, `SCREENSHOT_WORKSPACE_PAGE`, `SCREENSHOT_MODAL_SITE`) before deleting one. A visual no test needs is not kept.
- After Apple UI or rendering changes, run `bun scripts/duplication-scan.ts` from the repo root.
