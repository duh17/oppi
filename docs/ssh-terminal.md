# SSH Terminal experiment

SSH Terminal opens an interactive shell on one host from iPhone or iPad. It is an opt-in experiment, off by default. It does not run through the Oppi server and does not change Pi session ownership.

## Set up a host

1. Turn on **Settings → Experiments → SSH Terminal**.
2. Open **Settings → Network → SSH Terminal**. Enter a host, port (default 22), and username. The host has no default. Enable Remote Login or `sshd` on that host.
3. Choose **Password** or **This Device’s Key**.
   - **Password:** enter the password at connect. **Save Password** is optional.
   - **This Device’s Key:** copy the public key and add it as one line to `~/.ssh/authorized_keys` on the host. Oppi does not install it for you.
4. Tap **Connect**. Compare the displayed host-key fingerprint with the host’s fingerprint through an independent, trusted channel. Trust it only after they match. Oppi sends no credentials before host-key validation succeeds.

For example, on a Mac with an Ed25519 host key:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

After you save a host, **Terminal** appears directly below **MCP Servers** in the workspace sidebar. Tap it to open the host page, then tap **Connect**; opening the page never dials or asks for Face ID. **Edit Host** returns to setup. Turning the experiment off hides both entry points and does not create a key. **Tailscale → Check a Mac** remains available independently.

## Run on Connect

**Run on Connect** runs one command in the terminal instead of a login shell. This is the same exec-with-TTY request as `ssh -t host 'command'` or OpenSSH `RemoteCommand` with `RequestTTY yes`. Enter `herdr` to attach your Herdr session, or `tmux new -A -s main` for tmux. The connection ends when the command exits and the status names the command; **Reconnect** runs it again. The command must be on the `PATH` that non-interactive SSH commands see. Leave it empty for a normal login shell.

## Touch and keyboard

- Tap the terminal to hide the keyboard. With the keyboard hidden, a tap shows it again, unless the app asked for mouse input.
- When an app asks for mouse input (Herdr, tmux with `mouse on`, many TUIs), a tap with the keyboard hidden is a click at that cell, and dragging sends scroll-wheel steps to the app. The keyboard button in the navigation bar shows the keyboard.
- Otherwise, dragging reads local history; **Back to Live** returns to the bottom.

## Herdr

When `herdr` is on the host, the terminal checks Herdr's API (`herdr api snapshot`) every few seconds over the same SSH connection, in a separate command channel. A grid button appears in the navigation bar, with a count of agents waiting at an approval or question prompt. It opens a list of workspaces and agents showing whether each is working, needs you, done, or idle. Tapping a row runs `herdr workspace focus` or `herdr agent focus` on the host. Hosts without `herdr` are checked once per connection and then left alone.

## Credentials and host trust

- Profile metadata (host, port, username, and sign-in choice) is stored in app preferences. Passwords are never stored there or logged.
- An unsaved password is used for one connection attempt. Reconnect asks for it again.
- A saved password is in the app’s private Keychain, not the app group. It does not sync or migrate to another device. A device passcode is required to save it; reading it at connect requires Face ID, Touch ID, or device-passcode approval.
- On a physical device, the per-device P-256 SSH key is in the Secure Enclave. Signing requires user presence. The simulator uses an explicitly labelled software key. Selecting password sign-in does not create a key.
- Trusted host keys are stored in the app-private, this-device-only Keychain, shared by SSH Terminal and Check a Mac. A changed host key blocks sign-in. **Forget Trusted Key** requires confirmation; independently verify why it changed before trusting its replacement.
- **Delete Host** deletes the profile and saved password. It does not remove the per-device key or trusted host keys.

## Network and reconnect

When Oppi’s in-app Tailscale node is running, `*.ts.net` hosts use that node. Other hosts use direct TCP through your current network, including a system Tailscale VPN if active.

Oppi checks SSH round-trip liveness every 60 seconds by opening and closing an empty session channel, with a 15-second reply timeout. It requests no shell, command, or PTY on that probe. Direct TCP also uses kernel keepalive probes. Failure closes the connection and shows **Disconnected** with **Reconnect**.

Entering the background disconnects the shell. On return, tap **Reconnect**. A Wi-Fi or cellular path change shows a warning and offers the same action. Reconnect always opens a fresh shell; it does not replay input. Use `tmux` on the host if work must survive a disconnect.

## Limits

- One host profile. No private-key import, keyboard-interactive, or forwarding.
- The SSH library supports Ed25519/ECDSA host and user keys, Curve25519/ECDH key exchange, and AES-GCM encryption. RSA-only and legacy-only servers fail with an unsupported-algorithm error. A server that offers only keyboard-interactive cannot accept password sign-in here.
- Connection, authentication, and terminal-opening waits are bounded. A rejected credential, changed host key, unreachable host, or unsupported algorithm produces a visible error.
- Secure Enclave and biometric approval need physical-device testing. A simulator software key is not evidence of hardware protection.
