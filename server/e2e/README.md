# E2E Tests

End-to-end tests exercise the HTTP/TLS compatibility path against native or containerized servers.

## Prerequisites

- Model-backed suites run `anthropic/claude-haiku-5-5` through your Pi Anthropic login in `~/.pi/agent/auth.json` (override with `E2E_SOURCE_PI_AGENT_DIR`). Run `pi` and `/login` first. In strict mode the harness fails when that login is missing.
- Explicit Docker Compose mode requires Docker (OrbStack recommended).
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
5. Send a prompt requiring bash to print `E2E_TOOL_OK`; require correlated
   tool_start → tool_output containing the marker → tool_end before agent_end
6. Reconnect the split session stream and verify fresh state
7. Session isolation between workspaces
8. Workspace cleanup

The session-list assertions use the harness `listWorkspaceSessions()` helper. The server API requires `status=active` or `status=stopped`; tests should not call the collection route without an explicit status filter.

### Tailscale direct benchmark (`npm run bench:tailscale-network`)

This opt-in non-gating lane runs a fixed sample plan of Oppi REST, WebSocket, and file operations against a dedicated server on a separate macOS Tailscale peer. `tailscale ping` must select a direct path—not DERP—before and after the measurements. The ephemeral server uses HTTPS with a self-signed certificate. The benchmark client disables verification, while the Tailscale network path remains encrypted.

The runner accepts the SSH target and peer Tailscale IP only through environment variables, excludes them and other device and account identifiers from durable output, and writes sanitized JSON and Markdown to `.internal/reports/tailscale-network-benchmark-<timestamp>.{json,md}`. This real two-machine topology complements, rather than replaces, the same-phone physical-device A/B. It is not numerically interchangeable with other network paths.

Relevant feature-story dispositions from `.internal/reports/feature-user-story-status.csv`:

| Story        | Server evidence                                                       | Disposition                  |
| ------------ | --------------------------------------------------------------------- | ---------------------------- |
| `SERVER-001` | Creates a workspace session and opens its focused stream              | Automated                    |
| `SERVER-014` | Focused stream, app-event stream, reconnect, and REST catch-up        | Automated                    |
| `SERVER-021` | No HTTP shortcut; the normal HTTP/TLS suites remain separate          | Automated server evidence    |
| `SERVER-023` | Dictation start, binary PCM, stop, and deterministic final transcript | Automated                    |
| `SERVER-029` | Existing file route ownership is exercised by full and ranged reads   | Automated transport evidence |

## Running

```bash
# Preferred local HTTP/TLS mode: spawns the server directly
cd server && E2E_NATIVE=1 npm run test:e2e

# Explicit Docker Compose HTTP/TLS mode
cd server && npm run test:e2e

# Docker pairing flow only
cd server && npm run test:e2e:pairing

# Docker session flow only
cd server && npm run test:e2e:session

# Opt-in direct Tailscale benchmark against a separate macOS peer
cd server && \
  TAILSCALE_BENCH_SSH_TARGET=user@peer \
  TAILSCALE_BENCH_TARGET_IP=100.x.y.z \
  npm run bench:tailscale-network
```

On Mac Studio, do not add writable repository, worktree, report, or output bind mounts to the Docker lane. The current E2E compose file builds from a copied context, mounts the generated Haiku-lane `auth.json` and `settings.json` (see `model-lane.ts`), and stores server state in a named volume. Use native mode for normal local iteration.

## Configuration

| Env var                    | Default       | Description                                                                                               |
| -------------------------- | ------------- | --------------------------------------------------------------------------------------------------------- |
| `E2E_PORT`                 | `17760`       | Server port                                                                                               |
| `E2E_SOURCE_PI_AGENT_DIR`  | `~/.pi/agent` | Pi agent dir whose Anthropic login supplies the E2E access token                                          |
| `E2E_ANTHROPIC_EXTENSION`  | unset         | Pi extension linked into the isolated agent dir to send subscription requests (native mode only)          |
| `E2E_NATIVE`               | `0`           | `1` to skip Docker, run server natively                                                                   |
| `E2E_KEEP_NATIVE_DATA_DIR` | unset         | `1` to preserve the isolated native data dir and `server.log` after a test run                            |
| `E2E_SERVER_DIR`           | unset         | Override native server package dir for tarball/install validation                                         |
| `E2E_TLS_MODE`             | `self-signed` | Native mode TLS setting. Apple `/pair` and `/auth/*` require HTTPS; do not use `disabled` for iOS pairing |
| `OPPI_E2E_UI_HARNESS`      | `0`           | Enables `/e2e/ui/...` injection routes for Apple extension UI snapshot tests                              |

Tailscale benchmark-only variables:

| Env var                      | Default                | Description                                                 |
| ---------------------------- | ---------------------- | ----------------------------------------------------------- |
| `TAILSCALE_BENCH_SSH_TARGET` | required               | Batch-mode SSH target for the separate macOS peer           |
| `TAILSCALE_BENCH_TARGET_IP`  | required               | Peer Tailscale IP used by Oppi and direct-path verification |
| `TAILSCALE_BENCH_REGION`     | `US Pacific Northwest` | Coarse, non-identifying region written to the report        |

## Architecture

```
e2e/
├── harness.ts                         # Shared: Docker/native/package lifecycle, API/WS/bootstrap helpers
├── harness-cli.ts                     # Thin CLI wrapper for non-Vitest harness callers
├── model-lane.ts                      # Haiku model lane: isolated Pi auth + settings
├── pairing-flow.e2e.test.ts           # Suite 1: pairing flow
├── paired-session.e2e.test.ts         # Suite 2: already-paired session flow
├── docker-compose.e2e.yml             # HTTP/TLS Docker server config
├── tailscale-network-benchmark-client.ts
├── tailscale-network-benchmark-server.mjs
├── run-tailscale-network-benchmark.ts # Opt-in two-peer Tailscale runner
├── network-benchmark-common.ts        # Shared HTTPS/Tailscale benchmark sampling helpers
└── README.md                          # This file
```

The harness supports two modes:

- **Docker mode** (default): builds and starts `oppi-e2e` through Docker Compose
- **Native mode** (`E2E_NATIVE=1`): builds the server locally, starts it as a child process in a temp directory, and skips Docker cleanup
- **Packaged native mode** (`E2E_NATIVE=1 E2E_SERVER_DIR=/path/to/node_modules/oppi-server`): runs the installed package tarball through the same native harness without rebuilding source

Both modes give the server an isolated Pi agent dir from `model-lane.ts`: `auth.json` holds only a current Anthropic access token (Pi refreshes your login first if it expired), and `settings.json` sets `enabledModels` to Haiku so sessions created without a model use it. Your refresh token never leaves `~/.pi/agent`. Anthropic bills a subscription token sent through Pi's built-in provider as extra usage, so a subscription login also needs `E2E_ANTHROPIC_EXTENSION` pointing at a Pi extension that sends those requests the way Claude Code does. Shell wrappers call `node server/e2e/model-lane.ts write <pi-agent-dir>`. Model-backed test workspaces use a server-visible main checkout: an isolated directory under the native data dir or Docker's `/root/workspace` tmpfs.

Apple E2E scripts remain responsible for Xcode and simulator orchestration. Server-bootstrap details should flow through this harness shape: the model lane, server lifecycle, pairing, fixture workspace creation, invite files, and the guarded extension UI injection route.
