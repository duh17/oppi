# Oppi

Oppi is a mobile client + self-hosted server for supervising local [pi](https://github.com/badlogic/pi-mono) coding sessions on your own machine.

All agent execution happens on your own machine.

## Current Status

- iOS app: TestFlight beta
- Server: in this repo under `server/`

## Quick Start

### Requirements

- Host machine with Node.js 22+ (macOS or Linux)
- `pi` CLI installed: `npm install -g @mariozechner/pi-coding-agent`
- `pi` provider login completed (`pi` then `/login`)
- iPhone with Oppi installed (TestFlight)

### 1) Start the server (from source)

```bash
git clone https://github.com/duh17/oppi.git
cd oppi/server
npm install
npm run build
npx oppi init
npx oppi serve
```

> Once `oppi-server` is published to npm, global install is:
> `npm install -g oppi-server`

### 2) Pair your iPhone

In a second terminal:

```bash
cd oppi/server
npx oppi pair
```

Scan the QR in the Oppi app.

### 3) Run your first session

In Oppi:
1. Create a workspace
2. Start a session
3. Send a prompt
4. Approve/deny risky actions in the app when prompted

## Remote Access (optional)

If phone and server host are not on the same Wi-Fi, use Tailscale/WireGuard/etc.

You can force a hostname/IP into the pairing QR:

```bash
npx oppi pair --host my-mac.example.com
```

## Useful Commands

```bash
oppi init
oppi serve
oppi pair --host <host>
oppi status
oppi doctor
oppi config show
oppi env init
```

## Configuration and Docs

- Server setup/config: [`server/README.md`](server/README.md)
- Config schema: [`server/docs/config-schema.md`](server/docs/config-schema.md)
- Security docs: [`server/docs/`](server/docs)
- Theme system: [`docs/theme-system.md`](docs/theme-system.md)

## Privacy (current TestFlight build)

- No third-party analytics or crash telemetry is enabled.
- Sentry integration exists for development diagnostics, but TestFlight uploads disable `SENTRY_DSN`.
- Oppi session/workspace data stays on your self-hosted server.

## Demo Videos (coming soon)

- Setup from zero to first prompt
- Pairing + approval flow
- Theme import/customization

## License

[MIT](LICENSE)
