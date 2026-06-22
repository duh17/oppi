# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

## Permission prompts

Oppi supports Pi's standard extension UI API on mobile, including input and confirm flows. Extensions that ask before actions use the same mobile bridge as other Pi extension UI.
Approval decisions come from Pi extensions, not from Oppi-specific server rules.

## Authentication

Pairing generates a shared bearer token via QR code scan. All HTTP and WebSocket connections require this token. The server generates an Ed25519 identity key pair on first run; the fingerprint is embedded in the pairing invite so the iOS app can verify it's connecting to the right server.

Rotate the token with `oppi token rotate`.

## Transport

TLS is configurable: self-signed (with certificate pinning in the iOS app), Tailscale (Let's Encrypt via `tailscale cert`), Cloudflare, manual cert, or disabled. Self-signed mode auto-generates cert material and embeds the CA fingerprint in the pairing payload.

Plain HTTP is allowed for loopback development. Binding HTTP to a non-loopback interface requires the explicit `tls.allowInsecureNetworkHttp=true` escape hatch because the connection is unencrypted. Use TLS for any network you don't fully trust.

## Privacy

Oppi does not phone home. There are no accounts, no external analytics, and no data sent to a hosted Oppi service. Session data stays on your machine.

Diagnostics upload only to the paired Oppi server. Public builds require **Settings → Diagnostics → Send Diagnostics to Server** before uploading MetricKit, resource, or client-log diagnostics. Internal/debug builds upload diagnostics to the configured server automatically.

See [`docs/telemetry.md`](docs/telemetry.md) for the full telemetry policy.

## Reporting issues

If you find a security issue, open an issue on GitHub.
