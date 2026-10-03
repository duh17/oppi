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

   On first run, Oppi prints a pairing QR code and invite link. If this machine is on Tailscale and `tailscale cert` can issue it a certificate (HTTPS enabled for the tailnet), Oppi uses Tailscale TLS and the invite points at the machine's `*.ts.net` name. Otherwise it uses a self-signed certificate. A `tls.mode` other than `disabled` that you already set is kept.

2. Open Oppi on iPhone, then choose **Scan QR Code**, **Connect through Tailscale**, or **Enter manually / Connect to Server**. Opening an `oppi://connect` invite also starts pairing.

   **Connect through Tailscale** opens Oppi's in-app Tailscale connection. After you sign in, Oppi lists Macs on the same tailnet and can pair with one that is already running Oppi over Tailscale HTTPS. It does not install the Tailscale VPN. QR and manual pairing stay available.

3. Confirm server trust. If local authentication is enabled, iOS asks for it before accepting the server identity.

4. Oppi opens **Workspaces** at **All Sessions**. If the server has no workspaces, it opens guided **Create Workspace** setup.

From here, [Using Oppi](usage.md) covers the session list, prompting, steer vs follow-up, Quick Session, files, and voice.

Oppi does not create starter workspaces. Camera-free pairing opens the signed `oppi://connect` invite link. The manual sheet is still Host, Port, Token, and Name; it does not paste that invite.

## Reach the server

After pairing, Oppi uses authenticated HTTPS/WSS. The phone must reach the server over LAN, Tailscale, or a public HTTPS hostname. Tailscale HTTPS is supported. A reverse proxy is supported: set `publicUrl` to the phone-facing HTTPS origin and `proxy.trustedPeers` to the proxy's socket address as Oppi sees it (rate-limit identity on TLS origins; also required to authorize private HTTP). The local CLI stays on an owner-only Unix socket.

For remote pairing, include the host in the invite:

```bash
oppi pair --host <hostname-or-ip>
```

`--host` accepts a host or IP only: no scheme and no port. A `*.ts.net` host requires Tailscale TLS, because iOS does not accept a self-signed certificate on a Tailscale name. Enable HTTPS certificates for your tailnet, then include the Tailscale host in the first QR code from `serve`:

```bash
oppi config set tls.mode tailscale
oppi serve --host <your-host>.ts.net
```

With `self-signed` or `manual` TLS, pair through a LAN host or the server's Tailscale IP instead. `oppi pair` refuses a `*.ts.net` host in those modes.

Before pairing, the app probes HTTPS health and then sends exactly one pair request. If a connection error occurs after pairing starts, pairing might have succeeded; request a fresh invite instead of retrying the old one.

You can also pair by signing in to the Mac over SSH from **Tailscale → Check a Mac**. Oppi runs `oppi pair --json` only after `oppi status` says HTTPS and `https://127.0.0.1:<port>/health` answers on that Mac. A stopped server does not mint an invite. A `*.ts.net` name uses Oppi's Tailscale connection and is not dialed on the system network while that connection is off. Any other host, including a public name, uses the current network. An unknown or changed SSH host key sends no password. This does not install or start the server.

## Pair another device

Generate a new invite:

```bash
oppi pair
```

Then pair through QR scan, manual entry, or the invite link.

For remote HTTPS pairing, generate an invite with an explicit host:

```bash
oppi pair --host <hostname-or-ip>
```

`--host` accepts a host or IP only: no scheme and no port. The invite port comes from the server configuration:

```bash
oppi config get port
```

If the public origin is a reverse-proxied HTTPS hostname, set `publicUrl` instead of changing the listener port. Invites then advertise that origin and omit the origin TLS leaf pin (the phone uses the system CA):

```bash
oppi config set publicUrl https://oppi.example.com
oppi config set proxy.trustedPeers '["127.0.0.1/32","::1/128"]'
oppi pair
```

`--host` must not conflict with `publicUrl`. Direct self-signed and Tailscale pairing are unchanged when `publicUrl` is unset.

If the listener port changes for a direct deployment, set it, restart the server, and create a new invite:

```bash
oppi config set port <public-port>
```

## Invite rules

- Each invite is single-use.
- Invites expire after 90 seconds by default. `oppi pair --ttl <duration>` sets another lifetime, from 1 second to 30 days (for example `--ttl 10m`).
- Invites contain signed server identity and HTTPS authorization.
- Deep-link details are in [Deep links](deeplinks.md).

## Paired devices

Each paired device has a name. Oppi sends the device name in the `deviceName` field of `POST /pair` (trimmed, at most 64 characters). iOS 16 and later report only the generic model name ("iPhone") unless the app holds Apple's restricted device-name entitlement, so Oppi appends a short per-device suffix, for example `iPhone (A3F9)`. The server stores a missing or blank name as `Device`.

List and revoke devices from the host with `oppi devices` and `oppi devices revoke <id>`, or from a paired device with the same endpoints:

- `GET /auth/devices` returns `{"devices":[{"id","name","scope","createdAt","lastUsedAt","revokedAt","keyEnrolled"}]}`. Revoked devices stay in the list with `revokedAt` set. Times are Unix milliseconds.
- `DELETE /auth/devices/:id` revokes a device, invalidates its access tokens, and closes its open sockets. It returns `{"ok":true}`, or `404` for an unknown or already-revoked id.

Any paired device can list and revoke any other; there is no per-device permission. `GET /auth/devices` does not mark the caller, so a client compares the list with the device id in its own stored credential to find itself.

## Troubleshooting

### Invite expired, used, or pairing result unknown

Generate a fresh invite and pair again:

```bash
oppi pair
```

Do not retry a `/pair` mutation after a lost response.

### Could not reach the server

1. Check server state on the host:

   ```bash
   oppi status
   oppi doctor
   ```

2. Confirm the phone can reach the server the same way you paired: LAN, Tailscale, or public DNS. A LAN invite does not work from outside that network. For Tailscale or a public hostname, regenerate an explicit-host invite:

   ```bash
   oppi pair --host <hostname-or-ip>
   ```

3. Retry with a fresh invite. Invites expire after 90 seconds by default and are single-use.

### Secure connection failed

Generate a fresh invite from the same server, retry, and do not edit invite content manually.
