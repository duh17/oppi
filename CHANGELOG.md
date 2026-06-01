# Changelog

All notable changes to Oppi will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Oppi uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for public releases.

## Versioning policy

- **Major** versions include incompatible client/server protocol changes or other user-visible breaking changes that require manual migration.
- **Minor** versions include backward-compatible features, new app/server capabilities, and additive protocol extensions.
- **Patch** versions include bug fixes, performance improvements, hardening, documentation updates, and dependency updates.
- TestFlight build numbers, Apple build numbers, and internal tags are not SemVer releases.

When a release includes multiple artifacts, the release heading uses the public tag/version. The entry notes component versions that differ, such as the iOS marketing version, macOS marketing version, or npm `oppi-server` version.

## Changelog style

Keep one top-level product changelog for coordinated client/server releases. Use component scopes inside bullets instead of duplicating the same release across multiple files.

If `oppi-server` or an Apple client starts releasing on a truly independent cadence, add a component changelog at that artifact root and include it in that artifact's package/release.

Use these component scopes:

- **Client:** iOS/macOS app changes, UI, onboarding, app settings, TestFlight-facing behavior.
- **Server:** CLI, pairing, session runtime, policy, storage, telemetry, extensions, npm package behavior.
- **Protocol:** wire-contract changes that require both server and Apple updates.
- **Docs:** README, setup, security, release, and troubleshooting docs.

Example:

```markdown
### Added

- **Client:** Added the workspace browser deep link flow.
- **Server:** Added import support for stopped local sessions.
- **Protocol:** Added `workspace_session_list` pagination fields.
```

## [Unreleased]

## [0.4.0] - 2026-06-01

### Notes

- Release candidate for macOS app `0.2.0`, npm `oppi-server@0.4.0`, and the separate public Pi extension package `oppi-mirror`. The release focuses on Pi terminal mirroring, a mobile bridge for Pi extension UI, broader extension API compatibility, and the adaptive iPad workspace shell.

### Added

- **Server:** Added mirror mode for continuing Pi terminal sessions from mobile, including runtime routing, queue bridging, route catch-up, clean stop handling, live context usage estimates, and managed resume for stopped mirror sessions.
- **Protocol/Client/Server:** Added an extension UI relay so most standard Pi input and confirm dialogs from extensions can be shown and answered on Apple clients.
- **Client/Server:** Added persisted MetricKit crash diagnostic upload gated by the Send Diagnostics to Server setting.
- **Client:** Added nearby Apple pairing discovery and an adaptive iPad workspace shell.
- **Client:** Added review-comment selection flows for file and tool output, plus refreshed extension UI snapshot coverage.
- **Server:** Added diagnostics review tooling for client logs, MetricKit reports, server logs, and combined telemetry snapshots.
- **Packaging:** Added the separate public Pi extension package `oppi-mirror`, installable with `pi install npm:oppi-mirror` after publish.
- **Docs:** Added public deep-link documentation, the changelog/versioning policy, and refreshed setup, security, telemetry, sandbox, mirror, and extension docs.

### Changed

- **Server:** Removed custom Oppi permission policy code in favor of broader Pi extension API compatibility.
- **Server:** Updated `@earendil-works/pi-*` dependencies to `0.78.0`.
- **Server:** Renamed mirror runtime terminology and logs from earlier Pi mirror naming to Oppi runtime naming.
- **Client:** App-owned deep links now use only the `oppi://` scheme; legacy `pi://` handling was removed.
- **Client:** Model switches now apply immediately without the prompt-cache warning dialog.
- **Client:** Workspace home rows, workspace status controls, context counts, mirror status indicators, and link handling preferences were tightened for the new runtime model.
- **Client:** Renamed the public diagnostics toggle to “Send Diagnostics to Server” and clarified that it covers performance metrics, client breadcrumbs, and crash diagnostics.

### Fixed

- **Server:** Hardened sandbox workspace isolation, sandbox network defaults, mirror runtime handoff, shutdown, queue bridging, and stopped-session reconnection.
- **Server:** Reduced telemetry noise, corrected telemetry review accounting, limited hot telemetry importer integrity checks, and kept mirror errors out of terminal UI.
- **Protocol/Client/Server:** Preserved approval notification session streams and restored mirror event catch-up for route changes.
- **Client:** Improved session row hit targets, quick-session composer sizing, workspace overview wrapping/layout, live git/context refresh, streaming markdown height invalidation, and chat scroll stability.
- **Client:** Restored file viewer review comments, preserved absolute tool diff line numbers, clamped expanded read-code viewports, and stabilized media preview sizing.

### Removed

- **Server:** Removed the retired server policy gate entirely, including the policy/rules/audit stack, policy routes, and persistent user-events WebSocket path.
- **Client:** Removed legacy Apple permission surfaces and replaced selected-text Pi actions with review-comment selection flows.
- **Tooling:** Removed stale TestFlight notes and the retired TestFlight script.

### Migration notes

- **Server:** Existing Pi extensions with their own input, confirm, or approval flows can use the mobile extension UI bridge and should mostly behave as they do in terminal Pi. Existing config files with `policy` or `permissionGate` keys still start; `policy` is ignored and `permissionGate` remains a compatibility switch.

## [0.1.2] - 2026-03-31

### Notes

- Last public GitHub release before adopting this changelog. See the GitHub release and commit history for details.

[Unreleased]: https://github.com/duh17/oppi/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/duh17/oppi/compare/5c3ba2f4cf23...v0.4.0
[0.1.2]: https://github.com/duh17/oppi/releases/tag/v0.1.2
