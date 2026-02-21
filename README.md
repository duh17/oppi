<p align="center">
  <img src="docs/images/app-icon.png" width="80" height="80" alt="Oppi" />
</p>

<h1 align="center">Oppi</h1>

<p align="center">
  Native iOS client for <a href="https://github.com/badlogic/pi-mono">pi</a> coding sessions, supervised from your phone.
</p>

See [screenshots and demo video](docs/demo/).

---

## How it works

```
┌─────────┐        WSS / HTTPS        ┌──────────────┐
│  iPhone  │  ◄──────────────────────► │  oppi-server │
│  (Oppi)  │   stream, approvals, UI  │  (Node.js)   │
└─────────┘                            └──────┬───────┘
                                              │
                                      pi SDK (in-process)
                                      createAgentSession()
                                              │
                                       ┌──────┴───────┐
                                       │ LLM provider  │
                                       │ + tools       │
                                       └──────────────-┘
```

The server embeds the [pi SDK](https://github.com/badlogic/pi-mono) directly — no separate CLI process. Each session runs an in-process agent with tool execution, streaming, and a per-session permission gate. The iOS app connects over WebSocket to stream tool calls, render diffs and output, and handle permission approvals.

## Install

```bash
npm install -g oppi-server
oppi init
oppi serve
```

Requires Node.js 20+ and a [pi](https://github.com/badlogic/pi-mono) auth setup (`pi login`).

Pair your phone:

```bash
oppi pair
```

Scan the QR in the iOS app. If your phone and server aren't on the same network:

```bash
oppi pair --host my-mac.tailnet.ts.net
```

## Features

- **In-process pi agent** — SDK-based, no CLI spawning
- **Permission gate** — approve or deny tool calls from your phone
- **Policy engine** — auto-allow safe operations, prompt for risky ones
- **Streaming diffs** — see what the agent changed, line by line
- **ANSI terminal rendering** — colored terminal output preserved
- **Custom extension rendering** — structured tool output cards
- **Markdown + syntax highlighting** — full code block rendering
- **Themes** — Tokyo Night, Nord, or import your own
- **Workspaces** — isolated project contexts with skills
- **Reconnect replay** — catches up missed events after disconnect
- **Image input** — attach photos from your camera roll

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
- [Theme file guide](docs/theme-system.md)
- [Permission gate policy guide](server/docs/policy-engine.md)

## License

[MIT](LICENSE)
