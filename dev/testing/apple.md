# Testing Guide: Apple

Part of [Testing Guide](README.md). iOS build, unit, coverage, E2E, simulator labs, and Swift Testing filters.

## Apple

From `clients/apple/`:

### Prebuilt frameworks

The Oppi target links two untracked XCFrameworks under `clients/apple/Vendor/`: TailscaleKit and the terminal engine (below). Xcode checks linked XCFrameworks while it plans the build, before any Run Script phase, so a checkout or worktree without them fails with `There is no XCFramework found at …/Vendor/…` and the target's pre-build phases never get to run. `sim-pool.sh run` and Xcode Cloud run this first; run it yourself before a bare `xcodebuild` or an Xcode GUI build in a new worktree:

```bash
clients/apple/scripts/ensure-prebuilt-frameworks.sh
```

It is a no-op when `Vendor/` matches the pins, copies from `~/Library/Caches/oppi-*/<build-id>/` when the host cache matches, and builds from source only on a cache miss.

Xcode caches the failed build plan, error included, so a DerivedData that already failed this way keeps failing after `Vendor/` is filled. `sim-pool.sh run` drops that plan from its slot automatically; for other builds, delete `<DerivedData>/Build/Intermediates.noindex/XCBuildData/*.xcbuilddata` or use a fresh `-derivedDataPath`.

### Build TailscaleKit

The iOS app embeds the official TailscaleKit framework, which is built locally and not tracked. A cache miss after the pinned libtailscale commit or the omitted-feature list (`BUILD_ID`) changes needs Go (cgo) and Xcode, and keeps Go caches under `clients/apple/.build/tailscalekit`. Other checkouts reuse `~/Library/Caches/oppi-tailscalekit/<build-id>/` without Go or Xcode:

```bash
cd clients/apple
./scripts/build-tailscalekit.sh
```

### Nerd Font icons

Nerd Font icons ship in the app as `Oppi/Resources/Fonts/NerdFonts/SymbolsNerdFontMono-Regular.ttf` (Nerd Fonts v3.5.1 Symbols Only Mono). `NerdFontSymbols.swift` lists that face as every code font's cascade fallback. UIAppFonts registers it at launch.

### Build the terminal engine

The iOS app statically links a pinned libghostty-vt build, without SIMD C++
libraries. Kitty graphics is compiled in; PNG decode is an embedder callback,
and file image loads are not enabled. The framework is untracked. A cache miss
needs exactly Zig 0.16.0 and Xcode with the iOS device and simulator SDKs:

```bash
clients/apple/scripts/build-ghostty-vt.sh
```

`ensure-prebuilt-frameworks.sh` runs this before xcodebuild; the Oppi pre-build phase runs it again to catch pin bumps. Other checkouts reuse
`~/Library/Caches/oppi-ghostty-vt/<build-id>/` without Zig or network access.
The source revision and build options live in the script; update both deliberately.
`Oppi/Resources/GhosttyVt-LICENSE.txt` carries the distributed notices.
Only the iOS app links this library; OppiMac does not.

### Regenerate project

`Oppi.xcodeproj` is generated. Change `project.yml`, then run:

```bash
xcodegen generate
```

### Privacy manifests and archive report

Validate the tracked manifest contents and parsed XcodeGen target resource membership before building. Run the regression fixtures when you change the checker:

```bash
cd clients/apple
./scripts/check-privacy-manifests.sh
./scripts/check-privacy-manifests.sh self-test
```

These checks validate declared manifest contents and exact `project.yml` membership. They do not inspect executable API use or replace archive validation.

To inspect the final bundle layout without using distribution credentials, create an unsigned local archive and validate manifest placement and contents in the audited executable bundles:

```bash
cd clients/apple
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .build/privacy/Oppi.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  archive

./scripts/check-privacy-manifests.sh \
  --archive .build/privacy/Oppi.xcarchive
```

The unsigned archive proves manifest placement and contents for that build. It does not prove that every required-reason API has an accurate declaration. Xcode 26.6 does not expose a supported `xcrun` or `xcodebuild` operation for the merged privacy report. Before distribution, an authorized maintainer must create a normally signed archive without exporting or uploading it:

```bash
cd clients/apple
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/privacy/SignedDerivedData \
  -archivePath .build/privacy/Oppi-signed.xcarchive \
  archive

open -a Xcode .build/privacy/Oppi-signed.xcarchive
```

