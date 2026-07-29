# E2E Tests

End-to-end tests exercise the HTTP/TLS compatibility path and isolated Iroh transport against native or containerized servers.

## Prerequisites

- The HTTP/TLS suites require an OMLX-compatible OpenAI API server on localhost:8400 with at least one loaded model. They prefer `Qwen3.6-*` and fall back to the first model returned by `/v1/models`.
- Only explicit Docker Compose mode and the isolated Iroh suite require Docker (OrbStack recommended).
- The isolated Iroh suite uses a deterministic server-local stub and never accesses a host model endpoint.
- The Tailscale benchmark requires local `tailscale`, `ssh`, `rsync`, and `scp` commands, plus a separately provisioned macOS peer reachable through batch-mode SSH. The peer requires Node.js, npm, Tailscale, and npm registry access. The runner installs locked dependencies in a unique `/tmp` directory, then removes it.

## Test Suites

### Pairing Flow (`pairing-flow.e2e.test.ts`)

Exercises the first-time device-pairing lifecycle:

1. Unauthenticated access rejected (401)
2. Server generates invite with one-time pairing token
3. Client decodes invite payload (simulates QR scan)
4. POST /pair exchanges pairing token for device token
5. Replayed pairing token rejected (one-time use)
6. Device token authenticates all subsequent API calls
7. HTTP workspace snapshots and split session WebSocket accessible with device token

### Paired Session Flow (`paired-session.e2e.test.ts`)

Exercises the full session lifecycle for a paired device:

1. Create workspace and session
2. Verify `GET /workspaces/:workspaceId/sessions` snapshots
3. Open `WS /workspaces/:workspaceId/sessions/:sessionId/stream`
4. Send prompt, receive assistant response (text_delta + agent_end)
5. Send prompt requiring tool use, verify tool_start → tool_end lifecycle
6. Reconnect the split session stream and verify fresh state
7. Session isolation between workspaces
8. Workspace cleanup

The session-list assertions use the harness `listWorkspaceSessions()` helper. The server API requires `status=active` or `status=stopped`; tests should not call the collection route without an explicit status filter.

### Isolated Iroh transport (`npm run test:e2e:iroh`)

This non-skippable harness starts separate server and client containers. They share an internal Iroh network but use separate egress networks. The server binds Oppi HTTP to `127.0.0.1`, publishes no host port, and gives the client only an Iroh endpoint ticket through a shared bootstrap volume.

The client verifies:

1. the Oppi HTTP port is unreachable from the client container;
2. Iroh-only pairing binds the device token to the client node ID;
3. one `oppi/http/1` connection carries REST reads and mutations across multiple bi-streams;
4. file downloads, byte ranges, upload records, and binary upload bodies use existing routes;
5. focused-session and app-event WebSockets use existing upgrade handlers, reconnect, and use the REST catch-up route;
6. stream cancellation and invalid bearer errors remain isolated to one bi-stream;
7. dictation control and binary audio reach the existing dictation mux and a server-local deterministic STT stub.

The command fails unless the client executes at least 25 assertions. It writes combined Compose logs to `/tmp/oppi-iroh-isolated-<pid>-artifacts/compose.log` and prints the exact path.

### Iroh network benchmark (`npm run bench:iroh-network`)

This separate non-gating lane compares three paths through dedicated containers:

- HTTP direct over a project-scoped Docker bridge;
- Iroh direct, accepted only when the selected `Connection.paths()` snapshot has `isIp=true` and `isRelay=false`;
- forced Iroh relay, accepted only when the selected snapshot has `isRelay=true` and `isIp=false`.

The relay server and client use separate egress networks. After each endpoint establishes its public relay connection, the harness allowlists that relay's resolved address and blocks all other UDP with container-local firewall rules. The client also receives a relay-only `EndpointAddr` and verifies that the Oppi HTTP listener is unreachable. No service uses host networking, `host.docker.internal`, Tailscale, a host model endpoint, or a host-published Oppi port.

The fixed sample plan is 30 cold transport connections, 200 warm authenticated `/me` requests, 200 focused-WebSocket `get_state` round trips, 20 focused-WebSocket reconnects, and five uploads plus five downloads at 1, 10, and 50 MiB. Every Iroh sample records a sanitized selected-path snapshot, connection/path counter deltas, RTT, loss, congestion events, congestion window, and MTU. A path mismatch or missing sample fails the command.

The runner writes raw JSON and a Markdown comparison to `.internal/reports/iroh-benchmark-<timestamp>.{json,md}`. Runtime Compose logs remain in `/tmp/oppi-iroh-benchmark-<pid>-artifacts/`. Public relay measurements are rate-limited shared-service observations with no SLA.

### Tailscale direct benchmark (`npm run bench:tailscale-network`)

This opt-in non-gating lane runs the same sample counts and Oppi REST, WebSocket, and file operations against a dedicated server on a separate macOS Tailscale peer. `tailscale ping` must select a direct path—not DERP—before and after the measurements. The ephemeral server uses HTTPS with a self-signed certificate. The benchmark client disables verification, while the Tailscale network path remains encrypted.

