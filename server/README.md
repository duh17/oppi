# oppi-server

Server for [Oppi](../README.md). Embeds the [pi SDK](https://github.com/badlogic/pi-mono) to run agent sessions in-process.

## Quickstart

```bash
# 1. Install
git clone https://github.com/duh17/Oppi.git && cd Oppi/server
npm install

# 2. Set up pi auth (needed for LLM API calls)
pi login

# 3. Start (auto-inits config + shows pairing QR on first run)
npx oppi serve
```

Create a workspace in the app and start a session.

## Requirements

- Node.js 20+
- [pi](https://github.com/badlogic/pi-mono) CLI installed (`pi login` for LLM auth)
- macOS or Linux

## Docker

```bash
docker run -d --name oppi -p 7749:7749 node:22-bookworm sleep infinity
docker cp oppi-server/. oppi:/opt/oppi-server/
docker exec -w /opt/oppi-server oppi sh -c "npm install"

# Copy pi auth into the container
docker exec oppi mkdir -p /root/.pi/agent
docker cp ~/.pi/agent/auth.json oppi:/root/.pi/agent/

# Start (auto-inits + shows pairing QR)
docker exec -w /opt/oppi-server oppi npx oppi serve --host <your-hostname>
```

## Commands

```bash
npx oppi serve [--host <h>]      # start server (auto-inits on first run)
npx oppi pair [name]             # regenerate pairing QR
npx oppi status                  # show running sessions
npx oppi config show             # show config
npx oppi config set <key> <val>  # update config
npx oppi token rotate            # rotate owner bearer token
```

## Configuration

- Config: `~/.config/oppi/config.json`
- Data: `~/.config/oppi/`
- Override with `OPPI_DATA_DIR` or `--data-dir`

See [config-schema.md](docs/config-schema.md).

## Development

```bash
npm test                            # vitest
npm run check                       # typecheck + lint + format
npm run dev                         # watch mode
npm run test:e2e:linux              # linux container E2E
npm run test:e2e:lmstudio:contract  # real model contract tests
```

## License

MIT
