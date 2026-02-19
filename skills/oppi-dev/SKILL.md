---
name: oppi-dev
description: Build, deploy, and debug Oppi iOS + oppi-server with composable workflows. This skill should be used when running simulator or device test loops, triaging live mobile incidents, inspecting session traces, or collecting incident capture bundles.
---

# Oppi Dev

Run Oppi iOS + oppi-server workflows with deterministic, composable scripts.

iOS repo: `~/workspace/oppi`
Server repo: `~/workspace/oppi`

## Table of Contents

- [Default Entry Point](#default-entry-point)
- [Workflow Lanes (Default)](#workflow-lanes-default)
- [Direct Script Escape Hatch](#direct-script-escape-hatch)
- [Server Operations](#server-operations)
- [File Locations](#file-locations)
- [Collaboration Output Contract](#collaboration-output-contract)
- [Skill Refinement Process](#skill-refinement-process)
- [References](#references)

## Default Entry Point

Use a single command hub first. Keep direct script calls as fallback.

```bash
{baseDir}/scripts/oppi-workflow.sh help
```

The command hub composes existing scripts:
- repo scripts (`scripts/ios-dev-up.sh`, `ios/scripts/build-install.sh`, `ios/scripts/test-ui-reliability.sh`, `scripts/capture-session.sh`)
- skill scripts (`live-debug.sh`, `debug-session.sh`, `capture-session-pane.sh`, `session-lookup.py`)

## Workflow Lanes (Default)

Pick one lane first. Run lane checklist. Report artifacts.

### Lane 1 — Deterministic Simulator Proof

Use for reproducible UI verification and screenshot proof.

Checklist:
- [ ] Run targeted simulator test or reliability loop.
- [ ] Validate pass/fail with exact test name.
- [ ] Capture screenshot artifact path.
- [ ] Report result with next step.

Commands:

```bash
{baseDir}/scripts/oppi-workflow.sh sim-test

{baseDir}/scripts/oppi-workflow.sh sim-test \
  --only-testing OppiUITests/UIHangHarnessUITests/testThemeToggleAndKeyboardDuringStreamingNoStalls
```

Validation loop:
1. Run targeted test.
2. Fix code.
3. Rerun targeted test.
4. Run broader reliability test.

### Lane 2 — Local Dev Loop (Server + Device)

Use for day-to-day coding + deploy iteration.

Checklist:
- [ ] Ensure server is running (launchd).
- [ ] Build/install app on device.
- [ ] Launch and verify app opens.

Commands:

```bash
{baseDir}/scripts/oppi-workflow.sh dev-up -- --device B726F6B5-ED68-58A3-A434-1EC27090E2F9

{baseDir}/scripts/oppi-workflow.sh dev-up --no-launch -- --device B726F6B5-ED68-58A3-A434-1EC27090E2F9
```

### Lane 3 — Live Incident Triage

Use for active phone-side bug reports.

Checklist:
- [ ] Start live stream.
- [ ] Confirm active session id.
- [ ] Check combined logs (`server`, `device`, `trace`).
- [ ] Stop stream after triage.

Commands:

```bash
{baseDir}/scripts/oppi-workflow.sh live start --device B726F6B5-ED68-58A3-A434-1EC27090E2F9
{baseDir}/scripts/oppi-workflow.sh live check --grep "error"
{baseDir}/scripts/oppi-workflow.sh session latest
{baseDir}/scripts/oppi-workflow.sh live stop
```

### Lane 4 — Focused Incident Capture Bundle

Use for async debugging and collaboration handoff.

Checklist:
- [ ] Select session id.
- [ ] Capture in dedicated tmux pane.
- [ ] Save artifact directory.
- [ ] Report concise findings.

Commands:

```bash
{baseDir}/scripts/oppi-workflow.sh capture --session <session-id> --last 25m

# fallback (direct capture)
{baseDir}/scripts/oppi-workflow.sh capture-direct --session <session-id> --last 25m
```

## Direct Script Escape Hatch

Use direct scripts when command-hub abstraction is not sufficient.

### Build and install on connected iPhone

Always pass `--device` with the iPhone UDID (auto-detect is unreliable):

```bash
cd ~/workspace/oppi
ios/scripts/build-install.sh --launch --device B726F6B5-ED68-58A3-A434-1EC27090E2F9
ios/scripts/build-install.sh --launch --device B726F6B5-ED68-58A3-A434-1EC27090E2F9
```

### Deploy via TestFlight (remote)

```bash
cd ~/workspace/oppi
ios/scripts/testflight.sh --bump
ios/scripts/testflight.sh --build-only
```

Requires ASC API key. Setup: `references/testflight-setup.md`.

### Build + test (simulator)

```bash
cd ~/workspace/oppi/ios
xcodegen generate
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build
xcodebuild -project Oppi.xcodeproj -scheme Oppi \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

### UI reliability loops

```bash
cd ~/workspace/oppi/ios
xcodebuild -project Oppi.xcodeproj -scheme OppiUIReliability \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test
```

Targeted harness test:

```bash
cd ~/workspace/oppi/ios
xcodebuild -project Oppi.xcodeproj -scheme OppiUIReliability \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  -only-testing OppiUITests/UIHangHarnessUITests/testThemeToggleAndKeyboardDuringStreamingNoStalls \
  test
```

Long soak (opt-in):

```bash
cd ~/workspace/oppi/ios
PI_UI_HANG_LONG=1 xcodebuild -project Oppi.xcodeproj -scheme OppiUIReliability \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' \
  -only-testing OppiUITests/UIHangHarnessUITests/testStreamingKeepsBottomPinnedWhenNearBottom \
  test
```

Harness flags:
- `PI_UI_HANG_HARNESS=1`
- `PI_UI_HANG_NO_STREAM=1`
- `PI_UI_HANG_LONG=1`

## Server Operations

### Managed service (launchd — default)

```bash
# Setup/reload plist
launchctl unload ~/Library/LaunchAgents/dev.chenda.oppi.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/dev.chenda.oppi.plist

# Restart (KeepAlive auto-restarts after stop)
launchctl stop dev.chenda.oppi

# Status
launchctl list | grep dev.chenda.oppi
curl -s http://localhost:7749/health

# Logs
tail -f ~/.local/var/log/oppi.log
```

### Manual server start (fallback, no launchd)

```bash
cd ~/workspace/oppi
npx tsx src/index.ts serve
```

### Type check + tests (oppi-server)

```bash
cd ~/workspace/oppi
npx tsc --noEmit
npx vitest run
```

## File Locations

| What | Path |
|------|------|
| iOS source | `~/workspace/oppi/ios/Oppi/` |
| Server source | `~/workspace/oppi/server/src/` |
| XcodeGen config | `~/workspace/oppi/ios/project.yml` |
| Server config | `~/.config/oppi/config.json` |
| Users | `~/.config/oppi/users.json` |
| Session state | `~/.config/oppi/sessions/<userId>/<sessionId>.json` |
| Workspace config | `~/.config/oppi/workspaces/<userId>/<workspaceId>.json` |
| JSONL traces (host) | `~/.pi/agent/sessions/<workspace-path>/` |
| JSONL traces (container) | `~/.config/oppi/sandboxes/<userId>/<sessionId>/agent/sessions/` |

## Collaboration Output Contract

After each lane run, report:

1. Lane used
2. Commands run (exact)
3. Artifacts created (absolute paths)
4. Result (PASS/FAIL + reason)
5. Next action (single recommended step)

Template:

```text
Lane: <name>
Commands:
- ...
Artifacts:
- /absolute/path/...
Result: PASS|FAIL — <reason>
Next: <one command or one patch target>
```

## Skill Refinement Process

Run the refinement loop before major skill updates:

1. Load skill + inventory files.
2. Audit against checklist.
3. Classify issues (Critical/Major/Minor).
4. Apply fixes in priority order.
5. Validate command-hub smoke tests.
6. Record refinement summary.

Detailed process: `references/skill-refinement-process.md`.

## References

- `references/remote-debug-workflow.md` — composable lane workflows and checklists
- `references/session-schema.md` — session JSON schema, trace events, REST endpoints
- `references/testflight-setup.md` — TestFlight prerequisites and API key setup
- `references/skill-refinement-process.md` — audit + refinement workflow
