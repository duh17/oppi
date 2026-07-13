# Testing Guide

Canonical test commands for the Oppi monorepo.

## Policy as code

- Gate policy: `server/testing-policy.json`
- Gate runner: `cd server && npm run test:gate:pr-fast`
- PR fast gate currently runs `check` and `test:coverage`.
- Coverage thresholds live in `server/vitest.config.ts`; use the gate output as the current source of truth.

## Server

From `server/`:

```bash
npm run check
npm test
```

### One-shot Linux validation on macOS

Use Apple `container` copy-in mode for a clean Linux check without exposing the checkout through a host bind mount. This command streams the working tree into the container, so it includes uncommitted files while excluding local build products.

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

To support Apple `container` installations without the `container cp` plugin, including 0.9, the helper uses `tar` over `container exec -i` for copy-in and optional copy-out, then deletes the ephemeral container. It does not pass `--volume` or `--mount`.

On Mac Studio, do not replace this with an OrbStack/Docker command that bind-mounts the repo or an output directory writable.

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

### Simulator build

For Oppi maintainer/agent work, use the simulator pool so parallel runs do not collide:

```bash
cd clients/apple
bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh run -- \
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
bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh run -- \
  xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test -only-testing:OppiTests
```

Public fallback:

```bash
xcodebuild -project Oppi.xcodeproj -scheme OppiUnitTests test \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/derived-data-tests \
  -only-testing:OppiTests
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
bash ~/.pi/agent/skills/oppi-dev/scripts/sim-pool.sh run -- \
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

Run after Apple UI or rendering changes:

```bash
cd ~/workspace/oppi
bun scripts/duplication-scan.ts
```

### Protocol checks

Protocol changes must update and test both sides:

- Server contracts: `server/src/types.ts` and related `server/src/types/*`
- Apple models: `clients/apple/Oppi/Core/Models/*Message.swift`
- Protocol/model tests in both `server/tests` and `clients/apple/OppiTests`

## Failure investigation

- Do not pipe `sim-pool.sh` output through `grep`, `tail`, or `head`; the summary includes the log and artifact paths.
- When a wrapper prints a `.summary.json` or full log path, inspect that path before rerunning.
- E2E native failures preserve the temporary data dir for debugging.
- For failed XCUITests, inspect the `.xcresult` and the app UI hierarchy attachment when element visibility is unclear.
