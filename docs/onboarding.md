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

2. Open Oppi on iPhone, then choose **Scan QR Code** or **Enter manually / Connect to Server**. Opening an `oppi://connect` invite also starts pairing.

3. Confirm server trust. If local authentication is enabled, iOS asks for it before accepting the server identity.

4. Oppi opens **Workspaces** at **All Sessions**. If the server has no workspaces, it opens guided **Create Workspace** setup.

From here, [Using Oppi](usage.md) covers the session list, prompting, steer vs follow-up, Quick Session, files, and voice.

Oppi does not create starter workspaces. Manual connection requires host and token; an invalid manual port uses `7749`.

## Reach the server

After pairing, Oppi uses authenticated HTTPS/WSS. The phone must reach the server over LAN, Tailscale, or a public hostname. Tailscale HTTPS is supported. The local CLI stays on an owner-only Unix socket.

`host` in config is the HTTP/TLS **bind** address. Do not bind `0.0.0.0` on an npm or VPS install. Bind a Tailscale `100.x` address or a LAN IP:

```bash
oppi config set host <tailscale-ip-or-lan>
```

`oppi serve --host`, `oppi pair --host`, and `OPPI_PAIR_HOST` are the **advertised pairing hostname**. Use a MagicDNS name such as `cos-1.taila3ebc.ts.net` there. Binding `0.0.0.0` is not how you advertise MagicDNS.

When the advertised pairing host is MagicDNS (`*.ts.net`), set `tls.mode=tailscale` (`tailscale cert`) so the phone can use `https://<machine>.ts.net:<port>` with a real certificate (`<port>` is `config.port`). `tls.mode=self-signed` plus an advertised MagicDNS host is a mismatch; `oppi doctor` warns. LAN or mDNS pairing on a Tailscale-connected machine does not trigger that warning.

```bash
oppi config set tls.mode tailscale
oppi pair --host <machine>.<tailnet>.ts.net
oppi doctor
```

`--host` accepts a host or IP only: no scheme and no port. Before pairing, the app probes HTTPS health and then sends exactly one pair request. If a connection error occurs after pairing starts, pairing might have succeeded; request a fresh invite instead of retrying the old one.

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
