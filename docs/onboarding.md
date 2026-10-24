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

   On first run, Oppi prints a pairing QR code and invite link. If the machine is on Tailscale and `tailscale cert` can issue it a certificate (HTTPS enabled for the tailnet), Oppi uses Tailscale TLS and the invite points at the machine's `*.ts.net` name. Otherwise it uses a self-signed certificate. A `tls.mode` other than `disabled` that you already set is kept.

2. Open Oppi on iPhone and choose **Scan QR Code**, **Connect through Tailscale**, or **Enter manually / Connect to Server** (Host, Port, Token, and Name; it does not paste an invite). Opening an `oppi://connect` invite link also starts pairing.

   **Connect through Tailscale** opens Oppi's in-app Tailscale connection. After you sign in, Oppi lists Mac and Linux machines on your tailnet and can pair with one already running Oppi over Tailscale HTTPS. It does not install the Tailscale VPN.

3. Confirm server trust. If local authentication is enabled, iOS asks for it before accepting the server identity.

4. Oppi opens **Workspaces** at **All Sessions**. If the server has no workspaces, it opens guided **Create Workspace** setup; Oppi creates no starter workspaces.

Next: [Using Oppi](usage.md).

## Reach the server

After pairing, Oppi uses authenticated HTTPS and WSS. The phone must reach the server over LAN, Tailscale, or a public HTTPS hostname. The local CLI stays on an owner-only Unix socket.

For remote pairing, include the host in the invite. `--host` takes a host or IP only, with no scheme or port; the port comes from `oppi config get port`.

```bash
oppi pair --host <hostname-or-ip>
```

- **Tailscale name (`*.ts.net`):** needs Tailscale TLS, because iOS rejects a self-signed certificate on a Tailscale name. Enable HTTPS certificates for your tailnet, then put the host in the first QR code:

  ```bash
  oppi config set tls.mode tailscale
  oppi serve --host <your-host>.ts.net
  ```

  With `self-signed` or `manual` TLS, pair through a LAN host or the server's Tailscale IP; `oppi pair` refuses a `*.ts.net` host in those modes.
- **Reverse proxy:** set `publicUrl` to the phone-facing HTTPS origin and `proxy.trustedPeers` to the proxy's address as Oppi sees it. Invites then advertise that origin and omit the origin TLS pin, and `--host` must not conflict with `publicUrl`. See [Reverse proxy](reverse-proxy.md).
- **Changed listener port:** run `oppi config set port <public-port>`, restart, and create a new invite.

Before pairing, the app probes HTTPS health and then sends exactly one pair request. If a connection error occurs after pairing starts, pairing might have succeeded; request a fresh invite instead of retrying the old one.

You can also pair by signing in over SSH from **Tailscale → Check a Machine for Oppi**, for a Mac (Remote Login) or a Linux machine (`sshd`). Oppi runs `oppi pair --json` only after `oppi status` says HTTPS and `https://127.0.0.1:<port>/health` answers there, so a stopped server mints no invite. A `*.ts.net` name uses Oppi's Tailscale connection; any other host uses the current network. An unknown or changed SSH host key sends no password. This does not install or start the server.

## Pair another device

```bash
oppi pair                          # same network
oppi pair --host <hostname-or-ip>  # remote
```

Then pair through QR scan, manual entry, or the invite link.

## Invite rules

- Each invite is single-use and carries signed server identity and HTTPS authorization. Details are in [Deep links](deeplinks.md#pairing-invites).
- Invites expire after 90 seconds by default. `oppi pair --ttl <duration>` sets 1 second to 30 days (for example `--ttl 10m`).
- Once another device is paired, an invite with a lifetime over 90 seconds needs approval on a paired device.

## Approving a new device

When at least one device is already paired, these pairings wait for approval on a paired device:

- an invite with a lifetime over 90 seconds (`oppi pair --ttl 10m`, App Review hand-offs);
- a same-user Tailscale pairing (**Connect through Tailscale**), whatever its lifetime;
- a pairing approved by a custom `auth.module`.

A default 90-second invite needs no approval, and the first device on an empty server never does.

The new device shows a countdown. Every paired device with notifications on gets **Approve New Device?** with the device name, how it is pairing (`invite`, `tailscale`, or `custom`), and where from (client IP or Tailscale login), and paired devices also see the request in the app. Approving asks for Face ID, Touch ID, or the passcode. The host (the Unix socket and `oppi` CLI) cannot approve, so an agent on the host cannot let a device in on its own.

The request lasts 2 minutes. Deny or no answer fails closed: the new device reports it and needs a fresh invite. After approval it must finish within 60 seconds. Pending requests live in server memory, so a restart drops them. At most 8 can wait; past that the server answers `429` and the invite stays valid. The request is cancelled if the approving device is revoked first.

## New device alerts

Every new device, approved or not, sends **New Device Paired** to the other paired devices with notifications on: its name, pairing method, source, and time. The server logs `auth.device_enrolled` with the same facts. If you did not pair it, revoke it ([Paired devices](#paired-devices)). If you suspect the host itself, `oppi token rotate` revokes every paired device at once.

## Turn off Tailscale pairing

Same-user Tailscale pairing lets any machine signed in to your Tailscale account request an invite. To turn it off:

```bash
oppi config set auth.tailscalePairing false
oppi server restart
```

The app then reports Tailscale pairing as unavailable for that server. QR and invite-link pairing keep working.

## Paired devices

Oppi names each device with the model plus a short per-device suffix, for example `iPhone (A3F9)`, because iOS reports only the generic model name. The server keeps the name to one line of at most 64 characters, and a blank name becomes `Device`.

List and revoke devices from the host with `oppi devices` and `oppi devices revoke <id>`, or from a paired device in **Server Settings → Paired Devices**. Revoking signs the device out at once and closes its open connections. Revoked devices stay in the list with a revoked time. Any paired device can list and revoke any other; there is no per-device permission. Your own device is marked **This device** in the app and has no Revoke button.

## Troubleshooting

**Invite expired, used, or pairing result unknown.** Generate a fresh invite with `oppi pair` and pair again. Do not retry a pair request after a lost response.

**Could not reach the server.**

1. On the host, run `oppi status` and `oppi doctor`.
2. Confirm the phone reaches the server the way you paired: a LAN invite does not work from outside that network. For Tailscale or a public hostname, regenerate an invite with `oppi pair --host <hostname-or-ip>`.
3. Retry with a fresh invite.

**Secure connection failed.** Generate a fresh invite from the same server and retry. Do not edit invite content by hand.