In Xcode Organizer, control-click the archive, choose **Generate Privacy Report**, and save the report under `.internal/reports/privacy/`. Review every app and SDK declaration, including findings from statically linked dependencies, before distribution. The signed Organizer report is a mandatory manual distribution gate. Do not mark it complete without reviewing the generated report, and do not use `-exportArchive` for this check.

Apple’s source for the per-executable bundle rule and required-reason policy is [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api). Apple documents target resource membership and bundle locations in [Adding a privacy manifest to your app or third-party SDK](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).

### Simulator build

For Oppi maintainer/agent work, use the simulator pool so parallel runs do not collide:

```bash
cd clients/apple
./scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme Oppi build
```

#### Xcode toolchain

Every Oppi dev build lane builds with Xcode 27.1 (iOS 27.1 SDK, `/Applications/Xcode-27.1.app`) through `DEVELOPER_DIR`, never `xcode-select`. The default lives in `clients/apple/scripts/xcode-toolchain.txt` and is applied by `scripts/xcode-toolchain.sh` (shell lanes) and `scripts/xcode-toolchain.ts` (`sim-pool.sh`): an explicit `DEVELOPER_DIR` wins, otherwise the pinned app is used, and a missing app fails with a message instead of falling back to another Xcode. This covers `sim-pool.sh`, `ci-simulator.sh` (a runner image that keeps Xcode elsewhere exports `DEVELOPER_DIR`), `check-coverage.sh`, `ipad-shell-diagnostic.sh`, the TailscaleKit/GhosttyVt/asset-pack builders, and the oppi-dev skill's `install.sh`, `sim-lab.sh`, `ui-validate.sh`, and coverage script. A bare `xcodebuild` in your shell still uses whatever `DEVELOPER_DIR` you have; export `DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer` first. `plutil -p <Oppi.app>/Info.plist` should show `DTSDKName` `iphonesimulator27.1` (simulator) or `iphoneos27.1` (device).

iOS TestFlight archives (`scripts/release/apple/testflight.ts`) use that same pin for `xcodegen` and `xcodebuild`, and the command logs `xcodebuild -version` before it archives. Xcode Cloud images do not have `/Applications/Xcode-27.1.app`. `clients/apple/ci_scripts/ci_post_clone.sh` checks Apple's `CI_XCODE_CLOUD` variable (documented value `TRUE`; there is no `CI_WORKSPACE` variable) and exports `DEVELOPER_DIR` from `xcode-select -p`. The clone script fails unless `xcodebuild -version` reports Xcode 27.1. Set the workflow's Xcode version to 27.1 in App Store Connect (workflow Environment) before the next Xcode Cloud build. `clients/apple/scripts/release-mac.sh` is unchanged.

#### iPhone Duo lane

