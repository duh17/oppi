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

## HTTPS/WSS connections

After pairing, Oppi uses authenticated HTTPS/WSS. Automatic routing evaluates verified LAN HTTPS and paired HTTPS; Tailscale HTTPS is supported. The local CLI remains owner-only over its Unix socket.

Before pairing, the app uses a read-only HTTPS `GET /health` probe and then sends exactly one `POST /pair` with the device's P-256 public key. If a connection error occurs after pairing starts, pairing might have succeeded; request a fresh invite instead of retrying the old one.

After pairing, the client keeps HTTPS route health evidence. Availability failures suppress a route only for that pass; authentication and transport-integrity failures remain fail-closed. See [Networking and connection routing](networking.md) for recovery details.

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
- Invites contain signed server identity and HTTPS authorization.
- Deep-link details are in [Deep links](deeplinks.md).

## Troubleshooting

### Invite expired, used, or pairing result unknown

Generate a fresh invite and pair again:

```bash
oppi pair
```

Do not retry a `/pair` mutation after a lost response.

### Could not reach the server

1. Check server state:

   ```bash
   oppi status
   oppi doctor
   ```

2. For HTTPS, confirm phone-to-server connectivity through LAN, Tailscale, or public DNS. Regenerate an explicit-host invite if needed:

   ```bash
   oppi pair --host <hostname-or-ip>
   ```

3. Retry with a fresh invite.

### Secure connection failed

Generate a fresh invite from the same server, retry, and do not edit invite content manually.
