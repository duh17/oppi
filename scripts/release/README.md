# Tracked release operations

These scripts contain release-critical logic that must remain reviewable from a fresh Oppi checkout. Chen's personal `oppi-dev` skill can provide shorter wrappers, but those wrappers must delegate to these files rather than duplicate their behavior.

- `preflight.ts` — verifies component versions, Apple build numbers, What's New, release-note readiness, and tracked release paths.
- `release-notes.ts` — creates and updates the internal changelog. TestFlight What to Test remains a separate brief summary.
- `apple/testflight.ts` — archives and uploads, and exposes separate Internal TestFlight, external-group, and beta-review operations.
- `apple/asc.ts` — provides read-only App Store Connect release-status and usage helpers.

For an internal candidate, run these commands in order:

```bash
bun scripts/release/preflight.ts --build-number 44 --whats-new-from-build 43 --server-version 0.46.0 --mirror-version 0.45.0
# Run the reviewed release-candidate gates through the personal wrapper.
# After explicit upload approval:
bun scripts/release/apple/testflight.ts --build-number 44
bun scripts/release/apple/testflight.ts sync-internal 44
```

External groups and beta review are never part of the internal upload step:

```bash
bun scripts/release/apple/testflight.ts add-external-groups 44 "Pi Discord Beta" "Friends"
bun scripts/release/apple/testflight.ts submit-beta-review 44
```