`sim-pool.sh run --device-profile duo -- xcodebuild ...` (or `OPPI_SIM_DEVICE_PROFILE=duo`) leases a dedicated iPhone Duo simulator (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`) on the iOS 27.1 runtime (`com.apple.CoreSimulator.SimRuntime.iOS-27-1`). The profile uses slot 10 with a pool of one, so it never touches the iPhone slots 0-5 or the iPad lane (slots 8-9); concurrent Duo runs queue on that slot's lock. The pool creates `Oppi-Pool-10` on first use and recreates it if its device type or runtime ever differs. Explicit `OPPI_SIM_DEVICE_TYPE`, `OPPI_SIM_RUNTIME`, `OPPI_SIM_POOL_SLOT_START`, and `OPPI_SIM_POOL_COUNT` override the profile. The Duo has two displays: capture the outer one with `xcrun simctl io <udid> screenshot --display=1 <path>` and the inner one with `--display=3`.

```bash
cd clients/apple
./scripts/sim-pool.sh run --device-profile duo -- \
  xcodebuild -project Oppi.xcodeproj -scheme Oppi build
```

Public fallback when the local pool wrapper is unavailable: use a unique `-derivedDataPath`.

```bash
xcodebuild -project Oppi.xcodeproj -scheme Oppi build \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-build
```

### iOS unit tests

Use the dedicated `OppiUnitTests` scheme for `OppiTests`.

From the repo root, `./scripts/sim-pool.sh` and `clients/apple/scripts/sim-pool.sh` both work. An OppiTests-only `-scheme Oppi` run is rewritten to `OppiUnitTests` so agents do not build UI/E2E/perf bundles.

`run` always executes `xcodebuild` in the resolved checkout (`--root`, `OPPI_ROOT`, or this git root), even if you launched the script from another tree's `clients/apple`. Pass a worktree path or that tree's `clients/apple`. Missing worktree `.build/OppiTestsInfo.plist` is created automatically.

```bash
cd clients/apple
./scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests

# From any cwd, including main, test a worktree:
./scripts/sim-pool.sh run --root /path/to/worktree -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
```

Public fallback:

```bash
xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-tests \
  -only-testing:OppiTests
```

### iOS coverage gate

The repository owns separate local and CI simulator runners. `sim-pool.sh` manages persistent local simulators for parallel development. `ci-simulator.sh` selects an existing device from the ephemeral GitHub runner image and never creates or erases one. First run the focused harness self-tests. They verify path classification, retry result-bundle handling, failure classification, simulator selection, bounded simulator-readiness reboot retries, reuse of an already-booted pool simulator, DerivedData hang-progress, default compiler-index-store disable, simulator daemon slimming, lock-safe idle shutdown, and safe package-cache reset boundaries without launching a simulator. In particular, ordinary `rebuild:` application logs must not appear as linker failures, while Swift, clang, and `ld` diagnostics must remain visible.

```bash
./.githooks/pre-push --self-test

# Run the focused script checks while editing the coverage lane.
./clients/apple/scripts/sim-pool.sh self-test
./clients/apple/scripts/ci-simulator.sh self-test
./clients/apple/scripts/check-coverage.sh self-test
```

Run the full unit-test coverage gate locally with the simulator pool:

```bash
cd clients/apple
./scripts/check-coverage.sh
```

The single-device CI simulator runner is optional local coverage, not a GitHub job:

```bash
cd clients/apple
OPPI_SIMULATOR_RUNNER=ci ./scripts/check-coverage.sh
```

Do not run this command concurrently. It deliberately has no local lock and uses one existing device with one CI DerivedData path. Normal local builds and tests must use `sim-pool.sh`.

`check-coverage.sh` returns `2` only when collected coverage is below an enforced logic-layer threshold. Invalid or unavailable simulator-runner configuration returns `8`. Test, simulator, result-bundle, `xccov`, and report-analysis failures use other nonzero statuses. Swift package resolution returns `7` after both the restored-cache attempt and an empty-cache retry fail. A failed collection is not a coverage shortfall. The script prints package-resolution, build/test, report, and analysis wall times.

The local pool gives a simulator boot two 120-second readiness waits by default. For a new simulator, the second wait continues the same first-boot data migration instead of erasing and restarting it. Set `OPPI_SIM_POOL_BOOT_TIMEOUT` to change each wait or `OPPI_SIM_POOL_BOOT_RETRIES` to change the number of additional waits. An already-booted pool simulator is reused instead of shutdown/boot, unless its device environment carries E2E variables (`PI_E2E_*`, `OPPI_E2E_*`, `E2E_*`, `SECOND_E2E_*`): `simctl boot` turns the caller's `SIMCTL_CHILD_*` variables into device-level environment that survives until shutdown, so an E2E lane that boots a slot would otherwise leave every later run on it, unit tests included, starting the app in E2E mode (UIView animations off). The pool never passes the caller's `SIMCTL_CHILD_*` to its own `simctl` processes, and it probes a reused slot with `simctl spawn <udid> /usr/bin/env` and recycles (shutdown, clean boot) a contaminated one before the run, logging the variable names but not their values. If the probe itself fails, the slot is recycled. Raw `xcodebuild` on a pool device bypasses this; check `xcrun simctl getenv <udid> PI_E2E_INVITE_URL` first. After boot, `sim-pool.sh`, `ci-simulator.sh`, and `sim-lab.sh` disable unused background daemons (Siri extras, Spotlight, iCloud, PosterBoard, and similar) unless `OPPI_SIM_SLIM=0`. Those overrides persist across reboot and are reapplied after hang-recovery erase. Live Activities, speech, Photos, push, and universal links stay enabled. Maps navigation (`com.apple.navd`) also stays enabled: a missing navigationService can make the Maps widget retry and flood live diagnostics on iOS 27.2. Older slim devices with navd disabled are migrated by restoring that override and rebooting only the supplied device before tests; enabling the service in an already-spinning widget session is not sufficient. The already-slim fast path requires navd not be disabled, so the migration runs once per affected device. CI never creates or erases a simulator; it still slims the existing runner device. Pool simulators stay booted after a run; set `OPPI_SIM_POOL_KEEP_BOOTED=0` to shut them down, `OPPI_SIM_POOL_FORCE_CLEAN_BOOT=1` to recycle before xcodebuild, or `./scripts/sim-pool.sh shutdown-idle` to stop unused pool devices. Slot exclusion is Darwin `flock(2)` on a stable `$OPPI_SIM_POOL_LOCK_DIR/slot-N.lock` inode (never unlinked by the runner). Creation is not ownership. Persist `in-flight` / `uncertain` / `reusable` under flock before mutation. A dead wrapper PID does not authorize reuse by itself. Leased commands start behind a stdin gate and do not exec until the child is registered and its PGID is persisted (`flock-v2` / `gated-v1`). Parent-pipe EOF or publication failure prevents execution. Next acquire may reclaim a gated `in-flight` or `uncertain` lease when recorded groups exist and are idle, or when the ledger is proven empty (`publishedCount` 0 and not `publishing`). Legacy `flock-v1` `in-flight` records stay fail-closed, including idle pgids. Empty `flock-v1` pgids stay fail-closed. `uncertain` `flock-v1` reclaims only when recorded groups exist and are idle. Summary/`xcresulttool` failures do not quarantine a slot. Legacy `$LOCK_DIR/slot-N/` directories are skipped, not reaped. `shutdown-idle` and `prune-cache` follow the same prevent-first lease as `run`: they persist `in-flight` under flock, record child process groups, and do not leave a gated slot permanently quarantined after a proven-empty ledger. `shutdown-idle` rechecks `Booted` as device state and holds the lease through `simctl shutdown`. Killing `xcrun` does not mean CoreSimulator finished. Failed list/recheck/shutdown is reported. Hang detection (`OPPI_SIM_POOL_SILENCE_TIMEOUT`, default 180 seconds) counts log growth, DerivedData directory mtime, and CPU use of xcodebuild's process tree as progress. Long Swift compiles and module emits can print nothing for minutes, and the compilers run as xcodebuild's descendants in their own process groups, so only the tree CPU (at least a quarter of a core) keeps them alive; a run idle on all three signals is killed and retried after a simulator recovery. A finished test run stops waiting for xcodebuild after `OPPI_SIM_POOL_COMPLETION_TIMEOUT` (30 seconds) and keeps its result without a retry: the Swift Testing unit lane after `✔/✘ Test run with N tests`, and a single-bundle XCTest run of the `Oppi` or `OppiUnitTests` scheme (UI and E2E lanes) after its one `Test Suite 'Selected tests'|'All tests' passed|failed` result. Pool `xcodebuild` injects `COMPILER_INDEX_STORE_ENABLE=NO` unless the command already sets that setting or `OPPI_SIM_POOL_INDEX_STORE=1`. A matching `Oppi-Pool-N` must use the configured runtime and device type. `run` prefers a matching slot; if it leases a mismatched `Oppi-Pool-N`, it deletes that simulator under the slot lock and recreates it. The default pool is six iPhone slots (`OPPI_SIM_POOL_COUNT`, slots 0-5). Dedicated iPad lanes should start at slot 8 or higher (`OPPI_SIM_POOL_SLOT_START`).

A completed `OppiUnitTests` / `OppiTests` run is not retried when xcodebuild stalls during finalization. The pool recognizes one nonempty Swift Testing terminal result after XCTest completion, waits up to 30 seconds (`OPPI_SIM_POOL_COMPLETION_TIMEOUT`, positive seconds), then stops only its owned xcodebuild process group. After proven cleanup it returns the test result (0 for pass, 65 for test failure), while preserving any real nonzero xcodebuild exit. Attempt and final JSON include `completion_hang_detected`, `test_completion` (counts, issues, summary), and the raw `xcodebuild_exit_code` / `xcodebuild_signal`. `hang_detected` remains true. Result bundles and coverage can be incomplete; consumers that require those artifacts must still validate them. Partial/zero-test, mixed-bundle, parallel, repeated, or cancelled runs do not use this recovery. A pre-test or unfinished hang keeps the ordinary hang/retry path, and uncertain process cleanup never passes.

Parked worktrees keep Apple DerivedData in `clients/apple/.build/pool-<digits>` until the tree is removed. Do not copy or clone `.build` between checkouts; each tree needs its own cache. Reclaim idle cache without deleting logs, videos, or the stable Mac/CI paths:

```bash
./clients/apple/scripts/sim-pool.sh prune-cache
./clients/apple/scripts/sim-pool.sh prune-cache --apply
# Keep warm pool-0..5 caches on the active workstation checkout:
./clients/apple/scripts/sim-pool.sh prune-cache --apply --keep-slots 0-5
```

Dry-run is the default. Classification still lists numeric `pool-*` directories, `derived-data-*`, and one-off `mac-*` experiment dirs. It keeps `logs`, `videos`, `mac-tests`, `mac-debug`, `pre-push-mac`, `ci`, `privacy`, and `oppi-dev`. `--apply` deletes `pool-*` only after acquiring that slot's flock lease. `derived-data-*` and `mac-*` are skipped on apply (no exclusive lease shared with raw `xcodebuild`). Busy, live, and legacy slot locks are skipped. Gated `in-flight` and `uncertain` reclaim when recorded groups are idle or the ledger is proven empty; flock-v1 `in-flight` stays fail-closed. A failed pool-dir delete does not permanently quarantine the slot. `--keep-slots 0-5` retains the default warm iPhone pool caches. The next simulator build in a deleted cache recompiles from scratch (typically minutes per slot, about 2 GB/slot). This does not remove the worktree. Run it in a parked tree to reclaim that tree only.

The tracked pre-push hook is `.githooks/pre-push`. It does not collect coverage; it runs the faster local checks described above. Install it into a clone's configured hook directory after reviewing any existing local hook:

```bash
install -m 755 .githooks/pre-push "$(git rev-parse --git-path hooks)/pre-push"
```

### Swift Testing filters

`xcodebuild` strips one trailing `()` from Swift Testing identifiers. Use double parentheses for function-level filters.

```bash
# Suite
-only-testing:OppiTests/MySuiteStruct

# Function
-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'
```

### Swift Testing conventions

- Use Swift Testing for unit tests: `import Testing`, `@Test`, `#expect`.
- Use XCTest only for UI tests that require `XCUIApplication`.
- Group related tests with `@Suite`.
- Put `@MainActor` on the suite when all tests need main actor isolation.
- Use `Issue.record()` instead of `XCTFail()`.

### iOS E2E tests

Use the Oppi workflow wrapper. It starts a paired E2E server, writes invite/device-token files under `/tmp`, launches XCUITests, and cleans up the server.

Parent-facing strict UI verification with source-bound receipts is `bun clients/apple/scripts/qa-verify.ts`. See [qa-verification.md](qa-verification.md). That CLI always sets `OPPI_SIM_POOL_HANG_RETRIES=0` and does not claim Jev, speed, or terminal-mirror coverage.

```bash
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test

# Faster local iteration, no Docker
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native

# Focus one E2E test
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native \
  --only-testing OppiE2ETests/WebSocketLifecycleE2ETests/testNavigationKeepsWorkspaceListOnHTTPAndUsesBoundSessionStreams

# Preferred release gate: focused chat/composer/ask/attachment/session coverage
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group gate

# Slower extended coverage batch for pre-release or nightly coverage
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group extended
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group recovery
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group history
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group quick-session
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group extension-attention

# Broader/lab follow-up groups
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group regression
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group media --record-video=always
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group screenshot
```

`sim-test` writes E2E run artifacts under `.internal/reports/e2e-runs/<timestamp>/` by default. Set `E2E_ARTIFACT_DIR` or `E2E_DOCKER_LOG_DIR` to an absolute or repo-relative path when a release lane needs repeatable artifact collection. `OPPI_E2E_GROUP` and the release wrapper's `OPPI_RELEASE_E2E_GROUP` select the same groups. `gate`/`release-gate`/`smoke` run `ReleaseGateE2ETests` as the preferred blocking lane. `extended` runs the gate plus recovery, history, quick-session, and extension-attention batches for deeper pre-release coverage. `all` still means the historical broad `OppiE2ETests` suite, and `full-regression` keeps broad coverage for explicit slower checks.

Focused checks for the sessions-first root and direct share-extension send:

```bash
# All Sessions root, workspace drawer, workspace deep-link intake, scoped controls, and back navigation
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native \
  --only-testing OppiE2ETests/IPhoneSessionsFirstScreenshotE2ETests

# Safari share sheet → in-extension workspace selection and direct session send
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native \
  --only-testing OppiE2ETests/ShareSheetQuickSessionE2ETests

# Main-app Quick Session workspace/model/send flow
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --group quick-session
```

Focused unit coverage for navigation routing, Shortcuts text/image intake, direct share sending, credential migration, MetricKit previous-process context, and the main-thread watchdog:

```bash
cd clients/apple
./scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -only-testing:OppiTests/AppNavigationShellRoutingTests \
  -only-testing:OppiTests/WorkspaceDeepLinkTests \
  -only-testing:OppiTests/QuickSessionTriggerTests \
  -only-testing:OppiTests/StartQuickSessionIntentTests \
  -only-testing:OppiTests/ShareQuickSessionSenderTests \
  -only-testing:OppiTests/KeychainServiceTests \
  -only-testing:OppiTests/MetricKitSerializerTests \
  -only-testing:OppiTests/MainThreadLagWatchdogTests
```

Prerequisites:

- mlx-serve OpenAI-compatible endpoint on `http://127.0.0.1:11234`
- loaded chat model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` (the harness fails instead of using another model)

### Paired-server simulator labs

Use paired-server simulator labs when the UI depends on pairing, server toolbar state, workspace catalog refresh, session counts, auth, model-backed sessions, or any real server state. Use `IPhoneSessionsFirstScreenshotE2ETests` for the All Sessions root and workspace drawer. The existing `workspace-home/*` lab scenarios open one workspace's scoped detail. Use `--screenshot-preview` only for isolated mock component visuals.

The lab wrapper can run one-shot XCUITest scenarios, record simulator video, or boot a persistent simulator/server pair for manual driving:

```bash
# List scenarios
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-lab list

# One-shot scenario with screenshots + video + manifest
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-lab run \
  --scenario workspace-home/wrapping --native --record-video

# Persistent manual lab, hooked to local model/server; stop with sim-lab teardown
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-lab boot \
  --scenario workspace-home/dense-counts --record-video --replace

# Manual capture while persistent lab is running
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-lab screenshot --name after-row-tweak
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-lab teardown
```

Workspace-scoped lab files:

- Lab wrapper: `~/.pi/agent/skills/oppi-dev/scripts/apple/sim-lab.sh`
- Shared lab fixture/API/screenshot helpers: `clients/apple/OppiE2ETests/E2ELabFixtures.swift`
- Workspace-home scenarios: `clients/apple/OppiE2ETests/WorkspaceHomeScreenshotLabE2ETests.swift`
- One-shot run artifacts: `.pi/e2e-lab/runs/<timestamp>-<scenario>/manifest.json`
- XCTest screenshots: `/tmp/oppi-screenshots/*.png`

Run the current workspace-home scenarios directly through XCUITest when you do not need manifest/video collection:

```bash
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native \
  --only-testing OppiE2ETests/WorkspaceHomeScreenshotLabE2ETests/testWorkspaceHomeWrappingScreenshotLab

~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native \
  --only-testing OppiE2ETests/WorkspaceHomeScreenshotLabE2ETests/testWorkspaceHomeDenseCountsScreenshotLab
```

To add a scenario:

1. Add a case to `WorkspaceHomeLabScenario`.
2. Map the XCTest name in `currentScenario`.
3. Declare `fixtures`, `anchorWorkspaceName`, and `screenshotName`.
4. Add one focused XCTest method that calls `runWorkspaceHomeLab(...)`.
5. Prefer `E2ELabWorkspaceFixture` for normal workspace/session-count state; use `e2eLabAPIJSON(...)` only for custom server setup.

### Screenshot preview UI tests

Mock screenshot-preview surfaces launch the app with `--screenshot-preview` for isolated visual capture (`ui-validate` and manual QA), not for paired-server workspace behavior.

Post-run UI checks belong here or on a `sim-lab` scenario, not in a new XCUITest. Agent procedure lives in `.pi/skills/oppi-dev/references/local-build.md`. This file owns the launch command and artifact paths.

```bash
# Isolated surface dump: accessibility tree + audit + one PNG
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh ui-validate \
  --screen mermaid-rendering
```

Artifacts: `.pi/ui-validate/<timestamp>-<screen>/{tree.md,audit.md,screen.png,manifest.json}` from `XCUIElement.snapshot()` and `performAccessibilityAudit`. Review those files. Do not add another preview test method just to look at a screen; add a fixture to an existing named preview instead.

### Duplication and Apple guardrail check

Run after Apple UI or rendering changes. From the repo root:

```bash
bun scripts/duplication-scan.ts
```
