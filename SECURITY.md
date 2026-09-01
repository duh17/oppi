# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

## Permission prompts

Oppi supports Pi's standard extension UI API on mobile, including input and confirm flows. Extensions that ask before actions use the same mobile bridge as other Pi extension UI. Pi extensions make approval decisions; Oppi-specific server rules do not.

## Authentication

Pairing enrolls a per-device P-256 public key and returns a short-lived HTTPS/WSS access token. All HTTP and WebSocket connections require a valid token. The owner `sk_` credential is accepted only through the owner-local Unix socket. The server generates an Ed25519 identity key pair on first run; the fingerprint is embedded in the pairing invite so the iOS app can verify it's connecting to the right server.

Rotate the token with `oppi token rotate`.

## Transport

Configure TLS for network HTTP/WebSocket transport as self-signed (with certificate pinning in the iOS app), Tailscale (Let's Encrypt via `tailscale cert`), Cloudflare, manual cert, or disabled. Self-signed mode auto-generates certificate material and embeds the CA fingerprint in the pairing payload.

Remote Apple/server routing uses authenticated HTTPS/WSS, including HTTPS through Tailscale.

On npm or VPS installs, bind the HTTP/TLS listener to a Tailscale `100.x` or LAN IP (`oppi config set host <tailscale-ip-or-lan>`). Do not bind `0.0.0.0`. `config host` is the bind address; `oppi serve --host`, `oppi pair --host`, and `OPPI_PAIR_HOST` advertise the pairing hostname (MagicDNS such as `machine.ts.net`). When MagicDNS is the remote path, use `tls.mode=tailscale`. `oppi doctor` fails on a wildcard bind and warns when MagicDNS is present with `tls.mode=self-signed`.

A plain network HTTP listener can be used for health-only development, but pairing, device-auth, `dt_`/`at_` API authentication, and remote WebSockets require HTTPS/WSS. Binding HTTP to a non-loopback interface still requires the explicit `tls.allowInsecureNetworkHttp=true` escape hatch. Owner HTTP and the bearer-free Mirror bridge stay on the owner-only Unix socket.

## Privacy

Oppi has no hosted account service or external analytics. Session data stays on the paired server and in its configured workspaces, except for content sent to model, speech, voice, or network services that the server operator configures. Network metadata is visible to the network provider and any directly used infrastructure; tokens and private keys are not included in telemetry or logs.

Diagnostics upload only to the paired Oppi server. Public builds require **Settings → Privacy & Security → Send Diagnostics to Server** before they upload MetricKit, resource, or client-log diagnostics. Internal/debug builds upload diagnostics to the configured server automatically.

See [`dev/telemetry.md`](dev/telemetry.md) for the full telemetry policy.

## Reporting issues

If you find a security issue, email [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev). Do not include credentials, tokens, private prompts, workspace contents, or other secrets in a public GitHub issue.
