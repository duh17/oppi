# oppi-server

Server for [Oppi](../README.md). Embeds the [pi SDK](https://github.com/badlogic/pi-mono) to run agent sessions in-process.

## Quickstart

```bash
# 1. Install
git clone https://github.com/duh17/oppi && cd oppi/server
npm install && npm run build && npm link

# 2. Set up pi auth (needed for LLM API calls)
pi login

# 3. Initialize and start
oppi init          # creates config + generates auth token
oppi serve         # starts server on 0.0.0.0:7749

# 4. Pair your phone
oppi pair "MyMac"  # generates QR code / deep link
                   # scan in the iOS app
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
docker exec -w /opt/oppi-server oppi sh -c "npm install && npm run build && npm link"

# Copy pi auth into the container
docker exec oppi mkdir -p /root/.pi/agent
docker cp ~/.pi/agent/auth.json oppi:/root/.pi/agent/

# Init, serve, pair
docker exec oppi oppi init --yes
docker exec -d oppi oppi serve
docker exec oppi oppi pair "Docker" --host <your-hostname> --port 7749
```

## Commands

```bash
oppi init                    # first-time setup (config + auth token)
oppi serve                   # start server
oppi pair [name]             # generate pairing QR / deep link
oppi status                  # show running sessions
oppi config show             # show config
oppi config set <key> <val>  # update config
oppi token rotate            # rotate owner bearer token
oppi env init                # capture shell PATH for sessions
oppi env show                # show resolved session PATH
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
