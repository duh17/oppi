# Deterministic QA core

Parent-facing contributor CLI for strict iOS UI verification with source-bound receipts.

This is the reduced core: one CLI, one XCTest executor, one simple paired success, and one steering→follow-up queue transition. It does not include Jev, speed claims, or a terminal-mirror journey.

## Owner

`clients/apple/scripts/qa-verify.ts` is the execution owner. It fingerprints tested app, server, harness, and build-input bytes (tracked plus relevant new/untracked source), records external wrapper identity, allocates a fresh run directory and nonce, sets `OPPI_SIM_POOL_HANG_RETRIES=0`, reuses sim-pool / the documented paired E2E wrapper, binds each lane's owned sim-pool summary and built app/test-bundle identity, and prints one JSON object on `--json` stdout. Build chatter stays in the run log directory.

## Journeys

| ID | Lane | Claim |
| --- | --- | --- |
| `composer-ready` | paired E2E | Unique `chat.input` accepts synthetic text (exact field value); unique `chat.send` becomes enabled |
| `queue-move-steering-to-followup` | paired E2E | One command-seeded steering item moves to follow-up; UI plus one correlated `POST .../command` `get_queue` `command_result` |
| negatives | hang harness | Ambiguous/missing target, missing/ambiguous scope, absent postcondition, unconfirmed dispatch, unrelated wait, and evidence failure do not false-pass |

Queue setup uses existing `prompt` / `steer` / `get_queue` commands. Composer-send/stop is not the queue claim. Refresh is not the oracle. The required queue oracle is UI follow-up plus one correlated `get_queue` `command_result` with strict row fields (no defaulted version/id/message/createdAt/attachments). A visible version-mismatch banner is a required failure: honest product FAIL, not a harness pass. Terminal mirror is not exercised (`runtime=oppi`, `terminalMirrorExercised=false`). Hang-harness negatives mock the in-memory queue store.

The busy-turn seed can race the live model. That is a bounded fixture caveat, not permission to weaken the banner oracle or replace the real queue with a mock.

Requested step IDs and required assertion IDs live in `qa-verify-lib.ts`. Admission requires actual step records in catalog order, explicit nonnegative skip/cancel counts, matching compiled test-bundle identity, and the owned sim-pool summary for that command. Missing, foreign, stale, malformed, skipped, cancelled, zero-step, duplicate, incomplete, or collector-failed receipts cannot pass.

Generic `waitExists` / `waitHittable` / `waitGone` do not confirm a dispatch. Confirmation is coupled to the mutation's declared observable postcondition. An unrelated or already-present wait cannot authorize another mutation. Typing fails closed if keyboard focus is not established.

## Commands

```bash
bun clients/apple/scripts/qa-verify.ts journeys --json
bun clients/apple/scripts/qa-verify.ts fingerprint [--json]
bun clients/apple/scripts/qa-verify.ts run --lane negatives --json
bun clients/apple/scripts/qa-verify.ts run --lane e2e --native --json
```

Always inherit `OPPI_ROOT` for the worktree. The shared `apple/e2e.sh` is not in this worktree; the CLI reuses `~/.pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh sim-test` and does not invent a second server lifecycle. `--lane all` does not start the paired lane after timeout, cancel, or a non-quiescent stop.

## What it refuses

- `firstMatch`, index matches, coordinate taps, optional passes
- Falling back to the app when a scope is missing or ambiguous
- Treating tap/type return as a verified product outcome
- Clearing an unconfirmed dispatch with an unrelated wait
- Retrying after an unconfirmed dispatch
- Missing/malformed/incomplete sim-pool summaries or latest-by-time artifacts
- Simulator erase/reset or hang-retry fallback
- Labeling this slice as terminal E2E or a speed/Jev result
