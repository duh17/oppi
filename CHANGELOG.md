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

No unreleased public changes yet.

## [0.42.0] - 2026-06-22

### Notes

- Coordinated release prep for iOS TestFlight build 39 plus npm `oppi-server@0.42.0` and `oppi-mirror@0.42.0` after the `0.41.0` compatibility release.
- This release focuses on share-sheet Quick Sessions, grouped session files, extension UI stability, large-output/timeline reliability, and a Pi runtime refresh to `0.79.10`.

### Added

- **Client:** Added the iOS share extension for starting Quick Sessions from shared text, URLs, images, and files.
- **Client:** Added directory grouping in Session Files so touched files are easier to scan in large sessions.
- **Client/Server:** Added a redacted app event stream and UX telemetry coverage for live client/session events.
- **Client/Server:** Added extension-surface viewport entry points and replay coverage for scoped widget/status UI.
- **Server/Extensions:** Added first-party Pi extension packages for the existing `ask` flow and browser automation video tool.

### Changed

- **Server:** Updated embedded Pi runtime packages to `@earendil-works/pi-coding-agent@0.79.10`, `@earendil-works/pi-ai@0.79.10`, and `@earendil-works/pi-tui@0.79.10`; this brings Pi extension compaction event metadata (`reason`, `willRetry`) and exact-version `pi update` fixes into future Oppi-seeded runtimes.
- **Packaging:** Bumped coordinated server and first-party Pi extension package metadata to `0.42.0` so the update can publish after npm `0.41.0`.
- **Client:** Session rows and titles now follow generated Pi session names, real completion/unread timing, and server health instead of heartbeat noise.
- **Client:** Large markdown/code/diff tool output and cached timeline rows now use bounded caches, viewport policies, and deferred fullscreen rendering instead of letting release-candidate rows keep growing memory or layout cost.
- **Client/Server:** Extension UI state is grouped by semantic scope, keeps background widgets out of blocking prompt badges, and reconnects permission-gate sessions before sending responses.
- **Client/Server:** Pi settings/resources now live in the workspace resource UI, with loaded resource counts visible in session stats.

### Fixed

- **Client:** Fixed Quick Session share presentation timing, shared-payload cleanup, and empty Quick Session creation.
- **Client:** Fixed busy timeline anchoring, top-scroll edge cases, streaming markdown rendering, markdown code-block sizing, escaped inline LaTeX delimiters, and full-screen code font metrics.
- **Client:** Fixed workspace directory listings for dot/generated folders and safe reads for session-created workspace files.
- **Client:** Fixed disabled biometric gates, nearby-pairing callback safety, and redacted push/session event payloads.
- **Client/Server:** Fixed mirrored session heartbeat timestamp churn, compact session-tree payloads, Pi TUI task-record log spam, bridge reuse resilience, and session-catch-up reconnect behavior.
- **Server:** Fixed release diagnostics so WebSocket telemetry avoids raw URL metadata and the mechanical review gate checks the current protocol type file.
- **Dependencies:** Updated direct `ws` usage to `8.21.0` for the Oppi server and `oppi-mirror` package.
- **Dependencies:** Updated Vite/esbuild/tsx lockfile entries, the duplication-scan CLI flag, and the server lockfile's `undici` resolution to `6.27.0`, clearing `npm audit --omit=dev` for production dependencies.

### Migration notes

- **Server:** Update npm installs with `npm install -g oppi-server@0.42.0` after publish. App-managed runtimes update through the Oppi app bundle, not `oppi update`.
- **Mirror extension:** Install or refresh the Pi extension with `pi install npm:oppi-mirror` after publish, then use `/reload` in an already-running interactive Pi session.
- **Compatibility:** `oppi-mirror@0.42.0` requires Oppi server `0.41.0` or newer and an interactive terminal `pi` process.

## [0.41.0] - 2026-06-16

### Notes

- Public server and Pi extension compatibility release for npm `oppi-server@0.41.0` and `oppi-mirror@0.41.0`.
- This release focuses on Pi extension compatibility, mirrored terminal sessions, media playback, long tool output, review tools, and safer server packaging.
- iOS TestFlight build 38 covers the main compatibility release. The build 39 candidate adds share-sheet Quick Sessions, grouped Session Files, and targeted stability fixes on top of build 38.

### Added

- **Server/Packaging:** Added npm package metadata and validation coverage for `oppi-server@0.41.0`, including packed-install smoke paths for local macOS, Mac Mini, and Linux Docker validation.
- **Packaging:** Added the public `oppi-mirror@0.41.0` Pi extension package, installable with `pi install npm:oppi-mirror` after publish.
- **Protocol/Client/Server:** Added native rendering for Pi extension prompts, replayable widgets, custom trace messages, queued approvals, status/notification requests, tool snapshots, and fallback text.
- **Client/Server:** Added video playback from workspace files, session attachments, and expanded tool rows with authenticated byte-range streaming and system controls.
- **Client:** Added reader controls for text size, line spacing, wrapping, Mermaid state diagrams, markdown code-block wrapping, and full-output viewers for large tool results.
- **Client:** Added review-comment drafts for selected code and tool output, with composer draft restoration before sending.
- **Client:** Added share-sheet Quick Sessions and directory-grouped Session Files in the build 39 candidate.

