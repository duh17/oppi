# Oppi Bug-bash Playbook (Testing v1/F)

Last updated: 2026-02-27
Owner: Oppi maintainers (iOS + server)

Scope: repeatable bug intake -> repro -> replay fixture capture -> regression follow-up across iOS + server.

## 1) Quick Start (operator flow)

1. Log bug with the intake template (Section 2).
2. Classify affected invariant (`RQ-*`) from [`requirements-matrix.md`](./requirements-matrix.md).
3. Run reproducibility checklist (Section 3) and record environment + confidence.
4. Capture replay fixture bundle (Section 4).
5. Re-run with replay flow (Section 5) on server-only or end-to-end (server + iOS).
6. Add matrix traceability row and regression test target (Section 6).

---

## 2) Intake Triage Template

Use this template for every bug-bash report before coding.

```md
# Bug Intake

- Bug ID: BUG-YYYYMMDD-###
- Title:
- Reported by:
- Date/Time (local + UTC):
- Severity: blocker | high | medium | low
- Scope: server | ios | protocol | cross-stack
- Suspected invariant: RQ-*
- First seen in: commit SHA / build / branch
- Last known good: commit SHA / build / branch (if known)

## User-visible symptom
- Expected:
- Actual:

## Repro baseline
- Deterministic? yes/no/unknown
- Repro frequency (%):
- Smallest known repro steps:
  1.
  2.
  3.

## Environment
- Server commit:
- iOS commit:
- iOS target: simulator/device + model + OS
- Model/provider config (if relevant):
- Policy mode / gate config:

## Evidence
- Logs:
- Video/screenshot:
- Transcript/trace:
- Related issue/todo:
```

### Triage rules

- If no `RQ-*` maps cleanly, add a provisional invariant in notes and update matrix later.
- If severity is `blocker`/`high`, require replay fixture before closure.
- If cross-stack, assign both server + iOS owners in the same intake.

---

## 3) Reproducibility Checklist

Mark each item pass/fail/na.

### 3.1 Baseline hygiene

- [ ] Confirm current branch + commit SHAs for iOS and server.
- [ ] Confirm local uncommitted changes are not influencing repro.
- [ ] Confirm dependency/toolchain baseline is unchanged during run.

### 3.2 Repro quality

- [ ] Repro steps reduced to minimal sequence.
- [ ] Repro run repeated at least 3 times.
- [ ] Frequency captured (e.g., `3/3`, `2/5`).
- [ ] Timestamped start/end for each run.

### 3.3 Artifact capture

- [ ] Server logs captured for repro window.
- [ ] iOS logs captured (if iOS involved).
- [ ] Input/output transcript captured.
- [ ] If async/order bug: include event timeline with timestamps.

### 3.4 Invariant mapping

- [ ] Mapped to `RQ-*` in requirements matrix.
- [ ] Added or planned regression test path and test name.

---

## 4) Replay Fixture Capture Format

Store fixtures under:

- `docs/testing/bug-bash/fixtures/<BUG-ID>/`

Recommended file layout:

```text
docs/testing/bug-bash/fixtures/<BUG-ID>/
  fixture.json
  transcript.jsonl
  server.log
  ios.log                # optional if server-only
  notes.md
```

### 4.1 `fixture.json` schema (v1)

```json
{
  "schemaVersion": 1,
  "bugId": "BUG-20260227-001",
  "title": "Short bug summary",
  "invariant": "RQ-WS-002",
  "scope": "cross-stack",
  "capturedAt": "2026-02-27T15:30:00Z",
  "commits": {
    "server": "<sha>",
    "ios": "<sha>"
  },
  "environment": {
    "iosTarget": "iPhone 16 Pro simulator iOS 26.0",
    "policyMode": "default",
    "modelProvider": "lmstudio"
  },
  "repro": {
    "deterministic": false,
    "frequency": "2/5",
    "steps": [
      "Open workspace X",
      "Send prompt Y",
      "Approve permission Z"
    ]
  },
  "artifacts": {
    "transcript": "./transcript.jsonl",
    "serverLog": "./server.log",
    "iosLog": "./ios.log",
    "notes": "./notes.md"
  },
  "expectedFailureSignal": "Duplicate assistant row appears after reconnect"
}
```

