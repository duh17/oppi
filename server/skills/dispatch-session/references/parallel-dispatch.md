# Parallel Dispatch

Run multiple sessions simultaneously in the same workspace when file sets are disjoint.

## Prerequisites

Before dispatching N sessions to the same workspace:

1. **Verify file disjointness.** List every file each session will touch. Zero overlap required.
2. **Include boundary instructions in prompts.** Each agent must know exactly which files it owns:
   ```
   IMPORTANT: Do NOT touch files outside this list. Other agents are editing other files in parallel.
   ```
3. **Shared read-only files are fine.** Multiple agents can read the same files — only writes conflict.
4. **Directory creation is idempotent.** Multiple agents can `mkdir -p` the same dir safely.

## Dispatch Pattern

```bash
DISPATCH={baseDir}/dispatch.mjs

node "$DISPATCH" --workspace myproject --name "task-1" --model "model-id" --thinking medium --todo "TODO-aaaa" --prompt "..."
node "$DISPATCH" --workspace myproject --name "task-2" --model "model-id" --thinking medium --todo "TODO-bbbb" --prompt "..."
node "$DISPATCH" --workspace myproject --name "task-3" --model "model-id" --thinking medium --todo "TODO-cccc" --prompt "..."
```

## Review Pattern

After sessions complete:

```bash
git log --oneline -N          # check commits
git show --stat <sha>         # review each commit
grep -rn "pattern" path/      # verify no remaining issues
npm test                      # full test suite
```

## Stop Sessions

```bash
TOKEN=$(jq -r .token ~/.config/oppi/config.json)
BASE="http://127.0.0.1:7749"
WS_ID="<workspace-id>"

for SID in <session1> <session2> <session3>; do
  STATUS=$(curl -s "$BASE/workspaces/$WS_ID/sessions/$SID" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.session.status')
  echo "$SID: $STATUS"
  if [ "$STATUS" = "busy" ] || [ "$STATUS" = "ready" ]; then
    curl -s -X POST "$BASE/workspaces/$WS_ID/sessions/$SID/stop" \
      -H "Authorization: Bearer $TOKEN" | jq -r '.status // .error'
  fi
done
```

## Parallel vs Worktree vs Sequential

| Scenario | Approach |
|----------|----------|
| Disjoint file edits in same repo | **Parallel dispatch** (same workspace) |
| Overlapping files or risky merges | **Worktree** (isolated branch per agent) |
| Creating new files only | **Parallel dispatch** (safe if different filenames) |
| Large refactor touching shared code | **Sequential** or **worktree** |

## Phased Refactor Example

```bash
# Phase 1: create shared infrastructure (parallel, no file overlap)
node "$DISPATCH" --workspace proj --name "refactor: shared factories" --todo TODO-aaa --prompt "Create shared factory file..."
node "$DISPATCH" --workspace proj --name "refactor: shared waiters"   --todo TODO-bbb --prompt "Create shared waiter file..."

# Review, verify, close TODOs

# Phase 2: migrate callers (parallel, disjoint file sets)
node "$DISPATCH" --workspace proj --name "migrate: network tests" --todo TODO-ddd --prompt "Migrate network tests..."
node "$DISPATCH" --workspace proj --name "migrate: chat tests"    --todo TODO-eee --prompt "Migrate chat tests..."
node "$DISPATCH" --workspace proj --name "migrate: store tests"   --todo TODO-fff --prompt "Migrate store tests..."
```
