# Oppi server architecture: Server blocks and HTTP/WebSocket boundaries

Part of [Oppi server architecture](../architecture-server.md). Main server blocks and the HTTP and WebSocket surface.

## Main server blocks

| Block                                             | Owns                                                                                                                 | Does not own                               |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `server.ts`                                       | startup, dependency wiring, HTTPS, WebSocket, auth shell, and service lifecycle                                      | session semantics                          |
| `routes/*`                                        | HTTP parsing, auth-checked route boundaries, response shapes, app-event emission                                     | lifecycle, list, trace, or runtime policy  |
| `session-lifecycle-service.ts`                    | create/import, resume/open, stop, fork, delete, and mirror promotion policy                                          | HTTP response mapping                      |
| `session-list-service.ts`                         | recent/workspace/archive session row shaping, active runtime overlays, local-session catalog joins                   | route query parsing                        |
| `session-trace-service.ts`                        | trace source precedence, tool output lookup, overall diffs, changed-file summaries, and session-raw result mapping   | streaming bytes to HTTP responses          |
| `current-file.ts`                                 | current-file origin resolution, sandbox realpath confinement, servable-file limits, byte ranges, sidecar discovery  | route parsing and HTTP status mapping      |
| `session-title-generator.ts` + `token-usage.ts`   | Provider-owned Pi model requests and static built-in pricing lookup                                                  | session lifecycle or route behavior        |
| `agent-launch-service.ts`                         | idempotent saved-Agent and schedule launches into managed sessions                                                   | HTTP response mapping                      |
| `agent-schedules.ts` + `agent-schedule-runner.ts` | durable schedule definitions, due-run materialization, lease claiming, dispatch, and run history                     | Apple UI routing                           |
| `app-event-stream.ts`                             | global app-event WebSocket, app-event allowlist, row and extension UI mapping, workspace invalidation mapping        | focused timeline replay or command routing |
| `stream.ts` + `ws-message-handler.ts`             | focused session and audio WebSocket framing, fan-out, client-message routing                                         | workspace list data flow                   |
| `runtime-router.ts`                               | runtime ownership dispatch through `SessionRuntimes`                                                                 | shared Pi event projection semantics       |
| `sessions.ts` + `session-*`                       | managed session lifecycle, queue, stop, event translation, SDK calls                                                 | HTTP response shaping                      |
| `pi-tui-mirror-runtime.ts`                        | terminal mirror bridge registration, takeover, queue, and command proxying                                           | Apple focused-session transport            |
| `session-sqlite-store.ts` + `local-sessions.ts`   | persisted read models and local JSONL catalog                                                                        | runtime command delivery                   |

## HTTP and WebSocket boundaries

`server.ts` creates a mandatory local listener and, when configured, a network listener. Both share the same HTTP route and bearer-authentication shell:

- The mandatory local listener serves HTTP over an owner-only Unix socket. Its normal path is `$OPPI_DATA_DIR/run/oppi.sock`; deep custom data-directory paths use a deterministic socket under the user's temporary runtime directory. The runtime directory is `0700`, the socket and startup lock are `0600`, stale paths are ownership-checked, and startup refuses concurrent owners.
- The network listener serves configured HTTP(S) and scoped WebSockets to remote clients. TLS preparation runs off the main thread after the local socket begins listening, so certificate commands and renewal-lock waits do not block local requests. Expected Tailscale availability failures disable the remote listener; unexpected preparation errors remain fatal. Network TLS failure must never create a plaintext fallback.

The local socket accepts the bearer-free `/mirror/v1/bridge` upgrade and owner-authenticated upgrades for app-event, focused-session, control-session, and dictation streams. That mirror bridge stays bearer-free because Unix-socket ownership is the trust boundary. The network listener returns 404 for the mirror bridge and rejects owner `sk_` tokens. `server.ts` validates network startup security, handles `/health`, authenticates requests, and delegates authenticated HTTP from either listener to `RouteHandler`.

The server's supported remote boundary is HTTPS/WSS with per-device P-256 keys and short-lived access tokens. The owner Unix socket is the local CLI and Mac-app API, including owner-authenticated live streams; it is not a remote transport. The bearer-free Mirror bridge stays on that socket only.

`RouteHandler` owns route dispatch across domain files:

- `routes/identity.ts` — user, server info, pairing, stats, runtime status, provider-auth helpers.
- `routes/workspaces.ts` — workspace catalog, CRUD, Git status, worktrees, quick actions, review comments.
- `routes/sessions.ts` — session HTTP boundary for workspace and declared control scopes: create/import, resume, stop, fork, delete, traces, catch-up, tool output, session files, and diffs. Lifecycle, list, and trace/file policy is delegated to application services.
- `routes/agents.ts` — saved Agent definitions and saved-Agent session launches.
- `routes/schedules.ts` — schedule CRUD, manual runs, run history, and pause/resume/archive/restore.
- `routes/server-resources.ts` — server-global Skill/extension catalogs, server-authored capabilities, contained Skill file reads, enable/disable, and Mobile Output Guide configuration.
- `routes/uploads.ts` — chat attachment upload records and content.
- `routes/workspace-files.ts` — workspace `/paths` index, `contents` listings, and the legacy workspace `raw` byte route (GET/HEAD only).
- `routes/host-files.ts` — unified `/files/current` reads, guarded workspace-origin `PUT`, same-stem sidecar discovery, legacy exact-path host `/files/raw`, and home-directory listings. Eligible workspace-origin reads advertise a strong `ETag` of the exact returned bytes. Writes live in `workspace-file-edit.ts`. Same-directory temp, fsync, mode-preserving rename is not compare-and-swap against agent, git, or shell writers; only in-process editor PUTs for the same canonical file are serialized. The last recheck proves the target tag and the temp entry's inode and bytes, then renames by path. Rename and temp cleanup are path operations, not inode-safe: a same-host writer that swaps the temp name after that last check, or between cleanup's `lstat` and `unlink`, can still win. That is an accepted residual race of the same class as an agent, git, or shell writing the directory during the save. Clients must treat a 200 as "the editor's bytes were renamed into place", not as an absolute no-clobber guarantee.
- `routes/themes.ts`, `routes/skills.ts`, `routes/provider-auth.ts`, `routes/telemetry.ts`, and E2E harness routes.

WebSocket upgrade paths are explicit:

| Path                                                  | Owner                   | Purpose                                                  |
| ----------------------------------------------------- | ----------------------- | -------------------------------------------------------- |
| `/workspaces/:workspaceId/sessions/:sessionId/stream` | `BoundSessionStreamMux` | workspace-focused timeline, commands, queue sync, state  |
| `/control-sessions/:sessionId/stream`                 | `BoundSessionStreamMux` | control-focused timeline through the same runtime path   |
| `/app/events/stream`                                  | `AppEventStreamMux`     | app-wide session row and extension UI attention events   |
| `/dictation/stream`                                   | `DictationStreamMux`    | dictation control and binary audio                       |
| `/mirror/v1/bridge` (owner Unix socket only)          | `PiTuiMirrorRuntime`    | terminal Pi TUI mirror registration and command proxying |
