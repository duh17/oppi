# Tracked release operations

These scripts contain release-critical logic that must remain reviewable from a fresh Oppi checkout. Any wrapper around them must delegate to these files rather than duplicate their behavior.

- `preflight.ts` — verifies component versions, Apple build numbers, What's New, release-note readiness, and tracked release paths.
- `release-notes.ts` — creates and updates the internal changelog. TestFlight What to Test remains a separate brief summary.
- `apple/testflight.ts` — archives and uploads with Xcode 27.1 (`/Applications/Xcode-27.1.app`, or an explicit `DEVELOPER_DIR`), and exposes separate Internal TestFlight, external-group, and beta-review operations. The archive command logs `xcodebuild -version` before `xcodegen` and `xcodebuild`. Every run (including `--build-only`) first exports the IPA locally and fails unless the signed `Oppi.app` has `aps-environment=production` and the time-sensitive entitlement, and the app and notification extension carry the App Group from their entitlements files; the upload export runs only after that check passes.
- `apple/asc.ts` — provides read-only App Store Connect release-status and usage helpers.
- `apple/asc-listing.ts` — `plan` diffs the App Store listing in App Store Connect (app information, age rating, version text, App Review notes, price, availability) against `apple/app-store-listing.json`; `apply` writes only the differences. It never submits for review, never changes the attached build, and only sets a price when none exists, and then only free. It creates no encryption declaration: the app's Info.plist declares `ITSAppUsesNonExemptEncryption` NO. Review credentials stay out of the repository: `<FILL: label>` placeholders are filled from an untracked JSON file (`ASC_LISTING_FILLS`, default `~/.config/oppi-private/app-review.json`), `apply` refuses to write a field with an unfilled placeholder, and output masks password fills. App Privacy labels and EU trader status are not in the API and stay manual.

Xcode Cloud builds use the Xcode version selected for the workflow. Set that version to 27.1 in App Store Connect (workflow Environment). `clients/apple/ci_scripts/ci_post_clone.sh` fails the build when the selected Xcode is not 27.1.

For an internal candidate, run these commands in order:

```bash
bun scripts/release/preflight.ts --build-number 45 --whats-new-from-build 43 --server-version 0.46.0 --mirror-version 0.46.0
# Run the release-candidate gates: server `npm run test:gate:ci-coverage`,
# `clients/apple/scripts/check-coverage.sh`, and the E2E groups in dev/testing/apple.md.
# After explicit upload approval:
bun scripts/release/apple/testflight.ts --build-number 45
bun scripts/release/apple/testflight.ts sync-internal 45
```

External groups and beta review are never part of the internal upload step:

```bash
bun scripts/release/apple/testflight.ts add-external-groups 45 "Pi Discord Beta" "Friends"
bun scripts/release/apple/testflight.ts submit-beta-review 45
```
