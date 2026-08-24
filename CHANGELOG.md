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

Target: iOS `1.1.1` build `46`, unpublished `oppi-server@0.47.0` with bundled Pi runtime `0.84.3`, and unpublished `oppi-mirror@0.47.0`.

### Added

- **Client:** The model picker star saves that model as the Pi global default. Tapping a row still switches only the current session.
- **Client:** The thinking popover can save the current level as default. Picking a level stays session-only.
- **Client:** Session search lives in the bottom toolbar. Quick Session can pick a worktree, and `/` autocompletes workspace prompts and Skills before the session exists.
- **Client/Server:** Skill Edit uses the guided composer. Wiki links can open host files the server can already read and focus line anchors.
- **Client:** Double-tap zooms diagrams and images. Settings includes Privacy Policy and Support pages.
- **Server:** `oppi quota` prints provider usage windows. Session and Agent create accept Pi tool and thinking flags.
- **Server:** Allowlisted sandbox Oppi can spawn and steer sessions only in that workspace. Guest `ls` hides secret names.
- **Server:** Clean, already-merged Oppi worktree removes skip the approval prompt under confirmDestructiveOnly.

### Changed

- **Client:** Thinking menus list only the current model's supported levels. Failed compaction shows the error instead of looking cancelled.
- **Compatibility:** Build 46 requires `oppi-server@0.47.0` and `oppi-mirror@0.47.0`.
- **Client/Server:** Pairing uses a per-device key and short-lived HTTPS token. Iroh pairing is gone; re-pair over HTTPS or Tailscale if there is no HTTPS endpoint.
- **Client/Server:** Public session identity is Pi `Session.id` only.
- **Server:** Bundled Pi runtime packages move from `0.84.2` to `0.84.3`.
- **Mirror:** The extension connects over the owner Unix socket. Slash input from Oppi expands as Pi commands.

### Fixed

- **Client:** TestFlight Build 45 could crash shortly after launch when MetricKit delivered a nested diagnostic.
- **Client:** Wrapped Markdown tables no longer paint later rows over earlier cells.
- **Client:** Chat Files → Changed uses the same header search as All.
- **Client:** A ready session no longer opens empty when a web-search snippet cuts a UTF-16 surrogate pair.

### Removed

- **Client/Server:** Iroh pairing and the public `piSessionId` dual-ID path.

## [0.46.0] - 2026-08-10

Target: iOS `1.1.0` build `45`, `oppi-server@0.46.0` with bundled Pi runtime `0.84.1`, and `oppi-mirror@0.46.0`.

### Added

- **Client/Server:** Agents, schedules, Skills, and workspaces can be created or revised through an Oppi session from their management screens.
- **Client/Server:** Custom provider extensions can contribute models. Server details show Codex and xAI quotas, and Qwen has dedicated presentation.
- **Client:** Full-screen Markdown supports review comments, improved wide-table layout, and guided revisions from selected text.

### Changed

- **Server:** Custom provider extensions appear in the model picker and provider-auth list after install, a detected source edit, or enable/disable without an Oppi server restart. Active sessions still need `/reload`.
- **Protocol/Client/Server:** Agent, schedule, Skill, workspace, model, and session APIs changed incompatibly; Build 45 requires `oppi-server@0.46.0`.
- **Server:** Explicit model selection fails visibly when the requested model is unavailable instead of substituting another provider or model.
- **Client/Server:** Session, tool, Markdown, and cached-content presentation survives navigation, replay, and reconnection more consistently.
- **Server:** Oppi Mirror bootstrap input now expands slash commands, skills, and prompt templates through Pi instead of sending them as literal text.

### Fixed

- **Client/Server:** Kept workspace Skill toggles scoped, patched nested schedule actions correctly, completed cache persistence before follow-up reads, preserved owner themes, and gated navigation swipes on the touched scroll edge.

## [0.44.1] - 2026-07-16

### Notes

- Coordinated release for iOS `1.1.0` (build `42`) and `oppi-server@0.44.1`.
- `oppi-mirror` remains at `0.44.0`; this release does not publish a new mirror package.

### Added

- **Client/Server:** When Pi's `showCacheMissNotices` setting is enabled, live prompt-cache misses render as warning timeline rows with re-billed token and cost details. Notices are intentionally live-only and are not reconstructed after reload.
- **Client/Server:** Workspace rows show tracked, staged, and untracked Git summaries, updated from workspace API responses and app events.
- **Client:** Chat drafts are stored per session and survive navigation, app relaunch, and server switching until sent or cleared.
- **Server:** Local `oppi` commands use a bearer-authenticated Unix socket, so CLI traffic stays local and remains available when the remote TLS listener is offline.

### Changed