### 4.2 `transcript.jsonl` format

Use one JSON object per line. Keep raw ordering from capture source.

Required keys:

- `ts`: ISO-8601 timestamp with timezone
- `source`: `client` | `server` | `ios`
- `channel`: transport path (`ws`, `api`, `ui`, etc.)
- `event`: event/message type
- `payload`: redacted event payload

Example:

```jsonl
{"ts":"2026-02-27T15:30:01.100Z","source":"client","channel":"ws","event":"client_message","payload":{"type":"user_turn","clientTurnId":"abc"}}
{"ts":"2026-02-27T15:30:01.240Z","source":"server","channel":"ws","event":"server_message","payload":{"type":"assistant_delta","turnId":"t1","text":"hello"}}
```

Redaction rules:

- Remove secrets/tokens/device identifiers not needed for diagnosis.
- Keep structural fields (`type`, ids, ordering markers, timestamps).
- If payload is large, keep minimal failure-relevant subset and note truncation in `notes.md`.

---

## 5) Replay Execution Flow

## 5.1 Server replay (required for server/protocol/cross-stack bugs)

1. Check out the capture commit baseline if needed.
2. Run required server gates first:
   - `cd server && npm run check && npm test`
3. Re-run the relevant deterministic harness lane:
   - WebSocket/session behavior: `cd server && npm run test:e2e:linux`
   - Real runtime contract: `cd server && npm run test:e2e:lmstudio:contract`
4. Use `transcript.jsonl` + `fixture.json` to verify ordering/contract against expected failure signal.
5. Record pass/fail in fixture `notes.md` with timestamps.

## 5.2 iOS replay (required for iOS/cross-stack bugs)

1. Build/test iOS baseline:
   - `cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' build`
   - `cd ios && xcodebuild -project Oppi.xcodeproj -scheme Oppi -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test`
2. If timeline/chat/perf behavior is involved, run reliability harness:
   - `ios/scripts/test-ui-reliability.sh`
3. Replay the scenario steps from `fixture.json` and compare observable outcome to expected failure signal.
4. Capture updated iOS logs and link to regression test additions.

## 5.3 Cross-protocol validation

For any message shape / protocol behavior changes discovered during replay:

- Run `./scripts/check-protocol.sh`
- Update matrix status and bug mapping once snapshots/tests are in sync.

---

## 6) Regression Follow-up: expected outputs/artifacts

Every closed bug-bash item must produce all of the following:

1. **Matrix mapping row** in [`requirements-matrix.md`](./requirements-matrix.md) bug-bash section.
2. **Replay fixture bundle** at `docs/testing/bug-bash/fixtures/<BUG-ID>/`.
3. **Regression test reference** (exact file + test name) in bug tracking note.
4. **Verification note** stating:
   - failing behavior reproduced on old baseline,
   - fixed behavior verified on new commit,
   - gates run (`npm run check`, `npm test`, `xcodebuild test`, protocol check, etc. as applicable).

Closure checklist:

- [ ] Invariant mapped (`RQ-*`)
- [ ] Replay fixture committed
- [ ] Regression test added and passing
- [ ] Requirements matrix row updated to `fixed/verified` status
- [ ] Any remaining `partial/gap` follow-up tracked

---

## 7) Operator tips

- Prefer one fixture bundle per bug ID; avoid mixing unrelated failures.
- Keep filenames stable so follow-up commits only change content, not layout.
- For flaky repros, include both failing and passing run notes with counts.
- If capture is impossible (privacy/runtime constraints), document why and provide nearest deterministic surrogate case.
