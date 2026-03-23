# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

## Permission gate

A built-in policy engine gates every tool call. For each call, the gate can allow it, send it to your phone for approval, or block it. By default, most operations auto-run, but built-in heuristics catch dangerous patterns:

- **Pipe to shell** — commands piped from curl/wget into sh/bash
- **Data egress** — curl/wget with POST data or upload flags
- **Secret access** — reads of `.env`, credentials, private keys, `~/.ssh/`
- **Secret in URL** — environment variables expanded inside URLs

When a heuristic triggers, you get a push notification on your phone with the full command. You decide: allow or deny, scoped to once, this session, or globally.

See [policy engine docs](server/docs/policy-engine.md) for rules, heuristics, and audit logging.

## Authentication

Pairing generates a shared bearer token via QR code scan. All HTTP and WebSocket connections require this token. The server generates an Ed25519 identity key pair on first run; the fingerprint is embedded in the pairing invite so the iOS app can verify it's connecting to the right server.

Rotate the token with `npx oppi token rotate`.

## Transport

TLS is configurable: self-signed (with certificate pinning in the iOS app), Tailscale (Let's Encrypt via `tailscale cert`), Cloudflare, manual cert, or disabled. Self-signed mode auto-generates cert material and embeds the CA fingerprint in the pairing payload.

For local network use without TLS, the connection is unencrypted. Use TLS for any network you don't fully trust.

## Privacy

Oppi does not phone home. There are no accounts, no analytics, and no data sent to any external service. All session data stays on your machine.

Sentry crash reporting in the iOS app is opt-in and disabled by default. MetricKit performance telemetry is only collected in internal/TestFlight builds and stored locally on the server.

See [`docs/telemetry.md`](docs/telemetry.md) for the full telemetry policy.

## Reporting issues

If you find a security issue, open an issue on GitHub.
