# Testing Guide

Use these canonical test commands for the Oppi monorepo.

## Policy as code

- Gate policy: `server/testing-policy.json`
- Change-aware local gate: `.githooks/pre-push`
- Explicit full non-coverage gate: `cd server && npm run test:gate:pr-fast`
- Full threshold-enforced coverage: local `cd server && npm run test:gate:ci-coverage` (`test:coverage` on the server) and `oppi-workflow.sh release-all`
- Coverage thresholds live in `server/vitest.config.ts` and `clients/apple/scripts/check-coverage.sh`.

The local hook reads the refs Git pushes, classifies changed paths, and runs platform checks concurrently. Server changes run static checks plus Vitest's affected tests; server configuration and protocol changes run the full non-coverage suite. Apple changes compile affected test bundles with the repository simulator pool. Each lane requires its relevant worktree paths to match the pushed commit. Successful lanes are cached by commit, pushed range, lane mode, path set, and toolchain so retries do not repeat completed work.

Full server and Apple unit coverage run on the local workstation. Pre-push keeps compile, static-analysis, architecture, and affected-test failures on the push path. Use `cd server && npm run test:gate:ci-coverage` and `clients/apple/scripts/check-coverage.sh` for threshold-enforced coverage, or `oppi-workflow.sh release-all` for a release cut. `.github/workflows/hygiene.yml` still runs secret and file-size checks for every push and pull request.

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

Server E2E coverage is documented in `server/e2e/README.md`. Prefer native mode for local work; `E2E_NATIVE=1` also suppresses Docker cleanup:

```bash
cd server
E2E_NATIVE=1 npm run test:e2e
npm run test:e2e # Docker Compose mode when that environment is explicitly needed
```

## Apple

From `clients/apple/`:

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

```bash
cd clients/apple
./scripts/sim-pool.sh run -- \
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

The repository owns separate local and CI simulator runners. `sim-pool.sh` manages persistent local simulators for parallel development. `ci-simulator.sh` selects an existing device from the ephemeral GitHub runner image and never creates or erases one. First run the focused harness self-tests. They verify path classification, retry result-bundle handling, failure classification, simulator selection, bounded simulator-readiness reboot retries, and safe package-cache reset boundaries without launching a simulator. In particular, ordinary `rebuild:` application logs must not appear as linker failures, while Swift, clang, and `ld` diagnostics must remain visible.

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

The local pool gives a simulator boot two 120-second readiness waits by default. For a new simulator, the second wait continues the same first-boot data migration instead of erasing and restarting it. Set `OPPI_SIM_POOL_BOOT_TIMEOUT` to change each wait or `OPPI_SIM_POOL_BOOT_RETRIES` to change the number of additional waits.

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

- oMLX/OpenAI-compatible model endpoint on `http://localhost:8400`
- a usable non-ASR model; the harness prefers `Qwen3.6*`

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

Mock screenshot-preview tests live in `clients/apple/OppiUITests/ScreenshotPreviewUITests.swift` and launch the app with `--screenshot-preview`. They are useful for isolated visual surfaces, not for paired-server workspace behavior.

### Duplication and Apple guardrail check

Run after Apple UI or rendering changes. From the repo root:

```bash
bun scripts/duplication-scan.ts
```


### Protocol checks

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
