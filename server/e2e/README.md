# E2E Tests

End-to-end tests that exercise the full Oppi stack: Docker server + local OMLX models.

## Prerequisites

- Docker (OrbStack recommended)
- OMLX-compatible OpenAI API server on localhost:8400 with at least one model loaded
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

## Running

```bash
# Full suite (builds Docker image, runs both suites)
cd server && npm run test:e2e

# Pairing flow only
cd server && npm run test:e2e:pairing

# Session flow only
cd server && npm run test:e2e:session

# Native mode (faster iteration — no Docker, spawns server directly)
E2E_NATIVE=1 npm run test:e2e
```

## Configuration

| Env var         | Default         | Description                                        |
| --------------- | --------------- | -------------------------------------------------- |
| `E2E_PORT`      | `17760`         | Server port                                        |
| `E2E_MODEL`     | auto-discovered | Model ID for sessions (resolved from `/v1/models`) |
| `E2E_OMLX_PORT` | `8400`          | Local OMLX server port                             |
| `E2E_MLX_PORT`  | unset           | Legacy alias for `E2E_OMLX_PORT`                   |
| `E2E_NATIVE`    | `0`             | `1` to skip Docker, run server natively            |

## Architecture

```
e2e/
├── harness.ts                  # Shared: Docker lifecycle, API/WS helpers
├── pairing-flow.e2e.test.ts    # Suite 1: pairing flow
├── paired-session.e2e.test.ts  # Suite 2: already-paired session flow
├── docker-compose.e2e.yml      # Ephemeral Docker server config
└── README.md                   # This file
```

The harness supports two modes:

- **Docker mode** (default): builds and starts `oppi-e2e` container, OMLX reached via `host.docker.internal`
- **Native mode** (`E2E_NATIVE=1`): builds server locally, starts as child process in a temp directory

Both modes generate a temporary `models.json` from the probed local OMLX model, preferring `Qwen3.6*` when available. Both modes share the same test code — only server lifecycle differs.
