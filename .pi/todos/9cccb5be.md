{
  "id": "9cccb5be",
  "title": "P0: Add sandbox sync regression tests for symlink dereference",
  "tags": [
    "pi-remote",
    "sandbox",
    "testing",
    "regression",
    "phase-0"
  ],
  "status": "done",
  "created_at": "2026-02-07T16:27:14.190Z"
}

## Done

### Changes
- **New file: `pi-remote/src/sync.ts`** — extracted `copyFileDereferenced`, `syncFile`, `syncOptionalFile`, `isNewer`, `resolvePath` as exported pure functions
- **Modified: `pi-remote/src/sandbox.ts`** — imports sync utilities from `sync.ts`, removed private methods and module-level helpers
- **New file: `pi-remote/test-sandbox-sync.ts`** — 28 assertions across 15 test cases

### Test coverage
- `copyFileDereferenced`: symlink → regular, nested chain, mode preservation, regular file passthrough
- `syncFile`: symlink dereference, mtime-based skip/copy, missing source no-op
- `syncOptionalFile`: enabled+symlink, disabled removes dest, disabled no-op, enabled+missing source
- `isNewer`: newer/older/missing file cases
- Regression canary: proves `cpSync` preserves symlinks (old bug) vs `copyFileDereferenced` (fixed)
- Fetch allowlist scenario: symlinked dotfiles → regular file in sandbox

### Run
```bash
cd pi-remote && npx tsx test-sandbox-sync.ts
```
