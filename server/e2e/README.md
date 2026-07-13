# E2E Tests

End-to-end tests that exercise the full Oppi stack with a native or containerized server and local OMLX models.

## Prerequisites

- OMLX-compatible OpenAI API server on localhost:8400 with at least one model loaded
- Docker only for explicit Docker Compose mode
- Preferred model: `Qwen3.6-*` (fallback: first model returned by `/v1/models`)

## Test Suites

### Pairing Flow (`pairing-flow.e2e.test.ts`)

Exercises the first-time device pairing lifecycle:

1. Unauthenticated access rejected (401)
2. Server generates invite with one-time pairing token
3. Client decodes invite payload (simulates QR scan)
4. POST /pair exchanges pairing token for device token
5. Replayed pairing token rejected (one-time use)
6. Device token authenticates all subsequent API calls
7. HTTP workspace snapshots and split session WebSocket accessible with device token

### Paired Session Flow (`paired-session.e2e.test.ts`)

Exercises the full session lifecycle for an already-paired device:

1. Create workspace and session
2. Verify `GET /workspaces/:workspaceId/sessions` snapshots
3. Open `WS /workspaces/:workspaceId/sessions/:sessionId/stream`
4. Send prompt, receive assistant response (text_delta + agent_end)
5. Send prompt requiring tool use, verify tool_start → tool_end lifecycle
6. Reconnect the split session stream and verify fresh state
7. Session isolation between workspaces
8. Workspace cleanup

The session-list assertions use the harness `listWorkspaceSessions()` helper. The server API requires `status=active` or `status=stopped`; tests should not call the collection route without an explicit status filter.

## Running

```bash
# Preferred local mode: spawns the server directly and does not inspect Docker state
cd server && E2E_NATIVE=1 npm run test:e2e

# Explicit Docker Compose mode
cd server && npm run test:e2e

# Docker pairing flow only
cd server && npm run test:e2e:pairing

# Docker session flow only
cd server && npm run test:e2e:session
```

On Mac Studio, do not add writable repo, worktree, report, or output bind mounts to the Docker lane. The current E2E compose file builds from a copied context, mounts its generated `models.json` read-only, and stores server state in a named volume. Use native mode for normal local iteration.

## Configuration

| Env var               | Default         | Description                                                                  |
| --------------------- | --------------- | ---------------------------------------------------------------------------- |
| `E2E_PORT`            | `17760`         | Server port                                                                  |
| `E2E_MODEL`           | auto-discovered | Model ID for sessions (resolved from `/v1/models`)                           |
| `E2E_OMLX_PORT`       | `8400`          | Local OMLX server port                                                       |
| `E2E_MLX_PORT`        | unset           | Legacy alias for `E2E_OMLX_PORT`                                             |
| `E2E_NATIVE`          | `0`             | `1` to skip Docker, run server natively                                      |
| `E2E_SERVER_DIR`      | unset           | Override native server package dir for tarball/install validation            |
| `E2E_TLS_MODE`        | `self-signed`   | Native mode TLS setting; use `disabled` for iOS harnesses that need HTTP     |
| `OPPI_E2E_UI_HARNESS` | `0`             | Enables `/e2e/ui/...` injection routes for Apple extension UI snapshot tests |

## Architecture

```
e2e/
├── harness.ts                  # Shared: Docker/native/package lifecycle, API/WS/bootstrap helpers
├── harness-cli.ts              # Thin CLI wrapper for non-Vitest harness callers
├── pairing-flow.e2e.test.ts    # Suite 1: pairing flow
├── paired-session.e2e.test.ts  # Suite 2: already-paired session flow
├── docker-compose.e2e.yml      # Ephemeral Docker server config
└── README.md                   # This file
```

The harness supports two modes:

- **Docker mode** (default): builds and starts `oppi-e2e` through Docker Compose, with OMLX reached via `host.docker.internal`
- **Native mode** (`E2E_NATIVE=1`): builds the server locally, starts it as a child process in a temp directory, and skips Docker cleanup
- **Packaged native mode** (`E2E_NATIVE=1 E2E_SERVER_DIR=/path/to/node_modules/oppi-server`): runs the installed package tarball through the same native harness without rebuilding source

Both modes generate a temporary `models.json` from the probed local OMLX model, preferring `Qwen3.6*` when available. Both modes share the same test code — only server lifecycle differs.

Apple E2E scripts remain responsible for Xcode and simulator orchestration, but server bootstrap details should flow through this harness shape: model discovery, server lifecycle, pairing, fixture workspace creation, invite files, and the guarded extension UI injection route.
