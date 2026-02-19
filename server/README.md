# oppi-server

Self-hosted server for the [Oppi](https://github.com/duh17/oppi) mobile coding agent. Pairs with the Oppi iOS app to give you a mobile interface for AI-assisted coding on your own machine.

## Quick Start

```bash
git clone https://github.com/duh17/oppi.git
cd oppi/server
npm install
npx oppi init
npx oppi pair
npx oppi serve
```

## What It Does

Oppi runs [pi](https://github.com/badlogic/pi-mono) sessions directly on your Mac and is controlled from your phone. The server handles:

- **Session management** — create, fork, resume coding sessions
- **Workspace management** — host working directory + skill configuration per workspace
- **Tool gating** — approve/deny file writes, shell commands from your phone
- **Push notifications** — get notified when the agent needs input
- **Live streaming** — real-time agent output over WebSocket
- **Skill registry** — curate what your agent can do

## Requirements

- **Node.js** ≥ 22
- **[pi](https://github.com/badlogic/pi-mono)** — the coding agent runtime (`npm install -g @mariozechner/pi-coding-agent`)
- **macOS 15+** (Sequoia) for local development
- An LLM provider account (Anthropic, OpenAI, etc. — via `pi login`)

## Commands

```
oppi init                  Interactive setup wizard
oppi serve                 Start the server
oppi pair [--host <h>]     Generate QR code for iOS pairing
oppi status                Show server + pairing status
oppi doctor                Security + environment diagnostics
oppi token rotate          Rotate bearer token (invalidates existing clients)
oppi config get <key>      Read a config value
oppi config set <key> <v>  Write a config value
oppi config show           Show effective config
oppi config validate       Validate config file
oppi env init              Capture shell PATH for local sessions
oppi env show              Show resolved session PATH
```

## Configuration

Config lives in `~/.config/oppi/config.json` (or `$OPPI_DATA_DIR/config.json`).

Key settings:

| Key | Default | Description |
|-----|---------|-------------|
| `port` | `7749` | HTTP/WS listen port |
| `defaultModel` | `anthropic/claude-sonnet-4-20250514` | Default model for new sessions |
| `maxSessionsPerWorkspace` | `3` | Session limit per workspace |
| `maxSessionsGlobal` | `5` | Total session limit |
| `allowedCidrs` | private ranges + loopback | Source IP allowlist for HTTP/WS |
| `token` | generated on pairing | Owner/admin bearer token |

Run `oppi init` to set these interactively.

Config schema reference: `docs/config-schema.md`.

Security + pairing v3 draft (recommended posture): `docs/security-pairing-spec-v3.md`.

## Data Directory

All state (config, sessions, workspaces) lives under one directory:

```
~/.config/oppi/
├── config.json          # Server configuration
├── identity_ed25519     # Ed25519 private key
├── identity_ed25519.pub # Ed25519 public key
├── sessions/            # Session state + history
├── workspaces/          # Workspace definitions
├── rules.json           # Learned policy rules
└── skills/              # User-defined skills
```

Override with `OPPI_DATA_DIR` or `--data-dir`.

## Development

```bash
npm install
npm test                    # vitest test suite
npm run test:e2e:linux             # fast smoke test (fake pi)
npm run test:e2e:linux:full        # full pi install/run in linux container
npm run test:e2e:lmstudio:contract # pairing+WS+tool contract against LM Studio
npm run test:security:adversarial  # pairing-token adversarial harness (manual)
npm run test:load:ws               # HTTP/WS load harness (manual)
npm run tool:gate-client -- <args> # interactive permission-gate client
npm run build                      # TypeScript compile
npm run check               # typecheck + lint + format check
npm start                   # Start server (from compiled dist/)
npm run dev                 # Start with tsx watch (auto-reload)
```

## Linux Container E2E Lane

Run the linux-containerized E2E lane:

```bash
npm run test:e2e:linux      # smoke mode (fake pi)
npm run test:e2e:linux:full # full mode (installs real pi agent)
```

The script starts the server inside a Node 22 linux container and validates workspace/session CRUD over HTTP.

- **smoke mode** uses a fake `pi` binary for deterministic fast checks.
- **full mode** installs `@mariozechner/pi-coding-agent` inside the container and can reuse host caches/config.

Useful env flags:

```bash
USE_HOST_NPM_CACHE=1 HOST_NPM_CACHE=~/.npm npm run test:e2e:linux:full
HOST_PI_DIR=~/.pi npm run test:e2e:linux:full
```

## LM Studio Contract E2E Lane

Run a contract test against a real local LM Studio model:

```bash
npm run test:e2e:lmstudio:contract
```

Prerequisite:
- Load the model first in LM Studio (`lms load glm-4.7-flash-mlx`, or your `LMS_MODEL_ID`).
- If the model is missing (or `lms ps` is unavailable), the script prints a warning and skips with exit 0.
- Set `REQUIRE_LMS_MODEL=1` to fail instead of skipping.

What it verifies in one run:
- pairing token bootstrap -> `dt_` device token auth
- pairing-token replay rejection (`POST /pair` with used token returns `401`)
- websocket auth/path negative checks:
  - missing auth header -> `401`
  - bad auth token -> `401`
  - workspace/session mismatch path -> `404`
- session-stream (`/workspaces/:wid/sessions/:sid/stream`) contract:
  - prompt `requestId` -> matching successful `rpc_result`
  - event ordering checks (`connected` -> prompt send -> `rpc_result`; `agent_start` -> bash tool lifecycle -> `agent_end`)
  - tool lifecycle events (`tool_start` / `tool_output` / `tool_end`) for bash
  - permission-request auto-approval correlation (`permission_request.id` -> `permission_response.id`)
- user-stream (`/stream`) reconnect/catch-up contract:
  - subscribe with `sinceSeq` returns strict monotonic catch-up seqs (`seq > sinceSeq`)
  - catch-up contains missed durable events after disconnect/reconnect
  - replay determinism: repeated reconnect with same `sinceSeq` returns identical seq/type stream
  - ring-window miss path: forced overflow returns `catchUpComplete=false` and no replay events for stale `sinceSeq`
  - fallback hydration remains available on miss (`state` snapshot + successful `get_messages` RPC)
- turn idempotency contract:
  - duplicate prompt with same `clientTurnId` + same payload does not create duplicate run (`agent_start` remains single)
  - conflict prompt with same `clientTurnId` + different payload fails (`rpc_result.success=false`)
- stop lifecycle contract:
  - repeated `stop` requests produce one user `stop_requested`
  - terminal stop event observed (`stop_confirmed` or `stop_failed`) with state recovery checks
- run + no-progress timeouts with stop escalation (`stop`, `stop_session`)

Useful env flags:

```bash
RUN_TIMEOUT_MS=90000 NO_PROGRESS_TIMEOUT_MS=20000 npm run test:e2e:lmstudio:contract
STREAM_STEP_TIMEOUT_MS=45000 npm run test:e2e:lmstudio:contract
SESSION_EVENT_RING_CAPACITY=24 STREAM_RING_MISS_PROMPTS=14 npm run test:e2e:lmstudio:contract
LMS_MODEL_ID=glm-4.7-flash-mlx SERVER_MODEL_ID=lmstudio/glm-4.7-flash-mlx npm run test:e2e:lmstudio:contract
KEEP_E2E_ARTIFACTS=1 npm run test:e2e:lmstudio:contract
```

## Security

Oppi should be treated like SSH access to your workstation once authenticated.

Current + target controls:
- Timing-safe bearer auth on all HTTP/WS endpoints
- Token class separation (owner/admin, pairing bootstrap, device auth, push tokens)
- One-time, short-lived pairing bootstrap with device token issuance
- Source CIDR allowlist + startup exposure warnings
- Credential isolation — API keys remain on the local machine
- Config files written 0600, directories 0700
- Hard deny policy rules for dangerous operations

See `docs/security-pairing-spec-v3.md` for the v3 pairing/security contract and rollout guardrails.

## License

MIT
