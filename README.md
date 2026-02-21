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
npm run build
npm link
```

Requires Node.js 20+ and a [pi](https://github.com/badlogic/pi-mono) auth setup (`pi login`).

```bash
oppi init      # first-time setup
oppi serve     # start server
```

Pair your phone:

```bash
oppi pair
```

Scan the QR in the iOS app. Your phone and server need to be on the same local network. If they aren't, pass a reachable hostname:

```bash
oppi pair --host my-machine.local
```

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
- [Policy engine](server/docs/policy-engine.md)
- [Theme system](docs/theme-system.md)

## License

[MIT](LICENSE)