- **Server:** Updated the embedded Pi runtime packages to `0.80.8`, bringing cache-friendly dynamic extension tool loading and current provider/session-affinity fixes into Oppi sessions.
- **Client/Server:** The Mac app, terminal users, and managed host sessions use the same `oppi` executable installed by `npm install -g oppi-server`. The Mac app requires the npm package and does not bundle a second server runtime.
- **Server:** The package now requires Node.js 24 and compiles with the TypeScript 7 native compiler.
- **Client:** Internal builds honor the **Send Diagnostics to Server** setting, so device-local diagnostic uploads can be turned off when needed.

### Fixed

- **Client:** Isolated session and timeline caches by server, refreshed mounted views after theme changes, and reduced stream and dense-session navigation work that could stall the UI.
- **Client:** Cold-launch session links now wait for cached or refreshed sessions before routing, so Live Activity and notification links open the intended chat instead of the workspace root.
- **Client:** Kept long ask cards above the keyboard, preserved cross-block Markdown text selection and the dictation caret, and kept the Quick Session composer fitted while dismissing it only after a successful launch.
- **Client:** Preserved workspace scope after editing, kept the configured thinking-level order, showed queued attachment names, and returned edited review comments to the staged list.
- **Server:** Kept local and config commands working without Tailscale or a session database, and prevented managed agent sessions from targeting themselves through `oppi session`.
- **Client/Server:** Branched Pi sessions now open and page the active tree leaf without showing messages from another branch.

### Removed

- **Server:** Removed the unreachable `oppi-admin` extension from the npm server package.

## [0.44.0] - 2026-07-11

### Notes

- Coordinated release for iOS `1.1.0` (build `41`), `oppi-server@0.44.0`, and `oppi-mirror@0.44.0`.

### Added

- **Client:** iPhone and iPad now open to a sessions-first inbox. Sessions needing attention and sessions still working stay prominent, recent stopped sessions remain available, and a workspace sidebar or drawer opens workspace-specific sessions, files, and settings without replacing the inbox.
- **Server:** Expanded the `oppi` CLI for workspace, worktree, and session orchestration. It can create and manage workspaces and worktrees, launch sessions, send or queue messages, answer pending dialogs, watch or wait on session state, and inspect history progressively without loading a full trace.
- **Mirror extension:** Added durable lifecycle evidence for agent, turn, and tool activity in terminal-owned Pi session files.

### Changed

- **Protocol/Client/Server:** Stored attachments and tool-reported external files now load through session-scoped authenticated routes, including exact external paths reported during that session. Apple clients and servers must be updated together for these routes.

### Fixed

- **Client:** Collapsed file tool rows now prioritize showing the full filename before shortening directory paths, including when badges, edit stats, or first-pass layout reduce the available width.
- **Client:** Tool rows now use consistent backgrounds, borders, text colors, and status colors across light and dark themes.
- **Client:** Following the system appearance now loads the correct light or dark theme and recolors existing code, diffs, tool output, and session rows when appearance changes.
- **Client:** Relative images and links in session file previews resolve from the file being viewed, including in full screen.
- **Server:** Skill and extension toggles now write Pi project settings for that workspace, so changing a resource in one workspace no longer mutates global settings for other workspaces.
- **Mirror extension:** Pending blocking dialogs now replay after the bridge reconnects, so an unanswered terminal prompt remains available in Oppi.

### Migration notes

- **Mirror extension:** Install or refresh `oppi-mirror@0.44.0` after publish, then use `/reload` in any already-running interactive Pi session.

## [0.43.1] - 2026-06-30

### Notes

- Server-only npm patch; no Apple client version or protocol changes.

### Changed

- **Server:** Updated bundled Pi support to `0.80.3`.

### Fixed

- **Server:** Fixed session file previews for touched files that resolve through workspace symlinks while keeping outside-workspace paths blocked.

## [0.43.0] - 2026-06-30

### Notes

- Release prep for iOS TestFlight build 40 and npm `oppi-server@0.43.0`.
- This release focuses on a first pass at worktree-aware sessions, lower-resource long-session trace loading, extension widget and working-message rendering, Markdown/Mermaid reliability, and a Pi runtime refresh to `0.80.2`.
- Saved-agent and schedule foundations are included for server/CLI work, including approved automatic schedule runs.
- This release also prepares `oppi-mirror@0.43.0` so mirrored working-message forwarding can ship through the Pi extension package.

### Added

- **Client/Server:** Added a first pass at worktree-aware workspace/session context, including worktree metadata, selected-worktree quick actions, session launch context, and session-row indicators.
- **Client/Server:** Added trace paging and outline data so very long session histories can load in chunks instead of loading the full trace at once.
- **Client:** Added separate Session Outline and Session Files panels, inline file-browser back controls, optional haptic feedback controls, the Icon Composer app icon, and an Oppi docs prompt toggle.
- **Client:** Expanded Mermaid rendering coverage for flowcharts, sequence diagrams, state diagrams, mindmaps, and Gantt charts.
- **Mirror extension:** Added forwarding for extension working messages, working indicators, hidden-thinking labels, and tool-expanded state from terminal Pi sessions.
- **Server:** Added saved-agent, schedule, background schedule-runner, and commit-review launch foundations for CLI/API use.

