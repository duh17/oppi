# Security

Oppi runs a coding agent on your machine with filesystem and tool access. It is provided as-is with no warranty. Use at your own risk.

## Permission prompts

Oppi supports Pi's standard extension UI API on mobile, including input and confirm flows. Extensions that ask before actions use the same mobile bridge as other Pi extension UI. Pi extensions make approval decisions; Oppi-specific server rules do not.

## Authentication

A paired phone, or any other authenticated device principal, is the owner. It can read host files, run tools, and drive sessions. Workspace `realpath` confinement keeps paths inside the selected workspace; it is not a secret-file ACL.

Pairing enrolls a per-device P-256 public key and returns a short-lived HTTPS/WSS access token (`at_`, about ten minutes, stored hashed). Ordinary network HTTP and WebSocket calls send that bearer. `/health` is unauthenticated. Pair, migrate, challenge, and refresh are TLS bootstrap routes and do not use a live `at_`.

The owner `sk_` credential is accepted only on the owner-local Unix socket. The network listener rejects it.

The server generates an Ed25519 identity key pair on first run. The fingerprint is embedded in the pairing invite so the app can verify it is connecting to the right server.

Authenticated devices can list and revoke devices. Emergency owner rotation (`oppi token rotate`) stays on the Unix socket and revokes every device.

Leftover `dt_` tokens migrate over HTTPS (`POST /auth/migrate`). Ordinary HTTP/WS reject them.

## Transport

Configure TLS for network HTTP/WebSocket transport as self-signed (with leaf-certificate pinning in the iOS app and Share extension), Tailscale (Let's Encrypt via `tailscale cert`), manual cert, or disabled. `auto` and `cloudflare` modes are rejected. Self-signed mode auto-generates certificate material and embeds the **leaf** certificate fingerprint in the pairing payload. A configured pin is authoritative. Tailscale hosts without a pin use the system CA.

Remote Apple/server routing uses authenticated HTTPS/WSS, including HTTPS through Tailscale.

A plain network HTTP listener can be used for health-only development, but pairing, device-auth, `dt_`/`at_` API authentication, and remote WebSockets require HTTPS/WSS. Binding HTTP to a non-loopback interface still requires the explicit `tls.allowInsecureNetworkHttp=true` escape hatch. Owner HTTP and the bearer-free Mirror bridge stay on the owner-only Unix socket.

## Privacy

Oppi has no hosted account service or external analytics. Session data stays on the paired server and in its configured workspaces, except for content sent to model, speech, voice, or network services that the server operator configures. Network metadata is visible to the network provider and any directly used infrastructure. Tokens, pairing invites, and private keys are redacted from telemetry and ordinary logs; treat captured server logs and first-run pair output as sensitive while an invite is valid.

Diagnostics upload only to the paired Oppi server. Public builds require **Settings → Privacy & Security → Send Diagnostics to Server** before they upload MetricKit, resource, or client-log diagnostics. Internal/debug builds upload diagnostics to the configured server automatically.

See [`dev/telemetry.md`](dev/telemetry.md) for the full telemetry policy.

## Reporting issues

If you find a security issue, email [duh@chaosdonkey.dev](mailto:duh@chaosdonkey.dev). Do not include credentials, tokens, private prompts, workspace contents, or other secrets in a public GitHub issue.
