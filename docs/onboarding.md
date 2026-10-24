# Onboarding and pairing

Install the Oppi server on a Mac or Linux machine, keep it running, connect a model provider, and pair your iPhone.

## Before you start

You need:

- A Mac, or a Linux machine with glibc (x64 or arm64), that stays on while you use Oppi. Alpine and other musl systems need Node.js 22.19+ from the package manager first.
- `curl` or `wget`, and `tar`. macOS and most Linux installs have them.
- Oppi on your iPhone.

The installer runs as your user and never asks for `sudo`. It:

1. Uses `node` 22.19 or newer (with `npm`) from your login shell's `PATH`. If there is none, it downloads the official Node.js 22 build from nodejs.org, checks it against the published SHA-256 checksums, and puts it in `~/.oppi/runtime/node`.
2. Installs the `oppi-server` npm package in `~/.oppi/install`, links `oppi` into `~/.local/bin`, and adds that directory to `PATH` in your shell profile if it is missing. An `oppi` you installed with `npm install -g` stays where it is.
3. Installs a background service: a LaunchAgent on macOS, a systemd user service on Linux.
4. Waits until the server answers over HTTPS on `127.0.0.1`.

Server data (config, TLS, paired devices) lives in `~/.config/oppi`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | sh
```

Run the same command again to upgrade or repair; it ends in the same state. Options go after `sh -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/duh17/oppi/main/install.sh | sh -s -- --version 0.53.0
```

| Option | Effect |
|---|---|
| `--version <x.y.z>` | Install that `oppi-server` version instead of the latest. |
| `--no-service` | Skip the LaunchAgent or systemd unit and start `oppi serve` in the background. It does not start again after a reboot. |
| `--non-interactive` | Never prompt. Without it, the installer asks before it edits your shell profile. |

If you already manage Node.js and prefer npm, `npm install -g oppi-server` followed by `oppi server install` gives the same service. To run Oppi from a source checkout, see [server/README.md](../server/README.md).

## Set up from the app over SSH

The app can do the install for you. In Oppi, open **Tailscale → Check a Machine for Oppi** and sign in over SSH to a Mac (Remote Login) or a Linux machine (`sshd`). If Oppi is missing or stopped, **Install & Start** sends the same installer over SSH with `--non-interactive`, then pairs your iPhone.

Oppi runs `oppi pair --json` only after `oppi status` says HTTPS and `https://127.0.0.1:<port>/health` answers, so a stopped server mints no invite. A `*.ts.net` name uses Oppi's Tailscale connection; any other host uses the current network. An unknown or changed SSH host key sends no password.

## Keep it running

`oppi server` manages the background service:

```bash
oppi server status     # installed, running, runtime, data dir
oppi server restart    # after config or runtime changes
oppi server stop
oppi server uninstall
```

- **macOS:** the LaunchAgent `dev.chaosdonkey.oppi` starts Oppi at login and restarts it after a crash. Logs go to `~/.config/oppi/server.log`.
- **Linux:** the systemd user service `~/.config/systemd/user/oppi.service` restarts Oppi after a crash. Logs: `journalctl --user -u oppi`. To keep Oppi running after you log out and start it at boot, the installer turns on lingering with `loginctl enable-linger`. If your system needs an admin for that, the installer says so; until someone runs `sudo loginctl enable-linger <user>`, Oppi stops when your last session ends.
- **No systemd** (most containers, WSL without systemd): the installer starts `oppi serve` in the background and logs to `~/.oppi/serve.log`. Run `oppi serve` under your own supervisor to keep it running.

## Connect a model provider