The runner accepts the SSH target and peer Tailscale IP only through environment variables, excludes them and other device and account identifiers from durable output, and writes sanitized JSON and Markdown to `.internal/reports/tailscale-network-benchmark-<timestamp>.{json,md}`. This real two-machine topology complements, rather than replaces, the same-phone physical-device A/B. It is not numerically interchangeable with the same-host container direct lanes.

Relevant feature-story dispositions from `.internal/reports/feature-user-story-status.csv`:

| Story                                      | Isolated server evidence                                                | Disposition                         |
| ------------------------------------------ | ----------------------------------------------------------------------- | ----------------------------------- |
| `SERVER-001`                               | Creates a workspace session and opens its focused stream                | Automated                           |
| `SERVER-014`                               | Focused stream, app-event stream, reconnect, and REST catch-up          | Automated                           |
| `SERVER-020`                               | Iroh-only one-time pairing, node-bound bearer, invalid-bearer rejection | Automated                           |
| `SERVER-021`                               | No HTTP shortcut; the normal HTTP/TLS suites remain separate            | Automated server evidence           |
| `SERVER-023`                               | Dictation start, binary PCM, stop, and deterministic final transcript   | Automated                           |
| `SERVER-029`                               | Existing file route ownership is exercised by full and ranged reads     | Automated transport evidence        |
| `IOS-007`, `IOS-054`, `IOS-063`, `IOS-065` | Server transport paths are covered here                                 | Apple Iroh interoperability pending |

## Running

```bash
# Preferred local HTTP/TLS mode: spawns the server directly and requires local OMLX
cd server && E2E_NATIVE=1 npm run test:e2e

# Explicit Docker Compose HTTP/TLS mode
cd server && npm run test:e2e

# Docker pairing flow only
cd server && npm run test:e2e:pairing

# Docker session flow only
cd server && npm run test:e2e:session

# Isolated Iroh matrix; no host model endpoint required
cd server && npm run test:e2e:iroh

# Reproducible HTTP-direct / Iroh-direct / forced-relay benchmark
cd server && npm run bench:iroh-network

# Opt-in direct Tailscale benchmark against a separate macOS peer
cd server && \
  TAILSCALE_BENCH_SSH_TARGET=user@peer \
  TAILSCALE_BENCH_TARGET_IP=100.x.y.z \
  npm run bench:tailscale-network
```

On Mac Studio, do not add writable repository, worktree, report, or output bind mounts to the Docker lane. The current E2E compose file builds from a copied context, mounts its generated `models.json` read-only, and stores server state in a named volume. Use native mode for normal local iteration.

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

Tailscale benchmark-only variables:

| Env var                      | Default                | Description                                                 |
| ---------------------------- | ---------------------- | ----------------------------------------------------------- |
| `TAILSCALE_BENCH_SSH_TARGET` | required               | Batch-mode SSH target for the separate macOS peer           |
| `TAILSCALE_BENCH_TARGET_IP`  | required               | Peer Tailscale IP used by Oppi and direct-path verification |
| `TAILSCALE_BENCH_REGION`     | `US Pacific Northwest` | Coarse, non-identifying region written to the report        |

## Architecture

```
e2e/
├── harness.ts                  # Shared: Docker/native/package lifecycle, API/WS/bootstrap helpers
├── harness-cli.ts              # Thin CLI wrapper for non-Vitest harness callers
├── pairing-flow.e2e.test.ts    # Suite 1: pairing flow
├── paired-session.e2e.test.ts       # Suite 2: already-paired session flow
├── docker-compose.e2e.yml           # HTTP/TLS Docker server config
├── docker-compose.iroh-isolated.yml # Isolated Iroh server/client topology
├── iroh-isolated-server.ts          # Server bootstrap and deterministic STT stub
├── iroh-isolated-client.ts          # Raw HTTP/WebSocket-over-Iroh assertions
├── run-iroh-isolated-e2e.ts         # Non-skippable Compose runner
├── docker-compose.iroh-benchmark.yml
├── iroh-network-benchmark-{server,client,common}.ts
├── run-iroh-network-benchmark.ts    # Reproducible performance runner
├── tailscale-network-benchmark-client.ts
├── tailscale-network-benchmark-server.mjs
├── run-tailscale-network-benchmark.ts # Opt-in two-peer Tailscale runner
└── README.md                        # This file
```

The harness supports two modes:

- **Docker mode** (default): builds and starts `oppi-e2e` through Docker Compose, with OMLX reached via `host.docker.internal`
- **Native mode** (`E2E_NATIVE=1`): builds the server locally, starts it as a child process in a temp directory, and skips Docker cleanup
- **Packaged native mode** (`E2E_NATIVE=1 E2E_SERVER_DIR=/path/to/node_modules/oppi-server`): runs the installed package tarball through the same native harness without rebuilding source

Both modes generate a temporary `models.json` from the probed local OMLX model, preferring `Qwen3.6*` when available. They share the same test code; only server lifecycle differs.

Apple E2E scripts remain responsible for Xcode and simulator orchestration. Server-bootstrap details should flow through this harness shape: model discovery, server lifecycle, pairing, fixture workspace creation, invite files, and the guarded extension UI injection route.
