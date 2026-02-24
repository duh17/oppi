<p align="center">
  <img src="docs/images/app-icon.png" width="80" height="80" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Supervise <a href="https://github.com/badlogic/pi-mono">pi</a> coding sessions from your phone.<br />
  <a href="https://testflight.apple.com/join/yaRP9aed">TestFlight</a> · <a href="docs/demo/">Screenshots</a>
</p>

## How it works

The server embeds the [pi SDK](https://github.com/badlogic/pi-mono) directly — no separate CLI process. Each session runs an in-process agent with tool execution, streaming, and a policy-driven permission gate. The iOS app connects over WebSocket to stream output and handle approvals.

```
┌─────────┐        WSS / HTTPS        ┌──────────────┐
│  iPhone  │  ◄──────────────────────► │  oppi-server │
│  (Oppi)  │   stream, approvals, UI  │  (Node.js)   │
└─────────┘                            └──────┬───────┘
                                              │
                                      pi SDK (in-process)
                                              │
                                       ┌──────┴───────┐
                                       │ LLM provider  │
                                       │ + tools       │
                                       └──────────────-┘
```

## Install

```bash
git clone https://github.com/duh17/Oppi.git
cd Oppi/server
npm install
```

Requires Node.js 20+ and a [pi](https://github.com/badlogic/pi-mono) auth setup (`pi login`).

## Run

```bash
npx oppi serve
```

On first run, the server auto-initializes config and shows a pairing QR code. Scan it in the Oppi iOS app. Your phone and server need to be on the same local network. For off-LAN access via Tailscale, pair with your tailnet host: `npx oppi pair --host <your-host>.ts.net`.

If the auto-detected hostname isn't reachable from your phone, pass one explicitly:

```bash
npx oppi serve --host my-machine.local
```

## Commands

```
npx oppi serve [--host <h>]    start server (auto-inits on first run)
npx oppi pair [--host <h>]     regenerate pairing QR
npx oppi status                show running sessions
npx oppi doctor                check setup
npx oppi config show           show current config
npx oppi config set <k> <v>    update config
```

## Docs

- [Server README](server/README.md)
- [Config schema](server/docs/config-schema.md)
- [Policy engine](server/docs/policy-engine.md)
- [Theme system](docs/theme-system.md)
- [Telemetry stack (Sentry + MetricKit)](docs/telemetry.md)

## License

[MIT](LICENSE)
