# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

## Permission prompts

Oppi supports Pi's standard extension UI API on mobile, including input and confirm flows. Extensions that ask before actions use the same mobile bridge as other Pi extension UI.
Approval decisions come from Pi extensions, not from Oppi-specific server rules.

## Authentication

Pairing generates a bearer token via QR code scan. All HTTP and WebSocket connections require a valid token. Iroh pairing also binds the device token to the Apple client's Iroh endpoint ID, and every tunnel verifies the connected peer against that binding. The server generates an Ed25519 identity key pair on first run; the fingerprint is embedded in the pairing invite so the iOS app can verify it's connecting to the right server.

Rotate the token with `oppi token rotate`.

## Transport

TLS is configurable for the network HTTP/WebSocket transport: self-signed (with certificate pinning in the iOS app), Tailscale (Let's Encrypt via `tailscale cert`), Cloudflare, manual cert, or disabled. Self-signed mode auto-generates cert material and embeds the CA fingerprint in the pairing payload.

Iroh is an independent encrypted transport. The signed invite identifies the server endpoint ID, the app verifies the ticket and connected peer against that ID, and Iroh-only credentials fail closed without HTTP fallback. Iroh removes the need for an Oppi hostname, port, TLS certificate, LAN, or Tailscale, but it can use direct network paths, signed address lookup, and third-party relay infrastructure.

Plain HTTP is allowed for loopback development. Binding HTTP to a non-loopback interface requires the explicit `tls.allowInsecureNetworkHttp=true` escape hatch because the connection is unencrypted. Use TLS for any network HTTP listener you don't fully trust.

## Privacy

Oppi has no hosted account service or external analytics, and session data stays on your machine. When Iroh is enabled, endpoint discovery and connection establishment can contact configured address-lookup and relay services. Those services can observe endpoint identifiers, IP addresses, connection timing, duration, and approximate traffic volume; Oppi application traffic remains end-to-end encrypted between the signed Iroh endpoint IDs. See Iroh's [Security & Privacy](https://docs.iroh.computer/deployment/security-privacy) and [Relays](https://docs.iroh.computer/concepts/relays) documentation.

Before enabling Iroh by default in a public release, repeat this disclosure in the release notes and the app's privacy information, and identify whether that release uses public, managed dedicated, or self-hosted relay infrastructure.

Diagnostics upload only to the paired Oppi server. Public builds require **Settings → Diagnostics → Send Diagnostics to Server** before uploading MetricKit, resource, or client-log diagnostics. Internal/debug builds upload diagnostics to the configured server automatically.

See [`docs/telemetry.md`](docs/telemetry.md) for the full telemetry policy.

## Reporting issues

If you find a security issue, open an issue on GitHub.
