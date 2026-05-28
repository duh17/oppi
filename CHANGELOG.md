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

### Added

- **Client:** Added a Browser setting for choosing whether web links open in Oppi's in-app browser or the external browser.
- **Protocol:** Added pending permission and ask counts to workspace session-list summaries so cold workspace lists can show attention badges.
- **Docs:** Added public deep-link documentation for pairing, workspace, session, and permission links.
- **Docs:** Adopted this changelog and versioning policy for future releases.
- **Client/Server:** Added MetricKit crash diagnostic upload with persisted session context, gated by the Send Diagnostics to Server setting.

### Changed

- **Client:** App-owned deep links now use only the `oppi://` scheme; legacy `pi://` handling was removed.
- **Client:** Model switches now apply immediately without the prompt-cache warning dialog.
- **Client:** Workspace home rows use compact status indicators for active, stopped, and attention states.
- **Client:** Renamed the public diagnostics toggle to “Send Diagnostics to Server” and clarified that it covers performance metrics, client breadcrumbs, and crash diagnostics.

### Fixed

- **Client:** Session rows are fully tappable.
- **Client:** Workspace home preview rows preserve attention badges from HTTP snapshots before live request payloads arrive.

## [0.1.2] - 2026-03-31

### Notes

- Last public GitHub release before adopting this changelog. See the GitHub release and commit history for details.

[Unreleased]: https://github.com/duh17/oppi/compare/5c3ba2f4cf23...HEAD
[0.1.2]: https://github.com/duh17/oppi/releases/tag/v0.1.2
