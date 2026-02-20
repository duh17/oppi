# oppi-server

Self-hosted server for supervising [pi](https://github.com/badlogic/pi-mono) sessions from the Oppi iOS app.

## Requirements

- Node.js 20+
- [pi](https://github.com/badlogic/pi-mono) CLI installed and logged in
- macOS or Linux

## Install

```bash
npm install -g oppi-server
```

Or from source:

```bash
cd server
npm install
npm run build
```

## Usage

```bash
oppi init                    # initialize config
oppi serve                   # start server
oppi pair [--host <h>]       # generate pairing QR
oppi status                  # show running sessions
oppi doctor                  # check setup
oppi token rotate            # rotate auth token
oppi config show             # show config
oppi config set <key> <val>  # update config
oppi config validate         # validate config
oppi env init                # initialize environment
```

## Configuration

- Config: `~/.config/oppi/config.json`
- Data: `~/.config/oppi/`
- Override with `OPPI_DATA_DIR` or `--data-dir`

See [config-schema.md](docs/config-schema.md).

## Development

```bash
npm test                         # vitest
npm run check                    # typecheck + lint + format
npm run dev                      # watch mode
npm run test:e2e:linux           # linux container E2E
npm run test:e2e:lmstudio:contract  # real model contract tests
```

## License

MIT
