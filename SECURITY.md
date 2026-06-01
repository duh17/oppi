# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

## Permission prompts

Oppi no longer ships a server-side policy engine. SDK sessions load the user's global Pi `permission-gate` extension by default (`~/.pi/agent/extensions/permission-gate.ts`), and Oppi relays that extension's standard Pi UI dialogs to the client.

Treat this as user-owned defense in depth, not the hard security boundary. The extension can ask before high-impact actions and block obvious hazards, but real containment should come from workspace isolation, TLS/auth, and least-privilege host configuration.

## Authentication

Pairing generates a shared bearer token via QR code scan. All HTTP and WebSocket connections require this token. The server generates an Ed25519 identity key pair on first run; the fingerprint is embedded in the pairing invite so the iOS app can verify it's connecting to the right server.

Rotate the token with `npx oppi token rotate`.

## Transport

TLS is configurable: self-signed (with certificate pinning in the iOS app), Tailscale (Let's Encrypt via `tailscale cert`), Cloudflare, manual cert, or disabled. Self-signed mode auto-generates cert material and embeds the CA fingerprint in the pairing payload.

Plain HTTP is allowed for loopback development. Binding HTTP to a non-loopback interface requires the explicit `tls.allowInsecureNetworkHttp=true` escape hatch because the connection is unencrypted. Use TLS for any network you don't fully trust.

## Privacy

Oppi does not phone home. There are no accounts, no analytics, and no data sent to any external service. All session data stays on your machine.

Sentry crash reporting in the iOS app is opt-in and disabled by default. MetricKit performance telemetry is only collected in internal/TestFlight builds and stored locally on the server.

See [`docs/telemetry.md`](docs/telemetry.md) for the full telemetry policy.

## Reporting issues

If you find a security issue, open an issue on GitHub.