Oppi runs sessions with [Pi](https://github.com/badlogic/pi-mono), so it needs Pi credentials on the server.

- **In the app:** open **Server Settings → Model Providers**. Sign in with a provider account or enter an API key. The server stores it in Pi's `~/.pi/agent/auth.json`.
- **Already using Pi on this machine:** Oppi uses the same `~/.pi/agent/auth.json`, so providers you signed in to with Pi's `/login` work as they are.
- **Environment variables:** the background service does not read your shell profile, so an `ANTHROPIC_API_KEY` exported there does not reach it. Set it in the server config and restart:

  ```bash
  oppi config set runtimeEnv.ANTHROPIC_API_KEY <key>
  oppi server restart
  ```

  The same works for other Pi provider variables, such as `OPENAI_API_KEY`. The value is stored in plain text in `~/.config/oppi/config.json`.

## Pair a first device

1. Show an invite. The terminal installer prints one when it finishes. Later, with the server running, run:

   ```bash
   oppi pair
   ```

   It prints a pairing QR code and invite link. On its first start, the server picks TLS: if the machine is on Tailscale and `tailscale cert` can issue it a certificate (HTTPS enabled for the tailnet), Oppi uses Tailscale TLS and the invite points at the machine's `*.ts.net` name. Otherwise it uses a self-signed certificate. A `tls.mode` other than `disabled` that you already set is kept.

2. Open Oppi on iPhone and choose **Scan QR Code**, **Connect through Tailscale**, or **Enter manually / Connect to Server** (Host, Port, Token, and Name; it does not paste an invite). Opening an `oppi://connect` invite link also starts pairing.

   **Connect through Tailscale** opens Oppi's in-app Tailscale connection. After you sign in, Oppi lists Mac and Linux machines on your tailnet and can pair with one already running Oppi over Tailscale HTTPS. It does not install the Tailscale VPN.

3. Confirm server trust. If local authentication is enabled, iOS asks for it before accepting the server identity.

4. Oppi opens **Workspaces** at **All Sessions**. If the server has no workspaces, it opens guided **Create Workspace** setup; Oppi creates no starter workspaces.

Next: [Using Oppi](usage.md).

## Reach the server

After pairing, Oppi uses authenticated HTTPS and WSS. The local CLI stays on an owner-only Unix socket. The phone reaches the server one of three ways:

| Network | Works when | Pair with |
|---|---|---|
| Same Wi-Fi | The phone is on the server's local network. | `oppi pair` |
| Tailscale | The phone and the server are on the same tailnet (Oppi's in-app connection or the Tailscale app), from anywhere. | **Connect through Tailscale**, or `oppi pair --host <name>.ts.net` with Tailscale TLS |
| Public HTTPS URL | A reverse proxy you run serves Oppi at a public hostname. | `oppi pair` after setting `publicUrl` ([Reverse proxy](reverse-proxy.md)) |

**macOS firewall:** when the macOS firewall is on, the first start can ask whether `node` may accept incoming network connections. Choose **Allow**, or phones on Wi-Fi and Tailscale cannot connect.

For remote pairing, include the host in the invite. `--host` takes a host or IP only, with no scheme or port; the port comes from `oppi config get port`.

```bash
oppi pair --host <hostname-or-ip>
```

- **Tailscale name (`*.ts.net`):** needs Tailscale TLS, because iOS rejects a self-signed certificate on a Tailscale name. Enable HTTPS certificates for your tailnet, then switch the server to it:

  ```bash
  oppi config set tls.mode tailscale
  oppi server restart
  oppi pair --host <your-host>.ts.net
  ```

  With `self-signed` or `manual` TLS, pair through a LAN host or the server's Tailscale IP; `oppi pair` refuses a `*.ts.net` host in those modes.
- **Reverse proxy:** set `publicUrl` to the phone-facing HTTPS origin and `proxy.trustedPeers` to the proxy's address as Oppi sees it. Invites then advertise that origin and omit the origin TLS pin, and `--host` must not conflict with `publicUrl`. See [Reverse proxy](reverse-proxy.md).
- **Changed listener port:** run `oppi config set port <public-port>`, restart, and create a new invite.

Before pairing, the app probes HTTPS health and then sends exactly one pair request. If a connection error occurs after pairing starts, pairing might have succeeded; request a fresh invite instead of retrying the old one.

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

List and revoke devices from the host with `oppi devices` and `oppi devices revoke <id>`, or from a paired device in **Server Settings → Paired Devices**. Revoking signs the device out at once and closes its open connections. Revoked devices stay in the list with a revoked time. Any paired device can list and revoke any other; there is no per-device permission. Your own device is marked **This device** and has no Revoke button.

## Troubleshooting

**Installer stopped with an error.** The last `oppi-install: error` line names the failing step. `npm` failures leave a log in `~/.oppi/install/npm.log`; a `start_timeout` names where the server log is. Fix the cause and run the installer again.

**Invite expired, used, or pairing result unknown.** Generate a fresh invite with `oppi pair` and pair again. Do not retry a pair request after a lost response.

**Could not reach the server.**

1. On the host, run `oppi status` and `oppi doctor`.
2. Confirm the phone reaches the server the way you paired: a LAN invite does not work from outside that network. For Tailscale or a public hostname, regenerate an invite with `oppi pair --host <hostname-or-ip>`.
3. On macOS, check that the firewall allows incoming connections for `node`.
4. Retry with a fresh invite.

**Secure connection failed.** Generate a fresh invite from the same server and retry. Do not edit invite content by hand.
