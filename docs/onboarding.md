# Onboarding and pairing

Install the server with npm:

```bash
npm install -g oppi-server
```

Use `oppi ...` for normal installs. Source checkouts can use `node dist/src/cli.js ...` from `server/`.

## Pair a first device

1. Start the server:

   ```bash
   oppi serve
   ```

   On first run, Oppi prints a pairing QR code and invite link.

2. Open Oppi on iPhone, then choose **Pair Nearby Mac**, **Scan QR Code**, or **Enter manually / Connect to Server**. Opening an `oppi://connect` invite also starts pairing.

3. Confirm server trust. If local authentication is enabled, iOS asks for it before accepting the server identity.

4. Oppi opens **Workspaces** at **All Sessions**. If the server has no workspaces, it opens guided **Create Workspace** setup.

Oppi does not create starter workspaces. Manual connection requires host and token; an invalid manual port uses `7749`.

## Choose transports

A signed invite authorizes HTTPS, Iroh, or both. The historical signed value `irohPreferred` means both are authorized; it is not a product route-order label.

After pairing, each server offers these Apple connection modes:

| Mode           | Route order                              |
| -------------- | ---------------------------------------- |
| **Automatic**  | verified LAN HTTPS → paired HTTPS → Iroh |
| **HTTPS Only** | verified LAN HTTPS → paired HTTPS        |
| **Iroh Only**  | Iroh                                     |

Automatic is the default. A mode can restrict the signed transport set but cannot enable a route absent from the invite or the server-issued credential grant.

Before pairing, the app uses read-only probes to choose one authorized route: `GET /health` for HTTPS or validated Iroh metadata plus selected-path evidence for Iroh. It then sends exactly one `POST /pair`. HTTPS pairing includes the stable Apple Iroh node ID when the invite also authorizes Iroh; this records the binding without dialing Iroh. The server returns the issued credential's HTTP/Iroh grant. The app never replays the pairing mutation on another route. If a connection error occurs after pairing starts, pairing might have succeeded; request a fresh invite instead of retrying the old one.

After pairing, the client keeps the route with current health evidence. When it must select again, availability failures suppress a route only for that pass. An Iroh binding or transport-grant rejection disables Iroh for that credential but does not block LAN or paired HTTPS recovery. Unknown credentials and transport-integrity failures remain fail-closed. See [Networking and connection routing](networking.md) for recovery details.

## Enable Iroh

Enable Iroh durably, validate the configuration, then restart the server:

```bash
oppi config set iroh.enabled true
oppi config validate
```

For a LaunchAgent installation, restart with:

```bash
oppi server restart
```

When running `oppi serve` directly, stop and start that process instead. Generate a fresh invite after it starts:

```bash
oppi pair
```

Iroh-only pairing requires the server to be running with Iroh enabled and a host-free Iroh-only invite mode:

```bash
OPPI_IROH_INVITE_MODE=irohOnly oppi serve
```

Iroh-only pairing never falls back to HTTPS. Iroh carries the same REST, file, media, focused-session, app-event, and dictation traffic through the tunnel.

## Configure owner relays

Unset relay configuration uses Iroh's public defaults. To use owner-configured relays, set a non-empty list; it replaces the server's public relay map:

```bash
oppi config set iroh.relays '[{"url":"https://relay-us.example"},{"url":"https://relay-eu.example","quicPort":7842}]'
oppi config validate
oppi doctor
```

Relay URLs must be HTTPS root URLs without credentials, query, fragment, path, or disallowed IP literals. At most eight entries are allowed. An omitted `quicPort` is stored as `7842`.

Restart the server, then generate new invites and re-pair devices. Configuration changes do not alter the running endpoint or already paired devices. `oppi doctor` reports relay mode and configured/live drift without printing relay URLs.

Newer Apple clients add relay URLs from signed Iroh metadata to their process-global Iroh map before pairing and dialing. Older clients might ignore these URLs and fail when a server uses private-only relays. Oppi has no in-app relay editor; custom relay operation is separate from Oppi.

## Pair another device

Generate a new invite:

```bash
oppi pair
```

Then pair through Nearby Mac, QR scan, manual entry, or the invite link.

For remote HTTPS pairing, generate an invite with an explicit host:

```bash
oppi pair --host <hostname-or-ip>
```

`--host` accepts a host or IP only: no scheme and no port. The invite port comes from the server configuration:

```bash
oppi config get port
```

If the public port changes, set it, restart the server, and create a new invite:

```bash
oppi config set port <public-port>
```

## Invite rules

- Each invite is single-use.
- Invites expire after 90 seconds by default.
- Invites contain signed server identity and transport authorization.
- Deep-link details are in [Deep links](deeplinks.md).

## Troubleshooting

### Invite expired, used, or pairing result unknown

Generate a fresh invite and pair again:

```bash
oppi pair
```

Do not retry a `/pair` mutation after a lost response.

### Could not reach the server

1. Check server state and relay configuration:

   ```bash
   oppi status
   oppi doctor
   ```

2. For Iroh, confirm the server log contains `iroh_transport.started`. For custom relays, confirm the client is current enough to read signed relay URLs.

3. For HTTPS, confirm phone-to-server connectivity through LAN, Tailscale, or public DNS. Regenerate an explicit-host invite if needed:

   ```bash
   oppi pair --host <hostname-or-ip>
   ```

4. Retry with a fresh invite.

### Secure connection failed

Generate a fresh invite from the same server, retry, and do not edit invite content manually.
