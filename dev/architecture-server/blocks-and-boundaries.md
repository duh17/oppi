# Oppi server architecture: Server blocks and HTTP/WebSocket boundaries

Part of [Oppi server architecture](../architecture-server.md).

## Main server blocks

| Block | Owns | Does not own |
| --- | --- | --- |
| `server.ts` | startup, wiring, HTTPS, WebSocket, auth shell, service lifecycle | session semantics |
| `routes/*` | HTTP parsing, auth-checked boundaries, response shapes, app-event emission | lifecycle, list, trace, runtime policy |
| `session-lifecycle-service.ts` | create/import, resume, stop, fork, delete, mirror promotion | HTTP mapping |
| `session-list-service.ts` | recent/workspace/archive rows, runtime overlays, catalog joins | query parsing |
| `session-trace-service.ts` | trace precedence, tool output lookup, diffs, changed files | streaming bytes |
| `current-file.ts` | origin resolution, sandbox realpath confinement, servable limits, ranges, sidecars | HTTP status mapping |
| `git-safe.ts` | the only place the host runs git: mount confinement, read-only shadow git dir, no sandbox worktrees | status/diff parsing |
| `token-usage.ts` | static built-in pricing | lifecycle |
| `agent-launch-service.ts` | idempotent saved-Agent and schedule launches | HTTP mapping |
| `agent-schedules.ts` + `agent-schedule-runner.ts` | schedule definitions, due runs, leases, run history | Apple UI |
| `app-event-stream.ts` | app-event WebSocket and its allowlist | focused replay, commands |
| `stream.ts` + `ws-message-handler.ts` | focused session and audio framing, fan-out, client-message routing | workspace lists |
| `runtime-router.ts` | ownership dispatch (`SessionRuntimes`) | projection semantics |
| `sessions.ts` + `session-*` | managed lifecycle, queue, stop, event translation | HTTP shaping |
| `pi-tui-mirror-runtime.ts` | bridge registration, takeover, queue, command proxying | Apple transport |
| `session-sqlite-store.ts` + `local-sessions.ts` | read models, local JSONL catalog | command delivery |

## Listeners

- The local listener is mandatory: HTTP over an owner-only Unix socket at `$OPPI_DATA_DIR/run/oppi.sock` (deep data paths use a deterministic socket in the user's temp runtime dir). Directory `0700`, socket and startup lock `0600`, stale paths ownership-checked, concurrent owners refused.
- The network listener serves HTTPS and scoped WebSockets; TLS preparation runs off the main thread after the local socket listens. An expected Tailscale availability failure disables the remote listener; unexpected errors are fatal; TLS failure never falls back to plaintext.
- The mirror bridge (`/mirror/v1/bridge`) is bearer-free and lives only on the Unix socket, whose ownership is the trust boundary; the network listener answers 404 for it and rejects owner `sk_` tokens.

## Routes

`RouteHandler` dispatches to the domain files in `server/src/routes/`; `sessions.ts` serves workspace and control scopes and delegates policy to the session services. Every route also needs a [registry row](../architecture-server.md#route-registry).

**Current files** (`host-files.ts`, writes in `workspace-file-edit.ts`):

- Workspace-, skill-, and pi-origin reads advertise a strong `ETag` of the exact bytes. `origin=skill` resolves through `ServerResourceService.skillEditRoot` (editable Skills only, a single-file Skill limited to its file). `origin=pi` is allowlisted in `pi-agent-files.ts` (`SYSTEM.md`, `prompts/*.md`), re-checked on the canonical path so a link cannot reach another agent file.
- A missing allowlisted pi file answers an empty body, no `ETag`, and `X-Oppi-Creatable: 1`; one `PUT` with `If-None-Match: *` creates it via an fsynced temp `link`ed into place (a file that appeared first is 412). Workspace and Skill files are never created.
- Writes serialize per canonical file in-process only. The last recheck proves the target tag and the temp's inode and bytes, then renames by path; a same-host writer that swaps the temp after that check can still win (an accepted race, like an agent or git writing during the save). A 200 means "the editor's bytes were renamed into place", not a no-clobber guarantee.

## WebSocket upgrades

| Path | Owner | Purpose |
| --- | --- | --- |
| `/workspaces/:workspaceId/sessions/:sessionId/stream` | `BoundSessionStreamMux` | focused timeline, commands, queue, state |
| `/control-sessions/:sessionId/stream` | `BoundSessionStreamMux` | control sessions through the same path |
| `/app/events/stream` | `AppEventStreamMux` | session rows, extension attention |
| `/dictation/stream` | `DictationStreamMux` | dictation control and audio |
| `/mirror/v1/bridge` (Unix socket only) | `PiTuiMirrorRuntime` | terminal mirror registration and commands |
