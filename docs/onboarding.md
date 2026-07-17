# Onboarding and Pairing

Install the server with npm first:

```bash
npm install -g oppi-server
```

Use `oppi ...` commands for normal installs. Source checkouts can use `node dist/src/cli.js ...` from `server/`.

## First device

1. Start the server:

   ```bash
   oppi serve
   ```

   On first run, Oppi shows:
   - pairing QR code
   - invite link

2. Open Oppi on iPhone.

3. In onboarding, choose one:
   - **Pair Nearby Mac**: discover a Mac already showing Oppi pairing.
   - **Scan QR Code**: scan the QR code printed by the server.
   - **Enter manually** or **Connect to Server**: enter scheme, host, port, token, and display name.

   Opening an `oppi://connect` invite link on the phone also starts pairing.

4. Confirm server trust. If **Require Face ID/Touch ID/Optic ID/Passcode** is enabled, iOS asks for local authentication before accepting the server identity.

5. Oppi opens **Workspaces** at **All Sessions**.

6. If the server has no workspaces, Oppi opens guided **Create Workspace** setup.

Notes:

- Oppi does not auto-create starter workspaces for you.
- The guided create flow lets you pick a project, enter a path manually, or start with a blank workspace.
- Manual connection keeps **Connect** disabled until host and token are filled. If the port is invalid, Oppi uses `7749`.

For host-free pairing and app traffic, start the server in Iroh-only mode:

```bash
OPPI_IROH_TRANSPORT=1 OPPI_IROH_INVITE_MODE=irohOnly oppi serve
```

The signed invite identifies the Iroh endpoint instead of an Oppi host and port. The app uses the same REST, file, media, focused-session, app-event, and dictation behavior through the Iroh tunnel. Iroh-only pairing and connection failures do not fall back to HTTP.

For remote HTTP/TLS pairing (for example Tailscale or a VPS), generate an invite with an explicit host:

```bash
oppi pair --host <hostname-or-ip>
```

Host override notes:

- `--host` must be host/IP only (no `https://`, no `:port`).
- Invite port comes from server config:

  ```bash
  oppi config get port
  ```

- If clients must connect on a different port, set it first, restart `serve`, then generate a fresh invite:

  ```bash
  oppi config set port <public-port>
  ```

## Additional devices

1. Generate a new invite:

   ```bash
   oppi pair
   ```

2. On the new phone, use **Pair Nearby Mac**, scan the QR code, enter details manually, or open the invite link.

## Invite rules

- Invite is single-use.
- Invite expires after 90 seconds by default.
- Invite includes server identity and transport details.
- Deep-link format details live in [Deep links](deeplinks.md).

## Troubleshooting

### Invite expired or already used

1. Generate a new invite:

   ```bash
   oppi pair
   ```

2. Retry pairing immediately.

### Could not reach server

1. For Iroh, confirm the invite advertises `oppi/http/1`, the server log reports `iroh_transport.started`, and the device can reach the configured Iroh address-lookup or relay infrastructure. Generate a fresh invite if its ticket is stale.

2. For HTTP/TLS, confirm phone-to-server connectivity through LAN, Tailscale, or public DNS.

3. Check server health and config:

   ```bash
   oppi status
   oppi doctor
   ```

4. For HTTP/TLS, regenerate the invite with an explicit host:

   ```bash
   oppi pair --host <hostname-or-ip>
   ```

5. Retry pairing.

### Secure connection failed

1. Generate a fresh invite from the same server.

2. Retry pairing.

3. Do not edit invite content manually.
