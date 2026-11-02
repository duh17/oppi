# Deterministic QA core

Part of [Testing Guide](README.md); same standard. Strict iOS UI verification with source-bound receipts: one CLI, one XCTest executor, one paired success, one steering-item removal. It makes no Jev, speed, or terminal-mirror claim.

## Owner

`clients/apple/scripts/qa-verify.ts` fingerprints the tested app, server, harness, and build inputs (tracked plus relevant untracked source), allocates a fresh run directory and nonce, sets `OPPI_SIM_POOL_HANG_RETRIES=0`, reuses sim-pool and `clients/apple/scripts/e2e.sh` (never a second server lifecycle), binds each lane's sim-pool summary and built app identity, and prints one JSON object with `--json`. Step and assertion ids live in `qa-verify-lib.ts`.

## Journeys

| ID | Lane | Claim |
| --- | --- | --- |
| `composer-ready` | paired E2E | Unique `chat.input` accepts synthetic text; unique `chat.send` becomes enabled |
| `queue-remove-steering` | paired E2E | A seeded steering item is removed via `chat.messageQueue.remove.<itemId>`: its control is gone and one correlated `get_queue` `command_result` shows it absent with the queue version advanced |
| negatives | hang harness | Ambiguous or missing target, missing scope, absent postcondition, unconfirmed dispatch, unrelated wait, evidence failure never false-pass |

- The queue oracle is the UI plus the correlated `command_result` with strict row fields (nothing defaulted); refresh is not the oracle. A visible version-mismatch banner is an honest product FAIL. The busy-turn seed can race the live model: a bounded fixture caveat, never a reason to weaken the oracle or mock the queue.
- Admission requires step records in catalog order, explicit skip/cancel counts, the matching test-bundle identity, and the owned sim-pool summary. Missing, foreign, stale, malformed, skipped, cancelled, zero-step, duplicate, or incomplete receipts cannot pass.
- A generic wait (`waitExists`, `waitHittable`, `waitGone`) never confirms a dispatch; confirmation is the mutation's declared postcondition. Typing fails closed without keyboard focus.

## Commands

```bash
bun clients/apple/scripts/qa-verify.ts journeys --json
bun clients/apple/scripts/qa-verify.ts fingerprint [--json]
bun clients/apple/scripts/qa-verify.ts run --lane negatives --json
bun clients/apple/scripts/qa-verify.ts run --lane e2e --native --json
```

Inherit `OPPI_ROOT` for the worktree. `--lane all` does not start the paired lane after a timeout, cancel, or non-quiescent stop.

## What it refuses

`firstMatch`, index matches, coordinate taps, and optional passes; falling back to the app when a scope is missing or ambiguous; treating a tap's return as an outcome; clearing an unconfirmed dispatch with an unrelated wait or retrying after one; missing or latest-by-time artifacts; simulator erase or hang-retry fallback; labelling this as terminal E2E or a speed result.
