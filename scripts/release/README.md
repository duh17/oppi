# Tracked release operations

These scripts contain release-critical logic that must remain reviewable from a fresh Oppi checkout. Chen's personal `oppi-dev` skill can provide shorter wrappers, but those wrappers must delegate to these files rather than duplicate their behavior.

- `preflight.ts` — verifies component versions, Apple build numbers, What's New, release-note readiness, and tracked release paths.
- `release-notes.ts` — creates and updates the internal changelog. TestFlight What to Test remains a separate brief summary.
- `apple/testflight.ts` — archives and uploads with Xcode 27.1 (`/Applications/Xcode-27.1.app`, or an explicit `DEVELOPER_DIR`), and exposes separate Internal TestFlight, external-group, and beta-review operations. The archive command logs `xcodebuild -version` before `xcodegen` and `xcodebuild`.
- `apple/asc.ts` — provides read-only App Store Connect release-status and usage helpers.

Xcode Cloud builds use the Xcode version selected for the workflow. Set that version to 27.1 in App Store Connect (workflow Environment). `clients/apple/ci_scripts/ci_post_clone.sh` fails the build when the selected Xcode is not 27.1. `clients/apple/scripts/release-mac.sh` is unchanged.

For an internal candidate, run these commands in order:

```bash
bun scripts/release/preflight.ts --build-number 45 --whats-new-from-build 43 --server-version 0.46.0 --mirror-version 0.46.0
# Run the reviewed release-candidate gates through the personal wrapper.
# After explicit upload approval:
bun scripts/release/apple/testflight.ts --build-number 45
bun scripts/release/apple/testflight.ts sync-internal 45
```

External groups and beta review are never part of the internal upload step:

```bash
bun scripts/release/apple/testflight.ts add-external-groups 45 "Pi Discord Beta" "Friends"
bun scripts/release/apple/testflight.ts submit-beta-review 45
```
