<p align="center">
  <img src="docs/images/app-icon.png" width="80" height="80" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Native iOS client for <a href="https://github.com/badlogic/pi-mono">pi</a> coding sessions, supervised from your phone.
</p>

<!-- screenshots: uncomment when images are in docs/images/
<p align="center">
  <img src="docs/images/screenshot-chat.png" width="220" />
  <img src="docs/images/screenshot-diff.png" width="220" />
  <img src="docs/images/screenshot-permission.png" width="220" />
</p>
-->

---

## How it works

```
┌─────────┐         WSS / HTTPS         ┌──────────────┐       stdio        ┌─────┐
│  iPhone  │  ◄───────────────────────►  │  oppi-server │  ◄──────────────►  │ pi  │
│  (Oppi)  │    stream, approvals, UI    │  (Node.js)   │   spawn, manage    │ CLI │
└─────────┘                              └──────────────┘                    └─────┘
                                               │
                                          permission gate
                                          (TCP, per-session)
```

The server spawns and manages `pi` processes on your machine. The iOS app connects over WebSocket to stream tool calls, render output, and handle permission approvals. A per-session TCP permission gate lets the pi extension ask the server before executing risky operations.

All execution stays on your machine.

## Install

```bash
npm install -g oppi-server
oppi init
oppi serve
```

Requires Node.js 20+ and [pi](https://github.com/badlogic/pi-mono) CLI installed and logged in.

Pair your phone:

```bash
oppi pair
```

Scan the QR in Oppi. If your phone and server aren't on the same network:

```bash
oppi pair --host my-mac.tailnet.ts.net
```

## Features

- Markdown rendering with syntax-highlighted code blocks
- Inline diffs — see what the agent changed, line by line
- Permission gate — approve or deny tool calls from your phone
- Themes (Tokyo Night variants + Nord built in, or import your own)
- Workspaces and session management
- image input

## Commands

```
oppi init                  initialize config
oppi serve                 start server
oppi pair [--host <h>]     generate pairing QR
oppi status                show running sessions
oppi doctor                check setup
oppi config show           show current config
oppi config set <k> <v>    update config
```

## Docs

- [Server README](server/README.md)
- [Config schema](server/docs/config-schema.md)
- [Theme system](docs/theme-system.md)
- [Security & privacy](SECURITY.md)

## License

[MIT](LICENSE)
