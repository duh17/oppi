# E2E Tests

End-to-end tests that exercise the full Oppi stack: Docker server + LM Studio local models.

## Prerequisites

- Docker (OrbStack recommended)
- LM Studio running on localhost:1234 with at least one model loaded
- Default model: `glm-4.7-flash-mlx` (override with `E2E_MODEL=lmstudio/<model-id>`)

## Test Suites

### Pairing Flow (`pairing-flow.e2e.test.ts`)

Exercises the first-time device pairing lifecycle:
1. Unauthenticated access rejected (401)
2. Server generates invite with one-time pairing token
3. Client decodes invite payload (simulates QR scan)
4. POST /pair exchanges pairing token for device token
5. Replayed pairing token rejected (one-time use)
6. Device token authenticates all subsequent API calls
7. /stream WebSocket accessible with device token

### Paired Session Flow (`paired-session.e2e.test.ts`)

Exercises the full session lifecycle for an already-paired device:
1. Create workspace and session
2. Subscribe to session via /stream WebSocket
3. Send prompt, receive assistant response (text_delta + agent_end)
4. Send prompt requiring tool use, verify tool_start → tool_end lifecycle
5. Reconnect /stream, verify catch-up event replay
6. Session isolation between workspaces
7. Workspace cleanup

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

| Env var | Default | Description |
|---------|---------|-------------|
| `E2E_PORT` | `17760` | Server port |
| `E2E_MODEL` | `lmstudio/glm-4.7-flash-mlx` | Model ID for sessions |
| `E2E_NATIVE` | `0` | `1` to skip Docker, run server natively |
| `LMSTUDIO_API_URL` | `http://localhost:1234` | LM Studio API endpoint |

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
- **Docker mode** (default): builds and starts `oppi-e2e` container, LM Studio reached via `host.docker.internal`
- **Native mode** (`E2E_NATIVE=1`): builds server locally, starts as child process in a temp directory

Both modes share the same test code — only server lifecycle differs.
