# oppi-server

Self-hosted server runtime for the Oppi iOS app.

## Requirements

- Node.js 20+
- `pi` CLI (`npm install -g @mariozechner/pi-coding-agent`)
- `pi` provider login (`pi` then `/login`)
- macOS or Linux (Linux container lane is exercised via `npm run test:e2e:linux`)

## Install

### From npm (once published)

```bash
npm install -g oppi-server
```

### From source (today)

```bash
git clone https://github.com/duh17/oppi.git
cd oppi/server
npm install
npm run build
```

## Quick Start

### 1) Initialize config

```bash
# global install
oppi init

# source checkout
npx oppi init
```

### 2) Start server

```bash
# global install
oppi serve

# source checkout
npx oppi serve
```

### 3) Pair phone

In a second terminal:

```bash
# global install
oppi pair

# source checkout
npx oppi pair
```

Scan the QR in Oppi iOS.

## Common Commands

```bash
oppi init
oppi serve
oppi pair --host <hostname-or-ip>
oppi status
oppi doctor
oppi token rotate
oppi config show
oppi config set <key> <value>
oppi config validate
oppi env init
```

## Configuration

- Config file: `~/.config/oppi/config.json`
- Data directory: `~/.config/oppi/`
- Override data dir with `OPPI_DATA_DIR` or `--data-dir`

See:
- `docs/config-schema.md`
- `docs/security-pairing-spec-v3.md`

## Development

```bash
npm test
npm run build
npm run check
npm run dev
```

Advanced test lanes:

```bash
npm run test:e2e:linux
npm run test:e2e:linux:full
npm run test:e2e:lmstudio:contract
```

## Notes

- APNs push wiring exists on the server, but iOS release profile currently keeps push/live-activity surfaces disabled.
- If pairing works but session start fails, verify `pi` is installed and logged in.

## License

MIT