### Changed

- **Client/Server:** Pi extension prompts cover more Pi UI requests in SDK and mirrored sessions, including select, confirm, input, editor, queued approval, status, notification, and widget rendering.
- **Server:** Removed Oppi's custom subagent server implementation from this release path; subagent-style work now goes through Pi extensions or custom agents.
- **Client/Server:** Mirrored terminal sessions can reconnect, replay supported extension UI, queue follow-up messages, and hand control between terminal Pi and Oppi without losing pending prompts.
- **Client:** Expanded tool rows use native or virtualized viewers for long markdown, code, images, video, and media output instead of oversized timeline cells.
- **Client:** Session rows keep completion/unread timing stable when heartbeats, background status, or busy timeline appends arrive.
- **Client:** Workspace file browsing shows real directory entries, including dot directories and generated folders, while protected raw reads remain guarded.

### Fixed

- **Server:** Fixed SDK `/reload` so live Pi extension code reloads in the active session instead of only refreshing resource metadata.
- **Server:** Fixed release diagnostics so WebSocket telemetry avoids raw URL metadata and the mechanical review gate checks the current protocol type file.
- **Server:** Reduced noisy mirror task-record rejection logs for non-openable Pi task records.
- **Client/Server:** Fixed mirrored terminal widget replay, takeover prompts, stale contexts after compaction, concurrent forwarded dialogs, dead `pi-tui` session cleanup, and heartbeat-driven session-row timestamp churn.
- **Client:** Fixed long tool output truncation and timeline instability by loading full output on demand and evicting older cached output under memory pressure.
- **Client:** Fixed review-comment controls hiding behind the keyboard on iPad and duplicate selection actions.
- **Client:** Fixed split file navigation after compact-width rotation, escaped inline LaTeX delimiter rendering, full-screen code font metrics, and Quick Session share presentation timing.
- **Dependencies:** Updated Vite/esbuild/tsx lockfile entries and duplication-scan CLI compatibility.

### Migration notes

- **Server:** Update npm installs with `npm install -g oppi-server@0.41.0` after publish. App-managed runtimes update through the Oppi app bundle, not `oppi update`.
- **Mirror extension:** Install or refresh the Pi extension with `pi install npm:oppi-mirror` after publish, then use `/reload` in an already-running interactive Pi session.
- **Compatibility:** `oppi-mirror@0.41.0` requires Oppi server `0.41.0` or newer and an interactive terminal `pi` process.

## [0.4.0] - 2026-06-01

### Notes

- Release candidate for macOS app `0.2.0`, npm `oppi-server@0.4.0`, and the separate public Pi extension package `oppi-mirror`. The release focuses on Pi terminal mirroring, a mobile bridge for Pi extension UI, broader extension API compatibility, and the adaptive iPad workspace shell.

### Added

- **Server:** Added mirror mode for continuing Pi terminal sessions from mobile.
- **Protocol/Client/Server:** Added an extension UI relay so standard Pi extension input and confirm flows can be shown and answered on Apple clients.
- **Client/Server:** Added persisted MetricKit crash diagnostic upload gated by the Send Diagnostics to Server setting.
- **Client:** Added nearby Apple pairing discovery and an adaptive iPad workspace shell.
- **Client:** Added review-comment selection flows for file and tool output.
- **Packaging:** Added the separate public Pi extension package `oppi-mirror`, installable with `pi install npm:oppi-mirror` after publish.
- **Docs:** Added public deep-link documentation and refreshed setup, security, telemetry, sandbox, mirror, and extension docs.

### Changed

- **Server:** Replaced the custom Oppi approval flow with standard Pi extension permission handling for broader extension compatibility.
- **Client:** App-owned deep links now use only the `oppi://` scheme; retired `pi://` handling was removed.
- **Client:** Model switches now apply immediately without the prompt-cache warning dialog.
- **Client:** Renamed the public diagnostics toggle to “Send Diagnostics to Server” and clarified that it covers performance metrics, client breadcrumbs, and crash diagnostics.

### Fixed

- **Server:** Fixed server-side model switching so requested models are resolved against a refreshed runtime model registry.
- **Client:** Fixed the workspace session-list header wrapping/layout issue in the workspace overview.

### Removed

- **Server:** Removed the retired server approval stack and related routes.
- **Client:** Removed retired Apple permission screens.

### Migration notes

- **Server:** Existing Pi extensions with their own input, confirm, or approval flows can use the mobile extension UI bridge and should mostly behave as they do in terminal Pi. Existing configs with retired approval keys still start, but approval behavior now belongs to Pi extensions.

## [0.1.2] - 2026-03-31

### Notes

- Last public GitHub release before adopting this changelog. See the GitHub release and commit history for details.

[Unreleased]: https://github.com/duh17/oppi/compare/v0.42.0...HEAD
[0.42.0]: https://github.com/duh17/oppi/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/duh17/oppi/compare/v0.4.0...v0.41.0
[0.4.0]: https://github.com/duh17/oppi/compare/5c3ba2f4cf23...v0.4.0
[0.1.2]: https://github.com/duh17/oppi/releases/tag/v0.1.2
