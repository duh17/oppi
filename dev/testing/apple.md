# Testing Guide: Apple

Part of [Testing Guide](README.md). iOS build, unit, coverage, E2E, simulator labs, and Swift Testing filters.

## Apple

From `clients/apple/`:

### Build TailscaleKit

The iOS app embeds the official TailscaleKit framework, which is built locally and not tracked. Run once per checkout, and again after the pinned libtailscale commit or the omitted-feature list (`BUILD_ID`) changes. It needs Go (cgo) and Xcode, and keeps Go caches under `clients/apple/.build/tailscalekit`. A second checkout reuses `~/Library/Caches/oppi-tailscalekit/<build-id>/` without Go or Xcode:

```bash
cd clients/apple
./scripts/build-tailscalekit.sh
```

Without it, the Oppi target fails with a missing `Vendor/TailscaleKit/TailscaleKit.xcframework`.

### Nerd Font asset pack

Nerd Font icons ship as the Apple-hosted Background Assets pack `NerdFontSymbols` (prefetch policy), not in the app binary. `OppiAssetDownloader` (ExtensionKit, `StoreDownloaderExtension`) lets the system download it; `NerdFontSymbols.swift` registers the font and adds it as every code font's cascade fallback. Build the pack from the pinned, SHA-256-checked Symbols Nerd Font Mono:

```bash
cd clients/apple
./scripts/build-nerd-font-asset-pack.sh   # -> build/asset-packs/NerdFontSymbols.aar
```

Upload the `.aar` to App Store Connect (Transporter, `altool`, or the App Store Connect API) and submit it with the next TestFlight or App Store build; packs are versioned and reviewed separately from builds. Apple hosting serves only TestFlight and App Store installs. Xcode and simulator builds report the pack unavailable unless a `xcrun ba-serve` mock server and a Background Assets URL override are set up (see Apple's "Testing asset packs locally").

### Build the terminal engine

The iOS app statically links a pinned libghostty-vt build, without SIMD C++
libraries. Kitty graphics is compiled in; PNG decode is an embedder callback,
and file image loads are not enabled. The framework is untracked. A cache miss
needs exactly Zig 0.16.0 and Xcode with the iOS device and simulator SDKs:

```bash
clients/apple/scripts/build-ghostty-vt.sh
```

The Oppi pre-build phase runs this command. Other checkouts reuse
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

The local pool gives a simulator boot two 120-second readiness waits by default. For a new simulator, the second wait continues the same first-boot data migration instead of erasing and restarting it. Set `OPPI_SIM_POOL_BOOT_TIMEOUT` to change each wait or `OPPI_SIM_POOL_BOOT_RETRIES` to change the number of additional waits. An already-booted pool simulator is reused instead of shutdown/boot, unless its device environment carries E2E variables (`PI_E2E_*`, `OPPI_E2E_*`, `E2E_*`, `SECOND_E2E_*`): `simctl boot` turns the caller's `SIMCTL_CHILD_*` variables into device-level environment that survives until shutdown, so an E2E lane that boots a slot would otherwise leave every later run on it, unit tests included, starting the app in E2E mode (UIView animations off). The pool never passes the caller's `SIMCTL_CHILD_*` to its own `simctl` processes, and it probes a reused slot with `simctl spawn <udid> /usr/bin/env` and recycles (shutdown, clean boot) a contaminated one before the run, logging the variable names but not their values. If the probe itself fails, the slot is recycled. Raw `xcodebuild` on a pool device bypasses this; check `xcrun simctl getenv <udid> PI_E2E_INVITE_URL` first. After boot, `sim-pool.sh`, `ci-simulator.sh`, and `sim-lab.sh` disable unused background daemons (Siri extras, Spotlight, iCloud, PosterBoard, and similar) unless `OPPI_SIM_SLIM=0`. Those overrides persist across reboot and are reapplied after hang-recovery erase. Live Activities, speech, Photos, push, and universal links stay enabled. Maps navigation (`com.apple.navd`) also stays enabled: a missing navigationService can make the Maps widget retry and flood live diagnostics on iOS 27.2. Older slim devices with navd disabled are migrated by restoring that override and rebooting only the supplied device before tests; enabling the service in an already-spinning widget session is not sufficient. The already-slim fast path requires navd not be disabled, so the migration runs once per affected device. CI never creates or erases a simulator; it still slims the existing runner device. Pool simulators stay booted after a run; set `OPPI_SIM_POOL_KEEP_BOOTED=0` to shut them down, `OPPI_SIM_POOL_FORCE_CLEAN_BOOT=1` to recycle before xcodebuild, or `./scripts/sim-pool.sh shutdown-idle` to stop unused pool devices. Slot exclusion is Darwin `flock(2)` on a stable `$OPPI_SIM_POOL_LOCK_DIR/slot-N.lock` inode (never unlinked by the runner). Creation is not ownership. Persist `in-flight` / `uncertain` / `reusable` under flock before mutation. A dead wrapper PID does not authorize reuse by itself. Leased commands start behind a stdin gate and do not exec until the child is registered and its PGID is persisted (`flock-v2` / `gated-v1`). Parent-pipe EOF or publication failure prevents execution. Next acquire may reclaim a gated `in-flight` or `uncertain` lease when recorded groups exist and are idle, or when the ledger is proven empty (`publishedCount` 0 and not `publishing`). Legacy `flock-v1` `in-flight` records stay fail-closed, including idle pgids. Empty `flock-v1` pgids stay fail-closed. `uncertain` `flock-v1` reclaims only when recorded groups exist and are idle. Summary/`xcresulttool` failures do not quarantine a slot. Legacy `$LOCK_DIR/slot-N/` directories are skipped, not reaped. `shutdown-idle` and `prune-cache` follow the same prevent-first lease as `run`: they persist `in-flight` under flock, record child process groups, and do not leave a gated slot permanently quarantined after a proven-empty ledger. `shutdown-idle` rechecks `Booted` as device state and holds the lease through `simctl shutdown`. Killing `xcrun` does not mean CoreSimulator finished. Failed list/recheck/shutdown is reported. Hang detection treats DerivedData directory mtime as progress, not only log growth. Pool `xcodebuild` injects `COMPILER_INDEX_STORE_ENABLE=NO` unless the command already sets that setting or `OPPI_SIM_POOL_INDEX_STORE=1`. A matching `Oppi-Pool-N` must use the configured runtime and device type. `run` prefers a matching slot; if it leases a mismatched `Oppi-Pool-N`, it deletes that simulator under the slot lock and recreates it. The default pool is six iPhone slots (`OPPI_SIM_POOL_COUNT`, slots 0-5). Dedicated iPad lanes should start at slot 8 or higher (`OPPI_SIM_POOL_SLOT_START`).

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
