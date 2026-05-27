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

Fast PR gate:

```bash
npm run test:gate:pr-fast
```

Server E2E coverage is documented in `server/e2e/README.md`:

```bash
cd server
npm run test:e2e
E2E_NATIVE=1 npm run test:e2e
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

Why: the full `Oppi` scheme also builds `OppiPerfTests`, `OppiUITests`, and `OppiE2ETests`, which makes focused unit-test runs look hung.

### Swift Testing filters

`xcodebuild` strips one trailing `()` from Swift Testing identifiers. Use double parentheses for function-level filters.

```bash
# Suite
-only-testing:OppiTests/MySuiteStruct

# Function
-only-testing:'OppiTests/MySuiteStruct/myTestFunc()()'
```

### iOS E2E tests

Use the Oppi workflow wrapper. It starts a paired E2E server, writes invite/device-token files under `/tmp`, launches XCUITests, and cleans up the server.

```bash
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test

# Faster local iteration, no Docker
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native

# Focus one E2E test
~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test --native \
  --only-testing OppiE2ETests/WebSocketLifecycleE2ETests/testNavigationKeepsWorkspaceListOnHTTPAndUsesBoundSessionStreams
```

Prerequisites:

- oMLX/OpenAI-compatible model endpoint on `http://localhost:8400`
- a usable non-ASR model; the harness prefers `Qwen3.6*`

### Paired-server simulator labs

Use paired-server simulator labs when the UI depends on pairing, server toolbar state, workspace catalog refresh, session counts, auth, model-backed sessions, or any real server state. Use `--screenshot-preview` only for isolated mock component visuals.

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

Workspace-home lab files:

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

### Duplication check

Run after Apple UI or rendering changes:

```bash
cd ~/workspace/oppi
bash clients/apple/scripts/check-duplication.sh
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
