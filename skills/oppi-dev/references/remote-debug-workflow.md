# Remote Debug + Testing Workflow (Composable)

Use this workflow to keep Oppi debugging deterministic, scriptable, and collaboration-ready.

## Table of Contents

- [Command Hub](#command-hub)
- [Lane Selection](#lane-selection)
- [Lane 1 — Deterministic Simulator Proof](#lane-1--deterministic-simulator-proof)
- [Lane 2 — Local Dev Deploy Loop](#lane-2--local-dev-deploy-loop)
- [Lane 3 — Live Incident Triage](#lane-3--live-incident-triage)
- [Lane 4 — Focused Incident Capture](#lane-4--focused-incident-capture)
- [Collaboration Output Contract](#collaboration-output-contract)

## Command Hub

Use `scripts/oppi-workflow.sh` as the default entrypoint.

```bash
{baseDir}/scripts/oppi-workflow.sh help
```

The hub composes existing scripts instead of replacing them:
- repo `scripts/ios-dev-up.sh`
- repo `ios/scripts/build-install.sh`
- repo `ios/scripts/test-ui-reliability.sh`
- skill `scripts/live-debug.sh`
- skill `scripts/debug-session.sh`
- skill `scripts/capture-session-pane.sh`
- repo `scripts/capture-session.sh`

## Lane Selection

Choose exactly one lane first:

1. **Deterministic simulator proof**
   - Goal: verify UI behavior and capture screenshots.
2. **Local dev deploy loop**
   - Goal: iterate on code + server + phone quickly.
3. **Live incident triage**
   - Goal: inspect active user/device issue in real time.
4. **Focused incident capture**
   - Goal: collect a reproducible log bundle for async review.

## Lane 1 — Deterministic Simulator Proof

Checklist:
- [ ] Select a deterministic test/screenshot target.
- [ ] Run simulator reliability test loop.
- [ ] Capture screenshot artifacts with file paths.
- [ ] Report pass/fail with exact command lines.

Default command:

```bash
{baseDir}/scripts/oppi-workflow.sh sim-test
```

Targeted command:

```bash
{baseDir}/scripts/oppi-workflow.sh sim-test \
  --only-testing OppiUITests/UIHangHarnessUITests/testThemeToggleAndKeyboardDuringStreamingNoStalls
```

Validation loop:
1. Run targeted test.
2. If failing, patch and rerun the same test.
3. Run broader reliability loop.
4. Capture screenshot only after pass.

## Lane 2 — Local Dev Deploy Loop

Checklist:
- [ ] Start/restart server in tmux.
- [ ] Build and install app on device.
- [ ] Launch app and verify startup.
- [ ] Keep server logs visible in tmux pane.

Default command:

```bash
{baseDir}/scripts/oppi-workflow.sh dev-up -- --device <iphone-udid>
```

No-launch variant:

```bash
{baseDir}/scripts/oppi-workflow.sh dev-up --no-launch -- --device <iphone-udid>
```

## Lane 3 — Live Incident Triage

Checklist:
- [ ] Start live debug stream.
- [ ] Confirm active session id.
- [ ] Check combined logs with optional grep filter.
- [ ] Stop stream after triage.

Commands:

```bash
{baseDir}/scripts/oppi-workflow.sh live start --device <iphone-udid>
{baseDir}/scripts/oppi-workflow.sh live check --grep "error"
{baseDir}/scripts/oppi-workflow.sh session latest
{baseDir}/scripts/oppi-workflow.sh live stop
```

## Lane 4 — Focused Incident Capture

Checklist:
- [ ] Select session id.
- [ ] Capture in dedicated tmux pane.
- [ ] Store bundle path and summarize findings.

Preferred command:

```bash
{baseDir}/scripts/oppi-workflow.sh capture --session <session-id> --last 25m
```

Direct capture fallback:

```bash
{baseDir}/scripts/oppi-workflow.sh capture-direct --session <session-id> --last 25m
```

## Collaboration Output Contract

After every lane run, report:

1. **Lane** used (1/2/3/4)
2. **Commands** run (exact)
3. **Artifacts** created (full paths)
4. **Result** (pass/fail + concise reason)
5. **Next action** (single recommended next step)

Use this format:

```text
Lane: <name>
Commands:
- ...
Artifacts:
- /absolute/path/...
Result: PASS|FAIL — <reason>
Next: <one command or one patch target>
```