### Changed

- **Server:** Updated embedded Pi runtime packages to `@earendil-works/pi-coding-agent@0.80.2`, `@earendil-works/pi-ai@0.80.2`, and `@earendil-works/pi-tui@0.80.2`.
- **Server:** Saved-agent updates can clear optional description, instruction, resource, and session-default fields with `null`.
- **Client/Server:** Extension widget/status UI now projects working status, extension-provided working messages, and working indicators natively; renders styled terminal widgets; groups widgets into strips; and throttles widget snapshots.
- **Client:** Stopped workspace previews stay hidden so the workspace home screen focuses on active or actionable sessions.

### Fixed

- **Client:** Fixed read-image attachments, deferred SVG markdown images, ordered markdown lists around code blocks, wrapped detached code blocks, review-comment markdown surfaces, review file chrome, and What's New tracking for TestFlight builds that share a marketing version.
- **Client/Server:** Fixed persistent mirror UI replay after reconnect and reduced noisy turn-lifecycle info logs.
- **Server:** Fixed active trace indexing for session search and tightened session cleanup boundaries.
- **Client:** Fixed nearby-pairing invite delivery acknowledgement before the pairing flow advances.
- **Mac:** Fixed Mac app startup when another owner already manages the server process.

### Migration notes

- **Server:** Update npm installs with `npm install -g oppi-server@0.43.0` after publish. App-managed runtimes update through the Oppi app bundle, not `oppi update`.
- **Mirror extension:** Install or refresh `oppi-mirror@0.43.0` after publish, then use `/reload` in any already-running interactive Pi session.

## [0.42.0] - 2026-06-22

### Notes

- Coordinated release prep for iOS TestFlight build 39 plus npm `oppi-server@0.42.0` and `oppi-mirror@0.42.0` after the `0.41.0` compatibility release.
- This release focuses on grouped session files, extension UI stability, large-output/timeline reliability, and a Pi runtime refresh to `0.79.10`.

### Added

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
- **Server:** Host-backed Oppi SDK sessions now load Pi skills and extensions through Pi's settings/resource resolver instead of separate workspace skill and extension allow-lists, so project `.pi/skills` and `.pi/extensions` follow the same enabled/disabled rules as terminal Pi.

### Fixed

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
- iOS TestFlight build 38 covers the main compatibility release. The build 39 candidate adds grouped Session Files and targeted stability fixes on top of build 38.

### Added

- **Server/Packaging:** Added npm package metadata and validation coverage for `oppi-server@0.41.0`, including packed-install smoke paths for local macOS, Mac Mini, and Linux Docker validation.
- **Packaging:** Added the public `oppi-mirror@0.41.0` Pi extension package, installable with `pi install npm:oppi-mirror` after publish.
- **Protocol/Client/Server:** Added native rendering for Pi extension prompts, replayable widgets, custom trace messages, queued approvals, status/notification requests, tool snapshots, and fallback text.
- **Client/Server:** Added video playback from workspace files, session attachments, and expanded tool rows with authenticated byte-range streaming and system controls.
- **Client:** Added reader controls for text size, line spacing, wrapping, Mermaid state diagrams, markdown code-block wrapping, and full-output viewers for large tool results.
- **Client:** Added review-comment drafts for selected code and tool output, with composer draft restoration before sending.
- **Client:** Added directory-grouped Session Files in the build 39 candidate.

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
- **Client:** Fixed split file navigation after compact-width rotation, escaped inline LaTeX delimiter rendering, and full-screen code font metrics.
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

[Unreleased]: https://github.com/duh17/oppi/compare/v0.46.0...HEAD
[0.46.0]: https://github.com/duh17/oppi/compare/v0.44.1...v0.46.0
[0.44.1]: https://github.com/duh17/oppi/compare/v0.44.0...v0.44.1
[0.44.0]: https://github.com/duh17/oppi/compare/v0.43.1...v0.44.0
[0.43.1]: https://github.com/duh17/oppi/compare/v0.43.0...v0.43.1
[0.43.0]: https://github.com/duh17/oppi/compare/v0.42.0...v0.43.0
[0.42.0]: https://github.com/duh17/oppi/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/duh17/oppi/compare/v0.4.0...v0.41.0
[0.4.0]: https://github.com/duh17/oppi/compare/5c3ba2f4cf23...v0.4.0
[0.1.2]: https://github.com/duh17/oppi/releases/tag/v0.1.2
